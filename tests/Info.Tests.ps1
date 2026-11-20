# Tests Pester (v5+) des outils weather, calc et speed — sans réseau.
#   Invoke-Pester ./tests/Info.Tests.ps1
# Les réponses des services sont simulées : fichiers JSON enregistrés (PSTOOLS_WEATHER_URL,
# PSTOOLS_CALC_RATES_URL), « offline », ou mesures factices (PSTOOLS_SPEED_FAKE).

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $env:NO_COLOR = '1'
    $env:PSTOOLS_LANG = 'fr'   # les assertions portent sur les textes français ; l'anglais a ses propres tests
    $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))
    $script:Fixtures = Join-Path ([IO.Path]::GetTempPath()) ("pst-fixtures-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Fixtures -Force | Out-Null

    function Invoke-Tool {
        # Lance un outil dans un processus séparé ; retourne @{ Output; ExitCode }.
        param([string]$Name, [string[]]$Arguments = @())
        $file = Join-Path $script:Tools "$Name.ps1"
        # « $null | » ferme l'entrée standard : les outils qui lisent le pipeline n'attendent pas indéfiniment.
        $output = $null | & $script:Shell -NoProfile -File $file @Arguments 2>&1
        return @{ Output = (@($output) -join "`n"); ExitCode = $LASTEXITCODE }
    }

    function Invoke-Calc {
        # Résultat numérique de calc -Json.
        param([string]$Expression)
        $r = Invoke-Tool 'calc' @($Expression, '-Json')
        $r.ExitCode | Should -Be 0 -Because "$Expression : $($r.Output)"
        return ($r.Output | ConvertFrom-Json)
    }

    function Write-Fixture {
        param([string]$Name, [string]$Text)
        $path = Join-Path $script:Fixtures $Name
        [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding $false))
        return $path
    }

    # Réponse wttr.in (format j1) réduite à l'essentiel, datée d'aujourd'hui.
    $d0 = (Get-Date).ToString('yyyy-MM-dd'); $d1 = (Get-Date).AddDays(1).ToString('yyyy-MM-dd'); $d2 = (Get-Date).AddDays(2).ToString('yyyy-MM-dd')
    $hour = { param($code, $rain, $fr, $en) "{ ""time"": ""1200"", ""weatherCode"": ""$code"", ""chanceofrain"": ""$rain"", ""chanceofsnow"": ""0"", ""weatherDesc"": [{ ""value"": ""$en"" }], ""lang_fr"": [{ ""value"": ""$fr"" }] }" }
    $script:WeatherJson = Write-Fixture 'wttr.json' @"
{
  "current_condition": [{ "temp_C": "12", "temp_F": "54", "FeelsLikeC": "10", "FeelsLikeF": "50", "humidity": "77", "weatherCode": "113",
    "weatherDesc": [{ "value": "Sunny" }], "lang_fr": [{ "value": "Ensoleillé" }], "windspeedKmph": "15", "windspeedMiles": "9",
    "winddir16Point": "WSW", "precipMM": "0.4", "precipInches": "0.0", "pressure": "1017", "uvIndex": "2", "cloudcover": "10", "localObsDateTime": "$d0 06:51 PM" }],
  "nearest_area": [{ "areaName": [{ "value": "Fourviere" }], "country": [{ "value": "France" }], "region": [{ "value": "Rhone-Alpes" }] }],
  "weather": [
    { "date": "$d0", "mintempC": "8", "maxtempC": "14", "mintempF": "46", "maxtempF": "57", "astronomy": [{ "sunrise": "07:40 AM", "sunset": "05:00 PM" }],
      "hourly": [ $(& $hour 113 10 'Ensoleillé' 'Sunny') ] },
    { "date": "$d1", "mintempC": "6", "maxtempC": "11", "mintempF": "43", "maxtempF": "52", "hourly": [ $(& $hour 353 85 'Averses légères' 'Light rain shower') ] },
    { "date": "$d2", "mintempC": "-1", "maxtempC": "3", "mintempF": "30", "maxtempF": "37", "hourly": [ $(& $hour 338 20 'Neige forte' 'Heavy snow') ] }
  ]
}
"@
    $script:RatesJson = Write-Fixture 'frankfurter.json' '{"amount":1.0,"base":"EUR","date":"2026-11-19","rates":{"USD":1.1,"GBP":0.8,"JPY":160.0}}'
    $script:FallbackJson = Write-Fixture 'fallback.json' '{"date":"2026-11-19","eur":{"usd":1.1,"btc":0.00002,"gbp":0.8}}'
}

