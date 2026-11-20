<#
.SYNOPSIS
    ask — l'assistant IA du terminal (Claude) : questions, commandes, analyse de sorties.
.DESCRIPTION
    Envoie la question à l'API Claude d'Anthropic et affiche la réponse au fil de l'eau.
    Nécessite une clé d'API (variable ANTHROPIC_API_KEY, ou « ask -Setup »).
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
    [string]$Model,
    [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max')][string]$Effort = '',
    [switch]$Setup,
    [switch]$Status,
    [switch]$Help
)

$piped = @($input)
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg $Prompt)) {
    Show-PstHelp -Name 'ask' -Synopsis 'Posez une question à Claude sans quitter le terminal.' `
        -Usage @(
            'ask <question>                  réponse affichée au fil de l''eau',
            'ask -Cmd <ce que vous voulez>   propose une commande PowerShell, à exécuter ou copier',
            '<commande> | ask <question>     analyse une sortie, un journal, un fichier',
            'ask -Setup                      enregistre la clé d''API et les préférences'
        ) `
        -Options @(
            @('-Cmd', 'Demande une commande prête à l''emploi (confirmation avant exécution)'),
            @('-Raw', 'Avec -Cmd : affiche seulement la commande (scripts, raccourci Alt+A)'),
            @('-Model <id>', 'Modèle Claude (défaut : claude-opus-5-5)'),
            @('-Effort <niveau>', 'low (défaut, rapide), medium, high, xhigh, max'),
            @('-Status', 'Affiche la configuration actuelle'),
            @('-Setup', 'Configuration interactive')
        ) `
        -Examples @(
            'ask "différence entre Get-ChildItem -Recurse et -Depth ?"',
            'ask -Cmd "les 10 plus gros fichiers de ce dossier"',
            'Get-Content .\erreur.log -Tail 80 | ask "que s''est-il passé ?"',
            'git diff | ask "rédige un message de commit"'
        ) `
        -Notes @('Clé d''API : https://platform.claude.com/ (variable ANTHROPIC_API_KEY ou « ask -Setup »).',
            'Avec l''intégration au shell : Alt+A transforme la ligne tapée en commande, « fix » explique la dernière erreur.')
    exit 0
}

# ── Configuration ────────────────────────────────────────────────────────────

$configFile = Join-Path (Get-PstDataDir) 'ask.json'
$defaultModel = 'claude-opus-5-5'
$defaultEffort = 'low'

function Get-AskConfig {
    $config = @{ Model = $defaultModel; Effort = $defaultEffort; Key = '' }
    if (Test-Path -LiteralPath $configFile) {
        try {
            $saved = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.Model) { $config.Model = [string]$saved.Model }
            if ($saved.Effort) { $config.Effort = [string]$saved.Effort }
            if ($saved.Key) { $config.Key = [string]$saved.Key }
        }
        catch { $null = $_ }
    }
    return $config
}

function Get-ApiKey {
    # La variable d'environnement prime ; sinon la clé enregistrée, chiffrée pour ce compte Windows.
    param($Config)
    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }
    if (-not $Config.Key) { return $null }
    try {
        $secure = ConvertTo-SecureString -String $Config.Key -ErrorAction Stop
        return (New-Object System.Net.NetworkCredential '', $secure).Password
    }
    catch { return $null }
}

function Save-AskConfig {
    param($Config)
    $json = [ordered]@{ Model = $Config.Model; Effort = $Config.Effort; Key = $Config.Key } | ConvertTo-Json
    [IO.File]::WriteAllText($configFile, $json, (New-Object Text.UTF8Encoding $false))
}

$config = Get-AskConfig

if ($Status) {
    Show-PstHeader -Tool 'ask' -Subtitle 'configuration'
    $source = 'aucune'
    if ($env:ANTHROPIC_API_KEY) { $source = 'variable ANTHROPIC_API_KEY' } elseif ($config.Key) { $source = 'enregistrée (chiffrée pour votre compte)' }
    if ($source -eq 'aucune') { Write-PstStatus warn 'Clé d''API : aucune — lancez « ask -Setup »' } else { Write-PstStatus ok "Clé d'API : $source" }
    Write-PstStatus info "Modèle : $($config.Model)"
    Write-PstStatus info "Effort : $($config.Effort)"
    Write-Host ''
    exit 0
}

