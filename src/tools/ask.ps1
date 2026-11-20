<#
.SYNOPSIS
    ask — l'assistant IA du terminal : questions, commandes, analyse de sorties.
.DESCRIPTION
    Fonctionne avec l'IA de votre choix et votre propre clé d'API : Anthropic Claude,
    OpenAI, Google Gemini, Mistral, Groq, DeepSeek, xAI, OpenRouter, Ollama (local)
    ou tout service compatible OpenAI. Chaque réponse indique les jetons consommés
    et le coût ; « ask -Usage » affiche le bilan et le budget.
    Rien n'est envoyé tant que vous ne lancez pas la commande ; seuls la question,
    le texte éventuellement passé par le pipeline et un court contexte (version de
    Windows et de PowerShell, dossier courant) quittent la machine.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Prompt,
    # Reçoit le pipeline ; l'ensemble des lignes est lu plus bas via `$input.
    [Parameter(ValueFromPipeline = $true)][object]$InputObject,
    [switch]$Cmd,
    [switch]$Raw,
    [string]$Provider,
    [string]$Model,
    [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max')][string]$Effort = '',
    [switch]$Setup,
    [switch]$Status,
    [switch]$Usage,
    [switch]$Help
)

$piped = @($input)
$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'PsTools.ps1')
. (Join-Path $libDir 'PsTools.AI.ps1')
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg $Prompt)) {
    Show-PstHelp -Name 'ask' -Synopsis 'Posez une question à l''IA de votre choix sans quitter le terminal.' `
        -Usage @(
            'ask <question>                  réponse affichée au fil de l''eau',
            'ask -Cmd <ce que vous voulez>   propose une commande PowerShell, à exécuter ou copier',
            '<commande> | ask <question>     analyse une sortie, un journal, un fichier',
            'ask -Usage                      jetons consommés, coût, budget',
            'ask -Setup                      fournisseur, clé d''API, modèle, budget'
        ) `
        -Options @(
            @('-Cmd', 'Demande une commande prête à l''emploi (confirmation avant exécution)'),
            @('-Raw', 'Avec -Cmd : affiche seulement la commande (scripts, raccourci Alt+A)'),
            @('-Provider <id>', 'Fournisseur pour cette question : anthropic, openai, gemini, mistral, groq, deepseek, xai, openrouter, ollama, custom'),
            @('-Model <id>', 'Modèle pour cette question'),
            @('-Effort <niveau>', 'Réflexion : low (défaut, rapide), medium, high, xhigh, max'),
            @('-Usage', 'Tableau de bord de consommation'),
            @('-Status', 'Configuration actuelle'),
            @('-Setup', 'Configuration guidée')
        ) `
        -Examples @(
            'ask "différence entre Get-ChildItem -Recurse et -Depth ?"',
            'ask -Cmd "les 10 plus gros fichiers de ce dossier"',
            'Get-Content .\erreur.log -Tail 80 | ask "que s''est-il passé ?"',
            'git diff | ask -Provider openai "rédige un message de commit"'
        ) `
        -Notes @('Avec l''intégration au shell : Alt+A transforme la ligne tapée en commande, « fix » explique la dernière erreur.')
    exit 0
}

if ($Usage) { Show-PstAiUsage; exit 0 }

if ($Setup) {
    . (Join-Path $libDir 'PsTools.Wizard.ps1')
    if (-not (Test-PstInteractive)) { Write-PstStatus err 'La configuration demande un terminal interactif.'; exit 1 }
    Invoke-PstSetupMenu -AppRoot (Split-Path -Parent $PSScriptRoot) -Section 'ai'
    exit 0
}

$settings = Get-PstAiSettings
if ($Provider) {
    if (-not (Get-PstAiProvider $Provider)) { Write-PstStatus err "Fournisseur inconnu : « $Provider » $($g.Dot) voir « ask -Help »"; exit 1 }
    if ($Provider -ne $settings.Provider) {
        $settings.Provider = $Provider
        $settings.Model = (Get-PstAiProvider $Provider).Default
        $settings.BaseUrl = [string](Get-PstAiProvider $Provider).BaseUrl
    }
}
if ($Model) { $settings.Model = $Model }
if ($Effort) { $settings.Effort = $Effort }
if ($env:ANTHROPIC_BASE_URL -and $settings.Provider -eq 'anthropic') { $settings.BaseUrl = $env:ANTHROPIC_BASE_URL.TrimEnd('/') }
$providerInfo = Get-PstAiProvider $settings.Provider
$key = Get-PstAiKey $settings.Provider

