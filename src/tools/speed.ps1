<#
.SYNOPSIS
    speed — test de débit Internet : latence, téléchargement, envoi.
.DESCRIPTION
    Mesure la latence (médiane de quelques petites requêtes), le débit
    descendant (téléchargements chronométrés, 25 Mo au plus par défaut, sur
    quatre connexions) et le débit montant (10 Mo au plus), puis traduit le
    résultat en usages concrets. Serveur : speed.cloudflare.com (HTTPS, sans
    clé d'API). Le volume de données est annoncé avant le test.
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 200)][int]$Size = 25,
    [switch]$NoUpload,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'speed'

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'speed' -Synopsis (L 'Mesure la latence et les débits de votre connexion Internet.') `
        -Usage @((L 'speed [-Size <Mo>] [-NoUpload] [-Json]')) `
        -Options @(
            @((L '-Size <Mo>'), (L 'Volume maximal téléchargé, de 5 à 200 Mo (défaut : 25)')),
            @('-NoUpload', (L 'Ne mesure pas l''envoi (économise jusqu''à 10 Mo)')),
            @('-Json', (L 'Sortie JSON, pour les scripts'))
        ) `
        -Examples @('speed', 'speed -Size 10 -NoUpload', 'speed -Json') `
        -Notes @(
            (L 'Serveur : speed.cloudflare.com (HTTPS). Chaque mesure s''arrête au bout de 15 secondes.'),
            (L 'Sur une connexion mobile, -Size 10 -NoUpload limite la consommation à environ 10 Mo.')
        )
    exit 0
}

$baseUrl = 'https://speed.cloudflare.com'
if ($env:PSTOOLS_SPEED_URL) { $baseUrl = $env:PSTOOLS_SPEED_URL.TrimEnd('/') }   # réservé aux tests
$downBytes = [long]$Size * 1000000
$upBudget = 0
if (-not $NoUpload) { $upBudget = 10000000 }
$streams = 4
$deadlineMs = 15000
$culture = Get-PstCulture
$interactive = (Test-PstInteractive) -and -not $Json

# ── Verdicts (purs, testables) ───────────────────────────────────────────────

function Get-DownloadVerdict {
    param([double]$Mbps)
    if ($Mbps -lt 1.5) { return @('err', (L 'Très lent : navigation simple seulement, la vidéo va saccader.')) }
    if ($Mbps -lt 5) { return @('warn', (L 'Lent : web et vidéo en basse définition ; visio limitée.')) }
    if ($Mbps -lt 15) { return @('ok', (L 'OK pour la visio HD et la vidéo HD sur un écran.')) }
    if ($Mbps -lt 40) { return @('ok', (L 'Suffisant pour la 4K sur un écran.')) }
    if ($Mbps -lt 200) { return @('ok', (L 'Suffisant pour la 4K sur plusieurs écrans en même temps.')) }
    return @('ok', (L 'Très rapide : 4K partout et gros téléchargements en un clin d''œil.'))
}

function Get-UploadVerdict {
    param([double]$Mbps)
    if ($Mbps -lt 1) { return @('warn', (L 'Envoi faible : visio en qualité réduite, envois de fichiers lents.')) }
    if ($Mbps -lt 3) { return @('ok', (L 'Envoi correct pour la visio HD.')) }
    if ($Mbps -lt 20) { return @('ok', (L 'Envoi confortable : visio HD et partage de fichiers.')) }
    return @('ok', (L 'Envoi rapide : diffusion en direct et sauvegardes en ligne sans attendre.'))
}

function Get-LatencyVerdict {
    param([double]$Ms)
    if ($Ms -lt 30) { return @('ok', (L 'Latence excellente : jeu en ligne et appels très réactifs.')) }
    if ($Ms -lt 80) { return @('ok', (L 'Latence correcte pour les appels et la plupart des jeux.')) }
    if ($Ms -lt 150) { return @('warn', (L 'Latence élevée : léger décalage en visio et en jeu.')) }
    return @('err', (L 'Latence très élevée : décalage net en visio, jeu en ligne difficile.'))
}

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$mid] }
    return ($sorted[$mid - 1] + $sorted[$mid]) / 2
}

