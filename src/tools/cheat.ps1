<#
.SYNOPSIS
    cheat — exemples concrets d'une commande (pages tldr, ou cheat.sh).
.DESCRIPTION
    Affiche la fiche tldr d'une commande (tar, git-rebase, Get-ChildItem...) : description
    et exemples, avec les {{paramètres}} en couleur. En français, la page traduite est
    utilisée quand elle existe, sinon la page anglaise. Les fiches sont gardées dans le
    dossier de données pour un usage hors ligne.
    Hôtes contactés (HTTPS) : raw.githubusercontent.com (tldr), cheat.sh (-Source cheatsh).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [ValidateSet('tldr', 'cheatsh')][string]$Source = 'tldr',
    [ValidateSet('', 'common', 'windows', 'linux', 'osx')][string]$Platform = '',
    [string]$Search,
    [switch]$Update,
    [switch]$Offline,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'cheat'
$ProgressPreference = 'SilentlyContinue'

if ($Help -or (-not $Name -and -not $Search) -or (Test-PstHelpArg (@($Name) + @($Rest)))) {
    Show-PstHelp -Name 'cheat' -Synopsis (L 'Exemples d''utilisation d''une commande, prêts à copier.') `
        -Usage @(
            (L 'cheat <commande>                 fiche tldr (description et exemples)'),
            (L 'cheat <commande> -Source cheatsh fiche cheat.sh (plus détaillée)'),
            (L 'cheat -Search <mot>              cherche dans les fiches déjà consultées')
        ) `
        -Options @(
            @('-Source tldr|cheatsh', (L 'Source des exemples (défaut : tldr)')),
            @((L '-Platform <nom>'), (L 'Page tldr d''une plateforme : common, windows, linux, osx')),
            @('-Update', (L 'Télécharge à nouveau la fiche, même si elle est en cache')),
            @('-Offline', (L 'N''utilise que les fiches en cache, aucune requête réseau')),
            @((L '-Search <mot>'), (L 'Recherche dans les fiches en cache')),
            @('-Json', (L 'Sortie JSON (description et exemples), pour les scripts ou « ask »'))
        ) `
        -Examples @('cheat tar', 'cheat git rebase', 'cheat Get-ChildItem', 'cheat curl -Source cheatsh', 'cheat -Search archive') `
        -Notes @(
            (L 'Sources : raw.githubusercontent.com (pages tldr) et cheat.sh, en HTTPS.'),
            (L 'Fiches en cache dans le dossier de données : elles restent consultables hors ligne.')
        )
    if ($Help -or $Name) { exit 0 } else { exit 1 }
}

$cacheRoot = Join-Path (Get-PstDataDir) 'cheat'
$utf8 = New-Object Text.UTF8Encoding $false
$refreshAge = [TimeSpan]::FromDays(30)

# ── Réseau ───────────────────────────────────────────────────────────────────

function Invoke-HttpText {
    # GET HTTPS court (10 s) ; retourne @{ Ok; Status; Text }.
    param([string]$Url)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -UserAgent "ps-tools/$($script:Pst.Version) (PowerShell; curl-compatible)" -ErrorAction Stop
        return @{ Ok = $true; Status = [int]$r.StatusCode; Text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
    }
    catch {
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $null = $_ }
        return @{ Ok = $false; Status = $status; Text = '' }
    }
}

function Get-HttpErrorText {
    param([string]$HostName, [int]$Status)
    if ($Status -eq 429) { return (L 'Trop de requêtes vers {0} : réessayez dans quelques minutes.' $HostName) }
    if ($Status -eq 0) { return (L 'Connexion impossible à {0} (hors ligne ?).' $HostName) }
    return (L 'Réponse inattendue de {0} (HTTP {1}).' $HostName $Status)
}

# ── Noms et cache ────────────────────────────────────────────────────────────

function ConvertTo-PageName {
    # « git rebase » -> git-rebase ; « Get-ChildItem » -> get-childitem.
    param([string[]]$Words)
    return ((@($Words | Where-Object { $_ }) -join '-').Trim().ToLower() -replace '\s+', '-' -replace '[^a-z0-9.+_\-]', '')
}

function Get-PlatformOrder {
    if ($Platform) { return @($Platform) }
    if ($script:Pst.IsWindows) { return @('windows', 'common', 'linux', 'osx') }
    if ($IsMacOS) { return @('osx', 'common', 'linux', 'windows') }
    return @('linux', 'common', 'windows', 'osx')
}

