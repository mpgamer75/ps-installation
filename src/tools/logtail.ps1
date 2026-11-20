<#
.SYNOPSIS
    logtail — suit un fichier journal en direct, avec couleurs par niveau et filtre.
.DESCRIPTION
    Équivalent de « tail -f » enrichi. Le fichier est ouvert en lecture partagée :
    l'application qui l'écrit n'est jamais bloquée. Gère la rotation des journaux.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [ValidateRange(0, 100000)][int]$Lines = 20,
    [string]$Filter,
    [string]$Exclude,
    [switch]$NoFollow,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'logtail'

if ($Help -or -not $Path -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'logtail' -Synopsis (L 'Affiche la fin d''un journal et suit les nouvelles lignes.') `
        -Usage @(L 'logtail <fichier> [-Lines <n>] [-Filter <regex>] [-Exclude <regex>] [-NoFollow]') `
        -Options @(
            @('-Lines <n>', (L 'Nombre de lignes initiales (défaut : 20)')),
            @('-Filter <regex>', (L 'Ne garde que les lignes correspondantes (surlignées)')),
            @('-Exclude <regex>', (L 'Masque les lignes correspondantes')),
            @('-NoFollow', (L 'Affiche la fin du fichier puis quitte'))
        ) `
        -Examples @('logtail .\app.log', 'logtail C:\logs\api.log -Filter "error|timeout"', 'logtail app.log -Lines 100 -NoFollow') `
        -Notes @(L 'Touches : Q quitter · Espace insérer un repère horodaté')
    if ($Help -or $Path) { exit 0 } else { exit 1 }
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-PstStatus err (L 'Fichier introuvable : {0}' $Path); exit 1 }
$file = (Resolve-Path -LiteralPath $Path).ProviderPath
$g = $script:Pst.Glyph
$stats = @{ Error = 0; Warn = 0; Shown = 0 }

function Format-LogLine {
    # Colore selon le niveau détecté et surligne le filtre.
    param([string]$Line)
    $color = $null
    if ($Line -match '(?i)\b(fatal|critical|error|erreur|exception|fail(ed|ure)?|panic)\b') { $color = 'Err'; $stats.Error++ }
    elseif ($Line -match '(?i)\b(warn(ing)?|avertissement|deprecated)\b') { $color = 'Warn'; $stats.Warn++ }
    elseif ($Line -match '(?i)\b(debug|trace|verbose)\b') { $color = 'Dim' }
    elseif ($Line -match '(?i)\b(success|succès|ok|done|started|listening)\b') { $color = 'Ok' }
    if ($Filter -and $script:Pst.Ansi) {
        $e = $script:Pst.Esc
        $prefix = ''
        if ($color) { $rgb = $script:Pst.Theme[$color]; $prefix = "$e[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m" }
        $marked = [regex]::Replace($Line, "(?i)$Filter", { param($m) "$e[7m$($m.Value)$e[27m" })
        return "$prefix$marked$e[0m"
    }
    return (Paint $Line $color)
}

function Write-LogLine {
    param([string]$Line)
    if ($Filter -and $Line -notmatch "(?i)$Filter") { return }
    if ($Exclude -and $Line -match "(?i)$Exclude") { return }
    $stats.Shown++
    Write-Host (Format-LogLine $Line)
}

foreach ($pattern in $Filter, $Exclude) {
    if ($pattern) { try { $null = [regex]::new($pattern) } catch { Write-PstStatus err (L 'Expression régulière invalide : {0}' $pattern); exit 1 } }
}

$stream = $null
try {
    $stream = New-Object IO.FileStream $file, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]'ReadWrite, Delete')
    $reader = New-Object IO.StreamReader $stream, ([Text.Encoding]::UTF8), $true

    $subtitle = [IO.Path]::GetFileName($file)
    if ($Filter) { $subtitle += ' ' + (L '{0} filtre « {1} »' $g.Dot $Filter) }
    Show-PstHeader -Tool 'logtail' -Subtitle $subtitle

    # Dernières lignes : lecture complète en file bornée (suffisant jusqu'à plusieurs centaines de Mo).
    $tail = New-Object 'System.Collections.Generic.Queue[string]'
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($Lines -eq 0) { continue }
        $tail.Enqueue($line)
        if ($tail.Count -gt $Lines) { [void]$tail.Dequeue() }
    }
    foreach ($line in $tail) { Write-LogLine $line }

    if (-not $NoFollow) {
        $interactive = Test-PstInteractive
        if ($interactive) { try { [Console]::TreatControlCAsInput = $true } catch { $null = $_ } }
        $position = $stream.Position
        $pending = ''
        while ($true) {
            $length = (New-Object IO.FileInfo $file).Length
            if ($length -lt $position) {
                # Fichier tronqué ou remplacé (rotation) : on repart du début.
                Write-Host (Paint (L '{0} journal réinitialisé {0}' ($g.H * 3)) 'Accent2')
                $stream.Seek(0, [IO.SeekOrigin]::Begin) | Out-Null
                $reader.DiscardBufferedData()
                $position = 0
                $pending = ''
            }
            if ($length -gt $position) {
                $chunk = $reader.ReadToEnd()
                $position = $stream.Position
                $parts = ($pending + $chunk) -split "`r?`n"
                $pending = $parts[$parts.Count - 1]      # ligne incomplète : attend la suite
                for ($i = 0; $i -lt $parts.Count - 1; $i++) { Write-LogLine $parts[$i] }
            }
            if ($interactive) {
                $key = Read-PstKey -TimeoutMs 400
                if (Test-PstQuitKey $key) { break }
                if ($key -and $key.Key -eq 'Spacebar') { Write-Host (Paint (L '{0} repère {1} {0}' ($g.H * 3) (Get-Date -Format 'HH:mm:ss')) 'Accent') }
            }
            else { Start-Sleep -Milliseconds 400 }
        }
    }
}
catch { Write-PstStatus err (L 'Lecture impossible : {0}' $_.Exception.Message); exit 1 }
finally {
    try { [Console]::TreatControlCAsInput = $false } catch { $null = $_ }
    if ($stream) { $stream.Dispose() }
}

Write-Host ''
Write-Host (Paint ('  ' + (L '{1} ligne(s) {0} {2} erreur(s) {0} {3} avertissement(s)' $g.Dot $stats.Shown $stats.Error $stats.Warn)) 'Dim')
Write-Host ''