function Format-Megabytes {
    # Volumes annoncés en unités décimales (25 Mo = 25 000 000 octets), comme les débits.
    param([double]$Bytes)
    $format = 'N1'
    if ($Bytes % 1000000 -eq 0) { $format = 'N0' }
    $text = ($Bytes / 1e6).ToString($format, $culture)
    return (L '{0} Mo' $text)
}

function Format-Mbps {
    param([double]$Mbps)
    if ($Mbps -ge 100) { return (L '{0} Mbit/s' $Mbps.ToString('N0', $culture)) }
    return (L '{0} Mbit/s' $Mbps.ToString('N1', $culture))
}

# ── Mesures ──────────────────────────────────────────────────────────────────

function Get-FailureText {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.Threading.Tasks.TaskCanceledException] -or $ex -is [TimeoutException]) { return (L 'le serveur ne répond pas (délai dépassé)') }
    return (L 'pas de connexion Internet ou serveur injoignable')
}

function Test-OwnError {
    # Vrai pour les erreurs levées par ce script (message déjà traduit).
    param($ErrorRecord)
    return ($ErrorRecord.Exception.GetType().FullName -eq 'System.Management.Automation.RuntimeException')
}

function Assert-Response {
    param($Response)
    $code = [int]$Response.StatusCode
    if ($code -eq 429) { throw (L 'Trop de tests rapprochés (HTTP 429) : réessayez dans quelques minutes.') }
    if ($code -ge 400) { throw (L 'Le serveur de test a répondu par une erreur (HTTP {0}).' $code) }
}

function Write-ProgressLine {
    param([string]$Label, [double]$Percent, [string]$Detail)
    if (-not $interactive) { return }
    $line = '  ' + (Paint $script:Pst.Glyph.Pointer 'Accent') + ' ' + (Format-PstPad $Label 16) + (Format-PstBar $Percent 24 -Color 'Accent') + '  ' + (Paint $Detail 'Dim')
    Write-Host ("`r" + (Format-PstPad $line ((Get-PstWidth) - 2))) -NoNewline
}

function Clear-ProgressLine {
    if (-not $interactive) { return }
    Write-Host ("`r" + (' ' * ((Get-PstWidth) - 2)) + "`r") -NoNewline
}

function Measure-Latency {
    param($Client)
    $samples = @()
    $server = ''
    for ($k = 0; $k -lt 7; $k++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = $Client.GetAsync("$baseUrl/__down?bytes=0").GetAwaiter().GetResult()
        $sw.Stop()
        Assert-Response $resp
        $ms = $sw.Elapsed.TotalMilliseconds
        # Le serveur indique son propre temps de traitement : on le retire.
        $timing = $null
        if ($resp.Headers.Contains('Server-Timing')) { $timing = @($resp.Headers.GetValues('Server-Timing')) -join ',' }
        if ($timing -match 'dur=([\d.]+)') { $ms = [Math]::Max(0.1, $ms - [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)) }
        if ($resp.Headers.Contains('cf-meta-colo')) { $server = @($resp.Headers.GetValues('cf-meta-colo'))[0] }
        elseif ($resp.Headers.Contains('colo')) { $server = @($resp.Headers.GetValues('colo'))[0] }
        $resp.Dispose()
        if ($k -gt 0) { $samples += $ms }   # la première requête ouvre la connexion (TLS)
    }
    $jitter = 0
    for ($k = 1; $k -lt $samples.Count; $k++) { $jitter += [Math]::Abs($samples[$k] - $samples[$k - 1]) }
    if ($samples.Count -gt 1) { $jitter /= ($samples.Count - 1) }
    return @{ Ms = (Get-Median $samples); Jitter = $jitter; Server = $server }
}

