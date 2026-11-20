# Tests Pester (v5+) des outils de fichiers et du poste : tidy, dupes, awake.
#   Invoke-Pester ./tests/Files.Tests.ps1

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $env:NO_COLOR = '1'
    $env:PSTOOLS_LANG = 'fr'   # les assertions portent sur les textes français ; l'anglais a ses propres tests
    $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))

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

    function New-TestDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("pst-files-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function Set-TestFile {
        param([string]$File, [string]$Content, [DateTime]$Modified = (Get-Date))
        $dir = Split-Path -Parent $File
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($File, $Content)
        (Get-Item -LiteralPath $File -Force).LastWriteTime = $Modified
    }
}

AfterAll {
    if ($env:PSTOOLS_DATA -and (Test-Path $env:PSTOOLS_DATA)) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
    Remove-Item Env:PSTOOLS_DATA -ErrorAction SilentlyContinue
}

Describe 'Aide des outils de fichiers' {
    It '<_> répond à -Help en français et en anglais' -ForEach @('tidy', 'dupes', 'awake') {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION|USAGE'
        $r.Output | Should -Match $_
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-Tool $_ @('-Help') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.ExitCode | Should -Be 0
        $en.Output | Should -Not -Match '[éèàù]|défaut|fichiers? '
    }
}

Describe 'tidy' {
    BeforeEach {
        $script:Dir = New-TestDir
        Set-TestFile (Join-Path $Dir 'photo.jpg') 'img'
        Set-TestFile (Join-Path $Dir 'facture.pdf') 'pdf'
        Set-TestFile (Join-Path $Dir 'film.mkv') 'mkv'
        Set-TestFile (Join-Path $Dir 'setup.msi') 'msi'
        Set-TestFile (Join-Path $Dir 'script.ps1') 'code'
        Set-TestFile (Join-Path $Dir 'bizarre.xyz') 'other'
        Set-TestFile (Join-Path $Dir 'encours.crdownload') 'partial'
        Set-TestFile (Join-Path $Dir 'dl.part') 'partial'
        Set-TestFile (Join-Path (Join-Path $Dir 'Projet') 'interne.jpg') 'nested'
        Set-TestFile (Join-Path (Join-Path $Dir 'Images') 'photo.jpg') 'already there'
        Remove-Item (Join-Path $env:PSTOOLS_DATA 'tidy-journal.json') -ErrorAction SilentlyContinue
    }
    AfterEach { Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It '-DryRun montre l''aperçu sans rien déplacer' {
        $r = Invoke-Tool 'tidy' @($Dir, '-DryRun')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Installateurs'
        $r.Output | Should -Match '6 fichier\(s\) à ranger'
        $r.Output | Should -Match '2 téléchargement\(s\) en cours'
        $r.Output | Should -Match 'Simulation'
        (Join-Path $Dir 'photo.jpg') | Should -Exist
        (Join-Path $Dir 'Vidéos') | Should -Not -Exist
    }

    It 'ne déplace rien sans -Yes en session non interactive' {
        $r = Invoke-Tool 'tidy' @($Dir)
        $r.Output | Should -Match '-Yes'
        (Join-Path $Dir 'facture.pdf') | Should -Exist
    }

    It 'range par type, sans écraser ni descendre dans les sous-dossiers, puis -Undo remet tout en place' {
        $r = Invoke-Tool 'tidy' @($Dir, '-Yes')
        $r.ExitCode | Should -Be 0
        (Join-Path (Join-Path $Dir 'Documents') 'facture.pdf') | Should -Exist
        (Join-Path (Join-Path $Dir 'Vidéos') 'film.mkv') | Should -Exist
        (Join-Path (Join-Path $Dir 'Installateurs') 'setup.msi') | Should -Exist
        (Join-Path (Join-Path $Dir 'Code') 'script.ps1') | Should -Exist
        (Join-Path (Join-Path $Dir 'Autres') 'bizarre.xyz') | Should -Exist
        (Join-Path (Join-Path $Dir 'Images') 'photo (2).jpg') | Should -Exist
        [IO.File]::ReadAllText((Join-Path (Join-Path $Dir 'Images') 'photo.jpg')) | Should -Be 'already there'
        (Join-Path $Dir 'encours.crdownload') | Should -Exist
        (Join-Path (Join-Path $Dir 'Projet') 'interne.jpg') | Should -Exist
        (Join-Path $env:PSTOOLS_DATA 'tidy-journal.json') | Should -Exist

        $u = Invoke-Tool 'tidy' @('-Undo', '-Yes')
        $u.ExitCode | Should -Be 0
        $u.Output | Should -Match '6 fichier\(s\) remis en place'
        foreach ($n in 'photo.jpg', 'facture.pdf', 'film.mkv', 'setup.msi', 'script.ps1', 'bizarre.xyz') { (Join-Path $Dir $n) | Should -Exist }
        [IO.File]::ReadAllText((Join-Path $Dir 'photo.jpg')) | Should -Be 'img'
        (Join-Path $Dir 'Vidéos') | Should -Not -Exist          # dossier créé par le rangement, supprimé car vide
        (Join-Path (Join-Path $Dir 'Images') 'photo.jpg') | Should -Exist   # dossier préexistant conservé

        (Invoke-Tool 'tidy' @('-Undo')).Output | Should -Match 'Aucun rangement à annuler'
    }

    It '-By Date et -OlderThan ne rangent que les fichiers anciens, par mois' {
        Set-TestFile (Join-Path $Dir 'vieux.txt') 'old' (Get-Date '2025-03-14')
        $r = Invoke-Tool 'tidy' @($Dir, '-By', 'Date', '-OlderThan', '30', '-Yes')
        $r.ExitCode | Should -Be 0
        (Join-Path (Join-Path $Dir '2025-03') 'vieux.txt') | Should -Exist
        (Join-Path $Dir 'photo.jpg') | Should -Exist
    }

    It 'nomme les dossiers en anglais quand la langue est l''anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'tidy' @($Dir, '-Yes') } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match 'Tidy complete'
        (Join-Path (Join-Path $Dir 'Videos') 'film.mkv') | Should -Exist
        (Join-Path (Join-Path $Dir 'Installers') 'setup.msi') | Should -Exist
        (Join-Path (Join-Path $Dir 'Other') 'bizarre.xyz') | Should -Exist
    }

    It '-Json décrit le plan sans rien déplacer' {
        $j = (Invoke-Tool 'tidy' @($Dir, '-Json')).Output | ConvertFrom-Json
        @($j.Moves).Count | Should -Be 6
        $j.Skipped.Partial | Should -Be 2
        (Join-Path $Dir 'photo.jpg') | Should -Exist
    }

    It 'refuse un mode inconnu et un dossier introuvable' {
        (Invoke-Tool 'tidy' @($Dir, '-By', 'taille')).ExitCode | Should -Be 1
        (Invoke-Tool 'tidy' @((Join-Path $Dir 'absent'))).ExitCode | Should -Be 1
    }
}