function Find-CachedPage {
    # Fiche tldr en cache : <nom>.<plateforme>.<langue>.md ; le français d'abord en mode français.
    param([string]$Page)
    $dir = Join-Path $cacheRoot 'tldr'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $langs = @('en')
    if ($script:Pst.Lang -eq 'fr') { $langs = @('fr', 'en') }
    foreach ($lang in $langs) {
        foreach ($p in (Get-PlatformOrder)) {
            $file = Join-Path $dir "$Page.$p.$lang.md"
            if (Test-Path -LiteralPath $file) { return @{ File = $file; Platform = $p; Lang = $lang } }
        }
    }
    return $null
}

function Save-Page {
    param([string]$File, [string]$Text)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($File, $Text, $utf8)
}

function Get-TldrPage {
    # Retourne @{ Text; Platform; Lang; Cached } ou @{ Text = $null; Error }.
    param([string]$Page)
    $cached = Find-CachedPage $Page
    if ($cached -and -not $Update) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cached.File).LastWriteTime
        if ($Offline -or $age -lt $refreshAge) {
            return @{ Text = [IO.File]::ReadAllText($cached.File, [Text.Encoding]::UTF8); Platform = $cached.Platform; Lang = $cached.Lang; Cached = $true }
        }
    }
    if ($Offline) { return @{ Text = $null } }
    $langs = @('en')
    if ($script:Pst.Lang -eq 'fr') { $langs = @('fr', 'en') }
    $lastError = $null
    foreach ($p in (Get-PlatformOrder)) {
        foreach ($lang in $langs) {
            $folder = 'pages'
            if ($lang -ne 'en') { $folder = "pages.$lang" }
            $r = Invoke-HttpText "https://raw.githubusercontent.com/tldr-pages/tldr/main/$folder/$p/$Page.md"
            if ($r.Ok) {
                if ($cached) { Remove-Item -LiteralPath $cached.File -Force -ErrorAction SilentlyContinue }
                Save-Page (Join-Path (Join-Path $cacheRoot 'tldr') "$Page.$p.$lang.md") $r.Text
                return @{ Text = $r.Text; Platform = $p; Lang = $lang; Cached = $false }
            }
            if ($r.Status -ne 404) { $lastError = Get-HttpErrorText 'raw.githubusercontent.com' $r.Status; break }
        }
        if ($lastError) { break }
    }
    if ($cached) {
        if ($lastError) { Write-PstStatus warn ($lastError + ' ' + (L 'Copie en cache utilisée.')) }
        return @{ Text = [IO.File]::ReadAllText($cached.File, [Text.Encoding]::UTF8); Platform = $cached.Platform; Lang = $cached.Lang; Cached = $true }
    }
    return @{ Text = $null; Error = $lastError }
}

function Get-CheatShPage {
    param([string]$Page)
    $file = Join-Path (Join-Path $cacheRoot 'cheatsh') "$Page.txt"
    $exists = Test-Path -LiteralPath $file
    if ($exists -and ($Offline -or (-not $Update -and ((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime) -lt $refreshAge))) {
        return @{ Text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8); Cached = $true }
    }
    if ($Offline) { return @{ Text = $null } }
    $r = Invoke-HttpText "https://cheat.sh/$([Uri]::EscapeDataString($Page))?T"
    if ($r.Ok -and -not (Test-CheatShUnknown $r.Text)) {
        Save-Page $file $r.Text
        return @{ Text = $r.Text; Cached = $false }
    }
    if ($r.Ok -or $r.Status -eq 404) { return @{ Text = $null } }
    $err = Get-HttpErrorText 'cheat.sh' $r.Status
    if ($exists) {
        Write-PstStatus warn ($err + ' ' + (L 'Copie en cache utilisée.'))
        return @{ Text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8); Cached = $true }
    }
    return @{ Text = $null; Error = $err }
}

function Test-CheatShUnknown {
    param([string]$Text)
    return (-not $Text.Trim() -or $Text -match '^\s*Unknown topic\.' -or $Text -match '^\s*<!doctype html')
}

# ── Analyse et rendu ─────────────────────────────────────────────────────────