function Measure-Download {
    # Quatre téléchargements en parallèle, lus par blocs : progression et arrêt à 15 s.
    # Chaque flux passe par deux états : attente des en-têtes, puis lecture du corps.
    param($Client, [long]$Total)
    $per = [long][Math]::Ceiling($Total / $streams)
    $cts = New-Object System.Threading.CancellationTokenSource
    $tasks = @{}; $bodies = @{}; $buffers = @{}; $responses = @()
    try {
        for ($k = 0; $k -lt $streams; $k++) {
            $tasks[$k] = $Client.GetAsync("$baseUrl/__down?bytes=$per", [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
            $buffers[$k] = New-Object byte[] 65536
        }
        $active = New-Object System.Collections.ArrayList
        for ($k = 0; $k -lt $streams; $k++) { [void]$active.Add($k) }
        $received = [long]0
        $clock = [Diagnostics.Stopwatch]::StartNew()   # délai global, en-têtes compris
        $sw = New-Object Diagnostics.Stopwatch          # débit : à partir des premières données
        $lastDraw = -1000
        while ($active.Count -gt 0 -and $clock.ElapsedMilliseconds -lt ($deadlineMs + 5000) -and (-not $sw.IsRunning -or $sw.ElapsedMilliseconds -lt $deadlineMs)) {
            $waitList = [System.Threading.Tasks.Task[]]@($active | ForEach-Object { $tasks[$_] })
            $i = [System.Threading.Tasks.Task]::WaitAny($waitList, 200)
            if ($i -ge 0) {
                $k = $active[$i]
                if (-not $bodies.ContainsKey($k)) {
                    $resp = $tasks[$k].GetAwaiter().GetResult()
                    $responses += $resp
                    Assert-Response $resp
                    $bodies[$k] = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    if (-not $sw.IsRunning) { $sw.Start() }
                    $tasks[$k] = $bodies[$k].ReadAsync($buffers[$k], 0, $buffers[$k].Length, $cts.Token)
                }
                else {
                    $n = $tasks[$k].GetAwaiter().GetResult()
                    if ($n -le 0) { $active.RemoveAt($i) }
                    else {
                        $received += $n
                        $tasks[$k] = $bodies[$k].ReadAsync($buffers[$k], 0, $buffers[$k].Length, $cts.Token)
                    }
                }
            }
            if ($clock.ElapsedMilliseconds - $lastDraw -ge 120) {
                $lastDraw = $clock.ElapsedMilliseconds
                $mbps = 0
                if ($sw.Elapsed.TotalSeconds -gt 0) { $mbps = $received * 8 / $sw.Elapsed.TotalSeconds / 1e6 }
                $pct = [Math]::Max($received / [double]$Total, $sw.ElapsedMilliseconds / [double]$deadlineMs) * 100
                Write-ProgressLine (L 'Téléchargement') $pct ('{0} / {1}  {2}' -f (Format-Megabytes $received), (Format-Megabytes $Total), (Format-Mbps $mbps))
            }
        }
        $sw.Stop()
        if ($received -eq 0) { throw (L 'Test impossible : {0}.' (L 'le serveur ne répond pas (délai dépassé)')) }
        $seconds = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        return @{ Mbps = ($received * 8 / $seconds / 1e6); Bytes = $received; Seconds = $seconds; Cut = ($active.Count -gt 0) }
    }
    finally {
        $cts.Cancel()
        foreach ($b in $bodies.Values) { try { $b.Dispose() } catch { $null = $_ } }
        foreach ($r in $responses) { try { $r.Dispose() } catch { $null = $_ } }
        Clear-ProgressLine
    }
}

function Measure-Upload {
    # Petit envoi d'essai (1 Mo), puis un envoi calibré pour durer ~5 s (10 Mo au plus).
    param($Client, [long]$Budget)
    $rng = New-Object System.Random
    $send = {
        param([long]$Bytes, [int]$Parallel)
        $per = [int][Math]::Ceiling($Bytes / $Parallel)
        $data = New-Object byte[] $per
        $rng.NextBytes($data)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tasks = @()
        for ($k = 0; $k -lt $Parallel; $k++) {
            $content = New-Object System.Net.Http.ByteArrayContent (, $data)
            $tasks += $Client.PostAsync("$baseUrl/__up", $content)
        }
        while (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, 150)) {
            Write-ProgressLine (L 'Envoi') ([Math]::Min(99, $sw.ElapsedMilliseconds / 50)) (L '{0} en cours' (Format-Megabytes ($per * $Parallel)))
        }
        $sw.Stop()
        foreach ($t in $tasks) { $resp = $t.GetAwaiter().GetResult(); try { Assert-Response $resp } finally { $resp.Dispose() } }
        return @{ Bytes = [long]$per * $Parallel; Seconds = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001) }
    }
    try {
        $probe = & $send 1000000 1
        $probeMbps = $probe.Bytes * 8 / $probe.Seconds / 1e6
        $target = [long][Math]::Min($Budget - $probe.Bytes, $probeMbps * 1e6 / 8 * 5)
        $total = $probe.Bytes; $seconds = $probe.Seconds
        if ($target -ge 1000000) {
            $main = & $send $target 2
            return @{ Mbps = ($main.Bytes * 8 / $main.Seconds / 1e6); Bytes = ($total + $main.Bytes) }
        }
        return @{ Mbps = $probeMbps; Bytes = $total; Seconds = $seconds }
    }
    finally { Clear-ProgressLine }
}

