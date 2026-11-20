<#
.SYNOPSIS
    clean — nettoyeur de fichiers inutiles avec aperçu avant suppression.
.DESCRIPTION
    Analyse d'abord, supprime ensuite, et seulement après confirmation.
    Sans droits administrateur, les cibles système sont signalées et ignorées ;
    « clean -Elevate » relance l'outil dans une fenêtre administrateur.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [string[]]$Only,
    [switch]$List,
    [switch]$Elevate,
    [string]$Path,
    [int]$OlderThan = 0,
    [string[]]$Include,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'clean'

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'clean' -Synopsis (L 'Libère de l''espace disque : analyse, aperçu, puis suppression confirmée.') `
        -Usage @(
            (L 'clean [-DryRun] [-Yes] [-Only <cibles>]'),
            (L 'clean -Path <dossier> [-OlderThan <jours>] [-Include <motifs>] [-DryRun] [-Yes]')
        ) `
        -Options @(
            @('-DryRun', (L 'Montre ce qui serait supprimé, sans rien toucher')),
            @('-Yes', (L 'Ne pose aucune question (toutes les cibles accessibles)')),
            @((L '-Only <cibles>'), (L 'Limite aux cibles données, ex. : temp,browsers')),
            @('-List', (L 'Affiche les cibles connues et quitte')),
            @('-Elevate', (L 'Relance en administrateur pour les cibles système')),
            @((L '-Path <dossier>'), (L 'Nettoie un dossier précis (avec -OlderThan et/ou -Include)')),
            @((L '-OlderThan <jours>'), (L 'Ne garde que les fichiers non modifiés depuis N jours')),
            @((L '-Include <motifs>'), (L 'Motifs de fichiers, ex. : *.log,*.tmp'))
        ) `
        -Examples @('clean', 'clean -DryRun', 'clean -Only temp,thumbs -Yes', 'clean -Path D:\Logs -OlderThan 30 -Include *.log')
    exit 0
}

# ── Parcours de fichiers robuste ─────────────────────────────────────────────

function Test-SafeRoot {
    # Refuse les racines dangereuses (lecteur entier, profil, dossiers système).
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    try { $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    $forbidden = @($HOME, $env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemDrive, $env:LOCALAPPDATA, $env:APPDATA) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') }
    foreach ($f in $forbidden) { if ($full -ieq $f) { return $false } }
    return $true
}

function Get-TreeFiles {
    # Énumère les fichiers d'une arborescence sans s'arrêter aux accès refusés
    # et sans suivre les liens/jonctions.
    param([string]$Root, [string[]]$Patterns)
    $result = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $entry = New-Object IO.DirectoryInfo $dir
            foreach ($f in $entry.GetFiles()) {
                if ($Patterns) {
                    $match = $false
                    foreach ($p in $Patterns) { if ($f.Name -like $p) { $match = $true; break } }
                    if (-not $match) { continue }
                }
                [void]$result.Add($f)
            }
            foreach ($d in $entry.GetDirectories()) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($d.FullName)
            }
        }
        catch { $null = $_ }
    }
    return , $result
}

function Remove-EmptyDirs {
    param([string]$Root)
    try {
        $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Sort-Object { $_.FullName.Length } -Descending)
        foreach ($d in $dirs) {
            try { if (@($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete() } } catch { $null = $_ }
        }
    }
    catch { $null = $_ }
}

function Remove-FileList {
    # Supprime une liste de fichiers ; retourne octets libérés / fichiers ignorés.
    param($Files)
    $freed = 0.0; $done = 0; $skipped = 0
    foreach ($f in $Files) {
        try {
            $size = $f.Length
            if ($f.IsReadOnly) { $f.IsReadOnly = $false }
            $f.Delete()
            $freed += $size; $done++
        }
        catch { $skipped++ }
    }
    return @{ Freed = $freed; Done = $done; Skipped = $skipped }
}

# ── Mode « dossier précis » ──────────────────────────────────────────────────

if ($Path) {
    Show-PstHeader -Tool 'clean' -Subtitle (L 'dossier personnalisé')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (-not (Test-SafeRoot $root)) { Write-PstStatus err (L 'Par sécurité, ce dossier ne peut pas être nettoyé en bloc : {0}' $root); exit 1 }
    if ($OlderThan -le 0 -and -not $Include) {
        Write-PstStatus err (L 'Précisez -OlderThan <jours> et/ou -Include <motifs> pour cibler les fichiers.')
        exit 1
    }
    if ($Include) { $Include = @($Include | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }

    $files = Get-TreeFiles -Root $root -Patterns $Include
    if ($OlderThan -gt 0) {
        $limit = (Get-Date).AddDays(-$OlderThan)
        $files = @($files | Where-Object { $_.LastWriteTime -lt $limit })
    }
    $total = 0.0
    foreach ($f in $files) { $total += $f.Length }

    $criteria = @()
    if ($Include) { $criteria += (L 'motifs : {0}' ($Include -join ', ')) }
    if ($OlderThan -gt 0) { $criteria += (L 'plus de {0} jours' $OlderThan) }
    Write-PstStatus info "$root"
    Write-PstStatus info (L 'Critères {0} {1}' $script:Pst.Glyph.Dot ($criteria -join " $($script:Pst.Glyph.Dot) "))
    Write-PstStatus info (L '{0} fichier(s) {2} {1}' @($files).Count (Format-PstSize $total) $script:Pst.Glyph.Dot)
    Write-Host ''
    @($files | Sort-Object Length -Descending | Select-Object -First 10) | ForEach-Object {
        Write-Host ('    ' + (Format-PstPad (Format-PstSize $_.Length) 10 -Right) + '  ' + (Paint (Limit-PstText $_.FullName.Substring($root.Length).TrimStart('\', '/') ((Get-PstWidth) - 18)) 'Dim'))
    }
    if (@($files).Count -gt 10) { Write-Host (Paint (L '    ... et {0} autre(s)' (@($files).Count - 10)) 'Dim') }
    Write-Host ''

    if (@($files).Count -eq 0) { Write-PstStatus ok (L 'Rien à supprimer.'); exit 0 }
    if ($DryRun) { Write-PstStatus info (L 'Simulation : aucun fichier supprimé.'); exit 0 }
    if (-not $Yes) {
        if (-not (Test-PstInteractive)) { Write-PstStatus warn (L 'Session non interactive : ajoutez -Yes pour supprimer.'); exit 0 }
        if (-not (Read-PstConfirm (L 'Supprimer définitivement ces {0} fichier(s) ?' @($files).Count))) { Write-PstStatus info (L 'Annulé.'); exit 0 }
    }
    $r = Remove-FileList $files
    Remove-EmptyDirs $root
    Write-PstStatus ok (L '{0} libérés {2} {1} fichier(s) supprimé(s)' (Format-PstSize $r.Freed) $r.Done $script:Pst.Glyph.Dot)
    if ($r.Skipped) { Write-PstStatus warn (L '{0} fichier(s) verrouillé(s) ou protégé(s) ignoré(s)' $r.Skipped) }
    exit 0
}

# ── Cibles prédéfinies (Windows) ─────────────────────────────────────────────

Assert-PstWindows 'clean'

function Get-CleanTargets {
    $local = $env:LOCALAPPDATA
    $win = $env:WINDIR
    return @(
        @{ Id = 'temp'; Label = (L 'Fichiers temporaires de l''utilisateur'); Admin = $false; Roots = @($env:TEMP) },
        @{ Id = 'browsers'; Label = (L 'Caches des navigateurs (Chrome, Edge, Firefox)'); Admin = $false; Roots = @(
                "$local\Google\Chrome\User Data\*\Cache", "$local\Google\Chrome\User Data\*\Code Cache",
                "$local\Microsoft\Edge\User Data\*\Cache", "$local\Microsoft\Edge\User Data\*\Code Cache",
                "$local\Mozilla\Firefox\Profiles\*\cache2"
            )
        },
        @{ Id = 'thumbs'; Label = (L 'Cache des miniatures de l''Explorateur'); Admin = $false; Roots = @("$local\Microsoft\Windows\Explorer"); Patterns = @('thumbcache_*.db', 'iconcache_*.db'); Flat = $true },
        @{ Id = 'crash'; Label = (L 'Rapports d''erreurs et vidages mémoire'); Admin = $false; Roots = @(
                "$local\CrashDumps", "$local\Microsoft\Windows\WER\ReportArchive", "$local\Microsoft\Windows\WER\ReportQueue"
            )
        },
        @{ Id = 'recycle'; Label = (L 'Corbeille'); Admin = $false; Special = 'recycle' },
        @{ Id = 'wintemp'; Label = (L 'Fichiers temporaires de Windows'); Admin = $true; Roots = @("$win\Temp") },
        @{ Id = 'wupdate'; Label = (L 'Téléchargements Windows Update'); Admin = $true; Roots = @("$win\SoftwareDistribution\Download") }
    )
}

function Resolve-TargetRoots {
    param($Target)
    $roots = @()
    foreach ($r in @($Target.Roots)) {
        if (-not $r) { continue }
        foreach ($resolved in @(Resolve-Path -Path $r -ErrorAction SilentlyContinue)) {
            $p = $resolved.ProviderPath
            if ((Test-Path -LiteralPath $p -PathType Container) -and (Test-SafeRoot $p)) { $roots += $p }
        }
    }
    return $roots
}

function Get-TargetFiles {
    param($Target)
    $all = New-Object System.Collections.ArrayList
    foreach ($root in (Resolve-TargetRoots $Target)) {
        if ($Target.Flat) {
            try {
                foreach ($f in (New-Object IO.DirectoryInfo $root).GetFiles()) {
                    foreach ($p in $Target.Patterns) { if ($f.Name -like $p) { [void]$all.Add($f); break } }
                }
            }
            catch { $null = $_ }
        }
        else { $all.AddRange((Get-TreeFiles -Root $root -Patterns $Target.Patterns)) }
    }
    return , $all
}

function Get-RecycleBinInfo {
    $size = 0.0; $count = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($item in @($shell.Namespace(10).Items())) { $size += [double]$item.Size; $count++ }
    }
    catch { $null = $_ }
    return @{ Size = $size; Count = $count }
}

$targets = Get-CleanTargets
if ($Only) {
    $wanted = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() })
    $unknown = @($wanted | Where-Object { @($targets | ForEach-Object { $_.Id }) -notcontains $_ })
    if ($unknown.Count) { Write-PstStatus err (L 'Cible(s) inconnue(s) : {0} {1} voir « clean -List »' ($unknown -join ', ') $script:Pst.Glyph.Dot); exit 1 }
    $targets = @($targets | Where-Object { $wanted -contains $_.Id })
}

$isAdmin = Test-PstAdmin

if ($List) {
    Show-PstHeader -Tool 'clean' -Subtitle (L 'cibles')
    foreach ($t in $targets) {
        $tag = ''
        if ($t.Admin) { $tag = Paint "  $($script:Pst.Glyph.Lock)" 'Warn' }
        Write-Host ('    ' + (Paint (Format-PstPad $t.Id 10) 'Accent') + $t.Label + $tag)
    }
    Write-Host ''
    exit 0
}

if ($Elevate -and -not $isAdmin) {
    $forward = @()
    if ($DryRun) { $forward += '-DryRun' }
    if ($Only) { $forward += '-Only'; $forward += ($Only -join ',') }
    if (Start-PstElevated -ScriptPath $PSCommandPath -Arguments $forward) { Write-PstStatus ok (L 'Nettoyage relancé dans une fenêtre administrateur.') }
    exit 0
}

# ── Analyse ──────────────────────────────────────────────────────────────────

$subtitle = L 'analyse'
if ($DryRun) { $subtitle = L 'simulation' }
Show-PstHeader -Tool 'clean' -Subtitle $subtitle

$g = $script:Pst.Glyph
$scan = @()
foreach ($t in $targets) {
    $entry = @{ Target = $t; Size = 0.0; Count = 0; Files = $null; Locked = ($t.Admin -and -not $isAdmin) }
    if (-not $entry.Locked) {
        if ($script:Pst.Ansi) { Write-Host ("  $(Paint $g.Pointer 'Accent') " + (L 'Analyse : {0}...' $t.Label) + "$($script:Pst.Esc)[K`r") -NoNewline }
        if ($t.Special -eq 'recycle') {
            $bin = Get-RecycleBinInfo
            $entry.Size = $bin.Size; $entry.Count = $bin.Count
        }
        else {
            $entry.Files = Get-TargetFiles $t
            foreach ($f in $entry.Files) { $entry.Size += $f.Length }
            $entry.Count = $entry.Files.Count
        }
    }
    $scan += $entry
}
if ($script:Pst.Ansi) { Write-Host ("$($script:Pst.Esc)[K") -NoNewline }

