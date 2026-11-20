<#
.SYNOPSIS
    gitignore — génère un fichier .gitignore à partir des modèles de toptal.com/developers/gitignore.
.DESCRIPTION
    Affiche, écrit ou complète le .gitignore du projet sans jamais dupliquer une règle
    ni toucher aux lignes existantes. Sans argument dans un dépôt Git, propose les
    modèles adaptés aux fichiers présents (package.json, *.csproj, go.mod...).
    Hôte contacté (HTTPS) : www.toptal.com. Les modèles et la liste sont gardés en
    cache 7 jours dans le dossier de données ; -Offline n'utilise que le cache.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Templates,
    [switch]$Write,
    [switch]$List,
    [string]$Path = '.gitignore',
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Update,
    [switch]$Offline,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'gitignore'
$ProgressPreference = 'SilentlyContinue'

if ($Help -or (Test-PstHelpArg (@($Templates) + @($Rest)))) {
    Show-PstHelp -Name 'gitignore' -Synopsis (L 'Génère un .gitignore à partir de modèles (Node, Python, Visual Studio...).') `
        -Usage @(
            (L 'gitignore                         suggère des modèles d''après le dépôt Git courant'),
            (L 'gitignore <modèles>               affiche le .gitignore (ex. node,python)'),
            (L 'gitignore <modèles> -Write        ajoute les règles manquantes à ./.gitignore'),
            (L 'gitignore -List [filtre]          modèles disponibles')
        ) `
        -Options @(
            @('-Write', (L 'Écrit dans le fichier (fusion : aucune ligne dupliquée, contenu existant conservé)')),
            @((L '-Path <fichier>'), (L 'Fichier cible (défaut : .gitignore du dossier courant)')),
            @('-Yes', (L 'Écrit sans demander de confirmation')),
            @('-DryRun', (L 'Montre les lignes qui seraient ajoutées, sans écrire')),
            @('-List', (L 'Liste les modèles disponibles (filtre optionnel)')),
            @('-Update', (L 'Ignore le cache et télécharge à nouveau')),
            @('-Offline', (L 'N''utilise que le cache, aucune requête réseau')),
            @('-Json', (L 'Sortie JSON (avec -List ou les suggestions)'))
        ) `
        -Examples @('gitignore node,visualstudio', 'gitignore python -Write', 'gitignore node > .gitignore', 'gitignore -List java') `
        -Notes @(
            (L 'Source : www.toptal.com/developers/gitignore (HTTPS), mise en cache 7 jours.')
        )
    exit 0
}

# ── Réseau et cache ──────────────────────────────────────────────────────────

$apiBase = 'https://www.toptal.com/developers/gitignore/api/'
$apiHost = 'www.toptal.com'
$cacheDir = Join-Path (Get-PstDataDir) 'gitignore'
$maxAge = [TimeSpan]::FromDays(7)
$utf8 = New-Object Text.UTF8Encoding $false

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
    param([int]$Status)
    if ($Status -eq 429) { return (L 'Trop de requêtes vers {0} : réessayez dans quelques minutes.' $apiHost) }
    if ($Status -eq 0) { return (L 'Connexion impossible à {0} (hors ligne ?).' $apiHost) }
    return (L 'Réponse inattendue de {0} (HTTP {1}).' $apiHost $Status)
}

function Read-Cache {
    # Retourne @{ Text; Fresh } ou $null.
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    return @{ Text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8); Fresh = ($age -lt $maxAge) }
}

function Save-Cache {
    param([string]$File, [string]$Text)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($File, $Text, $utf8)
}

function Get-CachedOrFetch {
    # Cache frais d'abord, puis réseau, puis cache périmé. Retourne @{ Text; Error }.
    param([string]$File, [string]$Url)
    $cached = Read-Cache $File
    if ($cached -and ($Offline -or ($cached.Fresh -and -not $Update))) { return @{ Text = $cached.Text } }
    if ($Offline) { return @{ Text = $null; Error = (L 'Pas de copie en cache (relancez sans -Offline).') } }
    $r = Invoke-HttpText $Url
    if ($r.Ok) { Save-Cache $File $r.Text; return @{ Text = $r.Text } }
    if ($r.Status -eq 404) { return @{ Text = $null; Status = 404; Error = (L 'Modèle inconnu.') } }
    if ($cached) {
        Write-PstStatus warn ((Get-HttpErrorText $r.Status) + ' ' + (L 'Copie en cache utilisée.'))
        return @{ Text = $cached.Text }
    }
    return @{ Text = $null; Status = $r.Status; Error = (Get-HttpErrorText $r.Status) }
}

