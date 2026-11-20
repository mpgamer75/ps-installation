<#
.SYNOPSIS
    watch — relance une commande à intervalle régulier et met en évidence ce qui change.
.DESCRIPTION
    Équivalent de « watch -d » sous Linux. Aucun droit administrateur requis.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Command,
    [ValidateRange(1, 3600)][int]$Interval = 2,
    [ValidateRange(0, 100000)][int]$Count = 0,
    [switch]$NoDiff,
    [switch]$Help
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'watch'

if ($Help -or -not $Command -or (Test-PstHelpArg $Command)) {
    Show-PstHelp -Name 'watch' -Synopsis (L 'Observe la sortie d''une commande dans le temps.') `
        -Usage @(L 'watch [-Interval <s>] [-Count <n>] [-NoDiff] <commande>') `
        -Options @(
            @('-Interval <s>', (L 'Délai entre deux exécutions (défaut : 2)')),
            @('-Count <n>', (L 'Nombre d''exécutions (défaut : 0 = jusqu''à Q)')),
            @('-NoDiff', (L 'Ne surligne pas les lignes modifiées'))
        ) `
        -Examples @('watch "Get-ChildItem *.log"', 'watch -Interval 5 "git status -s"', 'watch "ports 3000"') `
        -Notes @(L 'Touches : Q quitter · Espace relancer tout de suite')
    if ($Help -or $Command) { exit 0 } else { exit 1 }
}

$text = ($Command -join ' ')
$block = [scriptblock]::Create($text)
$g = $script:Pst.Glyph
$interactive = Test-PstInteractive
if (-not $interactive -and $Count -eq 0) { $Count = 1 }

function Get-Output {
    try { $out = & $block 2>&1 | Out-String -Width 200 }
    catch { $out = L 'Erreur : {0}' $_.Exception.Message }
    return @(($out -replace "`r", '').TrimEnd() -split "`n")
}

$previous = $null
$changes = 0
$runs = 0
if ($interactive) { Start-PstScreen }
try {
    while ($true) {
        $lines = Get-Output
        $runs++
        $width = Get-PstWidth -Max 200
        $flags = New-Object 'bool[]' $lines.Count
        $changed = ($null -ne $previous -and $previous.Count -ne $lines.Count)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $flags[$i] = ($null -ne $previous -and ($i -ge $previous.Count -or $previous[$i] -ne $lines[$i]))
            if ($flags[$i]) { $changed = $true }
        }
        if ($changed) { $changes++ }
        $previous = $lines

        $frame = @()
        $frame += ' ' + (Get-PstHeaderLine -Tool 'watch' -Subtitle (Limit-PstText $text 50) -Width ($width - 1))
        $frame += ' ' + (Paint (L 'toutes les {1}s {0} exécution n° {2} {0} {3} changement(s) {0} {4} {0} Q quitter' $g.Dot $Interval $runs $changes (Get-Date -Format 'HH:mm:ss')) 'Dim')
        $frame += ''
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = Limit-PstText $lines[$i] ($width - 2)
            if ($flags[$i] -and -not $NoDiff) { $frame += (Paint $g.V 'Warn') + ' ' + (Paint $line 'Warn') }
            else { $frame += '  ' + $line }
        }

        if ($interactive) { Write-PstFrame $frame } else { $frame | Write-PstLine }
        if ($Count -gt 0 -and $runs -ge $Count) { break }
        if ($interactive) {
            $key = Read-PstKey -TimeoutMs ($Interval * 1000)
            if (Test-PstQuitKey $key) { break }
        }
        else { Start-Sleep -Seconds $Interval }
    }
}
finally { if ($interactive) { Stop-PstScreen } }