if ($Setup) {
    Show-PstHeader -Tool 'ask' -Subtitle 'configuration'
    if (-not (Test-PstInteractive)) { Write-PstStatus err 'La configuration demande un terminal interactif.'; exit 1 }
    Write-Host '  Créez une clé sur https://platform.claude.com/ puis collez-la ici (la saisie reste masquée).'
    Write-Host (Paint '  Entrée seule : conserver la clé actuelle.' 'Dim')
    $secure = Read-Host '  Clé d''API' -AsSecureString
    if ($secure.Length -gt 0) {
        if ($script:Pst.IsWindows) {
            $config.Key = ConvertFrom-SecureString -SecureString $secure
            Write-PstStatus ok 'Clé enregistrée, chiffrée pour votre compte Windows.'
        }
        else { Write-PstStatus warn 'Hors Windows, la clé n''est pas enregistrée : définissez ANTHROPIC_API_KEY.' }
    }
    Write-Host ''
    $models = @('claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-2')
    $labels = @('claude-opus-5-5    (recommandé)', 'claude-sonnet-5-5  (plus économique)', 'claude-haiku-5-5   (le plus rapide)', 'claude-fable-5-2   (le plus capable)')
    $pick = Read-PstChoice -Title 'Modèle par défaut' -Items $labels -Default ([Math]::Max(0, [array]::IndexOf($models, $config.Model)))
    if ($pick -ge 0) { $config.Model = $models[$pick] }
    Write-Host ''
    $efforts = @('low', 'medium', 'high')
    $pick = Read-PstChoice -Title 'Niveau de réflexion' -Items @('low     réponses rapides (recommandé au terminal)', 'medium  équilibré', 'high    questions difficiles') -Default ([Math]::Max(0, [array]::IndexOf($efforts, $config.Effort)))
    if ($pick -ge 0) { $config.Effort = $efforts[$pick] }
    Save-AskConfig $config
    Write-Host ''
    Write-PstStatus ok 'Configuration enregistrée. Essayez : ask "bonjour"'
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

$apiKey = Get-ApiKey $config
if (-not $apiKey) {
    Write-PstStatus err 'Aucune clé d''API Claude configurée.'
    Write-PstStatus info 'Lancez « ask -Setup », ou définissez la variable ANTHROPIC_API_KEY.'
    exit 1
}
if ($Model) { $config.Model = $Model }
if ($Effort) { $config.Effort = $Effort }

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

$body = [ordered]@{
    model         = $config.Model
    max_tokens    = 16000
    stream        = $true
    system        = $system
    output_config = @{ effort = $config.Effort }
    messages      = @(@{ role = 'user'; content = $userText })
}
# Repli automatique côté serveur si le modèle décline la demande (modèles qui le prennent en charge).
$useFallback = ($config.Model -match '^claude-(opus-5|fable-5|sonnet-5-5)')
if ($useFallback) { $body.fallbacks = 'default' }
$json = $body | ConvertTo-Json -Depth 6

# ── Appel en flux (SSE) ──────────────────────────────────────────────────────

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }

$baseUrl = 'https://api.anthropic.com'
if ($env:ANTHROPIC_BASE_URL) { $baseUrl = $env:ANTHROPIC_BASE_URL.TrimEnd('/') }
$live = -not $Cmd
$script:waiting = $false