$totalSize = 0.0
$maxSize = 1.0
foreach ($s in $scan) { $totalSize += $s.Size; if ($s.Size -gt $maxSize) { $maxSize = $s.Size } }

$rows = @()
foreach ($s in $scan) {
    if ($s.Locked) {
        $rows += , @((Paint $s.Target.Label 'Dim'), (Paint $g.Lock 'Warn'), '', '')
    }
    else {
        $rows += , @($s.Target.Label, (Format-PstSize $s.Size), [string]$s.Count, (Format-PstBar ($s.Size / $maxSize * 100) 16 -Color 'Accent'))
    }
}
$table = Format-PstTable -Columns @(
    @{ Name = (L 'Cible'); Width = 46 }, @{ Name = (L 'Taille'); Width = 10; Right = $true },
    @{ Name = (L 'Éléments'); Width = 8; Right = $true }, @{ Name = ''; Width = 16 }
) -Rows $rows
Format-PstBox -Title (L 'Espace récupérable : {0}' (Format-PstSize $totalSize)) -Lines $table | Write-PstLine
Write-Host ''

$lockedCount = @($scan | Where-Object { $_.Locked }).Count
if ($lockedCount -gt 0) {
    Write-PstStatus info (L '{0} cible(s) système demandent les droits administrateur : relancez avec « clean -Elevate ».' $lockedCount)
}

