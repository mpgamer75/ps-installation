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
Import-PstStrings 'ask'
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg $Prompt)) {
    Show-PstHelp -Name 'ask' -Synopsis (L 'Posez une question à l''IA de votre choix sans quitter le terminal.') `
        -Usage @(
            (L 'ask <question>                  réponse affichée au fil de l''eau'),
            (L 'ask -Cmd <ce que vous voulez>   propose une commande PowerShell, à exécuter ou copier'),
            (L '<commande> | ask <question>     analyse une sortie, un journal, un fichier'),
            (L 'ask -Usage                      jetons consommés, coût, budget'),
            (L 'ask -Setup                      fournisseur, clé d''API, modèle, budget')
        ) `
        -Options @(
            @('-Cmd', (L 'Demande une commande prête à l''emploi (confirmation avant exécution)')),
            @('-Raw', (L 'Avec -Cmd : affiche seulement la commande (scripts, raccourci Alt+A)')),
            @('-Provider <id>', (L 'Fournisseur pour cette question : anthropic, openai, gemini, mistral, groq, deepseek, xai, openrouter, ollama, custom')),
            @('-Model <id>', (L 'Modèle pour cette question')),
            @((L '-Effort <niveau>'), (L 'Réflexion : low (défaut, rapide), medium, high, xhigh, max')),
            @('-Usage', (L 'Tableau de bord de consommation')),
            @('-Status', (L 'Configuration actuelle')),
            @('-Setup', (L 'Configuration guidée'))
        ) `
        -Examples @(
            (L 'ask "différence entre Get-ChildItem -Recurse et -Depth ?"'),
            (L 'ask -Cmd "les 10 plus gros fichiers de ce dossier"'),
            (L 'Get-Content .\erreur.log -Tail 80 | ask "que s''est-il passé ?"'),
            (L 'git diff | ask -Provider openai "rédige un message de commit"')
        ) `
        -Notes @((L 'Avec l''intégration au shell : Alt+A transforme la ligne tapée en commande, « fix » explique la dernière erreur.'))
    exit 0
}

if ($Usage) { Show-PstAiUsage; exit 0 }

if ($Setup) {
    . (Join-Path $libDir 'PsTools.Wizard.ps1')
    if (-not (Test-PstInteractive)) { Write-PstStatus err (L 'La configuration demande un terminal interactif.'); exit 1 }
    Invoke-PstSetupMenu -AppRoot (Split-Path -Parent $PSScriptRoot) -Section 'ai'
    exit 0
}

$settings = Get-PstAiSettings
if ($Provider) {
    if (-not (Get-PstAiProvider $Provider)) { Write-PstStatus err (L 'Fournisseur inconnu : « {0} » {1} voir « ask -Help »' $Provider $g.Dot); exit 1 }
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
    Show-PstHeader -Tool 'ask' -Subtitle (L 'configuration')
    $keyText = $key.Source
    if (-not $key.Key) { $keyText = if ($providerInfo.KeyRequired) { Paint (L 'aucune (ask -Setup)') 'Warn' } else { L 'non requise' } }
    $price = Get-PstAiPrice $settings.Provider $settings.Model
    $priceText = L 'inconnu'
    if ($price.Free) { $priceText = L 'gratuit (local)' }
    elseif ($price.Known) { $priceText = L '{0} / {1} par million de jetons (entrée / sortie)' (Format-PstMoney $price.In) (Format-PstMoney $price.Out) }
    $budgetText = L 'aucun'
    if ($settings.Budget -gt 0) { $budgetText = L '{0} utilisés sur {1} ce mois-ci' (Format-PstMoney (Get-PstAiMonthCost)) (Format-PstMoney $settings.Budget) }
    $lines = @(
        ((Paint (Format-PstPad (L 'Fournisseur') 13) 'Accent') + $providerInfo.Label),
        ((Paint (Format-PstPad (L 'Modèle') 13) 'Accent') + $settings.Model),
        ((Paint (Format-PstPad (L 'Clé') 13) 'Accent') + $keyText),
        ((Paint (Format-PstPad (L 'Tarif') 13) 'Accent') + $priceText),
        ((Paint (Format-PstPad (L 'Budget') 13) 'Accent') + $budgetText),
        ((Paint (Format-PstPad (L 'Réflexion') 13) 'Accent') + $settings.Effort)
    )
    if ($providerInfo.Custom -or $settings.Provider -eq 'ollama') { $lines += (Paint (Format-PstPad (L 'Adresse') 13) 'Accent') + $settings.BaseUrl }
    Format-PstBox -Lines $lines | Write-PstLine
    Write-Host ''
    exit 0
}

# ── Préparation de la requête ────────────────────────────────────────────────