function ConvertFrom-TemplateList {
    # La liste arrive sous forme « a,b,c » sur plusieurs lignes.
    param([string]$Text)
    return @($Text -split '[,\r\n]+' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TemplateList {
    $r = Get-CachedOrFetch (Join-Path $cacheDir 'list.txt') ($apiBase + 'list')
    if (-not $r.Text) { return $null }
    return @(ConvertFrom-TemplateList $r.Text)
}

# ── Noms de modèles ──────────────────────────────────────────────────────────

$aliases = @{
    'c#' = 'csharp'; 'cs' = 'csharp'; 'vs' = 'visualstudio'; 'vscode' = 'visualstudiocode'; 'py' = 'python'
    'js' = 'node'; 'javascript' = 'node'; 'nodejs' = 'node'; 'ts' = 'node'; 'typescript' = 'node'; 'golang' = 'go'
    'mac' = 'macos'; 'osx' = 'macos'; 'jetbrains' = 'jetbrains+all'; 'idea' = 'jetbrains+all'; 'dotnet' = 'dotnetcore'; 'cpp' = 'c++'
}

function ConvertTo-TemplateNames {
    param([string[]]$Words)
    $names = @()
    foreach ($w in @($Words | ForEach-Object { $_ -split '[,;\s]+' })) {
        $n = $w.Trim().ToLower()
        if (-not $n) { continue }
        if ($aliases.ContainsKey($n)) { $n = $aliases[$n] }
        if ($names -notcontains $n) { $names += $n }
    }
    return $names
}

function Get-CloseNames {
    param([string]$Name, [string[]]$Known)
    $root = $Name -replace '[^a-z0-9]', ''
    return @($Known | Where-Object { $_.Contains($Name) -or ($root.Length -ge 2 -and $_.StartsWith($root.Substring(0, [Math]::Min(3, $root.Length)))) } | Select-Object -First 6)
}

# ── Fusion ───────────────────────────────────────────────────────────────────

function Merge-GitIgnoreText {
    # Ajoute à $Existing les règles de $Addition qui n'y figurent pas encore.
    # Les lignes existantes restent intactes ; les sections sans règle nouvelle sont omises.
    # Retourne @{ Text; Added (lignes ajoutées); Rules (nombre de règles nouvelles) }.
    param([AllowEmptyString()][string]$Existing = '', [string]$Addition, [string]$Label)
    $nl = "`n"
    if ($Existing -match "`r`n") { $nl = "`r`n" }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in ($Existing -split "\r?\n")) { $t = $line.Trim(); if ($t -and -not $t.StartsWith('#')) { [void]$seen.Add($t) } }

    # Découpe en sections (« ### Nom ### »), chacune en paragraphes séparés par des lignes vides.
    $sections = New-Object System.Collections.ArrayList
    $current = @{ Header = $null; Paragraphs = (New-Object System.Collections.ArrayList) }
    [void]$sections.Add($current)
    $para = New-Object System.Collections.ArrayList
    foreach ($raw in ($Addition -split "\r?\n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^#\s*(Created by|Edit at|End of)\s+https?://') { continue }
        if ($line -match '^###.*###$') {
            if ($para.Count) { [void]$current.Paragraphs.Add(@($para)); $para.Clear() }
            $current = @{ Header = $line; Paragraphs = (New-Object System.Collections.ArrayList) }
            [void]$sections.Add($current)
            continue
        }
        if (-not $line.Trim()) {
            if ($para.Count) { [void]$current.Paragraphs.Add(@($para)); $para.Clear() }
            continue
        }
        [void]$para.Add($line)
    }
    if ($para.Count) { [void]$current.Paragraphs.Add(@($para)) }

    $added = New-Object System.Collections.ArrayList
    $rules = 0
    foreach ($s in $sections) {
        $kept = New-Object System.Collections.ArrayList
        $sectionRules = 0
        foreach ($p in $s.Paragraphs) {
            $lines = @()
            $hadRules = $false
            $newRules = 0
            foreach ($line in $p) {
                $t = $line.Trim()
                if ($t.StartsWith('#')) { $lines += $line; continue }
                $hadRules = $true
                if ($seen.Contains($t)) { continue }
                [void]$seen.Add($t)
                $lines += $line
                $newRules++
            }
            $sectionRules += $newRules
            # Paragraphe de commentaires seuls : conservé ; paragraphe dont toutes les règles existent déjà : omis.
            if ($newRules -or -not $hadRules) { [void]$kept.Add($lines) }
        }
        if ($sectionRules -eq 0) { continue }
        $rules += $sectionRules
        if ($added.Count) { [void]$added.Add('') }
        if ($s.Header) { [void]$added.Add($s.Header) }
        $first = $true
        foreach ($p in $kept) {
            if (-not $first) { [void]$added.Add('') }
            foreach ($l in $p) { [void]$added.Add($l) }
            $first = $false
        }
    }
    if ($rules -eq 0) { return @{ Text = $Existing; Added = @(); Rules = 0 } }

    $block = @("# gitignore: $Label (https://www.toptal.com/developers/gitignore)") + @($added)
    $text = $Existing
    if ($text.Length -and -not ($text.EndsWith("`n"))) { $text += $nl }
    if ($text.Trim().Length) { $text += $nl }
    $text += ($block -join $nl) + $nl
    return @{ Text = $text; Added = $block; Rules = $rules }
}

# ── Détection ────────────────────────────────────────────────────────────────

function Find-GitRoot {
    param([string]$Start)
    $dir = $Start
    for ($i = 0; $i -lt 40 -and $dir; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $dir = [IO.Path]::GetDirectoryName($dir)
    }
    return $null
}

function Get-TemplateSuggestions {
    # Repère les modèles utiles d'après les fichiers du dossier (et de ses sous-dossiers directs).
    param([string]$Root)
    $rules = @(
        @('package.json', 'node'), @('*.csproj', 'visualstudio'), @('*.sln', 'visualstudio'), @('*.fsproj', 'visualstudio'), @('*.vbproj', 'visualstudio'),
        @('requirements.txt', 'python'), @('pyproject.toml', 'python'), @('setup.py', 'python'), @('Pipfile', 'python'),
        @('go.mod', 'go'), @('Cargo.toml', 'rust'), @('pom.xml', 'maven'), @('pom.xml', 'java'), @('build.gradle', 'gradle'), @('build.gradle.kts', 'gradle'),
        @('composer.json', 'composer'), @('Gemfile', 'ruby'), @('*.tf', 'terraform'), @('CMakeLists.txt', 'cmake'), @('pubspec.yaml', 'flutter'),
        @('angular.json', 'angular'), @('next.config.js', 'nextjs'), @('next.config.mjs', 'nextjs'), @('*.uproject', 'unrealengine'), @('project.godot', 'godot'),
        @('.vscode', 'visualstudiocode'), @('.idea', 'jetbrains+all'), @('.env', 'dotenv')
    )
    $dirs = @($Root)
    try {
        $dirs += @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop |
                Where-Object { $_.Name -notin '.git', 'node_modules', 'bin', 'obj', 'target', 'dist', 'build', '.venv', 'venv' } |
                Select-Object -First 40 | ForEach-Object { $_.FullName })
    }
    catch { $null = $_ }
    $found = [ordered]@{}
    foreach ($rule in $rules) {
        if ($found.Contains($rule[1])) { continue }
        foreach ($d in $dirs) {
            $hit = @(Get-ChildItem -LiteralPath $d -Filter $rule[0] -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($hit.Count) {
                $where = $hit[0].Name
                if ($d -ne $Root) { $where = (Split-Path -Leaf $d) + '/' + $hit[0].Name }
                $found[$rule[1]] = $where
                break
            }
        }
    }
    return $found
}

# ── Écriture ─────────────────────────────────────────────────────────────────

function Get-TemplateText {
    param([string[]]$Names)
    $known = $null
    if (-not $Offline -or (Test-Path -LiteralPath (Join-Path $cacheDir 'list.txt'))) { $known = Get-TemplateList }
    if ($known) {
        $unknown = @($Names | Where-Object { $known -notcontains $_ })
        if ($unknown.Count) {
            foreach ($u in $unknown) {
                $close = @(Get-CloseNames $u $known)
                if ($close.Count) { Write-PstStatus err (L 'Modèle inconnu : « {0} ». Vouliez-vous dire : {1} ?' $u ($close -join ', ')) }
                else { Write-PstStatus err (L 'Modèle inconnu : « {0} » (voir « gitignore -List »).' $u) }
            }
            return $null
        }
    }
    $key = (@($Names | Sort-Object) -join ',')
    $file = Join-Path (Join-Path $cacheDir 'templates') (($key -replace '[^a-z0-9+,.\-]', '_') + '.gitignore')
    $r = Get-CachedOrFetch $file ($apiBase + [Uri]::EscapeDataString($key).Replace('%2C', ','))
    if (-not $r.Text) {
        if ($r.Status -eq 404) { Write-PstStatus err (L 'Modèle inconnu : « {0} » (voir « gitignore -List »).' ($Names -join ', ')) }
        else { Write-PstStatus err $r.Error }
        return $null
    }
    if ($r.Text -match '#!! ERROR: (.+?) is undefined') {
        Write-PstStatus err (L 'Modèle inconnu : « {0} » (voir « gitignore -List »).' $Matches[1])
        return $null
    }
    return $r.Text
}

function Invoke-Write {
    param([string[]]$Names)
    $text = Get-TemplateText $Names
    if (-not $text) { return 1 }
    $target = $Path
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Get-Location).ProviderPath $target }
    $existing = ''
    $bom = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $bytes = [IO.File]::ReadAllBytes($target)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $existing = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    }
    $merge = Merge-GitIgnoreText -Existing $existing -Addition $text -Label ($Names -join ', ')

    Show-PstHeader -Tool 'gitignore' -Subtitle ($Names -join ', ')
    if ($merge.Rules -eq 0) {
        Write-PstStatus ok (L '{0} contient déjà toutes ces règles : rien à ajouter.' $target)
        Write-Host ''
        return 0
    }
    $max = 40
    $shown = @($merge.Added | Select-Object -First $max)
    foreach ($l in $shown) {
        if ($l.Trim().StartsWith('#')) { Write-Host ('    ' + (Paint $l 'Dim')) }
        elseif ($l) { Write-Host ('  ' + (Paint '+' 'Ok' -Bold) + ' ' + (Paint $l 'Ok')) }
        else { Write-Host '' }
    }
    if ($merge.Added.Count -gt $max) { Write-Host (Paint ('    ' + (L '... et {0} autre(s) ligne(s)' ($merge.Added.Count - $max))) 'Dim') }
    Write-Host ''
    $verb = L 'créé'
    if (Test-Path -LiteralPath $target) { $verb = L 'complété' }
    Write-PstStatus info (L '{0} règle(s) nouvelle(s) pour {1} ({2})' $merge.Rules $target $verb)
    if ($DryRun) { Write-PstStatus info (L 'Simulation : aucun fichier modifié.'); Write-Host ''; return 0 }
    if (-not $Yes) {
        if (-not (Test-PstInteractive)) { Write-PstStatus warn (L 'Session non interactive : ajoutez -Yes pour écrire.'); Write-Host ''; return 1 }
        if (-not (Read-PstConfirm (L 'Écrire ces lignes ?') -DefaultYes)) { Write-PstStatus info (L 'Annulé : aucun fichier modifié.'); Write-Host ''; return 0 }
    }
    try { [IO.File]::WriteAllText($target, $merge.Text, (New-Object Text.UTF8Encoding $bom)) }
    catch { Write-PstStatus err (L 'Écriture impossible : {0}' $_.Exception.Message); return 1 }
    Write-PstStatus ok (L '{0} mis à jour : {1} règle(s) ajoutée(s).' $target $merge.Rules)
    Write-Host ''
    return 0
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

