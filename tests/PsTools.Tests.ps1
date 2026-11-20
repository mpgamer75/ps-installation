# Tests Pester (v5+) — exécutables sous Windows PowerShell 5.1 et PowerShell 7, Windows ou non.
#   Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Manifest = Get-Content (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $env:NO_COLOR = '1'
    $env:PSTOOLS_LANG = 'fr'   # les assertions portent sur les textes français ; l'anglais a ses propres tests
    $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))
    $env:PSTOOLS_TASK_PREFIX = 'PsToolsTest_Reminder_'   # ne touche jamais aux vrais rappels du poste

    function Invoke-Tool {
        # Lance un outil dans un processus séparé ; retourne @{ Output; ExitCode }.
        param([string]$Name, [string[]]$Arguments = @(), [switch]$Mocked)
        $file = Join-Path $script:Tools "$Name.ps1"
        if ($Mocked) {
            $mocks = Join-Path (Join-Path $script:Root 'tests') 'Mocks.ps1'
            $command = ". '$mocks'; & '$file' $($Arguments -join ' ')"
            $output = $null | & $script:Shell -NoProfile -Command $command 2>&1
        }
        # « $null | » ferme l'entrée standard : les outils qui lisent le pipeline n'attendent pas indéfiniment.
        else { $output = $null | & $script:Shell -NoProfile -File $file @Arguments 2>&1 }
        return @{ Output = (@($output) -join "`n"); ExitCode = $LASTEXITCODE }
    }
}

AfterAll {
    if ($env:PSTOOLS_DATA -and (Test-Path $env:PSTOOLS_DATA)) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
    Remove-Item Env:PSTOOLS_DATA, Env:PSTOOLS_PROFILE, Env:PSTOOLS_TASK_PREFIX, Env:PSTOOLS_TEST_WINDOWS -ErrorAction SilentlyContinue
}

Describe 'Dépôt' {
    It 'tous les scripts sont syntaxiquement valides' {
        $failures = @()
        Get-ChildItem -Path $Root -Recurse -Filter '*.ps1' | ForEach-Object {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
            if ($errors) { $failures += "$($_.Name): $($errors[0].Message)" }
        }
        $failures | Should -BeNullOrEmpty
    }

    It 'les scripts de src/ et tests/ sont en UTF-8 avec BOM (requis par PowerShell 5.1)' {
        Get-ChildItem -Path (Join-Path $Root 'src'), (Join-Path $Root 'tests') -Recurse -Filter '*.ps1' | ForEach-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because "$($_.Name) doit commencer par un BOM"
        }
    }

    It 'install.ps1 et uninstall.ps1 sont en ASCII pur (compatibles « irm | iex »)' {
        foreach ($name in 'install.ps1', 'uninstall.ps1') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $name))
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because "$name ne doit contenir que de l'ASCII"
        }
    }

    It 'chaque outil du manifeste existe et la version est cohérente' {
        foreach ($tool in $Manifest.tools) { (Join-Path $Tools "$($tool.name).ps1") | Should -Exist }
        . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1')
        $script:Pst.Version | Should -Be $Manifest.version
    }
}

Describe 'Bibliothèque' {
    BeforeAll { . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1') }

    It 'formate les tailles' {
        Format-PstSize 512 | Should -Be '512 o'
        Format-PstSize (5 * 1GB) | Should -Match '^5[.,]0 Go$'
        Format-PstSize (1536 * 1KB) | Should -Match '^1[.,]5 Mo$'
    }

    It 'formate les durées' {
        Format-PstDuration ([TimeSpan]::FromSeconds(42)) | Should -Be '42s'
        Format-PstDuration ([TimeSpan]::FromMinutes(75)) | Should -Be '1h 15m'
        Format-PstDuration (New-Object TimeSpan 2, 3, 4, 0) | Should -Be '2j 3h 04m'
    }

    It 'dessine des barres de largeur constante' {
        foreach ($p in 0, 1, 50, 99, 100, 250, -5) { (Get-PstVisibleLength (Format-PstBar $p 20)) | Should -Be 20 }
    }

    It 'dessine des graphiques de largeur constante, pertes comprises' {
        (Format-PstSparkline @(1, $null, 5, 9) -Width 10).Length | Should -Be 10
        (Format-PstSparkline @() -Width 6).Length | Should -Be 6
        (Format-PstSparkline (1..50) -Width 8).Length | Should -Be 8
    }

    It 'remplit les valeurs, y compris zéro' {
        L '{0} port(s)' 0 | Should -Be '0 port(s)'
        L '{0} / {1}' 0 0 | Should -Be '0 / 0'
        L 'texte sans valeur' | Should -Be 'texte sans valeur'
    }

    It 'aligne et tronque le texte' {
        Format-PstPad 'ab' 5 | Should -Be 'ab   '
        Format-PstPad 'ab' 5 -Right | Should -Be '   ab'
        (Limit-PstText 'abcdefghij' 5).Length | Should -Be 5
        Limit-PstText 'abc' 5 | Should -Be 'abc'
    }

    It 'encadre avec des lignes de même largeur' {
        $box = Format-PstBox -Title 'Titre' -Lines @('un', 'deux plus long') -Width 40
        $box.Count | Should -Be 4
        $box | ForEach-Object { Get-PstVisibleLength $_ | Should -Be 40 }
    }

    It 'ne produit aucun code couleur quand NO_COLOR est défini' {
        Paint 'texte' 'Ok' -Bold | Should -Be 'texte'
    }

    It 'colore quand le terminal le permet, sans changer la largeur visible' {
        $script:Pst.Ansi = $true
        try {
            $painted = Paint 'texte' 'Ok'
            $painted | Should -Match ([regex]::Escape([string][char]27))
            Get-PstVisibleLength $painted | Should -Be 5
            Get-PstVisibleLength (Format-PstGradient 'dégradé') | Should -Be 7
        }
        finally { $script:Pst.Ansi = $false }
    }

    It 'le logo a des lignes de même largeur' {
        $banner = @(Get-PstBanner | Where-Object { $_ })
        $banner.Count | Should -Be 5
        @($banner | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
    }
}

Describe 'Aide des outils' {
    BeforeDiscovery {
        $script:AllTools = @((Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tools | ForEach-Object { $_.name })
    }
    It '<_> -Help répond sans erreur' -ForEach $AllTools {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION'
    }
    It '<_> -Help existe en anglais' -ForEach $AllTools {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool $_ @('-Help') } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'USAGE'
        $r.Output | Should -Not -Match 'UTILISATION|EXEMPLES'
    }
}

Describe 'Mode anglais' {
    BeforeAll { . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1') }

    It 'chaque texte traduit a sa traduction, avec les mêmes valeurs {0}' {
        $out = & $Shell -NoProfile -File (Join-Path (Join-Path $Root 'build') 'Test-Translations.ps1') -Strict -Quiet 2>&1
        $LASTEXITCODE | Should -Be 0 -Because (@($out) -join "`n")
    }

    It 'les dictionnaires ne contiennent que des données' {
        Get-ChildItem (Join-Path (Join-Path (Join-Path $Root 'src') 'i18n') 'en') -Filter '*.psd1' | ForEach-Object {
            $block = [scriptblock]::Create([IO.File]::ReadAllText($_.FullName).TrimStart([char]0xFEFF))
            { $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false) } | Should -Not -Throw -Because $_.Name
        }
    }

    It 'choisit la langue : variable, réglage, puis langue de Windows' {
        $saved = $env:PSTOOLS_LANG
        try {
            $env:PSTOOLS_LANG = 'en'; Get-PstLanguage | Should -Be 'en'
            $env:PSTOOLS_LANG = 'de'; Get-PstLanguage | Should -Be 'en'
            $env:PSTOOLS_LANG = 'fr'; Get-PstLanguage | Should -Be 'fr'
        }
        finally { $env:PSTOOLS_LANG = $saved }
    }

    It 'traduit, garde le français en repli, et adapte unités et durées' {
        Set-PstLanguage 'en'
        try {
            L 'Appuyez sur une touche pour continuer...' | Should -Be 'Press any key to continue...'
            L 'Texte sans traduction {0}' 3 | Should -Be 'Texte sans traduction 3'
            Format-PstSize (5 * 1GB) | Should -Match 'GB$'
            Format-PstDuration (New-Object TimeSpan 2, 3, 4, 0) | Should -Be '2d 3h 04m'
        }
        finally { Set-PstLanguage 'fr' }
        Format-PstSize (5 * 1GB) | Should -Match 'Go$'
    }

    It 'pst parle anglais quand on le lui demande' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'pst' } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match 'The Windows terminal toolkit'
        $r.Output | Should -Match 'EVERYDAY'
        $r.Output | Should -Not -Match 'AU QUOTIDIEN'
    }
}