function ConvertFrom-TldrMarkdown {
    # Page tldr -> @{ Title; Description[]; Info; Examples = @(@{ Description; Command }) }.
    param([string]$Text)
    $page = @{ Title = ''; Description = @(); Info = ''; Examples = @() }
    $pending = $null
    foreach ($raw in ($Text -split "\r?\n")) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -match '^#\s+(.+)$') { $page.Title = $Matches[1].Trim(); continue }
        if ($line -match '^>\s?(.*)$') {
            $d = $Matches[1].Trim()
            if ($d -match '^(More information|Plus d''informations|Plus d''information)\s*:\s*<?([^>]+)>?\.?$') { $page.Info = $Matches[2].Trim() }
            elseif ($d) { $page.Description += $d }
            continue
        }
        if ($line -match '^-\s+(.+)$') { $pending = $Matches[1].Trim(); continue }
        if ($line -match '^`(.+)`$') {
            $page.Examples += @{ Description = [string]$pending; Command = $Matches[1] }
            $pending = $null
        }
    }
    return $page
}

function Format-TldrCommand {
    # Met les {{paramètres}} en évidence ; sans couleur, la notation {{...}} est conservée.
    param([string]$Command)
    if (-not $script:Pst.Ansi) { return $Command }
    $parts = [regex]::Split($Command, '(\{\{.*?\}\})')
    $out = ''
    foreach ($p in $parts) {
        if (-not $p) { continue }
        if ($p -match '^\{\{(.*)\}\}$') { $out += Paint $Matches[1] 'Warn' }
        else { $out += Paint $p 'Accent' -Bold }
    }
    return $out
}

function Show-TldrPage {
    param($Page, [string]$Platform, [string]$Lang, [bool]$Cached)
    $width = Get-PstWidth -Max 100
    $subtitle = "tldr $($script:Pst.Glyph.Dot) $Platform"
    if ($script:Pst.Lang -eq 'fr' -and $Lang -eq 'en') { $subtitle += " $($script:Pst.Glyph.Dot) " + (L 'page en anglais') }
    if ($Cached) { $subtitle += " $($script:Pst.Glyph.Dot) " + (L 'cache') }
    Show-PstHeader -Tool 'cheat' -Subtitle $subtitle
    Write-Host ('  ' + (Paint $Page.Title 'Title' -Bold))
    foreach ($d in $Page.Description) { foreach ($w in (Format-PstWrap $d ($width - 4))) { Write-Host ('  ' + $w) } }
    if ($Page.Info) { Write-Host ('  ' + (Paint $Page.Info 'Dim')) }
    Write-Host ''
    foreach ($ex in $Page.Examples) {
        $first = $true
        foreach ($w in (Format-PstWrap $ex.Description ($width - 6))) {
            $mark = '  '
            if ($first) { $mark = (Paint $script:Pst.Glyph.Pointer 'Accent2') + ' ' }
            Write-Host ('  ' + $mark + (Paint $w 'Dim'))
            $first = $false
        }
        Write-Host ('      ' + (Format-TldrCommand $ex.Command))
        Write-Host ''
    }
}

function Show-CheatShPage {
    param([string]$Text, [string]$Page, [bool]$Cached)
    $subtitle = 'cheat.sh'
    if ($Cached) { $subtitle += " $($script:Pst.Glyph.Dot) " + (L 'cache') }
    Show-PstHeader -Tool 'cheat' -Subtitle $subtitle
    Write-Host ('  ' + (Paint $Page 'Title' -Bold))
    Write-Host ''
    foreach ($raw in ($Text.TrimEnd() -split "\r?\n")) {
        $line = $raw -replace "$([char]27)\[[0-9;]*m", ''
        if ($line -match '^\s*#\[cheat') { continue }
        if ($line -match '^\s*#') { Write-Host ('  ' + (Paint $line 'Dim')) }
        elseif ($line.Trim()) { Write-Host ('  ' + (Paint $line 'Accent')) }
        else { Write-Host '' }
    }
    Write-Host ''
}

function Show-NotFound {
    param([string]$Page, [string]$ErrorText)
    if ($Json) { [ordered]@{ Name = $Page; Found = $false; Error = $ErrorText } | ConvertTo-Json -Compress; return }
    Show-PstHeader -Tool 'cheat'
    if ($ErrorText) { Write-PstStatus err $ErrorText }
    elseif ($Offline) { Write-PstStatus warn (L 'Aucune fiche en cache pour « {0} » (relancez sans -Offline).' $Page) }
    else { Write-PstStatus warn (L 'Aucune fiche trouvée pour « {0} ».' $Page) }
    Write-Host ''
    Write-Host (Paint ('    ' + (L 'Essayez :')) 'Dim')
    if ($Source -eq 'tldr') { Write-Host ('      ' + (Paint "cheat $Page -Source cheatsh" 'Ok')) }
    else { Write-Host ('      ' + (Paint "cheat $Page" 'Ok')) }
    Write-Host ('      ' + (Paint ('ask "' + (L 'comment utiliser {0} ?' $Page) + '"') 'Ok'))
    Write-Host ''
}