Describe 'dupes' {
    BeforeAll {
        $script:Dir = New-TestDir
        $big = 'x' * 4096
        Set-TestFile (Join-Path (Join-Path $Dir 'a') 'gros.bin') $big (Get-Date '2026-01-10')
        Set-TestFile (Join-Path (Join-Path $Dir 'b') 'gros copie.bin') $big (Get-Date '2025-06-01')
        Set-TestFile (Join-Path $Dir 'gros.bin') $big (Get-Date '2026-02-01')
        Set-TestFile (Join-Path (Join-Path $Dir 'a') 'note.txt') 'pareil' (Get-Date '2026-01-01')
        Set-TestFile (Join-Path (Join-Path $Dir 'b') 'note.txt') 'pareil' (Get-Date '2026-01-01')
        Set-TestFile (Join-Path (Join-Path $Dir 'a') 'diff.txt') 'abc1'
        Set-TestFile (Join-Path (Join-Path $Dir 'b') 'diff.txt') 'abc2'   # même taille, contenu différent
        Set-TestFile (Join-Path $Dir 'vide1.txt') ''
        Set-TestFile (Join-Path $Dir 'vide2.txt') ''
    }
    AfterAll { Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'groupe par contenu, trie par espace perdu et propose la plus ancienne' {
        $j = (Invoke-Tool 'dupes' @($Dir, '-Json')).Output | ConvertFrom-Json
        @($j.Groups).Count | Should -Be 2
        $j.Groups[0].Copies | Should -Be 3
        $j.Groups[0].WastedBytes | Should -Be 8192
        $j.ReclaimableBytes | Should -Be (8192 + 6)
        $keeper = @($j.Groups[0].Files | Where-Object { $_.Keep })
        $keeper.Count | Should -Be 1
        $keeper[0].Path | Should -Match 'gros copie\.bin$'
        # Égalité de date : le chemin le plus court l'emporte.
        @($j.Groups[1].Files | Where-Object { $_.Keep }).Count | Should -Be 1
    }

    It '-Min et -Include filtrent les fichiers' {
        $j = (Invoke-Tool 'dupes' @($Dir, '-Min', '1K', '-Json')).Output | ConvertFrom-Json
        @($j.Groups).Count | Should -Be 1
        $j = (Invoke-Tool 'dupes' @($Dir, '-Include', '*.txt', '-Json')).Output | ConvertFrom-Json
        @($j.Groups).Count | Should -Be 1
        $j.Groups[0].Bytes | Should -Be 6
        (Invoke-Tool 'dupes' @($Dir, '-Min', 'beaucoup')).ExitCode | Should -Be 1
    }

    It 'affiche le rapport et ne supprime rien en simulation' {
        $r = Invoke-Tool 'dupes' @($Dir, '-DryRun')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '3 copies de'
        $r.Output | Should -Match '2 groupe\(s\) de doublons'
        $r.Output | Should -Match 'Simulation'
        (Join-Path $Dir 'gros.bin') | Should -Exist
    }

    It 'ne suit pas les liens symboliques' {
        $link = Join-Path $Dir 'lien'
        try { New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $Dir 'a') -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'création de lien impossible sans droits'; return }
        try {
            $r = Invoke-Tool 'dupes' @($Dir, '-Json')
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $j = $r.Output | ConvertFrom-Json
            $j | Should -Not -BeNullOrEmpty -Because $r.Output
            $j.FilesScanned | Should -Be 7 -Because $r.Output
        }
        finally {
            # Supprime le lien lui-même (Remove-Item sous 5.1 peut échouer ou suivre la cible).
            try { [IO.Directory]::Delete($link) } catch { Remove-Item $link -Force -ErrorAction SilentlyContinue }
        }
    }

    It '-Yes garde exactement une copie par groupe' {
        $work = New-TestDir
        try {
            Copy-Item -Path (Join-Path $Dir '*') -Destination $work -Recurse
            $r = Invoke-Tool 'dupes' @($work, '-Yes', '-Keep', 'shortest')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '3 fichier\(s\) supprimé\(s\)'
            (Join-Path $work 'gros.bin') | Should -Exist
            (Join-Path (Join-Path $work 'a') 'gros.bin') | Should -Not -Exist
            (Join-Path (Join-Path $work 'b') 'gros copie.bin') | Should -Not -Exist
            @(Get-ChildItem $work -Recurse -Filter 'note.txt').Count | Should -Be 1
            (Join-Path (Join-Path $work 'b') 'diff.txt') | Should -Exist
        }
        finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parle anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'dupes' @($Dir, '-DryRun') } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match '3 copies of'
        $r.Output | Should -Match 'reclaimable'
        $r.Output | Should -Match 'Dry run'
    }
}

Describe 'awake' {
    It 'explique qu''il faut Windows ailleurs' -Skip:([bool]($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)) {
        $r = Invoke-Tool 'awake' @('5s')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'nécessite Windows'
    }

    It 'respecte une courte durée en session non interactive, puis rétablit la veille' {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Tool 'awake' @('2s', '-Display') -Mocked
        $watch.Stop()
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'écran allumé'
        $r.Output | Should -Match 'Veille normale rétablie'
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1.5
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'sans durée en session non interactive, affiche un écran et rend la main' {
        $r = Invoke-Tool 'awake' @() -Mocked
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'indiquez une durée'
    }

    It 'comprend -Until et les heures en anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'awake' @('-Until', '23:59', '-Once') -Mocked } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Ends\s+\w+day, \w+ \d+ at 23:59'
        $r.Output | Should -Match 'Normal sleep restored'
    }

    It 'refuse une durée ou une heure invalide' {
        (Invoke-Tool 'awake' @('2x') -Mocked).ExitCode | Should -Be 1
        (Invoke-Tool 'awake' @('-Until', '25:00') -Mocked).ExitCode | Should -Be 1
    }
}