$words = @(@($Templates) + @($Rest) | Where-Object { $_ })

if ($List) {
    $known = Get-TemplateList
    if (-not $known) {
        $r = Get-CachedOrFetch (Join-Path $cacheDir 'list.txt') ($apiBase + 'list')
        Write-PstStatus err $r.Error
        exit 1
    }
    $filter = ($words -join ' ').Trim().ToLower()
    $items = @($known | Where-Object { -not $filter -or $_.Contains($filter) })
    if ($Json) { ConvertTo-Json -InputObject @($items) -Compress; exit 0 }
    $subtitle = L '{0} modèle(s)' $items.Count
    if ($filter) { $subtitle = L '{0} modèle(s) contenant « {1} »' $items.Count $filter }
    Show-PstHeader -Tool 'gitignore' -Subtitle $subtitle
    if (-not $items.Count) { Write-PstStatus info (L 'Aucun modèle ne correspond.'); Write-Host ''; exit 0 }
    $colW = 2 + [Math]::Max(8, (@($items | ForEach-Object { $_.Length }) | Measure-Object -Maximum).Maximum)
    $perLine = [Math]::Max(1, [int][Math]::Floor(((Get-PstWidth) - 4) / $colW))
    for ($i = 0; $i -lt $items.Count; $i += $perLine) {
        $line = ''
        foreach ($name in $items[$i..([Math]::Min($i + $perLine, $items.Count) - 1)]) {
            $cell = $name
            if ($filter) { $cell = $name.Replace($filter, (Paint $filter 'Accent' -Bold)) }
            $line += Format-PstPad $cell $colW
        }
        Write-Host ('  ' + $line.TrimEnd())
    }
    Write-Host ''
    exit 0
}