# ── Recherche ────────────────────────────────────────────────────────────────

function Search-Cache {
    param([string]$Word)
    $hits = @()
    if (-not (Test-Path -LiteralPath $cacheRoot)) { return $hits }
    $files = @(Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Include '*.md', '*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    $done = @{}
    foreach ($f in $files) {
        $isTldr = $f.Extension -eq '.md'
        $page = $f.BaseName
        if ($isTldr) { $page = ($f.Name -split '\.')[0] }
        $src = 'cheatsh'
        if ($isTldr) { $src = 'tldr' }
        if ($done.ContainsKey("$src|$page")) { continue }
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $lines = @($text -split "\r?\n" | Where-Object { $_ -match [regex]::Escape($Word) })
        if (-not $lines.Count -and $page -notmatch [regex]::Escape($Word)) { continue }
        $done["$src|$page"] = $true
        $snippet = ''
        if ($lines.Count) { $snippet = ($lines[0].Trim() -replace '^[>#\-`\s]+', '' -replace '`$', '') }
        $hits += [ordered]@{ Name = $page; Source = $src; Match = $snippet; Count = $lines.Count }
    }
    return @($hits | Sort-Object { - $_.Count }, { $_.Name })
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

if ($Search) {
    $hits = @(Search-Cache $Search)
    if ($Json) { ConvertTo-Json -InputObject @($hits) -Depth 3 -Compress; exit 0 }
    Show-PstHeader -Tool 'cheat' -Subtitle (L 'recherche « {0} »' $Search)
    if (-not $hits.Count) {
        Write-PstStatus info (L 'Aucune fiche en cache ne contient « {0} ».' $Search)
        Write-Host (Paint ('    ' + (L 'La recherche porte sur les fiches déjà consultées.')) 'Dim')
        Write-Host ''
        exit 0
    }
    $width = Get-PstWidth -Max 100
    $rows = @()
    foreach ($h in $hits) {
        $snippet = Limit-PstText $h.Match ($width - 34)
        if ($snippet -and $script:Pst.Ansi) { $snippet = [regex]::Replace($snippet, [regex]::Escape($Search), { param($m) Paint $m.Value 'Accent' -Bold }, 'IgnoreCase') }
        $rows += , @($h.Name, $h.Source, $snippet)
    }
    Format-PstTable -Columns @(@{ Name = (L 'Commande'); Width = 18 }, @{ Name = (L 'Source'); Width = 8 }, @{ Name = (L 'Extrait'); Width = $width - 34 }) -Rows $rows |
        ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-PstStatus info (L '{0} fiche(s) trouvée(s).' $hits.Count)
    Write-Host ''
    exit 0
}

$page = ConvertTo-PageName (@($Name) + @($Rest))
if (-not $page) { Write-PstStatus err (L 'Nom de commande invalide.'); exit 1 }

if ($Source -eq 'cheatsh') {
    $r = Get-CheatShPage $page
    if (-not $r.Text) { Show-NotFound $page $r.Error; exit 1 }
    if ($Json) { [ordered]@{ Name = $page; Found = $true; Source = 'cheat.sh'; Text = ($r.Text -replace "$([char]27)\[[0-9;]*m", '') } | ConvertTo-Json -Compress; exit 0 }
    Show-CheatShPage $r.Text $page $r.Cached
    exit 0
}

$r = Get-TldrPage $page
if (-not $r.Text) { Show-NotFound $page $r.Error; exit 1 }
$parsed = ConvertFrom-TldrMarkdown $r.Text
if ($Json) {
    [ordered]@{
        Name = $page; Found = $true; Source = 'tldr'; Platform = $r.Platform; Language = $r.Lang; Title = $parsed.Title
        Description = ($parsed.Description -join ' '); Info = $parsed.Info
        Examples = @($parsed.Examples | ForEach-Object { [ordered]@{ Description = $_.Description; Command = $_.Command } })
    } | ConvertTo-Json -Depth 4
    exit 0
}
Show-TldrPage $parsed $r.Platform $r.Lang $r.Cached