function Invoke-ClaudeStream {
    # Retourne @{ Text; StopReason; Error; Status }.
    $result = @{ Text = ''; StopReason = ''; Error = ''; Status = 0 }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "$baseUrl/v1/messages"
    $request.Headers.Add('x-api-key', $apiKey)
    $request.Headers.Add('anthropic-version', '2026-10-21')
    if ($useFallback) { $request.Headers.Add('anthropic-beta', 'server-side-fallback-2026-07-01') }
    $request.Content = New-Object System.Net.Http.StringContent $json, ([Text.Encoding]::UTF8), 'application/json'
    $response = $null
    $reader = $null
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $result.Status = [int]$response.StatusCode
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object IO.StreamReader $stream, ([Text.Encoding]::UTF8)
        if (-not $response.IsSuccessStatusCode) {
            $raw = $reader.ReadToEnd()
            try { $result.Error = [string]($raw | ConvertFrom-Json).error.message } catch { $result.Error = $raw }
            if (-not $result.Error) { $result.Error = "HTTP $($result.Status)" }
            return $result
        }
        $text = New-Object System.Text.StringBuilder
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.StartsWith('data:')) { continue }
            $payload = $line.Substring(5).Trim()
            if (-not $payload) { continue }
            try { $evt = $payload | ConvertFrom-Json } catch { continue }
            switch ([string]$evt.type) {
                'content_block_delta' {
                    if ($evt.delta.type -eq 'text_delta') {
                        $chunk = [string]$evt.delta.text
                        [void]$text.Append($chunk)
                        if ($live) {
                            if ($script:waiting) { Clear-Waiting }
                            Write-Host $chunk -NoNewline
                        }
                    }
                }
                'message_delta' { if ($evt.delta.stop_reason) { $result.StopReason = [string]$evt.delta.stop_reason } }
                'error' { $result.Error = [string]$evt.error.message }
            }
        }
        $result.Text = $text.ToString()
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $result.Error = $inner.Message
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
    return $result
}

function Show-Waiting {
    if (-not $script:Pst.Ansi -or $Raw) { return }
    Write-Host ("  " + (Paint "$($g.Info) Claude réfléchit..." 'Dim')) -NoNewline
    $script:waiting = $true
}
function Clear-Waiting {
    if ($script:waiting) { Write-Host "`r$($script:Pst.Esc)[K" -NoNewline }
    $script:waiting = $false
}

if (-not $Raw) { Show-PstHeader -Tool 'ask' -Subtitle $config.Model }

$answer = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Show-Waiting
    $answer = Invoke-ClaudeStream
    Clear-Waiting
    # Nouvel essai uniquement sur les erreurs passagères, et seulement si rien n'a encore été affiché.
    $transient = (@(408, 429, 500, 502, 503, 504, 529) -contains $answer.Status)
    if (-not $answer.Error -or -not $transient -or $answer.Text -or $attempt -eq 3) { break }
    Start-Sleep -Seconds (2 * $attempt)
}

if ($answer.Error) {
    if ($live -and $answer.Text) { Write-Host '' }
    switch ($answer.Status) {
        401 { Write-PstStatus err 'Clé d''API refusée. Vérifiez-la avec « ask -Setup ».' }
        403 { Write-PstStatus err "Accès refusé : $($answer.Error)" }
        404 { Write-PstStatus err "Modèle introuvable : $($config.Model). Choisissez-en un autre avec « ask -Setup »." }
        429 { Write-PstStatus err 'Limite de requêtes atteinte. Réessayez dans un instant.' }
        default {
            if ($answer.Status -ge 500) { Write-PstStatus err "Le service Claude est momentanément indisponible ($($answer.Status)). Réessayez dans un instant." }
            elseif ($answer.Status -eq 0) { Write-PstStatus err "Connexion impossible : $($answer.Error)" }
            else { Write-PstStatus err "Requête refusée ($($answer.Status)) : $($answer.Error)" }
        }
    }
    exit 1
}
if ($answer.StopReason -eq 'refusal') {
    if ($live -and $answer.Text) { Write-Host '' }
    Write-PstStatus warn 'Claude a décliné cette demande.'
    exit 1
}

if (-not $Cmd) {
    Write-Host ''
    if ($answer.StopReason -eq 'max_tokens') { Write-PstStatus warn 'Réponse interrompue : longueur maximale atteinte.' }
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