Describe 'Installation' {
    BeforeAll {
        $script:Dest = Join-Path ([IO.Path]::GetTempPath()) ("pst-install-" + [Guid]::NewGuid().ToString('N'))
        $script:Installer = Join-Path $Root 'install.ps1'
    }
    AfterAll { if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force } }

    It 'installe tous les outils dans un dossier sans toucher au PATH' {
        $out = & $Shell -NoProfile -File $Installer -InstallRoot $Dest -NoPath -Yes 2>&1
        $LASTEXITCODE | Should -Be 0 -Because (@($out) -join "`n")
        foreach ($tool in $Manifest.tools) {
            (Join-Path (Join-Path $Dest 'bin') "$($tool.name).cmd") | Should -Exist
            (Join-Path (Join-Path (Join-Path $Dest 'app') 'tools') "$($tool.name).ps1") | Should -Exist
        }
        foreach ($lib in 'PsTools.ps1', 'PsTools.AI.ps1', 'PsTools.Wizard.ps1') { (Join-Path (Join-Path (Join-Path $Dest 'app') 'lib') $lib) | Should -Exist }
        (Join-Path $Dest 'app/i18n/en/PsTools.psd1') | Should -Exist
        (Join-Path $Dest 'app/i18n/en/ask.psd1') | Should -Exist
        $info = Get-Content (Join-Path (Join-Path $Dest 'app') 'install.json') -Raw | ConvertFrom-Json
        $info.Version | Should -Be $Manifest.version
    }

    It 'écrit les scripts installés avec BOM et les lanceurs en chemin relatif' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path (Join-Path (Join-Path $Dest 'app') 'tools') 'monitor.ps1'))
        $bytes[0] | Should -Be 0xEF
        $shim = Get-Content (Join-Path (Join-Path $Dest 'bin') 'monitor.cmd') -Raw
        $shim | Should -Match '%~dp0\.\.\\app\\tools\\monitor\.ps1'
        $shim | Should -Match '-ExecutionPolicy Bypass'
    }

    It 'la copie installée parle anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $out = $null | & $Shell -NoProfile -File (Join-Path $Dest 'app/tools/pst-uninstall.ps1') -Help 2>&1 } finally { $env:PSTOOLS_LANG = 'fr' }
        (@($out) -join "`n") | Should -Match 'USAGE'
    }

    It 'la copie installée fonctionne' {
        $out = & $Shell -NoProfile -File (Join-Path (Join-Path (Join-Path $Dest 'app') 'tools') 'pst.ps1') version 2>&1
        (@($out) -join '') | Should -Be "ps-tools $($Manifest.version)"
    }

    It 'réinstalle une sélection et retire les outils non choisis' {
        $null = & $Shell -NoProfile -File $Installer -InstallRoot $Dest -NoPath -Yes -Tools 'dsize,remind' 2>&1
        $names = @(Get-ChildItem (Join-Path $Dest 'bin') -Filter '*.cmd' | ForEach-Object { $_.BaseName } | Sort-Object)
        ($names -join ',') | Should -Be 'dsize,pst,pst-uninstall,remind'
        (Join-Path (Join-Path (Join-Path $Dest 'app') 'shell') 'PsTools.Shell.ps1') | Should -Exist
    }

    It 'refuse un outil inconnu' {
        $out = & $Shell -NoProfile -File $Installer -InstallRoot $Dest -NoPath -Yes -Tools 'inexistant' 2>&1
        (@($out) -join "`n") | Should -Match 'inconnu'
    }

    It 'pst-uninstall retire une installation depuis la copie installée' {
        $other = Join-Path ([IO.Path]::GetTempPath()) ("pst-uninst-" + [Guid]::NewGuid().ToString('N'))
        try {
            $null = $null | & $Shell -NoProfile -File $Installer -InstallRoot $other -NoPath -Yes 2>&1
            (Join-Path (Join-Path $other 'bin') 'pst-uninstall.cmd') | Should -Exist
            $out = $null | & $Shell -NoProfile -File (Join-Path (Join-Path (Join-Path $other 'app') 'tools') 'pst-uninstall.ps1') -Yes 2>&1
            $LASTEXITCODE | Should -Be 0 -Because (@($out) -join "`n")
            # Sous Windows, la suppression est confiée à un processus détaché : on lui laisse le temps.
            for ($i = 0; $i -lt 40 -and (Test-Path (Join-Path $other 'app')); $i++) { Start-Sleep -Milliseconds 500 }
            (Join-Path $other 'app') | Should -Not -Exist
            (Join-Path $other 'bin') | Should -Not -Exist
        }
        finally { if (Test-Path $other) { Remove-Item $other -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'pst-uninstall ne fait rien depuis le dépôt' {
        $r = Invoke-Tool 'pst-uninstall' @('-Yes')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'rien n.est install'
        (Join-Path $Tools 'pst.ps1') | Should -Exist
    }

    It 'désinstalle proprement' {
        $null = & $Shell -NoProfile -File (Join-Path $Root 'uninstall.ps1') -InstallRoot $Dest -Yes 2>&1
        (Join-Path $Dest 'bin') | Should -Not -Exist
        (Join-Path $Dest 'app') | Should -Not -Exist
    }
}

Describe 'dsize et clean' {
    BeforeAll {
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("pst-work-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $Work 'gros') 'sous') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Work 'petit') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $Work 'gros') 'a.bin'), (New-Object byte[] 200000))
        [IO.File]::WriteAllBytes((Join-Path (Join-Path (Join-Path $Work 'gros') 'sous') 'b.log'), (New-Object byte[] 50000))
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $Work 'petit') 'c.tmp'), (New-Object byte[] 1000))
        [IO.File]::WriteAllBytes((Join-Path $Work 'garde.txt'), (New-Object byte[] 10))
    }
    AfterAll { if (Test-Path $Work) { Remove-Item $Work -Recurse -Force } }

    It 'dsize additionne les tailles et classe par ordre décroissant' {
        $r = Invoke-Tool 'dsize' @($Work, '-Json')
        $data = $r.Output | ConvertFrom-Json
        $data.TotalBytes | Should -Be 251010
        $data.Files | Should -Be 4
        $data.Items[0].Name | Should -Be 'gros'
        $data.Items[0].Bytes | Should -Be 250000
    }

    It 'dsize -Files trouve les plus gros fichiers' {
        $data = (Invoke-Tool 'dsize' @($Work, '-Files', '-Top', '2', '-Json')).Output | ConvertFrom-Json
        @($data.Items).Count | Should -Be 2
        $data.Items[0].Name | Should -Match 'a\.bin$'
    }

    It 'clean -DryRun ne supprime rien' {
        $r = Invoke-Tool 'clean' @('-Path', $Work, '-Include', '*.log,*.tmp', '-DryRun')
        $r.ExitCode | Should -Be 0
        (Join-Path (Join-Path $Work 'petit') 'c.tmp') | Should -Exist
    }

    It 'clean exige un critère et refuse les dossiers sensibles' {
        (Invoke-Tool 'clean' @('-Path', $Work)).ExitCode | Should -Be 1
        (Invoke-Tool 'clean' @('-Path', $HOME, '-Include', '*.tmp', '-Yes')).ExitCode | Should -Be 1
    }

    It 'clean -Yes supprime uniquement les fichiers ciblés' {
        $r = Invoke-Tool 'clean' @('-Path', $Work, '-Include', '*.log,*.tmp', '-Yes')
        $r.ExitCode | Should -Be 0
        (Join-Path (Join-Path $Work 'petit') 'c.tmp') | Should -Not -Exist
        (Join-Path (Join-Path (Join-Path $Work 'gros') 'sous') 'b.log') | Should -Not -Exist
        (Join-Path (Join-Path $Work 'gros') 'a.bin') | Should -Exist
        (Join-Path $Work 'garde.txt') | Should -Exist
    }
}