AfterAll {
    foreach ($dir in $env:PSTOOLS_DATA, $script:Fixtures) { if ($dir -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force } }
    Remove-Item Env:PSTOOLS_DATA, Env:PSTOOLS_WEATHER_URL, Env:PSTOOLS_CALC_RATES_URL, Env:PSTOOLS_CALC_FALLBACK_URL, Env:PSTOOLS_SPEED_FAKE, Env:PSTOOLS_SPEED_URL -ErrorAction SilentlyContinue
}

Describe 'Aide des outils weather, calc et speed' {
    It '<_> -Help répond en français puis en anglais' -ForEach @('weather', 'calc', 'speed') {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION'
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-Tool $_ @('-Help') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.ExitCode | Should -Be 0
        $en.Output | Should -Match 'USAGE'
        $en.Output | Should -Not -Match 'é'
    }
}

Describe 'calc' {
    It 'calcule avec priorités, puissances et parenthèses' {
        (Invoke-Calc '2 + 3 * 4^2').Value | Should -Be 50
        (Invoke-Calc '-2^2').Value | Should -Be -4
        (Invoke-Calc '(1 + 2) * (3 - 1) / 4').Value | Should -Be 1.5
        (Invoke-Calc '2^3^2').Value | Should -Be 512
        (Invoke-Calc '10 % 3').Value | Should -Be 1
        (Invoke-Calc '0.1 + 0.2').Text | Should -Be '0,3'
    }

    It 'accepte la virgule décimale française et les espaces de milliers' {
        (Invoke-Calc '3,5 * 2').Value | Should -Be 7
        (Invoke-Calc '1 000 000 / 4').Value | Should -Be 250000
        (Invoke-Calc '1,25 + 0.75').Value | Should -Be 2
    }

    It 'gère les fonctions et leurs arguments' {
        (Invoke-Calc 'sqrt(16) + abs(-3)').Value | Should -Be 7
        (Invoke-Calc 'max(3,5; 2)').Value | Should -Be 3.5
        (Invoke-Calc 'min(4, 9, 2)').Value | Should -Be 2
        (Invoke-Calc 'round(2,345; 2)').Value | Should -Be 2.35
        (Invoke-Calc 'round(7.5)').Value | Should -Be 8
        (Invoke-Calc '5!').Value | Should -Be 120
    }

    It 'calcule les pourcentages' {
        (Invoke-Calc '15% de 80').Value | Should -Be 12
        (Invoke-Calc '15% of 80').Value | Should -Be 12
        (Invoke-Calc '80 + 20%').Value | Should -Be 96
        (Invoke-Calc '80 - 25%').Value | Should -Be 60
        (Invoke-Calc '50% * 10').Value | Should -Be 5
    }

    It 'affiche le résultat dans la culture française' {
        $r = Invoke-Tool 'calc' @('3,5 * 3')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '3,5 \* 3\s+=\s+10,5'
    }

    It 'signale clairement les erreurs' {
        $cases = @{ '1/0' = 'Division par zéro'; '2 +' = 'incomplète'; '(1+2' = 'Parenthèse fermante manquante'; '1+2)' = 'en trop'; 'foo(2)' = 'inconnu'; 'sqrt(-1)' = 'négatif' }
        foreach ($k in $cases.Keys) {
            $r = Invoke-Tool 'calc' @($k)
            $r.ExitCode | Should -Be 1 -Because $k
            $r.Output | Should -Match $cases[$k] -Because $k
        }
    }

    It 'n''exécute jamais l''entrée comme du code PowerShell' {
        $victim = Join-Path $script:Fixtures 'victim.txt'
        Set-Content -Path $victim -Value 'x'
        foreach ($expr in @("1; Remove-Item '$victim'", "`$(Remove-Item '$victim')", 'Get-Date', '[Environment]::Exit(0)', "1 + `$env:PATH")) {
            $r = Invoke-Tool 'calc' @($expr)
            $r.ExitCode | Should -Be 1 -Because $expr
        }
        $victim | Should -Exist
    }

    It 'convertit les unités' {
        [Math]::Round((Invoke-Calc '10 km en mi').Value, 4) | Should -Be 6.2137
        (Invoke-Calc '10 in to cm').Value | Should -Be 25.4
        (Invoke-Calc '20 °C en °F').Value | Should -Be 68
        [Math]::Round((Invoke-Calc '300 K en C').Value, 2) | Should -Be 26.85
        (Invoke-Calc '1,5 Go en Mo').Value | Should -Be 1500
        (Invoke-Calc '1 Gio en Mio').Value | Should -Be 1024
        (Invoke-Calc '90 min en h').Value | Should -Be 1.5
        (Invoke-Calc '2 l en cl').Value | Should -Be 200
        [Math]::Round((Invoke-Calc '100 km/h en mph').Value, 2) | Should -Be 62.14
        [Math]::Round((Invoke-Calc '1 lb en g').Value, 2) | Should -Be 453.59
        (Invoke-Calc '8 Mbit en Mo').Value | Should -Be 1
    }

    It 'refuse les unités incompatibles' {
        $r = Invoke-Tool 'calc' @('10 km en kg')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'incompatibles'
    }

    It 'convertit les devises et met les taux en cache' {
        $env:PSTOOLS_CALC_RATES_URL = $script:RatesJson
        $env:PSTOOLS_CALC_FALLBACK_URL = $script:FallbackJson
        try {
            $r = Invoke-Calc '100 EUR en USD'
            $r.Value | Should -Be 110
            $r.Stale | Should -BeFalse
            (Invoke-Calc '110 $ en €').Value | Should -Be 100
            (Invoke-Calc '80 GBP en USD').Value | Should -Be 110
            (Invoke-Calc '1 BTC en EUR').Value | Should -Be 50000   # absent de Frankfurter : source de repli
            $out = Invoke-Tool 'calc' @('100 EUR en USD')
            $out.Output | Should -Match '110,00 USD'
            $out.Output | Should -Match 'taux du 19 novembre 2026'
        }
        finally { Remove-Item Env:PSTOOLS_CALC_RATES_URL, Env:PSTOOLS_CALC_FALLBACK_URL -ErrorAction SilentlyContinue }
        Join-Path $env:PSTOOLS_DATA 'calc-rates.json' | Should -Exist
    }

    It 'utilise les derniers taux connus hors ligne et le dit' {
        $cache = Join-Path $env:PSTOOLS_DATA 'calc-rates.json'
        [IO.File]::WriteAllText($cache, '{ "fetched": "2020-01-01", "date": "2020-01-01", "source": "frankfurter", "rates": { "EUR": 1, "USD": 2 } }')
        $env:PSTOOLS_CALC_RATES_URL = 'offline'; $env:PSTOOLS_CALC_FALLBACK_URL = 'offline'
        try {
            $r = Invoke-Tool 'calc' @('10 EUR en USD')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '20,00 USD'
            $r.Output | Should -Match 'Hors ligne'
            (Invoke-Calc '10 EUR en USD').Stale | Should -BeTrue
            Remove-Item $cache
            $none = Invoke-Tool 'calc' @('10 EUR en USD')
            $none.ExitCode | Should -Be 1
            $none.Output | Should -Match 'indisponibles'
        }
        finally { Remove-Item Env:PSTOOLS_CALC_RATES_URL, Env:PSTOOLS_CALC_FALLBACK_URL -ErrorAction SilentlyContinue }
    }

    It 'évalue chaque ligne reçue par le pipeline' {
        $file = Join-Path $script:Tools 'calc.ps1'
        $out = @("2 + 2", "10 km en m") | & $script:Shell -NoProfile -File $file 2>&1
        ($out -join "`n") | Should -Match '=\s+4'
        ($out -join "`n") | Should -Match '10\s?000 m'
    }

    It 'sans expression ni entrée, renvoie une erreur sans attendre' {
        $r = Invoke-Tool 'calc'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Aucune expression'
    }

    It 'parle anglais et accepte la virgule des milliers en anglais' {
        $env:PSTOOLS_LANG = 'en'
        try {
            $r = Invoke-Tool 'calc' @('1,000 + 0.5')
            $err = Invoke-Tool 'calc' @('1/0')
            $args2 = Invoke-Tool 'calc' @('max(3.5, 2)', '-Json')
        }
        finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match '1,000\.5'
        $err.Output | Should -Match 'Division by zero'
        $args2.ExitCode | Should -Be 0
    }
}