# ── Exécution ────────────────────────────────────────────────────────────────

$result = [ordered]@{
    Server = ''; LatencyMs = $null; JitterMs = $null; DownloadMbps = $null; UploadMbps = $null
    DownloadBytes = 0; UploadBytes = 0; Partial = $false; UploadError = ''; Verdicts = @()
}

if (-not $Json) {
    Show-PstHeader -Tool 'speed' -Subtitle 'speed.cloudflare.com'
    if ($upBudget -gt 0) { $volume = L 'Ce test va transférer jusqu''à {0} en téléchargement et {1} en envoi.' (Format-Megabytes $downBytes) (Format-Megabytes $upBudget) }
    else { $volume = L 'Ce test va transférer jusqu''à {0} en téléchargement (envoi non mesuré).' (Format-Megabytes $downBytes) }
    Write-PstStatus info $volume
    Write-Host ''
}

if ($env:PSTOOLS_SPEED_FAKE) {
    # Réservé aux tests : « latency=12;jitter=2;down=95.5;up=20 » remplace les mesures réseau.
    $fake = @{}
    foreach ($pair in $env:PSTOOLS_SPEED_FAKE -split ';') {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $fake[$kv[0].Trim()] = [double]::Parse($kv[1], [Globalization.CultureInfo]::InvariantCulture) }
    }
    $result.Server = 'TEST'
    $result.LatencyMs = $fake.latency; $result.JitterMs = $fake.jitter; $result.DownloadMbps = $fake.down
    $result.DownloadBytes = $downBytes
    if ($upBudget -gt 0 -and $fake.ContainsKey('up')) { $result.UploadMbps = $fake.up; $result.UploadBytes = $upBudget }
}
else {
    $client = $null
    try {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
        if ($baseUrl -eq 'offline') { throw (New-Object System.Net.WebException 'offline') }
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('ps-tools-speed/1.0')

        if ($interactive) { Write-Host ('  ' + (Paint ($script:Pst.Glyph.Pointer + ' ' + (L 'Mesure de la latence...')) 'Dim')) -NoNewline }
        $lat = Measure-Latency $client
        Clear-ProgressLine
        $result.LatencyMs = [Math]::Round($lat.Ms, 1); $result.JitterMs = [Math]::Round($lat.Jitter, 1); $result.Server = $lat.Server

        $down = Measure-Download $client $downBytes
        $result.DownloadMbps = [Math]::Round($down.Mbps, 2); $result.DownloadBytes = $down.Bytes; $result.Partial = [bool]$down.Cut
    }
    catch {
        $message = $_.Exception.Message
        if (-not (Test-OwnError $_)) { $message = L 'Test impossible : {0}.' (Get-FailureText $_) }
        if ($Json) { [ordered]@{ Error = $message } | ConvertTo-Json }
        else { Clear-ProgressLine; Write-PstStatus err $message }
        if ($client) { $client.Dispose() }
        exit 1
    }
    if ($upBudget -gt 0) {
        try {
            $up = Measure-Upload $client $upBudget
            $result.UploadMbps = [Math]::Round($up.Mbps, 2); $result.UploadBytes = $up.Bytes
        }
        catch {
            $result.UploadError = $_.Exception.Message
            if (-not (Test-OwnError $_)) { $result.UploadError = Get-FailureText $_ }
        }
    }
    $client.Dispose()
}