if ($Status) {
    Show-PstHeader -Tool 'ask' -Subtitle 'configuration'
    $keyText = $key.Source
    if (-not $key.Key) { $keyText = if ($providerInfo.KeyRequired) { Paint 'aucune (ask -Setup)' 'Warn' } else { 'non requise' } }
    $price = Get-PstAiPrice $settings.Provider $settings.Model
    $priceText = 'inconnu'
    if ($price.Free) { $priceText = 'gratuit (local)' }
    elseif ($price.Known) { $priceText = '{0} / {1} par million de jetons (entrée / sortie)' -f (Format-PstMoney $price.In), (Format-PstMoney $price.Out) }
    $budgetText = 'aucun'
    if ($settings.Budget -gt 0) { $budgetText = "$(Format-PstMoney (Get-PstAiMonthCost)) utilisés sur $(Format-PstMoney $settings.Budget) ce mois-ci" }
    $lines = @(
        ((Paint (Format-PstPad 'Fournisseur' 13) 'Accent') + $providerInfo.Label),
        ((Paint (Format-PstPad 'Modèle' 13) 'Accent') + $settings.Model),
        ((Paint (Format-PstPad 'Clé' 13) 'Accent') + $keyText),
        ((Paint (Format-PstPad 'Tarif' 13) 'Accent') + $priceText),
        ((Paint (Format-PstPad 'Budget' 13) 'Accent') + $budgetText),
        ((Paint (Format-PstPad 'Réflexion' 13) 'Accent') + $settings.Effort)
    )
    if ($providerInfo.Custom -or $settings.Provider -eq 'ollama') { $lines += (Paint (Format-PstPad 'Adresse' 13) 'Accent') + $settings.BaseUrl }
    Format-PstBox -Lines $lines | Write-PstLine
    Write-Host ''
    exit 0
}

# ── Préparation de la requête ────────────────────────────────────────────────

$question = (@($Prompt) -join ' ').Trim()
$context = (@($piped | ForEach-Object { [string]$_ }) -join "`n").Trim()
if (-not $question -and -not $context) {
    Write-PstStatus err 'Posez une question : ask "comment faire ... ?"  (aide : ask -Help)'
    exit 1
}
$maxContext = 400000
if ($context.Length -gt $maxContext) {
    Write-PstStatus err ("Le texte reçu par le pipeline est trop long ({0:N0} caractères, maximum {1:N0})." -f $context.Length, $maxContext)
    Write-PstStatus info 'Réduisez-le avant de l''envoyer, par exemple : ... | Select-Object -Last 500 | ask "..."'
    exit 1
}
if (-not $key.Key -and $providerInfo.KeyRequired) {
    Write-PstStatus err "Aucune clé d'API $($providerInfo.Label) configurée."
    $hint = 'Lancez « ask -Setup » (ou « pst setup »)'
    if ($providerInfo.EnvVar) { $hint += ", ou définissez la variable $($providerInfo.EnvVar)" }
    Write-PstStatus info "$hint."
    exit 1
}
if (-not $settings.BaseUrl) { Write-PstStatus err 'Adresse du service non configurée : lancez « ask -Setup ».'; exit 1 }
if (-not $settings.Model) { Write-PstStatus err "Aucun modèle choisi pour $($providerInfo.Label) : ask -Model <identifiant>, ou « ask -Setup »."; exit 1 }

$osName = 'Windows'
if (-not $script:Pst.IsWindows) { $osName = [string][Environment]::OSVersion.Platform }
else { try { $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $null = $_ } }
$rights = 'utilisateur standard (sans droits administrateur)'
if (Test-PstAdmin) { $rights = 'administrateur' }

$system = @"
Tu es l'assistant intégré au terminal de l'utilisateur, via la commande « ask » de ps-tools.

Environnement : $osName, PowerShell $($PSVersionTable.PSVersion), dossier courant « $((Get-Location).Path) », session $rights.

Tes réponses s'affichent telles quelles dans une console : écris du texte brut, court et direct, sans titres ni tableaux Markdown. Mets les commandes sur leur propre ligne, indentées de quatre espaces, pour qu'elles se copient facilement. Privilégie PowerShell et les outils présents sur Windows ; si une commande demande des droits administrateur ou modifie le système de façon difficile à annuler, dis-le en une phrase. Réponds dans la langue de la question.
"@
if ($Cmd) {
    $system += "`n`nL'utilisateur veut une commande à exécuter. Réponds uniquement par la commande PowerShell, sur une seule ligne, sans explication, sans balise de code et sans guillemets autour. Elle doit fonctionner telle quelle dans l'environnement décrit. Si la demande est impossible ou ambiguë au point de ne pas pouvoir choisir, réponds par une ligne commençant par « # » qui explique pourquoi."
}