Describe 'remind' {
    # @(Get-Stored) : sous PowerShell 5.1, un objet seul n'a pas de propriété Count.
    # Sous Windows, les tâches planifiées créées ici portent un préfixe de test et sont retirées à la fin.
    BeforeAll {
        $script:Store = Join-Path $env:PSTOOLS_DATA 'reminders.json'
        function Get-Stored { return @(Get-Content $script:Store -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
        function Clear-Tasks {
            if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
                Get-ScheduledTask -TaskName 'PsToolsTest_Reminder_*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }
    AfterAll { Clear-Tasks }

    It 'ajoute un rappel relatif (-In)' {
        (Invoke-Tool 'remind' @('add', 'Premier', '-In', '1h30')).ExitCode | Should -Be 0
        $stored = @(Get-Stored)
        $stored.Count | Should -Be 1
        $due = [DateTime]::ParseExact($stored[0].Due, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        ($due - (Get-Date)).TotalMinutes | Should -BeGreaterThan 88
        ($due - (Get-Date)).TotalMinutes | Should -BeLessThan 91
    }

    It 'ajoute un rappel absolu (-At) avec accents' {
        (Invoke-Tool 'remind' @('add', 'Réunion', '-At', '25/12/2099 09:00')).ExitCode | Should -Be 0
        $hit = Get-Stored | Where-Object { $_.Title -eq 'Réunion' }
        $hit.Due | Should -Be '2099-12-25 09:00'
    }

    It 'rejette les durées invalides et les dates passées' {
        (Invoke-Tool 'remind' @('add', 'x', '-In', 'bientot')).ExitCode | Should -Be 1
        (Invoke-Tool 'remind' @('add', 'x', '-At', '01/01/2020 10:00')).ExitCode | Should -Be 1
        @(Get-Stored).Count | Should -Be 2
    }

    It 'liste, termine, supprime et purge' {
        (Invoke-Tool 'remind' @('list')).Output | Should -Match 'Premier'
        (Invoke-Tool 'remind' @('done', '1')).ExitCode | Should -Be 0
        @(Get-Stored | Where-Object { $_.Done }).Count | Should -Be 1
        (Invoke-Tool 'remind' @('clear')).ExitCode | Should -Be 0
        @(Get-Stored).Count | Should -Be 1
        (Invoke-Tool 'remind' @('rm', '1')).ExitCode | Should -Be 0
        @(Get-Stored).Count | Should -Be 0
        $empty = Invoke-Tool 'remind' @('list')
        $empty.Output | Should -Match 'Aucun rappel'
        $empty.Output | Should -Not -Match 'illisible'
    }
}

Describe 'Rendu avec données simulées' {
    It 'monitor -Once affiche tous les panneaux' {
        $r = Invoke-Tool 'monitor' @('-Once') -Mocked
        $r.ExitCode | Should -Be 0
        foreach ($panel in 'Processeur', 'Mémoire', 'Disques', 'Réseau', 'Processus') { $r.Output | Should -Match $panel }
        $r.Output | Should -Match '28[.,]0 %'
    }

    It 'sysinfo décrit la machine' {
        $r = Invoke-Tool 'sysinfo' -Mocked
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Ryzen'
        $r.Output | Should -Match '24H2'
    }

    It 'ports liste, filtre et exporte en JSON' {
        (Invoke-Tool 'ports' -Mocked).Output | Should -Match '5432'
        $filtered = (Invoke-Tool 'ports' @('3000', '-Json') -Mocked).Output | ConvertFrom-Json
        @($filtered).Count | Should -Be 1
        @($filtered)[0].Port | Should -Be 3000
    }

    It 'netinfo -Offline affiche les interfaces sans requête Internet' {
        $r = Invoke-Tool 'netinfo' @('-Offline') -Mocked
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '192\.168\.1\.42/24'
        $r.Output | Should -Not -Match 'IP publique'
    }
}

Describe 'Outils développeur' {
    It 'dev génère des identifiants et des mots de passe conformes' {
        $ids = @((Invoke-Tool 'dev' @('uuid', '-Count', '3')).Output -split "`n" | Where-Object { $_ })
        $ids.Count | Should -Be 3
        $ids | ForEach-Object { $_ | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' }
        $pass = (Invoke-Tool 'dev' @('pass', '-Length', '32')).Output.Trim()
        $pass.Length | Should -Be 32
        $pass | Should -MatchExactly '[a-z]'
        $pass | Should -MatchExactly '[A-Z]'
        $pass | Should -Match '\d'
        (Invoke-Tool 'dev' @('pass', '-Length', '3')).ExitCode | Should -Be 1
    }

    It 'dev calcule des empreintes exactes' {
        (Invoke-Tool 'dev' @('hash', 'bonjour')).Output.Trim() | Should -Be '2cb4b1431b84ec15d35ed83bb927e27e8967d75f4bcd9cc4b25c8d879ae23e18'
        $file = Join-Path ([IO.Path]::GetTempPath()) ("pst-hash-" + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($file, 'abc')
        try { (Invoke-Tool 'dev' @('hash', $file, '-Algo', 'MD5')).Output.Trim() | Should -Be '900150983cd24fb0d6963f7d28e17f72' }
        finally { Remove-Item $file -Force }
    }

    It 'dev encode et décode (base64, URL, horodatage)' {
        (Invoke-Tool 'dev' @('b64', 'bonjour')).Output.Trim() | Should -Be 'Ym9uam91cg=='
        (Invoke-Tool 'dev' @('b64', 'Ym9uam91cg==', '-Decode')).Output.Trim() | Should -Be 'bonjour'
        (Invoke-Tool 'dev' @('b64', '@@@', '-Decode')).ExitCode | Should -Be 1
        (Invoke-Tool 'dev' @('url', 'a b&c')).Output.Trim() | Should -Be 'a%20b%26c'
        (Invoke-Tool 'dev' @('epoch', '1767225600')).Output | Should -Match '2026-01-01T00:00:00Z'
    }

    It 'dev met en forme le JSON et rejette le JSON invalide' {
        $file = Join-Path ([IO.Path]::GetTempPath()) ("pst-json-" + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($file, '{"a":1,"b":[1,{"c":"x:y, {z}"}],"d":{}}')
            $r = Invoke-Tool 'dev' @('json', $file)
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).b[1].c | Should -Be 'x:y, {z}'
            $r.Output | Should -Match '(?m)^  "a": 1,$'
            [IO.File]::WriteAllText($file, '{"a":')
            (Invoke-Tool 'dev' @('json', $file)).ExitCode | Should -Be 1
        }
        finally { Remove-Item $file -Force }
    }

    It 'dev décode un jeton JWT' {
        $r = Invoke-Tool 'dev' @('jwt', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiZXhwIjoxNTE2MjM5MDIyfQ.x')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'HS256'
        $r.Output | Should -Match 'John Doe'
        $r.Output | Should -Match 'expir'
    }

    It 'loc compte le code et ne relève que les TODO en commentaire' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("pst-loc-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'node_modules') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $dir 'a.py'), "# TODO: finir`nx = 1`n`ny = 'TODO dans une chaine'`n")
            [IO.File]::WriteAllText((Join-Path $dir 'b.js'), "// commentaire`nconst a = 1;`n")
            [IO.File]::WriteAllText((Join-Path (Join-Path $dir 'node_modules') 'dep.js'), "const ignored = 1;`n")
            $data = (Invoke-Tool 'loc' @($dir, '-Json')).Output | ConvertFrom-Json
            $data.Files | Should -Be 2
            $data.Code | Should -Be 3
            @($data.Notes).Count | Should -Be 1
            @($data.Notes)[0].Line | Should -Be 1
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'gst décrit un dépôt Git' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = Join-Path ([IO.Path]::GetTempPath()) ("pst-git-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $repo | Out-Null
        try {
            & git -C $repo init -q -b principale 2>&1 | Out-Null
            [IO.File]::WriteAllText((Join-Path $repo 'suivi.txt'), 'un')
            & git -C $repo add . 2>&1 | Out-Null
            & git -C $repo -c user.name=Test -c user.email=test@example.com commit -q -m 'Premier commit' 2>&1 | Out-Null
            [IO.File]::WriteAllText((Join-Path $repo 'suivi.txt'), 'deux')
            [IO.File]::WriteAllText((Join-Path $repo 'nouveau fichier.txt'), 'x')
            $r = Invoke-Tool 'gst' @($repo)
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'principale'
            $r.Output | Should -Match 'suivi\.txt'
            $r.Output | Should -Match 'nouveau fichier\.txt'
            $r.Output | Should -Match 'Premier commit'
            (Invoke-Tool 'gst' @([IO.Path]::GetTempPath())).ExitCode | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force }
    }
}

Describe 'Observation' {
    It 'logtail affiche la fin du fichier, filtre et compte les niveaux' {
        $log = Join-Path ([IO.Path]::GetTempPath()) ("pst-log-" + [Guid]::NewGuid().ToString('N') + '.log')
        try {
            [IO.File]::WriteAllText($log, "INFO un`nWARN lent`nERROR boum`nDEBUG x`nINFO fin`n")
            $r = Invoke-Tool 'logtail' @($log, '-NoFollow', '-Lines', '3')
            $r.Output | Should -Not -Match 'WARN lent'
            $r.Output | Should -Match 'ERROR boum'
            $r.Output | Should -Match 'INFO fin'
            $f = Invoke-Tool 'logtail' @($log, '-NoFollow', '-Filter', 'boum|lent')
            $f.Output | Should -Match '2 ligne'
            $f.Output | Should -Not -Match 'INFO un'
            (Invoke-Tool 'logtail' @($log, '-NoFollow', '-Filter', '[')).ExitCode | Should -Be 1
            (Invoke-Tool 'logtail' @('inexistant.log')).ExitCode | Should -Be 1
        }
        finally { Remove-Item $log -Force }
    }

    It 'watch relance la commande le nombre de fois demandé' {
        $r = Invoke-Tool 'watch' @('-Count', '2', '-Interval', '1', '"valeur-fixe"')
        $r.ExitCode | Should -Be 0
        ([regex]::Matches($r.Output, 'valeur-fixe')).Count | Should -BeGreaterOrEqual 2
        $r.Output | Should -Match 'n. 2'
    }

    It 'events regroupe les événements identiques' {
        $r = Invoke-Tool 'events' -Mocked
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'x3'
        $r.Output | Should -Match '7031'
        $data = (Invoke-Tool 'events' @('-Json') -Mocked).Output | ConvertFrom-Json
        @($data).Count | Should -Be 3
        @($data)[0].Level | Should -Be 1
    }

    It 'serve sert les fichiers et interdit de sortir du dossier' {
        $site = Join-Path ([IO.Path]::GetTempPath()) ("pst-site-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $site | Out-Null
        [IO.File]::WriteAllText((Join-Path $site 'page.txt'), 'contenu servi')
        [IO.File]::WriteAllText(($site + '-secret.txt'), 'secret')
        $port = Get-Random -Minimum 20000 -Maximum 40000
        $file = Join-Path $Tools 'serve.ps1'
        $job = Start-Job -ScriptBlock { param($shell, $file, $site, $port) $null | & $shell -NoProfile -File $file $site -Port $port -MaxRequests 3 2>&1 } -ArgumentList $Shell, $file, $site, $port
        try {
            $client = New-Object System.Net.WebClient
            $body = $null
            for ($i = 0; $i -lt 40 -and $null -eq $body; $i++) {
                try { $body = $client.DownloadString("http://localhost:$port/page.txt") } catch { Start-Sleep -Milliseconds 500 }
            }
            $body | Should -Be 'contenu servi'
            $client.DownloadString("http://localhost:$port/") | Should -Match 'page\.txt'
            $status = 0
            try { $null = $client.DownloadString("http://localhost:$port/..%2f$(Split-Path -Leaf $site)-secret.txt") }
            catch { $status = [int]$_.Exception.InnerException.Response.StatusCode }
            $status | Should -BeIn 403, 404, 400
        }
        finally {
            $job | Wait-Job -Timeout 10 | Out-Null
            $job | Remove-Job -Force
            Remove-Item $site -Recurse -Force
            Remove-Item ($site + '-secret.txt') -Force
        }
    }
}

Describe 'ask' {
    It 'refuse de partir sans clé d''API, avec un message utile' {
        $saved = $env:ANTHROPIC_API_KEY
        $env:ANTHROPIC_API_KEY = $null
        try {
            $r = Invoke-Tool 'ask' @('bonjour')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'ask -Setup'
        }
        finally { $env:ANTHROPIC_API_KEY = $saved }
    }

    It 'signale une connexion impossible sans planter' {
        $saved = $env:ANTHROPIC_API_KEY, $env:ANTHROPIC_BASE_URL
        $env:ANTHROPIC_API_KEY = 'cle-de-test'
        $env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:9'
        try {
            $r = Invoke-Tool 'ask' @('bonjour')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Connexion impossible'
        }
        finally { $env:ANTHROPIC_API_KEY = $saved[0]; $env:ANTHROPIC_BASE_URL = $saved[1] }
    }
}

Describe 'Intégration au shell' {
    BeforeAll {
        $script:ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ("pst-profile-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $ProfileDir | Out-Null
        $env:PSTOOLS_PROFILE = Join-Path $ProfileDir 'profile.ps1'
        [IO.File]::WriteAllText($env:PSTOOLS_PROFILE, "# profil existant`r`nSet-Alias pstexistant Get-Date`r`n")
        $script:ShellScript = Join-Path (Join-Path (Join-Path $Root 'src') 'shell') 'PsTools.Shell.ps1'
        function Invoke-InShell {
            # Charge l'intégration dans un shell neuf et exécute une commande.
            param([string]$Command)
            $full = "`$env:PSTOOLS_NO_KEYS = '1'; . '$script:ShellScript'; $Command"
            return (@($null | & $script:Shell -NoProfile -Command $full 2>&1) -join "`n")
        }
    }
    AfterAll {
        Remove-Item Env:PSTOOLS_PROFILE -ErrorAction SilentlyContinue
        if (Test-Path $ProfileDir) { Remove-Item $ProfileDir -Recurse -Force }
    }

    It 'pst shell on ajoute un seul bloc sans toucher au reste du profil' {
        (Invoke-Tool 'pst' @('shell', 'on', '-Yes')).ExitCode | Should -Be 0
        (Invoke-Tool 'pst' @('shell', 'on', '-Yes')).ExitCode | Should -Be 0
        $text = [IO.File]::ReadAllText($env:PSTOOLS_PROFILE)
        ([regex]::Matches($text, '# >>> ps-tools >>>')).Count | Should -Be 1
        $text | Should -Match 'Set-Alias pstexistant Get-Date'
        $text | Should -Match 'PsTools\.Shell\.ps1'
    }

    It 'le profil modifié se charge et définit les commandes' {
        $out = @($null | & $Shell -NoProfile -Command "`$env:PSTOOLS_NO_KEYS = '1'; . '$env:PSTOOLS_PROFILE'; (Get-Command mkcd, mark, jump, fix, pstexistant -ErrorAction SilentlyContinue).Count" 2>&1) -join ''
        $out.Trim() | Should -Be '5'
    }

    It 'pst shell off retire le bloc et conserve le profil' {
        (Invoke-Tool 'pst' @('shell', 'off')).ExitCode | Should -Be 0
        $text = [IO.File]::ReadAllText($env:PSTOOLS_PROFILE)
        $text | Should -Not -Match 'ps-tools'
        $text | Should -Match 'Set-Alias pstexistant Get-Date'
    }

    It 'l''invite affiche le dossier et la branche Git' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = Join-Path $ProfileDir 'depot'
        New-Item -ItemType Directory -Path $repo | Out-Null
        & git -C $repo init -q -b ma-branche 2>&1 | Out-Null
        $out = Invoke-InShell "`$global:PstShell.Ansi = `$false; Set-Location -LiteralPath '$repo'; Get-PstPromptText -Success `$true"
        $out | Should -Match 'depot'
        $out | Should -Match 'git:ma-branche'
    }

    It 'l''invite colorée se construit sans erreur' {
        $out = Invoke-InShell "`$global:PstShell.Ansi = `$true; `$before = `$Error.Count; `$p = Get-PstPromptText -Success `$false -ExitCode 2; `$p.Contains([string][char]27 + '[1;38;2;'); `$Error.Count - `$before"
        $lines = @($out -split "`n" | Where-Object { $_.Trim() })
        $lines[0].Trim() | Should -Be 'True'
        $lines[1].Trim() | Should -Be '0'
    }

    It 'les favoris mémorisent et retrouvent un dossier' {
        $target = Join-Path $ProfileDir 'cible'
        New-Item -ItemType Directory -Path $target | Out-Null
        $out = Invoke-InShell "Set-Location -LiteralPath '$target'; mark essai | Out-Null; Set-Location -LiteralPath '$ProfileDir'; jump essai; (Get-Location).ProviderPath; jump -; (Get-Location).ProviderPath"
        $lines = @($out -split "`n" | Where-Object { $_ -match 'pst-profile' } | Select-Object -Last 2)
        (Split-Path -Leaf $lines[0].Trim()) | Should -Be 'cible'
        (Split-Path -Leaf $lines[1].Trim()) | Should -Be (Split-Path -Leaf $ProfileDir)
    }

    It 'les commandes façon Unix fonctionnent dans un pipeline' {
        $out = Invoke-InShell "if (Get-Command grep -CommandType Function -ErrorAction SilentlyContinue) { ('alpha','beta','gamma' | grep 'a$' | Measure-Object).Count } else { 2 }; if (Get-Command head -CommandType Function -ErrorAction SilentlyContinue) { (1..9 | head -n 2) -join ',' } else { '1,2' }"
        $out | Should -Match '(?m)^2\s*$'
        $out | Should -Match '1,2'
    }
}

Describe 'Configuration et thèmes' {
    BeforeAll {
        . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1')
        $script:SavedData = $env:PSTOOLS_DATA
        $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-cfg-" + [Guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        if (Test-Path $env:PSTOOLS_DATA) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
        $env:PSTOOLS_DATA = $SavedData
    }

    It 'fournit une configuration complète par défaut' {
        $c = Get-PstConfig
        $c.theme | Should -Be 'cyan'
        $c.ai.effort | Should -Be 'low'
        $c.shell.prompt | Should -BeTrue
    }

    It 'enregistre puis relit la configuration en gardant les valeurs par défaut' {
        $c = Get-PstConfig
        $c.shell.keys = $false   # entrée nommée « keys » : piège classique des tables PowerShell
        $c.theme = 'clair'
        $c.ai.provider = 'openai'
        $c.ai.prices['openai/test'] = @{ in = 1.5; out = 6 }
        Save-PstConfig $c
        $again = Get-PstConfig
        $again.theme | Should -Be 'clair'
        $again.ai.provider | Should -Be 'openai'
        $again.ai.prices['openai/test'].out | Should -Be 6
        $again.shell.keys | Should -BeFalse
        $again.shell.prompt | Should -BeTrue
        Save-PstConfig $again   # une configuration relue doit pouvoir être réenregistrée
    }

    It 'chiffre les clés et sait les effacer' {
        Set-PstSecret 'ai.test' 'sk-secret-123'
        Get-PstSecret 'ai.test' | Should -Be 'sk-secret-123'
        [IO.File]::ReadAllText((Join-Path $env:PSTOOLS_DATA 'secrets.json')) | Should -Not -Match 'sk-secret-123'
        Set-PstSecret 'ai.test' ''
        Get-PstSecret 'ai.test' | Should -BeNullOrEmpty
    }

    It 'chaque thème définit les sept couleurs' {
        foreach ($name in $script:PstThemes.Keys) {
            foreach ($role in 'Accent', 'Accent2', 'Ok', 'Warn', 'Err', 'Dim', 'Title') { @($script:PstThemes[$name][$role]).Count | Should -Be 3 -Because "$name.$role" }
        }
        Set-PstTheme 'inexistant'
        $script:Pst.ThemeName | Should -Be 'cyan'
    }

    It 'coupe un texte à la largeur demandée' {
        $lines = Format-PstWrap 'un deux trois quatre cinq six sept' 10
        $lines | ForEach-Object { $_.Length | Should -BeLessOrEqual 10 }
        ($lines -join ' ') | Should -Be 'un deux trois quatre cinq six sept'
    }
}

Describe 'Profil PowerShell bloqué' {
    BeforeAll {
        . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1')
        $script:ProfileDir2 = Join-Path ([IO.Path]::GetTempPath()) ("pst-blocked-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $ProfileDir2 | Out-Null
        $script:SavedProfile = $env:PSTOOLS_PROFILE
        $env:PSTOOLS_PROFILE = Join-Path $ProfileDir2 'profile.ps1'
    }
    AfterAll {
        $env:PSTOOLS_PROFILE = $SavedProfile
        Remove-Item Env:PSTOOLS_TEST_PROFILE_BLOCKED -ErrorAction SilentlyContinue
        if (Test-Path $ProfileDir2) { Remove-Item $ProfileDir2 -Recurse -Force }
    }

    It 'teste réellement le chargement, sans laisser de fichier de test' {
        Test-PstProfileLoadable $env:PSTOOLS_PROFILE | Should -BeTrue
        @(Get-ChildItem $ProfileDir2 -Force).Count | Should -Be 0
    }

    It 'ignore la préférence Bypass héritée des lanceurs' {
        $env:PSExecutionPolicyPreference = 'Bypass'
        try { Test-PstProfileLoadable $env:PSTOOLS_PROFILE | Should -BeTrue; $env:PSExecutionPolicyPreference | Should -Be 'Bypass' }
        finally { Remove-Item Env:PSExecutionPolicyPreference -ErrorAction SilentlyContinue }
    }

    It 'n''écrit pas dans un profil bloqué et retire un ancien bloc' {
        [IO.File]::WriteAllText($env:PSTOOLS_PROFILE, "# a moi`r`n")
        (Invoke-Tool 'pst' @('shell', 'on', '-Yes')).ExitCode | Should -Be 0
        [IO.File]::ReadAllText($env:PSTOOLS_PROFILE) | Should -Match 'ps-tools'
        $env:PSTOOLS_TEST_PROFILE_BLOCKED = '1'
        try {
            # Situation de la version 2.2 : bloc présent, profil bloqué. Le diagnostic le signale...
            (Invoke-Tool 'pst' @('doctor')).Output | Should -Match 'Profil bloqu'
            # ... et « pst shell on » retire le bloc au lieu de le laisser échouer.
            $r = Invoke-Tool 'pst' @('shell', 'on', '-Yes')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'bloqu'
            [IO.File]::ReadAllText($env:PSTOOLS_PROFILE) | Should -Not -Match 'ps-tools'
            [IO.File]::ReadAllText($env:PSTOOLS_PROFILE) | Should -Match 'a moi'
        }
        finally { Remove-Item Env:PSTOOLS_TEST_PROFILE_BLOCKED -ErrorAction SilentlyContinue }
    }

    It 'supprime un profil qui ne contenait que le bloc ps-tools' {
        Remove-Item $env:PSTOOLS_PROFILE -Force
        (Invoke-Tool 'pst' @('shell', 'on', '-Yes')).ExitCode | Should -Be 0
        $env:PSTOOLS_TEST_PROFILE_BLOCKED = '1'
        try { $null = Invoke-Tool 'pst' @('shell', 'on', '-Yes') } finally { Remove-Item Env:PSTOOLS_TEST_PROFILE_BLOCKED -ErrorAction SilentlyContinue }
        $env:PSTOOLS_PROFILE | Should -Not -Exist
    }

    It 'calcule la clé de zone Intranet d''un serveur' {
        (Get-PstZoneKey 'beijaflore.com').Key | Should -Match 'Domains\\beijaflore\.com$'
        (Get-PstZoneKey 'fs01.corp.example.com').Key | Should -Match 'Domains\\example\.com\\fs01\.corp$'
        (Get-PstZoneKey '10.1.2.3').Range | Should -Be '10.1.2.3'
        (Get-PstProfileLocation '\\beijaflore.com\users\docs\profile.ps1').Server | Should -Be 'beijaflore.com'
        (Get-PstProfileLocation '\\beijaflore.com\users\docs\profile.ps1').IsNetwork | Should -BeTrue
    }
}

Describe 'Assistant IA' {
    BeforeDiscovery {
        # Évalué à la découverte des tests : décide si les tests du faux service tournent.
        $script:HasPython = [bool](Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1)
    }
    BeforeAll {
        $lib = Join-Path (Join-Path $Root 'src') 'lib'
        . (Join-Path $lib 'PsTools.ps1')
        . (Join-Path $lib 'PsTools.AI.ps1')
        $script:SavedData = $env:PSTOOLS_DATA
        $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-ai-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $env:PSTOOLS_DATA | Out-Null
        $script:SavedKeys = @{}
        foreach ($name in 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_BASE_URL') { $SavedKeys[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }

        # Faux service d'IA (Python), s'il est disponible.
        $script:Python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1
        $script:MockPort = Get-Random -Minimum 41000 -Maximum 49000
        $script:Trace = Join-Path $env:PSTOOLS_DATA 'trace.json'
        $script:Mock = $null
        if ($Python) {
            $startArgs = @{ FilePath = $Python.Source; ArgumentList = @((Join-Path $PSScriptRoot 'MockAiServer.py'), $MockPort, "`"$Trace`"", 300); PassThru = $true }
            if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) { $startArgs.WindowStyle = 'Hidden' }
            $script:Mock = Start-Process @startArgs
            for ($i = 0; $i -lt 40; $i++) {
                try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $MockPort); $c.Close(); break } catch { Start-Sleep -Milliseconds 250 }
            }
        }
        $script:MockUrl = "http://127.0.0.1:$MockPort"
        function Get-Trace { return (Get-Content $Trace -Raw -Encoding UTF8 | ConvertFrom-Json) }
    }
    AfterAll {
        if ($Mock -and -not $Mock.HasExited) { Stop-Process -Id $Mock.Id -Force -ErrorAction SilentlyContinue }
        foreach ($name in $SavedKeys.Keys) { [Environment]::SetEnvironmentVariable($name, $SavedKeys[$name]) }
        if (Test-Path $env:PSTOOLS_DATA) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
        $env:PSTOOLS_DATA = $SavedData
    }

    It 'chaque fournisseur est complet et chaque prix cohérent' {
        foreach ($id in $script:PstAiProviders.Keys) {
            $p = $script:PstAiProviders[$id]
            $p.Label | Should -Not -BeNullOrEmpty
            $p.Protocol | Should -BeIn 'anthropic', 'openai'
            foreach ($m in $p.Models) { $m.Out | Should -BeGreaterOrEqual $m.In -Because "$id/$($m.Id)" }
            if ($p.Default -and $p.Models.Count) { @($p.Models | ForEach-Object { $_.Id }) | Should -Contain $p.Default }
        }
    }

    It 'applique paliers longs, changements datés et heures de pointe' {
        (Get-PstAiPrice anthropic claude-haiku-5-5 5000).In | Should -Be 0.10
        (Get-PstAiPrice anthropic claude-haiku-5-5 150000).In | Should -Be 0.50
        (Get-PstAiPrice gemini gemini-4-carbon 0 ([DateTime]'2026-11-25')).In | Should -Be 2
        (Get-PstAiPrice gemini gemini-4-carbon 0 ([DateTime]'2026-12-02')).In | Should -Be 4
        $peak = ([DateTimeOffset]'2026-11-23T07:00:00Z').LocalDateTime     # lundi, 7 h UTC
        $offPeak = ([DateTimeOffset]'2026-11-22T07:00:00Z').LocalDateTime  # dimanche
        (Get-PstAiPrice deepseek deepseek-flash 0 $peak).In | Should -Be 0.30
        (Get-PstAiPrice deepseek deepseek-flash 0 $offPeak).In | Should -Be 0.15
        (Get-PstAiPrice ollama llama4).Free | Should -BeTrue
        (Get-PstAiPrice openai modele-inconnu).Known | Should -BeFalse
        Get-PstAiCost (Get-PstAiPrice anthropic claude-opus-5-5) 1000000 100000 | Should -Be 6
    }

    It 'privilégie la clé de l''environnement puis la clé enregistrée' {
        (Get-PstAiKey openai).Key | Should -BeNullOrEmpty
        Set-PstSecret 'ai.openai' 'sk-enregistree'
        (Get-PstAiKey openai).Key | Should -Be 'sk-enregistree'
        $env:OPENAI_API_KEY = 'sk-environnement'
        try { (Get-PstAiKey openai).Key | Should -Be 'sk-environnement' }
        finally { $env:OPENAI_API_KEY = $null; Set-PstSecret 'ai.openai' '' }   # aucun test ne doit joindre un vrai service
    }

    It 'dialogue avec un service Anthropic (flux, jetons, coût)' -Skip:(-not $HasPython) {
        $r = Invoke-PstAiRequest -Provider anthropic -Model claude-opus-5-5 -Key k -BaseUrl $MockUrl -System s -User u
        $r.Error | Should -BeNullOrEmpty
        $r.Text | Should -Be 'Bonjour, réponse accentuée : éàü.'
        $r.In | Should -Be 1200
        $r.Out | Should -Be 300
        $r.Cost | Should -BeGreaterThan 0.0107
        $r.Cost | Should -BeLessThan 0.0109
        $t = Get-Trace
        $t.path | Should -Be '/v1/messages'
        $t.headers.'x-api-key' | Should -Be 'k'
        $t.body.output_config.effort | Should -Be 'low'
    }

    It 'dialogue avec un service compatible OpenAI (usage, coût fourni, Groq, repli)' -Skip:(-not $HasPython) {
        $r = Invoke-PstAiRequest -Provider openai -Model gpt-6.2-sol -Key k -BaseUrl "$MockUrl/v1" -System s -User u
        $r.Text | Should -Be 'Bonjour, réponse accentuée : éàü.'
        $r.In | Should -Be 2000
        $r.Cost | Should -BeGreaterThan 0.0089
        (Get-Trace).body.reasoning_effort | Should -Be 'low'
        (Invoke-PstAiRequest -Provider openrouter -Model x/y -Key withcost -BaseUrl "$MockUrl/v1" -System s -User u).Cost | Should -Be 0.0421
        (Invoke-PstAiRequest -Provider groq -Model openai/gpt-oss-20b -Key groq -BaseUrl "$MockUrl/v1" -System s -User u).Out | Should -Be 500
        $retry = Invoke-PstAiRequest -Provider mistral -Model mistral-large-4 -Key nostreamoptions -BaseUrl "$MockUrl/v1" -System s -User u
        $retry.Error | Should -BeNullOrEmpty
        $retry.In | Should -Be 2000
        $estimate = Invoke-PstAiRequest -Provider custom -Model x -Key nousage -BaseUrl "$MockUrl/v1" -System ('s' * 40) -User ('u' * 40)
        $estimate.Estimated | Should -BeTrue
        $estimate.In | Should -Be 20
    }

    It 'liste les modèles, filtre les non conversationnels et lit les prix en direct' -Skip:(-not $HasPython) {
        $m = Get-PstAiModels -Provider openrouter -Key k -BaseUrl "$MockUrl/v1"
        $m.Ok | Should -BeTrue
        $m.Models | Should -Contain 'gpt-6.2-sol'
        $m.Models | Should -Not -Contain 'text-embedding-9'
        $m.Prices['vendor/priced-model'].in | Should -Be 2
        (Get-PstAiModels -Provider openai -Key bad -BaseUrl "$MockUrl/v1").Status | Should -Be 401
    }

    It 'ask affiche la réponse, les jetons et le coût, puis journalise' -Skip:(-not $HasPython) {
        $env:ANTHROPIC_API_KEY = 'k'; $env:ANTHROPIC_BASE_URL = $MockUrl
        try {
            $r = Invoke-Tool 'ask' @('-Provider', 'anthropic', 'bonjour')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'réponse accentuée'
            $r.Output | Should -Match 'jetons'
            $r.Output | Should -Match '\$'
            (Invoke-Tool 'ask' @('-Provider', 'anthropic', '-Cmd', '-Raw', 'gros fichiers')).Output.Trim() | Should -Be 'Get-ChildItem -File'
            $env:ANTHROPIC_API_KEY = 'bad'
            (Invoke-Tool 'ask' @('-Provider', 'anthropic', 'x')).Output | Should -Match 'Clé d.API refusée'
        }
        finally { $env:ANTHROPIC_API_KEY = $null; $env:ANTHROPIC_BASE_URL = $null }
        $usage = Invoke-Tool 'ask' @('-Usage')
        $usage.Output | Should -Match 'Ce mois-ci'
        $usage.Output | Should -Match 'claude-opus-5-5'
        (Get-PstAiUsage).Count | Should -BeGreaterOrEqual 2
    }

    It 'ask guide quand la clé ou le modèle manque' {
        $r = Invoke-Tool 'ask' @('-Provider', 'openai', 'x')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'OPENAI_API_KEY'
        (Invoke-Tool 'ask' @('-Provider', 'ollama', 'x')).Output | Should -Match 'Aucun modèle'
        (Invoke-Tool 'ask' @('-Provider', 'inconnu', 'x')).Output | Should -Match 'Fournisseur inconnu'
    }
}

Describe 'Assistant d''installation' {
    BeforeAll {
        $lib = Join-Path (Join-Path $Root 'src') 'lib'
        . (Join-Path $lib 'PsTools.ps1')
        . (Join-Path $lib 'PsTools.AI.ps1')
        . (Join-Path $lib 'PsTools.Wizard.ps1')
        $script:SavedData = $env:PSTOOLS_DATA
        $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-wiz-" + [Guid]::NewGuid().ToString('N'))
        $script:SavedProfile = $env:PSTOOLS_PROFILE
        $env:PSTOOLS_PROFILE = Join-Path $env:PSTOOLS_DATA 'profil\profile.ps1'
    }
    AfterAll {
        if (Test-Path $env:PSTOOLS_DATA) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
        $env:PSTOOLS_DATA = $SavedData
        $env:PSTOOLS_PROFILE = $SavedProfile
    }

    It 'parcourt toutes les étapes et retourne les choix' {
        $manifest = Get-Content (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $state = Invoke-PstInstallWizard -Manifest $manifest -IsAdmin $false -Roots @{ CurrentUser = 'C:\u'; AllUsers = 'C:\a' } 6>$null
        $state | Should -Not -BeNullOrEmpty
        $state.Scope | Should -Be 'CurrentUser'
        @($state.Tools).Count | Should -Be @($manifest.tools | Where-Object { -not $_.required }).Count
        $state.Shell.Enabled | Should -BeTrue
    }

    It 'applique le thème et l''intégration au shell choisis' {
        $appRoot = Join-Path $Root 'src'
        $result = Invoke-PstApplyConfig -State @{ Theme = 'ambre'; Shell = @{ Enabled = $true; Prompt = $true; Keys = $false; Aliases = $true; Remedy = '' }; Ai = $null } -AppRoot $appRoot 6>$null
        $result | Should -Be 'active'
        (Get-PstConfig).theme | Should -Be 'ambre'
        (Get-PstConfig).shell.keys | Should -BeFalse
        [IO.File]::ReadAllText($env:PSTOOLS_PROFILE) | Should -Match 'PsTools\.Shell\.ps1'
        $null = Disable-PstShell
    }

    It 'l''intégration au shell respecte les réglages enregistrés' {
        $c = Get-PstConfig; $c.theme = 'clair'; $c.shell.aliases = $false; Save-PstConfig $c
        $shellScript = Join-Path (Join-Path (Join-Path $Root 'src') 'shell') 'PsTools.Shell.ps1'
        $out = @($null | & $Shell -NoProfile -Command "`$env:PSTOOLS_NO_KEYS = '1'; . '$shellScript'; [bool](Get-Command mkcd -ErrorAction SilentlyContinue); `$global:PstShell.Colors.Path -join ','" 2>&1) -join "`n"
        $out | Should -Match 'False'
        $out | Should -Match '0,105,190'
    }
}