$candidates = @($scan | Where-Object { -not $_.Locked -and $_.Count -gt 0 })
if ($candidates.Count -eq 0) { Write-PstStatus ok (L 'Tout est déjà propre.'); Write-Host ''; exit 0 }
if ($DryRun) { Write-PstStatus info (L 'Simulation : aucun fichier supprimé.'); Write-Host ''; exit 0 }

# ── Sélection et suppression ─────────────────────────────────────────────────

$chosen = $candidates
if (-not $Yes) {
    if (-not (Test-PstInteractive)) { Write-PstStatus warn (L 'Session non interactive : ajoutez -Yes pour supprimer.'); exit 0 }
    Write-Host ''
    $labels = @($candidates | ForEach-Object { '{0}  {1}' -f (Format-PstPad $_.Target.Label 46), (Format-PstSize $_.Size) })
    $preset = New-Object 'bool[]' $candidates.Count
    for ($i = 0; $i -lt $candidates.Count; $i++) { $preset[$i] = ($candidates[$i].Target.Id -ne 'recycle') }
    $picked = Read-PstMultiChoice -Title (L 'Que voulez-vous nettoyer ?') -Items $labels -Selected $preset
    if ($null -eq $picked -or @($picked).Count -eq 0) { Write-PstStatus info (L 'Annulé, rien n''a été supprimé.'); exit 0 }
    $chosen = @($picked | ForEach-Object { $candidates[$_] })
    $sum = 0.0
    foreach ($c in $chosen) { $sum += $c.Size }
    Write-Host ''
    if (-not (Read-PstConfirm (L 'Supprimer définitivement {0} ?' (Format-PstSize $sum)))) { Write-PstStatus info (L 'Annulé, rien n''a été supprimé.'); exit 0 }
}

Write-Host ''
$freed = 0.0; $skipped = 0
foreach ($c in $chosen) {
    if ($c.Target.Special -eq 'recycle') {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            $freed += $c.Size
            Write-PstStatus ok ("{0}  {1}" -f (Format-PstPad $c.Target.Label 46), (Format-PstSize $c.Size))
        }
        catch { Write-PstStatus warn (L 'Corbeille : {0}' $_.Exception.Message) }
        continue
    }
    $r = Remove-FileList $c.Files
    if (-not $c.Target.Flat) { foreach ($root in (Resolve-TargetRoots $c.Target)) { Remove-EmptyDirs $root } }
    $freed += $r.Freed; $skipped += $r.Skipped
    Write-PstStatus ok ("{0}  {1}" -f (Format-PstPad $c.Target.Label 46), (Format-PstSize $r.Freed))
}

Write-Host ''
$summary = @((Paint (L '{0} libérés' (Format-PstSize $freed)) 'Ok' -Bold))
if ($skipped) { $summary += Paint (L '{0} fichier(s) en cours d''utilisation conservé(s)' $skipped) 'Dim' }
Format-PstBox -Title (L 'Nettoyage terminé') -Lines $summary -Width 60 -Color 'Ok' | Write-PstLine
Write-Host ''