$userText = $question
if ($context) {
    if (-not $question) { $question = 'Analyse ce texte et dis-moi l''essentiel.' }
    $userText = "$question`n`n<entree>`n$context`n</entree>"
}

# ── Appel ────────────────────────────────────────────────────────────────────

$live = -not $Cmd
$script:waiting = $false
if (-not $Raw) { Show-PstHeader -Tool 'ask' -Subtitle "$($providerInfo.Label) $($g.Dot) $($settings.Model)" }
if ($script:Pst.Ansi -and -not $Raw) {
    Write-Host ("  " + (Paint "$($g.Info) Réflexion en cours..." 'Dim')) -NoNewline
    $script:waiting = $true
}
$onText = $null
if ($live) {
    $onText = {
        param($chunk)
        if ($script:waiting) { Write-Host "`r$($script:Pst.Esc)[K" -NoNewline; $script:waiting = $false }
        Write-Host $chunk -NoNewline
    }
}

$answer = Invoke-PstAiRequest -Provider $settings.Provider -Model $settings.Model -Key $key.Key -BaseUrl $settings.BaseUrl `
    -Effort $settings.Effort -System $system -User $userText -OnText $onText
if ($script:waiting) { Write-Host "`r$($script:Pst.Esc)[K" -NoNewline; $script:waiting = $false }

if ($answer.Error) {
    if ($live -and $answer.Text) { Write-Host '' }
    Write-PstStatus err (Get-PstAiErrorHint $answer $settings.Provider)
    exit 1
}
$source = 'ask'
if ($Cmd) { $source = 'cmd' }
Add-PstAiUsage $answer $source

if ($answer.StopReason -eq 'refusal') {
    if ($live -and $answer.Text) { Write-Host '' }
    Write-PstStatus warn 'Le modèle a décliné cette demande.'
    exit 1
}

if (-not $Cmd) {
    Write-Host ''
    if ($answer.StopReason -eq 'max_tokens') { Write-PstStatus warn 'Réponse interrompue : longueur maximale atteinte.' }
    Write-Host ''
    Write-Host ('  ' + (Format-PstAiFooter $answer $settings.Budget))
    if ($settings.Budget -gt 0 -and (Get-PstAiMonthCost) -ge $settings.Budget) { Write-PstStatus warn 'Budget mensuel dépassé (ask -Usage pour le détail).' }
    Write-Host ''
    exit 0
}

# ── Mode commande ────────────────────────────────────────────────────────────

$command = $answer.Text.Trim()
$command = ($command -replace '^```[a-zA-Z]*\s*', '' -replace '\s*```$', '').Trim()
$command = (@($command -split "`r?`n" | Where-Object { $_.Trim() }) -join '; ')
if ($Raw) { Write-Output $command; exit 0 }

if (-not $command) { Write-PstStatus warn 'Aucune commande proposée.'; exit 1 }
if ($command.StartsWith('#')) { Write-PstStatus warn $command.TrimStart('#').Trim(); Write-Host ''; exit 1 }

Format-PstBox -Title 'Commande proposée' -Lines @(Paint $command 'Ok' -Bold) -Color 'Accent' | Write-PstLine
Write-Host ('  ' + (Format-PstAiFooter $answer $settings.Budget))
Write-Host ''
if (-not (Test-PstInteractive)) { exit 0 }

$choice = Read-PstChoice -Title 'Que faire ?' -Items @('Exécuter', 'Copier dans le presse-papiers', 'Annuler') -Default 2
Write-Host ''
switch ($choice) {
    0 {
        Write-Host (Paint "  $($g.Pointer) $command" 'Dim')
        Write-Host ''
        try { & ([scriptblock]::Create($command)) | Out-Host }
        catch { Write-PstStatus err $_.Exception.Message; exit 1 }
    }
    1 {
        try { Set-Clipboard -Value $command; Write-PstStatus ok 'Copiée : collez-la avec Ctrl+V.' }
        catch { Write-PstStatus warn "Presse-papiers indisponible : $($_.Exception.Message)" }
    }
    default { Write-PstStatus info 'Annulé.' }
}
Write-Host ''