$question = (@($Prompt) -join ' ').Trim()
$context = (@($piped | ForEach-Object { [string]$_ }) -join "`n").Trim()
if (-not $question -and -not $context) {
    Write-PstStatus err (L 'Posez une question : ask "comment faire ... ?"  (aide : ask -Help)')
    exit 1
}
$maxContext = 400000
if ($context.Length -gt $maxContext) {
    Write-PstStatus err (L 'Le texte reçu par le pipeline est trop long ({0:N0} caractères, maximum {1:N0}).' $context.Length $maxContext)
    Write-PstStatus info (L 'Réduisez-le avant de l''envoyer, par exemple : ... | Select-Object -Last 500 | ask "..."')
    exit 1
}
if (-not $key.Key -and $providerInfo.KeyRequired) {
    Write-PstStatus err (L 'Aucune clé d''API {0} configurée.' $providerInfo.Label)
    if ($providerInfo.EnvVar) { Write-PstStatus info (L 'Lancez « ask -Setup » (ou « pst setup »), ou définissez la variable {0}.' $providerInfo.EnvVar) }
    else { Write-PstStatus info (L 'Lancez « ask -Setup » (ou « pst setup »).') }
    exit 1
}
if (-not $settings.BaseUrl) { Write-PstStatus err (L 'Adresse du service non configurée : lancez « ask -Setup ».'); exit 1 }
if (-not $settings.Model) { Write-PstStatus err (L 'Aucun modèle choisi pour {0} : ask -Model <identifiant>, ou « ask -Setup ».' $providerInfo.Label); exit 1 }

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
if ($script:Pst.Lang -eq 'en') {
    # Consigne en anglais pour l'interface anglaise ; le modèle répond toujours dans la langue de la question.
    $rights = 'standard user (no administrator rights)'
    if (Test-PstAdmin) { $rights = 'administrator' }
    $system = @"
You are the assistant built into the user's terminal, through the "ask" command of ps-tools.

Environment: $osName, PowerShell $($PSVersionTable.PSVersion), current folder "$((Get-Location).Path)", $rights session.

Your answers are printed as-is in a console: write plain text, short and direct, without Markdown headings or tables. Put commands on their own line, indented by four spaces, so they are easy to copy. Prefer PowerShell and the tools available on Windows; if a command needs administrator rights or changes the system in a way that is hard to undo, say so in one sentence. Answer in the language of the question.
"@
    if ($Cmd) {
        $system += "`n`nThe user wants a command to run. Reply with the PowerShell command only, on a single line, with no explanation, no code fence and no quotes around it. It must work as-is in the environment described. If the request is impossible or too ambiguous to choose, reply with a single line starting with `"#`" that explains why."
    }
}

$userText = $question
if ($context) {
    if (-not $question) { $question = L 'Analyse ce texte et dis-moi l''essentiel.' }
    $userText = "$question`n`n<entree>`n$context`n</entree>"
}

# ── Appel ────────────────────────────────────────────────────────────────────

$live = -not $Cmd
$script:waiting = $false
if (-not $Raw) { Show-PstHeader -Tool 'ask' -Subtitle "$($providerInfo.Label) $($g.Dot) $($settings.Model)" }
if ($script:Pst.Ansi -and -not $Raw) {
    Write-Host ("  " + (Paint "$($g.Info) $(L 'Réflexion en cours...')" 'Dim')) -NoNewline
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
    Write-PstStatus warn (L 'Le modèle a décliné cette demande.')
    exit 1
}

if (-not $Cmd) {
    Write-Host ''
    if ($answer.StopReason -eq 'max_tokens') { Write-PstStatus warn (L 'Réponse interrompue : longueur maximale atteinte.') }
    Write-Host ''
    Write-Host ('  ' + (Format-PstAiFooter $answer $settings.Budget))
    if ($settings.Budget -gt 0 -and (Get-PstAiMonthCost) -ge $settings.Budget) { Write-PstStatus warn (L 'Budget mensuel dépassé (ask -Usage pour le détail).') }
    Write-Host ''
    exit 0
}

# ── Mode commande ────────────────────────────────────────────────────────────

$command = $answer.Text.Trim()
$command = ($command -replace '^```[a-zA-Z]*\s*', '' -replace '\s*```$', '').Trim()
$command = (@($command -split "`r?`n" | Where-Object { $_.Trim() }) -join '; ')
if ($Raw) { Write-Output $command; exit 0 }

if (-not $command) { Write-PstStatus warn (L 'Aucune commande proposée.'); exit 1 }
if ($command.StartsWith('#')) { Write-PstStatus warn $command.TrimStart('#').Trim(); Write-Host ''; exit 1 }

Format-PstBox -Title (L 'Commande proposée') -Lines @(Paint $command 'Ok' -Bold) -Color 'Accent' | Write-PstLine
Write-Host ('  ' + (Format-PstAiFooter $answer $settings.Budget))
Write-Host ''
if (-not (Test-PstInteractive)) { exit 0 }

$choice = Read-PstChoice -Title (L 'Que faire ?') -Items @((L 'Exécuter'), (L 'Copier dans le presse-papiers'), (L 'Annuler')) -Default 2
Write-Host ''
switch ($choice) {
    0 {
        Write-Host (Paint "  $($g.Pointer) $command" 'Dim')
        Write-Host ''
        try { & ([scriptblock]::Create($command)) | Out-Host }
        catch { Write-PstStatus err $_.Exception.Message; exit 1 }
    }
    1 {
        try { Set-Clipboard -Value $command; Write-PstStatus ok (L 'Copiée : collez-la avec Ctrl+V.') }
        catch { Write-PstStatus warn (L 'Presse-papiers indisponible : {0}' $_.Exception.Message) }
    }
    default { Write-PstStatus info (L 'Annulé.') }
}
Write-Host ''