Describe 'weather' {
    BeforeEach { $env:PSTOOLS_WEATHER_URL = $script:WeatherJson }
    AfterEach { Remove-Item Env:PSTOOLS_WEATHER_URL -ErrorAction SilentlyContinue }

    It 'affiche les conditions actuelles et trois jours de prévisions' {
        $r = Invoke-Tool 'weather' @('lyon')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Lyon, France'
        $r.Output | Should -Match 'Ensoleillé'
        $r.Output | Should -Match '12 °C'
        $r.Output | Should -Match 'ressenti 10 °C'
        $r.Output | Should -Match '15 km/h\s+OSO'
        $r.Output | Should -Match '77 %'
        $r.Output | Should -Match 'Aujourd''hui'
        $r.Output | Should -Match 'Demain'
        $r.Output | Should -Match 'Averses légères\s+85 %'
        $r.Output | Should -Match '-1°'
    }

    It 'produit un JSON normalisé' {
        $r = Invoke-Tool 'weather' @('Lyon', '-Json')
        $r.ExitCode | Should -Be 0
        $w = $r.Output | ConvertFrom-Json
        $w.Current.TempC | Should -Be 12
        $w.Current.Code | Should -Be 113
        @($w.Forecast).Count | Should -Be 3
        $w.Forecast[1].RainChance | Should -Be 85
        $w.Location.Country | Should -Be 'France'
        $w.Units | Should -Be 'metric'
    }

    It 'passe en unités impériales' {
        $r = Invoke-Tool 'weather' @('Lyon', '-Imperial')
        $r.Output | Should -Match '54 °F'
        $r.Output | Should -Match '9 mph'
    }

    It 'mémorise puis oublie la ville' {
        $r = Invoke-Tool 'weather' @('-Set', 'Saint-Malo')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Ville mémorisée : Saint-Malo'
        $saved = Get-Content (Join-Path $env:PSTOOLS_DATA 'weather.json') -Raw | ConvertFrom-Json
        $saved.city | Should -Be 'Saint-Malo'
        (Invoke-Tool 'weather').Output | Should -Match 'Saint-Malo'
        (Invoke-Tool 'weather' @('-Forget')).ExitCode | Should -Be 0
        Join-Path $env:PSTOOLS_DATA 'weather.json' | Should -Not -Exist
        (Invoke-Tool 'weather').Output | Should -Match 'adresse IP'
    }

    It 'échoue proprement hors ligne ou sur une réponse illisible' {
        $env:PSTOOLS_WEATHER_URL = 'offline'
        $r = Invoke-Tool 'weather' @('Lyon')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Pas de connexion'
        $env:PSTOOLS_WEATHER_URL = Write-Fixture 'bad.json' '<html>oops</html>'
        $bad = Invoke-Tool 'weather' @('Lyon')
        $bad.ExitCode | Should -Be 1
        $bad.Output | Should -Match 'illisible'
    }

    It 'parle anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'weather' @('Lyon') } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match 'Sunny'
        $r.Output | Should -Match 'feels like 10 °C'
        $r.Output | Should -Match 'Tomorrow'
        $r.Output | Should -Match 'WSW'
        $r.Output | Should -Not -Match 'Température|Demain'
    }
}

