<#
.SYNOPSIS
    weather — la météo du moment et les prévisions sur trois jours.
.DESCRIPTION
    Conditions actuelles (température, ressenti, vent, humidité) et prévisions
    à trois jours, obtenues par une requête HTTPS vers wttr.in (aucune clé
    d'API). La ville choisie avec -Set est mémorisée dans le dossier de données ;
    sans ville, wttr.in déduit la position de l'adresse IP.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$City,
    [string]$Set,
    [switch]$Forget,
    [switch]$Imperial,
    [switch]$Metric,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'weather'

if ($Help -or (Test-PstHelpArg (@($City) + @($Rest)))) {
    Show-PstHelp -Name 'weather' -Synopsis (L 'Météo actuelle et prévisions à trois jours.') `
        -Usage @(
            (L 'weather [ville] [-Imperial] [-Json]'),
            (L 'weather -Set <ville> [-Imperial]     mémorise la ville (et les unités)'),
            (L 'weather -Forget                      oublie la ville mémorisée')
        ) `
        -Options @(
            @((L 'ville'), (L 'Ville à afficher (défaut : ville mémorisée, sinon position de l''IP)')),
            @((L '-Set <ville>'), (L 'Mémorise la ville par défaut')),
            @('-Imperial', (L 'Unités impériales (°F, mph, pouces)')),
            @('-Metric', (L 'Unités métriques (défaut)')),
            @('-Json', (L 'Sortie JSON, pour les scripts'))
        ) `
        -Examples @('weather', 'weather Lyon', 'weather -Set "Saint-Malo"', 'weather "New York" -Imperial', 'weather -Json') `
        -Notes @((L 'Données : wttr.in (requête HTTPS, sans clé d''API).'))
    exit 0
}

# ── Réglages ─────────────────────────────────────────────────────────────────

$settingsFile = Join-Path (Get-PstDataDir) 'weather.json'
$settings = Read-PstJsonFile $settingsFile
if (-not ($settings -is [hashtable])) { $settings = @{} }

if ($Forget) {
    if (Test-Path -LiteralPath $settingsFile) { Remove-Item -LiteralPath $settingsFile -Force }
    Write-PstStatus ok (L 'Ville oubliée : la position sera déduite de l''adresse IP.')
    exit 0
}

if ($Set) {
    $settings.city = $Set.Trim()
    if ($Imperial) { $settings.units = 'imperial' } elseif ($Metric -or -not $settings.units) { $settings.units = 'metric' }
    Write-PstJsonFile $settingsFile $settings
    if (-not $Json) { Write-PstStatus ok (L 'Ville mémorisée : {0}' $settings.city) }
    $City = $settings.city
}

if (-not $City -and $Rest) { $City = ($Rest -join ' ') }
elseif ($City -and $Rest) { $City = (@($City) + @($Rest)) -join ' ' }
if (-not $City -and $settings.city) { $City = [string]$settings.city }
$useImperial = $Imperial -or (-not $Metric -and $settings.units -eq 'imperial')

# ── Données ──────────────────────────────────────────────────────────────────

function Get-WeatherUrl {
    param([string]$Place)
    $path = ''
    if ($Place) { $path = [Uri]::EscapeDataString($Place.Trim()) }
    $url = "https://wttr.in/$($path)?format=j1"
    if ($script:Pst.Lang -eq 'fr') { $url += '&lang=fr' }
    # Réservé aux tests : un chemin de fichier (réponse enregistrée) ou « offline ».
    if ($env:PSTOOLS_WEATHER_URL) { $url = $env:PSTOOLS_WEATHER_URL }
    return $url
}

function Get-WeatherText {
    # Retourne le JSON brut ; lève une erreur au message déjà traduit.
    param([string]$Url, [string]$Place)
    if ($Url -eq 'offline') { throw (L 'Pas de connexion Internet ou wttr.in injoignable.') }
    if (Test-Path -LiteralPath $Url -PathType Leaf) { return [IO.File]::ReadAllText($Url, [Text.Encoding]::UTF8) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
    $ProgressPreference = 'SilentlyContinue'
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -UserAgent 'curl/8 (ps-tools)' -ErrorAction Stop
        return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    }
    catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { $code = 0 }
        $body = ''
        try { $body = [string]$_.ErrorDetails.Message } catch { $body = '' }
        if ($code -eq 429) { throw (L 'wttr.in limite le nombre de requêtes (HTTP 429) : réessayez dans quelques minutes.') }
        if ($code -eq 404 -or $body -match '(?i)unknown location|location not found') { throw (L 'Ville inconnue : « {0} ».' $Place) }
        if ($code -gt 0) { throw (L 'wttr.in a répondu par une erreur (HTTP {0}) : réessayez plus tard.' $code) }
        throw (L 'Pas de connexion Internet ou wttr.in injoignable.')
    }
}

function Get-Field {
    # Valeur d'un champ wttr.in, qui sont des tableaux [{ value = ... }].
    param($Node, [string]$Name)
    $v = $Node.$Name
    if ($null -eq $v) { return '' }
    if ($v -is [array] -or $v -is [System.Collections.IList]) {
        if (@($v).Count -eq 0) { return '' }
        $v = @($v)[0]
    }
    if ($v.PSObject.Properties['value']) { return [string]$v.value }
    return [string]$v
}

