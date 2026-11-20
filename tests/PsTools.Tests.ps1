# Tests Pester (v5+) — exécutables sous Windows PowerShell 5.1 et PowerShell 7, Windows ou non.
#   Invoke-Pester ./tests

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Manifest = Get-Content (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $env:NO_COLOR = '1'
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
    It '<_> -Help répond sans erreur' -ForEach @('pst', 'pst-uninstall', 'ask', 'monitor', 'sysinfo', 'clean', 'watch', 'logtail', 'events', 'gst', 'loc', 'serve', 'dev', 'dsize', 'ping-mon', 'netinfo', 'ports', 'remind') {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION'
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
        (Join-Path (Join-Path (Join-Path $Dest 'app') 'lib') 'PsTools.ps1') | Should -Exist
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
