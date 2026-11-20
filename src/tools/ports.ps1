<#
.SYNOPSIS
    ports — qui écoute sur quel port ? (équivalent de « ss -ltnp » / « lsof -i »)
.DESCRIPTION
    Lecture sans droits administrateur. Fermer le processus d'un autre
    utilisateur ou d'un service (-Kill) demande une session administrateur.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Filter,
    [switch]$Udp,
    [int]$Kill = 0,
    [switch]$Yes,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'ports'

if ($Help -or (Test-PstHelpArg (@($Filter) + @($Rest)))) {
    Show-PstHelp -Name 'ports' -Synopsis (L 'Liste les ports en écoute et les processus associés.') `
        -Usage @((L 'ports [filtre] [-Udp] [-Json]'), 'ports -Kill <port> [-Yes]') `
        -Options @(
            @((L 'filtre'), (L 'Numéro de port ou morceau de nom de processus')),
            @('-Udp', (L 'Inclut aussi les points de terminaison UDP')),
            @('-Kill <port>', (L 'Arrête le processus qui écoute sur ce port')),
            @('-Yes', (L 'Avec -Kill : ne demande pas de confirmation')),
            @('-Json', (L 'Sortie JSON, pour les scripts'))
        ) `
        -Examples @('ports', 'ports 3000', 'ports node', 'ports -Kill 8080')
    exit 0
}

Assert-PstWindows 'ports'

function Get-Listeners {
    $names = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[[int]$p.Id] = $p.ProcessName }
    $list = New-Object System.Collections.ArrayList
    try {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            [void]$list.Add([pscustomobject]@{ Proto = 'TCP'; Address = $c.LocalAddress; Port = [int]$c.LocalPort; ProcessId = [int]$c.OwningProcess; Process = [string]$names[[int]$c.OwningProcess] })
        }
        if ($Udp) {
            foreach ($c in @(Get-NetUDPEndpoint -ErrorAction Stop)) {
                [void]$list.Add([pscustomobject]@{ Proto = 'UDP'; Address = $c.LocalAddress; Port = [int]$c.LocalPort; ProcessId = [int]$c.OwningProcess; Process = [string]$names[[int]$c.OwningProcess] })
            }
        }
    }
    catch {
        # Repli universel : netstat (présent sur tous les Windows)
        foreach ($line in @(& netstat.exe -ano 2>$null)) {
            $parts = @($line.Trim() -split '\s+')
            $isTcp = ($parts.Count -eq 5 -and $parts[0] -eq 'TCP' -and $parts[3] -eq 'LISTENING')
            $isUdp = ($Udp -and $parts.Count -eq 4 -and $parts[0] -eq 'UDP')
            if (-not ($isTcp -or $isUdp)) { continue }
            $cut = $parts[1].LastIndexOf(':')
            $procId = [int]$parts[$parts.Count - 1]
            [void]$list.Add([pscustomobject]@{ Proto = $parts[0]; Address = $parts[1].Substring(0, $cut).Trim('[', ']'); Port = [int]$parts[1].Substring($cut + 1); ProcessId = $procId; Process = [string]$names[$procId] })
        }
    }
    return @($list | Sort-Object Port, Proto, Address)
}

$all = @(Get-Listeners)

# ── Arrêt d'un processus par port ────────────────────────────────────────────

if ($Kill -gt 0) {
    Show-PstHeader -Tool 'ports' -Subtitle (L 'libérer le port {0}' $Kill)
    $hits = @($all | Where-Object { $_.Port -eq $Kill } | Sort-Object ProcessId -Unique)
    if ($hits.Count -eq 0) { Write-PstStatus info (L 'Aucun processus n''écoute sur le port {0}.' $Kill); Write-Host ''; exit 0 }
    foreach ($h in $hits) {
        $label = "$($h.Process) (PID $($h.ProcessId))"
        if ($h.ProcessId -le 4) { Write-PstStatus warn (L '{0} est un processus système : il ne sera pas arrêté.' $label); continue }
        if (-not $Yes -and -not (Read-PstConfirm (L 'Arrêter {0} ?' $label))) { Write-PstStatus info (L '{0} conservé.' $label); continue }
        try {
            Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop
            Write-PstStatus ok (L '{0} arrêté, port {1} libéré.' $label $Kill)
        }
        catch {
            Write-PstStatus err (L 'Impossible d''arrêter {0} : {1}' $label $_.Exception.Message)
            if (-not (Test-PstAdmin)) { Write-PstStatus info (L 'Ce processus appartient sans doute au système : réessayez depuis un terminal administrateur.') }
        }
    }
    Write-Host ''
    exit 0
}

# ── Liste ────────────────────────────────────────────────────────────────────

$shown = @($all)
if ($Filter) {
    if ($Filter -match '^\d+$') { $shown = @($all | Where-Object { $_.Port -eq [int]$Filter }) }
    else { $shown = @($all | Where-Object { $_.Process -like "*$Filter*" }) }
}

if ($Json) { ConvertTo-Json -InputObject @($shown) -Depth 3; exit 0 }

$g = $script:Pst.Glyph
$known = @{
    21 = 'FTP'; 22 = 'SSH'; 25 = 'SMTP'; 53 = 'DNS'; 80 = 'HTTP'; 135 = 'RPC'; 139 = 'NetBIOS'; 443 = 'HTTPS'; 445 = 'SMB'
    1433 = 'SQL Server'; 3000 = 'Dev (Node)'; 3306 = 'MySQL'; 3389 = (L 'Bureau à distance'); 5000 = 'Dev'; 5173 = 'Vite'
    5432 = 'PostgreSQL'; 5985 = 'WinRM'; 6379 = 'Redis'; 8000 = 'Dev'; 8080 = 'HTTP alt.'; 27017 = 'MongoDB'
}

$subtitle = L '{0} port(s) en écoute' $shown.Count
if ($Filter) { $subtitle += ' ' + (L '{0} filtre « {1} »' $g.Dot $Filter) }
Show-PstHeader -Tool 'ports' -Subtitle $subtitle

if ($shown.Count -eq 0) { Write-PstStatus info (L 'Aucun port ne correspond.'); Write-Host ''; exit 0 }

$rows = @()
foreach ($s in $shown) {
    # Une écoute sur toutes les interfaces est joignable depuis le réseau.
    $exposed = @('0.0.0.0', '::') -contains $s.Address
    if ($exposed) { $scope = Paint (L 'réseau') 'Warn' } else { $scope = Paint (L 'local') 'Ok' }
    $proc = $s.Process
    if (-not $proc) { $proc = '?' }
    $protoColor = 'Accent'
    if ($s.Proto -eq 'UDP') { $protoColor = 'Accent2' }
    $rows += , @(
        (Paint $s.Proto $protoColor), (Paint ([string]$s.Port) 'Title' -Bold), (Limit-PstText $s.Address 24), $scope,
        [string]$s.ProcessId, (Limit-PstText $proc 26), (Paint ([string]$known[$s.Port]) 'Dim')
    )
}
Format-PstTable -Columns @(
    @{ Name = 'Proto'; Width = 5 }, @{ Name = 'Port'; Width = 6; Right = $true }, @{ Name = (L 'Adresse'); Width = 24 },
    @{ Name = (L 'Portée'); Width = 7 }, @{ Name = 'PID'; Width = 7; Right = $true }, @{ Name = (L 'Processus'); Width = 26 }, @{ Name = (L 'Usage courant'); Width = 18 }
) -Rows $rows | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host (Paint ('  ' + (L '« réseau » = joignable depuis d''autres machines {0} ports -Kill <port> pour libérer un port' $g.Dot)) 'Dim')
Write-Host ''
