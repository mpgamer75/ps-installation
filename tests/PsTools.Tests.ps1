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
            $output = & $script:Shell -NoProfile -Command $command 2>&1
        }
        else { $output = & $script:Shell -NoProfile -File $file @Arguments 2>&1 }
        return @{ Output = (@($output) -join "`n"); ExitCode = $LASTEXITCODE }
    }
}

AfterAll {
    if ($env:PSTOOLS_DATA -and (Test-Path $env:PSTOOLS_DATA)) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
    Remove-Item Env:PSTOOLS_DATA, Env:PSTOOLS_TASK_PREFIX, Env:PSTOOLS_TEST_WINDOWS -ErrorAction SilentlyContinue
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
    It '<_> -Help répond sans erreur' -ForEach @('pst', 'monitor', 'sysinfo', 'clean', 'dsize', 'ping-mon', 'netinfo', 'ports', 'remind') {
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
        ($names -join ',') | Should -Be 'dsize,pst,remind'
    }

    It 'refuse un outil inconnu' {
        $out = & $Shell -NoProfile -File $Installer -InstallRoot $Dest -NoPath -Yes -Tools 'inexistant' 2>&1
        (@($out) -join "`n") | Should -Match 'inconnu'
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