if ($words.Count) {
    $names = @(ConvertTo-TemplateNames $words)
    if ($Write -or $DryRun) { exit (Invoke-Write $names) }
    $text = Get-TemplateText $names
    if (-not $text) { exit 1 }
    ($text.TrimEnd() -split "\r?\n") | ForEach-Object { Write-Output $_ }
    exit 0
}

# Sans argument : suggestions d'après le dépôt Git.
$here = (Get-Location).ProviderPath
$gitRoot = Find-GitRoot $here
if (-not $gitRoot) {
    Show-PstHeader -Tool 'gitignore'
    Write-PstStatus info (L 'Pas de dépôt Git ici : indiquez les modèles voulus.')
    Write-Host (Paint ('    gitignore node,python  ' + $script:Pst.Glyph.Dot + '  gitignore -List  ' + $script:Pst.Glyph.Dot + '  gitignore -Help') 'Dim')
    Write-Host ''
    exit 0
}
$found = Get-TemplateSuggestions $gitRoot
$candidates = [ordered]@{}
foreach ($k in $found.Keys) { $candidates[$k] = @{ Reason = $found[$k]; On = $true } }
$osDefault = 'windows'
if (-not $script:Pst.IsWindows) { if ($IsMacOS) { $osDefault = 'macos' } else { $osDefault = 'linux' } }
foreach ($os in 'windows', 'macos', 'linux') {
    if (-not $candidates.Contains($os)) { $candidates[$os] = @{ Reason = (L 'système'); On = ($os -eq $osDefault) } }
}