Describe 'speed' {
    AfterEach { Remove-Item Env:PSTOOLS_SPEED_FAKE, Env:PSTOOLS_SPEED_URL -ErrorAction SilentlyContinue }

    It 'annonce le volume de données puis traduit les débits en usages' {
        $env:PSTOOLS_SPEED_FAKE = 'latency=12;jitter=2;down=95.5;up=20'
        $r = Invoke-Tool 'speed'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'jusqu''à 25 Mo en téléchargement et 10 Mo en envoi'
        $r.Output | Should -Match '95,5 Mbit/s'
        $r.Output | Should -Match '4K sur plusieurs écrans'
        $r.Output | Should -Match 'Latence excellente'
    }

    It 'adapte les verdicts aux connexions lentes et respecte -NoUpload' {
        $env:PSTOOLS_SPEED_FAKE = 'latency=200;jitter=40;down=3;up=0.5'
        $r = Invoke-Tool 'speed' @('-NoUpload', '-Size', '10')
        $r.Output | Should -Match 'jusqu''à 10 Mo en téléchargement \(envoi non mesuré\)'
        $r.Output | Should -Match 'Lent :'
        $r.Output | Should -Match 'Latence très élevée'
        $r.Output | Should -Not -Match 'Envoi faible'
    }

    It 'produit un JSON' {
        $env:PSTOOLS_SPEED_FAKE = 'latency=30;jitter=3;down=12;up=2'
        $r = Invoke-Tool 'speed' @('-Json')
        $r.ExitCode | Should -Be 0
        $j = $r.Output | ConvertFrom-Json
        $j.DownloadMbps | Should -Be 12
        $j.UploadMbps | Should -Be 2
        @($j.Verdicts).Count | Should -Be 3
        $j.Verdicts[0].Text | Should -Match 'visio HD'
    }

    It 'échoue proprement sans connexion' {
        $env:PSTOOLS_SPEED_URL = 'offline'
        $r = Invoke-Tool 'speed' @('-NoUpload')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'pas de connexion'
    }

    It 'parle anglais' {
        $env:PSTOOLS_SPEED_FAKE = 'latency=12;jitter=2;down=95.5;up=20'
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'speed' } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match 'up to 25 MB of download'
        $r.Output | Should -Match '95\.5 Mbps'
        $r.Output | Should -Match 'Enough for 4K on several screens'
    }

    It 'mesure réellement le débit (réseau, si PSTOOLS_NETWORK_TESTS)' -Skip:(-not $env:PSTOOLS_NETWORK_TESTS) {
        $r = Invoke-Tool 'speed' @('-Size', '5', '-NoUpload', '-Json')
        $r.ExitCode | Should -Be 0
        ($r.Output | ConvertFrom-Json).DownloadMbps | Should -BeGreaterThan 0
    }
}