function Get-Description {
    param($Node)
    $d = ''
    if ($script:Pst.Lang -eq 'fr') { $d = Get-Field $Node 'lang_fr' }
    if (-not $d) { $d = Get-Field $Node 'weatherDesc' }
    return $d.Trim()
}

function Get-WindDirection {
    param([string]$Point)
    if ($script:Pst.Lang -ne 'fr') { return $Point }
    return ($Point -replace 'W', 'O')
}

function ConvertFrom-WttrJson {
    # Transforme la réponse wttr.in (format j1) en objet simple, testable hors ligne.
    param([string]$Text, [string]$Place)
    try { $data = $Text.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw (L 'Réponse illisible de wttr.in : réessayez plus tard.') }
    if ($null -eq $data -or $null -eq $data.current_condition) { throw (L 'Réponse illisible de wttr.in : réessayez plus tard.') }
    $cur = @($data.current_condition)[0]
    $area = $null
    if ($data.nearest_area) { $area = @($data.nearest_area)[0] }
    $areaName = ''; $country = ''; $region = ''
    if ($area) { $areaName = Get-Field $area 'areaName'; $country = Get-Field $area 'country'; $region = Get-Field $area 'region' }
    $name = $areaName
    if ($Place) { $name = (Get-Culture).TextInfo.ToTitleCase($Place.Trim()) }

    $days = @()
    foreach ($d in @($data.weather | Select-Object -First 3)) {
        $hours = @($d.hourly)
        $noon = $hours | Where-Object { [string]$_.time -eq '1200' } | Select-Object -First 1
        if (-not $noon -and $hours.Count) { $noon = $hours[[int][Math]::Floor($hours.Count / 2)] }
        $rain = 0; $snow = 0
        foreach ($h in $hours) {
            $rain = [Math]::Max($rain, [int]$h.chanceofrain)
            $snow = [Math]::Max($snow, [int]$h.chanceofsnow)
        }
        $days += [ordered]@{
            Date = [string]$d.date
            MinC = [int]$d.mintempC; MaxC = [int]$d.maxtempC; MinF = [int]$d.mintempF; MaxF = [int]$d.maxtempF
            Code = [int]$noon.weatherCode; Description = (Get-Description $noon)
            RainChance = $rain; SnowChance = $snow
            Sunrise = ''; Sunset = ''
        }
        if ($d.astronomy) {
            $astro = @($d.astronomy)[0]
            $days[-1].Sunrise = [string]$astro.sunrise
            $days[-1].Sunset = [string]$astro.sunset
        }
    }
    return [ordered]@{
        Location = [ordered]@{ Name = $name; Area = $areaName; Region = $region; Country = $country }
        Current  = [ordered]@{
            TempC = [int]$cur.temp_C; TempF = [int]$cur.temp_F; FeelsLikeC = [int]$cur.FeelsLikeC; FeelsLikeF = [int]$cur.FeelsLikeF
            Humidity = [int]$cur.humidity; WindKmh = [int]$cur.windspeedKmph; WindMph = [int]$cur.windspeedMiles
            WindDir = [string]$cur.winddir16Point; PrecipMM = [double]::Parse(('0' + [string]$cur.precipMM), [Globalization.CultureInfo]::InvariantCulture)
            PrecipIn = [double]::Parse(('0' + [string]$cur.precipInches), [Globalization.CultureInfo]::InvariantCulture)
            Pressure = [int]$cur.pressure; UV = [int]$cur.uvIndex; CloudCover = [int]$cur.cloudcover
            Code = [int]$cur.weatherCode; Description = (Get-Description $cur); Observed = [string]$cur.localObsDateTime
        }
        Forecast = $days
    }
}

function Get-WeatherGlyph {
    # Codes météo WWO (utilisés par wttr.in) → symbole simple et couleur.
    param([int]$Code)
    $ascii = [bool]$env:PSTOOLS_ASCII
    $kind = switch ($Code) {
        113 { 'sun' }
        116 { 'partly' }
        { $_ -in 119, 122 } { 'cloud' }
        { $_ -in 143, 248, 260 } { 'fog' }
        { $_ -in 200, 386, 389, 392, 395 } { 'storm' }
        { $_ -in 179, 182, 185, 227, 230, 281, 284, 311, 314, 317, 320, 323, 326, 329, 332, 335, 338, 350, 362, 365, 368, 371, 374, 377 } { 'snow' }
        { $_ -in 176, 263, 266, 293, 296, 299, 302, 305, 308, 353, 356, 359 } { 'rain' }
        default { 'cloud' }
    }
    $map = @{
        sun    = @([string][char]0x2600, '*', 'Warn')
        partly = @([string][char]0x25D1, '%', 'Warn')
        cloud  = @([string][char]0x2601, '~', 'Dim')
        fog    = @([string][char]0x2261, '=', 'Dim')
        rain   = @([string][char]0x2602, '/', 'Accent')
        snow   = @([string][char]0x2744, '+', 'Title')
        storm  = @([string][char]0x21AF, '!', 'Warn')
    }
    $entry = $map[$kind]
    $glyph = $entry[0]
    if ($ascii) { $glyph = $entry[1] }
    return (Paint $glyph $entry[2] -Bold)
}

