<#
.SYNOPSIS
    events — les erreurs et avertissements récents du journal Windows, regroupés.
.DESCRIPTION
    Lit les journaux Système et Application sans droits administrateur.
    Le journal Sécurité (-Log Security) demande une session administrateur.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 8760)][int]$Hours = 24,
    [string[]]$Log = @('System', 'Application'),
    [ValidateSet('error', 'warn', 'all')][string]$Level = 'warn',
    [ValidateRange(1, 200)][int]$Top = 15,
    [int]$Id = 0,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'events' -Synopsis 'Que s''est-il passé sur cette machine ? Les événements Windows qui comptent.' `
        -Usage @('events [-Hours <n>] [-Level error|warn|all] [-Log <journaux>] [-Top <n>]', 'events -Id <n>      détail du dernier événement portant cet identifiant') `
        -Options @(
            @('-Hours <n>', 'Période analysée en heures (défaut : 24)'),
            @('-Level', 'error : critiques et erreurs · warn : + avertissements (défaut) · all : tout'),
            @('-Log <journaux>', 'Journaux lus (défaut : System,Application)'),
            @('-Top <n>', 'Nombre de groupes affichés (défaut : 15)'),
            @('-Id <n>', 'Affiche le message complet d''un événement'),
            @('-Json', 'Sortie JSON, pour les scripts')
        ) `
        -Examples @('events', 'events -Hours 72 -Level error', 'events -Id 7031', 'events -Json | ask "y a-t-il un problème sérieux ?"')
    exit 0
}

Assert-PstWindows 'events'

$Log = @($Log | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$levels = switch ($Level) { 'error' { 1, 2 } 'warn' { 1, 2, 3 } default { 1, 2, 3, 4 } }
$since = (Get-Date).AddHours(-$Hours)
$g = $script:Pst.Glyph

$found = New-Object System.Collections.ArrayList
$denied = @()
foreach ($name in $Log) {
    $query = @{ LogName = $name; StartTime = $since; Level = $levels }
    if ($Id -gt 0) { $query.Id = $Id }
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable $query -MaxEvents 3000 -ErrorAction Stop)) { [void]$found.Add($e) }
    }
    catch {
        # « Aucun événement » n'est pas une erreur ; tout le reste (accès refusé, journal absent) est signalé.
        if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatchingEventsFound') { $denied += $name }
    }
}

function Get-FirstLine {
    param([string]$Message)
    if (-not $Message) { return '(message indisponible)' }
    return (@($Message -split "`r?`n" | Where-Object { $_.Trim() })[0]).Trim()
}

if ($Id -gt 0 -and -not $Json) {
    Show-PstHeader -Tool 'events' -Subtitle "événement $Id"
    $last = $found | Sort-Object TimeCreated -Descending | Select-Object -First 1
    if (-not $last) { Write-PstStatus info "Aucun événement $Id sur les $Hours dernières heures."; Write-Host ''; exit 0 }
    Write-PstStatus info "$($last.ProviderName) $($g.Dot) $($last.LogName) $($g.Dot) $($last.TimeCreated.ToString('dd/MM/yyyy HH:mm:ss')) $($g.Dot) $($found.Count) occurrence(s)"
    Write-Host ''
    foreach ($line in @("$($last.Message)" -split "`r?`n")) { Write-Host "    $line" }
    Write-Host ''
    exit 0
}

# Regroupement par source + identifiant : un service qui plante 40 fois = une ligne.
$groups = @($found | Group-Object { "$($_.LogName)|$($_.ProviderName)|$($_.Id)" } | ForEach-Object {
        $latest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [pscustomobject]@{
            Level = [int]$latest.Level; Count = $_.Count; Id = [int]$latest.Id; Source = [string]$latest.ProviderName
            Log = [string]$latest.LogName; Last = $latest.TimeCreated; Message = (Get-FirstLine $latest.Message)
        }
    } | Sort-Object Level, @{ Expression = 'Count'; Descending = $true } | Select-Object -First $Top)

if ($Json) { ConvertTo-Json -InputObject @($groups) -Depth 3; exit 0 }

$critical = @($found | Where-Object { $_.Level -le 2 }).Count
$warnings = @($found | Where-Object { $_.Level -eq 3 }).Count
Show-PstHeader -Tool 'events' -Subtitle "$Hours dernières heures $($g.Dot) $($Log -join ', ')"

$summaryColor = 'Ok'
if ($critical -gt 0) { $summaryColor = 'Err' } elseif ($warnings -gt 0) { $summaryColor = 'Warn' }
Write-Host ('  ' + (Paint "$critical erreur(s)" $summaryColor -Bold) + (Paint " $($g.Dot) $warnings avertissement(s) $($g.Dot) $($found.Count) événement(s) au total" 'Dim'))
Write-Host ''
foreach ($d in $denied) { Write-PstStatus warn "Journal « $d » illisible (droits administrateur requis, ou journal inexistant)." }

if ($groups.Count -eq 0) { Write-PstStatus ok 'Rien à signaler sur la période.'; Write-Host ''; exit 0 }

$width = Get-PstWidth -Max 120
$messageW = [Math]::Max(20, $width - 62)
$rows = @()
foreach ($x in $groups) {
    switch ($x.Level) {
        1 { $mark = Paint 'CRIT' 'Err' -Bold }
        2 { $mark = Paint 'ERR ' 'Err' }
        3 { $mark = Paint 'WARN' 'Warn' }
        default { $mark = Paint 'INFO' 'Dim' }
    }
    $rows += , @($mark, (Paint "x$($x.Count)" 'Title'), [string]$x.Id, (Limit-PstText $x.Source 24), $x.Last.ToString('dd/MM HH:mm'), (Paint (Limit-PstText $x.Message $messageW) 'Dim'))
}
Format-PstTable -Columns @(
    @{ Name = 'Niv.'; Width = 4 }, @{ Name = 'Nb'; Width = 5; Right = $true }, @{ Name = 'ID'; Width = 6; Right = $true },
    @{ Name = 'Source'; Width = 24 }, @{ Name = 'Dernier'; Width = 11 }, @{ Name = 'Message'; Width = $messageW }
) -Rows $rows | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host (Paint "  events -Id <ID> pour le message complet $($g.Dot) events -Json | ask `"que faut-il corriger ?`"" 'Dim')
Write-Host ''