$verdicts = @()
if ($null -ne $result.DownloadMbps) { $verdicts += , (Get-DownloadVerdict $result.DownloadMbps) }
if ($null -ne $result.UploadMbps) { $verdicts += , (Get-UploadVerdict $result.UploadMbps) }
if ($null -ne $result.LatencyMs) { $verdicts += , (Get-LatencyVerdict $result.LatencyMs) }
$result.Verdicts = @($verdicts | ForEach-Object { [ordered]@{ Level = $_[0]; Text = $_[1] } })

if ($Json) { $result | ConvertTo-Json -Depth 4; exit 0 }

# ── Rendu ────────────────────────────────────────────────────────────────────

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 76
$label = 16
function Get-SpeedBar {
    # Échelle logarithmique : 1 Mbit/s → 0 %, 1 Gbit/s → 100 %.
    param([double]$Mbps)
    $pct = [Math]::Max(0, [Math]::Min(100, [Math]::Log10([Math]::Max($Mbps, 1)) / 3 * 100))
    return (Format-PstBar $pct 20 -Color 'Accent')
}
$lines = @()
$latencyText = ([double]$result.LatencyMs).ToString('N0', $culture)
$jitterText = ([double]$result.JitterMs).ToString('N0', $culture)
$lines += (Paint (Format-PstPad (L 'Latence') $label) 'Accent') + (Paint (L '{0} ms' $latencyText) 'Title' -Bold) + (Paint ('  ' + (L '(gigue {0} ms)' $jitterText)) 'Dim')
$lines += (Paint (Format-PstPad (L 'Téléchargement') $label) 'Accent') + (Format-PstPad (Paint (Format-Mbps $result.DownloadMbps) 'Title' -Bold) 16) + (Get-SpeedBar $result.DownloadMbps)
if ($null -ne $result.UploadMbps) {
    $lines += (Paint (Format-PstPad (L 'Envoi') $label) 'Accent') + (Format-PstPad (Paint (Format-Mbps $result.UploadMbps) 'Title' -Bold) 16) + (Get-SpeedBar $result.UploadMbps)
}
elseif ($upBudget -gt 0) {
    $lines += (Paint (Format-PstPad (L 'Envoi') $label) 'Accent') + (Paint (L 'non mesuré ({0})' (Limit-PstText $result.UploadError 40)) 'Warn')
}
$lines += ''
foreach ($v in $verdicts) {
    $mark = switch ($v[0]) { 'ok' { Paint $g.Ok 'Ok' -Bold } 'warn' { Paint $g.Warn 'Warn' -Bold } default { Paint $g.Err 'Err' -Bold } }
    foreach ($part in (Format-PstWrap $v[1] ($width - 8))) {
        $lines += "$mark $part"
        $mark = ' '
    }
}
Format-PstBox -Title (L 'Résultat') -Lines $lines -Width $width -Color 'Accent' | Write-PstLine
Write-Host ''
$foot = L 'Données transférées : {0}' (Format-Megabytes ($result.DownloadBytes + $result.UploadBytes))
if ($result.Server) { $foot += "  $($g.Dot)  " + (L 'serveur Cloudflare {0}' $result.Server) }
Write-Host ('  ' + (Paint $foot 'Dim'))
if ($result.Partial) { Write-Host ('  ' + (Paint (L 'Téléchargement arrêté au bout de 15 s : débit mesuré sur les données reçues.') 'Dim')) }
Write-Host ''
exit 0