$place = $City
try {
    $text = Get-WeatherText (Get-WeatherUrl $place) $place
    $w = ConvertFrom-WttrJson $text $place
}
catch {
    if ($Json) { [ordered]@{ Error = $_.Exception.Message } | ConvertTo-Json }
    else { Write-PstStatus err $_.Exception.Message }
    exit 1
}

if ($Json) {
    $w.Units = 'metric'
    if ($useImperial) { $w.Units = 'imperial' }
    $w | ConvertTo-Json -Depth 5
    exit 0
}

# ── Rendu ────────────────────────────────────────────────────────────────────

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 72
$c = $w.Current
$title = $w.Location.Name
if ($w.Location.Country -and $title -notmatch [regex]::Escape($w.Location.Country)) { $title += ", $($w.Location.Country)" }
if (-not $title) { $title = L 'Position actuelle' }

if ($useImperial) {
    $temp = '{0} °F' -f $c.TempF; $feels = '{0} °F' -f $c.FeelsLikeF
    $wind = '{0} mph' -f $c.WindMph
    $precip = '{0} in' -f $c.PrecipIn.ToString('0.##', (Get-PstCulture))
}
else {
    $temp = '{0} °C' -f $c.TempC; $feels = '{0} °C' -f $c.FeelsLikeC
    $wind = '{0} km/h' -f $c.WindKmh
    $precip = '{0} mm' -f $c.PrecipMM.ToString('0.#', (Get-PstCulture))
}
$dir = Get-WindDirection $c.WindDir

Show-PstHeader -Tool 'weather' -Subtitle $title
$label = 16
$lines = @(
    ((Get-WeatherGlyph $c.Code) + '  ' + (Paint $c.Description 'Title' -Bold)),
    '',
    ((Paint (Format-PstPad (L 'Température') $label) 'Accent') + (Paint $temp 'Title' -Bold) + (Paint ('  ' + (L '(ressenti {0})' $feels)) 'Dim')),
    ((Paint (Format-PstPad (L 'Vent') $label) 'Accent') + $wind + (Paint "  $dir" 'Dim')),
    ((Paint (Format-PstPad (L 'Humidité') $label) 'Accent') + ('{0} %' -f $c.Humidity)),
    ((Paint (Format-PstPad (L 'Précipitations') $label) 'Accent') + $precip + (Paint ("  $($g.Dot)  " + (L 'UV {0}' $c.UV)) 'Dim'))
)
Format-PstBox -Title (L 'Maintenant') -Lines $lines -Width $width -Color 'Accent' | Write-PstLine
Write-Host ''

if ($w.Forecast.Count) {
    $today = (Get-Date).Date
    $rows = @()
    foreach ($d in $w.Forecast) {
        $dayName = $d.Date
        try {
            $date = [DateTime]::ParseExact($d.Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $delta = ($date - $today).Days
            if ($delta -eq 0) { $dayName = L 'Aujourd''hui' }
            elseif ($delta -eq 1) { $dayName = L 'Demain' }
            else { $dayName = $date.ToString((L 'dddd d'), (Get-PstCulture)) }
        }
        catch { $dayName = $d.Date }
        if ($useImperial) { $min = '{0}°' -f $d.MinF; $max = '{0}°' -f $d.MaxF } else { $min = '{0}°' -f $d.MinC; $max = '{0}°' -f $d.MaxC }
        $rain = '{0} %' -f $d.RainChance
        $rainColor = 'Dim'
        if ($d.RainChance -ge 70) { $rainColor = 'Accent' } elseif ($d.RainChance -ge 40) { $rainColor = 'Title' }
        $descW = [Math]::Max(10, $width - 40)
        $rows += , @($dayName, (Paint $min 'Accent'), (Paint $max 'Warn'), ((Get-WeatherGlyph $d.Code) + ' ' + (Limit-PstText $d.Description $descW)), (Paint $rain $rainColor))
    }
    $descW = [Math]::Max(10, $width - 40)
    $table = Format-PstTable -Columns @(
        @{ Name = (L 'Jour'); Width = 12 }, @{ Name = (L 'Min'); Width = 4; Right = $true }, @{ Name = (L 'Max'); Width = 4; Right = $true },
        @{ Name = (L 'Ciel'); Width = ($descW + 2) }, @{ Name = (L 'Pluie'); Width = 6; Right = $true }
    ) -Rows $rows
    Format-PstBox -Title (L 'Prévisions') -Lines $table -Width $width | Write-PstLine
}
Write-Host ''
$foot = L 'Source : wttr.in'
if (-not $City) { $foot += '  ' + $g.Dot + '  ' + (L 'position déduite de l''adresse IP (weather -Set <ville> pour la fixer)') }
Write-Host ('  ' + (Paint $foot 'Dim'))
Write-Host ''
exit 0