if ($Json) {
    ConvertTo-Json -InputObject @($candidates.Keys | ForEach-Object { [ordered]@{ Name = $_; Reason = $candidates[$_].Reason; Suggested = $candidates[$_].On } }) -Compress
    exit 0
}

Show-PstHeader -Tool 'gitignore' -Subtitle (Split-Path -Leaf $gitRoot)
if (-not $found.Count) { Write-PstStatus info (L 'Aucun type de projet reconnu dans ce dépôt.') }
$keys = @($candidates.Keys)
if (-not (Test-PstInteractive)) {
    foreach ($k in $keys) {
        $mark = $script:Pst.Glyph.Off
        if ($candidates[$k].On) { $mark = $script:Pst.Glyph.On }
        Write-Host ('    ' + $mark + ' ' + (Format-PstPad $k 18) + (Paint $candidates[$k].Reason 'Dim'))
    }
    $chosen = @($keys | Where-Object { $candidates[$_].On })
    Write-Host ''
    Write-PstStatus info (L 'Pour écrire ces modèles : {0}' ('gitignore ' + ($chosen -join ',') + ' -Write'))
    Write-Host ''
    exit 0
}
$labels = @($keys | ForEach-Object { (Format-PstPad $_ 18) + (Paint $candidates[$_].Reason 'Dim') })
$selected = [bool[]]@($keys | ForEach-Object { [bool]$candidates[$_].On })
$picked = Read-PstMultiChoice -Title (L 'Modèles à inclure dans .gitignore') -Items $labels -Selected $selected
Write-Host ''
if ($null -eq $picked -or @($picked).Count -eq 0) { Write-PstStatus info (L 'Annulé : aucun fichier modifié.'); Write-Host ''; exit 0 }
$names = @(@($picked) | ForEach-Object { $keys[$_] })
if (-not [IO.Path]::IsPathRooted($Path) -and $Path -eq '.gitignore') { $Path = Join-Path $gitRoot '.gitignore' }
exit (Invoke-Write $names)
