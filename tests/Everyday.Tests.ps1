# Tests Pester (v5+) des outils du quotidien : todo, note, timer.
#   Invoke-Pester ./tests/Everyday.Tests.ps1

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $env:NO_COLOR = '1'
    $env:PSTOOLS_LANG = 'fr'   # les assertions portent sur les textes français ; l'anglais a ses propres tests
    $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))
    $env:PSTOOLS_TASK_PREFIX = 'PsToolsTest_Reminder_'

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

    function New-DataDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $env:PSTOOLS_DATA = $dir
        return $dir
    }

    function Get-TodoJson {
        param([string[]]$Arguments = @('list', '-All'))
        $r = Invoke-Tool 'todo' (@($Arguments) + '-Json')
        $r.ExitCode | Should -Be 0
        return @($r.Output | ConvertFrom-Json | ForEach-Object { $_ })
    }
}

AfterAll {
    if ($env:PSTOOLS_DATA -and (Test-Path $env:PSTOOLS_DATA)) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
    Remove-Item Env:PSTOOLS_DATA, Env:PSTOOLS_TASK_PREFIX -ErrorAction SilentlyContinue
}

Describe 'Aide des outils du quotidien' {
    It '<_> -Help répond en français et en anglais' -ForEach @('todo', 'note', 'timer') {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION'
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-Tool $_ @('-Help') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.ExitCode | Should -Be 0
        $en.Output | Should -Match 'USAGE'
        $en.Output | Should -Not -Match 'UTILISATION'
    }
}

Describe 'todo' {
    BeforeAll { $script:Data = New-DataDir }
    AfterAll { if (Test-Path $Data) { Remove-Item $Data -Recurse -Force } }

    It 'ajoute une tâche avec étiquette et priorité dans le texte' {
        $r = Invoke-Tool 'todo' @('add', 'Acheter du pain +courses !!', '-Due', 'demain')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'ajoutée : Acheter du pain'
        $t = @(Get-TodoJson)[0]
        $t.text | Should -Be 'Acheter du pain'
        $t.tags | Should -Be @('courses')
        $t.priority | Should -Be 'high'
        $t.due | Should -Be ((Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd'))
        (Join-Path $Data 'todo.json') | Should -Exist
    }

    It 'accepte les mots sans guillemets et les options -Priority / -Tag' {
        $r = Invoke-Tool 'todo' @('add', 'Appeler', 'le', 'garage', '-Priority', 'low', '-Tag', 'voiture')
        $r.ExitCode | Should -Be 0
        $t = Get-TodoJson | Where-Object { $_.text -eq 'Appeler le garage' }
        $t.priority | Should -Be 'low'
        $t.tags | Should -Be @('voiture')
        $t.group | Should -Be 'someday'
    }

    It 'comprend l''échéance « <In> »' -ForEach @(
        @{ In = "aujourd'hui"; Days = 0 }, @{ In = 'today'; Days = 0 }, @{ In = 'tomorrow'; Days = 1 },
        @{ In = '+3j'; Days = 3 }, @{ In = '+3d'; Days = 3 }, @{ In = '+2sem'; Days = 14 }, @{ In = 'hier'; Days = -1 }
    ) {
        $r = Invoke-Tool 'todo' @('add', "Échéance $In", '-Due', $In, '-Json')
        $r.ExitCode | Should -Be 0
        ($r.Output | ConvertFrom-Json).due | Should -Be ((Get-Date).Date.AddDays($Days).ToString('yyyy-MM-dd'))
    }

    It 'comprend les jours de la semaine et les dates' {
        $today = (Get-Date).Date
        $delta = (1 - [int]$today.DayOfWeek + 7) % 7
        if ($delta -eq 0) { $delta = 7 }
        foreach ($word in 'lundi', 'monday') {
            (Invoke-Tool 'todo' @('add', "Jour $word", '-Due', $word, '-Json')).Output | ConvertFrom-Json |
                ForEach-Object { $_.due | Should -Be ($today.AddDays($delta).ToString('yyyy-MM-dd')) }
        }
        ((Invoke-Tool 'todo' @('add', 'Date ISO', '-Due', '2030-12-25', '-Json')).Output | ConvertFrom-Json).due | Should -Be '2030-12-25'
        ((Invoke-Tool 'todo' @('add', 'Date FR', '-Due', '25/12/2030', '-Json')).Output | ConvertFrom-Json).due | Should -Be '2030-12-25'
    }

    It 'refuse une échéance invalide' {
        $r = Invoke-Tool 'todo' @('add', 'Mauvaise date', '-Due', '31/02')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Échéance non reconnue'
    }

    It 'groupe et numérote : en retard, aujourd''hui, à venir, un jour' {
        $null = New-DataDir
        $null = Invoke-Tool 'todo' @('add', 'Plus tard')
        $null = Invoke-Tool 'todo' @('add', 'Demain', '-Due', 'demain')
        $null = Invoke-Tool 'todo' @('add', 'Retard', '-Due', 'hier')
        $null = Invoke-Tool 'todo' @('add', 'Ce jour', '-Due', '+0')
        $r = Invoke-Tool 'todo'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '(?s)En retard.*en retard de 1 j.*Pour aujourd.hui.*aujourd.hui.*À venir.*demain.*Un jour.*Plus tard'
        $tasks = @(Get-TodoJson)
        ($tasks | ForEach-Object { $_.group }) -join ',' | Should -Be 'overdue,today,upcoming,someday'
        $tasks[0].number | Should -Be 1
    }

    It 'termine, rouvre, modifie et supprime par numéro' {
        $null = New-DataDir
        $null = Invoke-Tool 'todo' @('add', 'Une')
        $null = Invoke-Tool 'todo' @('add', 'Deux')
        $r = Invoke-Tool 'todo' @('done', '1')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'c.est fait : Une'
        (Invoke-Tool 'todo').Output | Should -Not -Match '\bUne\b'
        (Get-TodoJson | Where-Object { $_.text -eq 'Une' }).done | Should -BeTrue

        $done = Get-TodoJson | Where-Object { $_.text -eq 'Une' }
        (Invoke-Tool 'todo' @('undo', [string]$done.number)).ExitCode | Should -Be 0
        (Get-TodoJson | Where-Object { $_.text -eq 'Une' }).done | Should -BeFalse

        $r = Invoke-Tool 'todo' @('edit', '2', 'Deux bis', '-Due', 'demain', '-Priority', 'haute')
        $r.ExitCode | Should -Be 0
        $t = Get-TodoJson | Where-Object { $_.text -eq 'Deux bis' }
        $t.priority | Should -Be 'high'
        $t.number | Should -Be 1   # avec une échéance, elle passe devant

        (Invoke-Tool 'todo' @('rm', '1', '-DryRun')).ExitCode | Should -Be 0
        @(Get-TodoJson).Count | Should -Be 2
        $r = Invoke-Tool 'todo' @('rm', '1')
        $r.ExitCode | Should -Be 1   # session non interactive sans -Yes
        @(Get-TodoJson).Count | Should -Be 2
        (Invoke-Tool 'todo' @('rm', '1', '-Yes')).ExitCode | Should -Be 0
        @(Get-TodoJson).text | Should -Be @('Une')
    }

    It 'refuse un numéro invalide' {
        $r = Invoke-Tool 'todo' @('done', '42')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Numéro invalide'
    }

    It 'filtre par étiquette' {
        $null = New-DataDir
        $null = Invoke-Tool 'todo' @('add', 'Pain +courses')
        $null = Invoke-Tool 'todo' @('add', 'Vidange +voiture')
        $r = Invoke-Tool 'todo' @('list', '-Tag', 'courses')
        $r.Output | Should -Match 'Pain'
        $r.Output | Should -Not -Match 'Vidange'
        @(Get-TodoJson @('list', '-Tag', 'voiture')).text | Should -Be @('Vidange')
    }

    It 'purge les tâches faites (aperçu, puis -Yes)' {
        $null = New-DataDir
        $null = Invoke-Tool 'todo' @('add', 'Garder')
        $null = Invoke-Tool 'todo' @('add', 'Finie', '-Due', 'today')
        $null = Invoke-Tool 'todo' @('done', '1')
        $r = Invoke-Tool 'todo' @('clear', '-DryRun')
        $r.Output | Should -Match 'À purger : Finie'
        @(Get-TodoJson).Count | Should -Be 2
        (Invoke-Tool 'todo' @('clear', '-Yes')).ExitCode | Should -Be 0
        @(Get-TodoJson).text | Should -Be @('Garder')
    }

    It 'résiste à un fichier corrompu et le met de côté' {
        $dir = New-DataDir
        [IO.File]::WriteAllText((Join-Path $dir 'todo.json'), '{ pas du json')
        $r = Invoke-Tool 'todo'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'illisible'
        $r = Invoke-Tool 'todo' @('add', 'Nouvelle')
        $r.ExitCode | Should -Be 0
        @(Get-ChildItem $dir -Filter 'todo.corrupt-*.json').Count | Should -Be 1
        @(Get-TodoJson).text | Should -Be @('Nouvelle')
    }

    It 'rejette une commande inconnue' {
        $r = Invoke-Tool 'todo' @('bidule')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Commande inconnue'
    }

    It 'parle anglais' {
        $null = New-DataDir
        $env:PSTOOLS_LANG = 'en'
        try {
            $r = Invoke-Tool 'todo' @('add', 'Buy milk', '-Due', 'tomorrow', '-Priority', 'medium')
            $l = Invoke-Tool 'todo'
        }
        finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match 'Task #1 added: Buy milk'
        $l.Output | Should -Match '(?s)Upcoming.*tomorrow'
        $l.Output | Should -Not -Match 'tâche|demain'
    }
}

Describe 'note' {
    BeforeAll { $script:Data = New-DataDir }
    AfterAll { if (Test-Path $Data) { Remove-Item $Data -Recurse -Force } }

    It 'ajoute une note horodatée au fichier Markdown du jour' {
        $r = Invoke-Tool 'note' @('Appeler le plombier')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Note ajoutée'
        $file = Join-Path (Join-Path $Data 'notes') ((Get-Date).ToString('yyyy-MM-dd') + '.md')
        $file | Should -Exist
        $text = [IO.File]::ReadAllText($file)
        $text | Should -Match '^# Notes du '
        $text | Should -Match '(?m)^- \*\*\d{2}:\d{2}\*\* Appeler le plombier$'
    }

    It 'accepte le pipeline (plusieurs lignes)' {
        $file = Join-Path $script:Tools 'note.ps1'
        $out = 'ligne une', 'ligne deux' | & $script:Shell -NoProfile -File $file 2>&1
        $LASTEXITCODE | Should -Be 0
        (@($out) -join "`n") | Should -Match '\+1 ligne'
        $notes = @((Invoke-Tool 'note' @('-Json')).Output | ConvertFrom-Json | ForEach-Object { $_ })
        ($notes | Where-Object { $_.text -match '^ligne une' }).text | Should -Be "ligne une`nligne deux"
    }

    It 'liste les dernières notes, y compris celles écrites à la main' {
        $notes = Join-Path $Data 'notes'
        $day = (Get-Date).Date.AddDays(-1)
        [IO.File]::WriteAllText((Join-Path $notes ($day.ToString('yyyy-MM-dd') + '.md')), "# Hier`n`n- **08:15** Réunion budget`nidée notée à la main`n")
        $r = Invoke-Tool 'note'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '(?s)Aujourd.hui.*Appeler le plombier.*Hier.*08:15\s+Réunion budget.*idée notée à la main'
    }

    It 'cherche dans toutes les notes, sans tenir compte de la casse' {
        $r = Invoke-Tool 'note' @('-Search', 'PLOMBIER')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Appeler le plombier'
        $r.Output | Should -Match '1 note\(s\) trouvée'
        $r.Output | Should -Not -Match 'budget'
        @((Invoke-Tool 'note' @('-Search', 'budget', '-Json')).Output | ConvertFrom-Json).Count | Should -Be 1
        (Invoke-Tool 'note' @('-Search', 'introuvable')).Output | Should -Match 'Aucune note ne contient'
    }

    It 'liste les jours avec le nombre de notes' {
        $days = @((Invoke-Tool 'note' @('-List', '-Json')).Output | ConvertFrom-Json | ForEach-Object { $_ })
        $days.Count | Should -Be 2
        $days[0].date | Should -Be ((Get-Date).ToString('yyyy-MM-dd'))
        $days[0].count | Should -Be 2
        $days[1].count | Should -Be 2
        (Invoke-Tool 'note' @('-List')).Output | Should -Match '4 note\(s\) sur 2 jour'
    }

    It '-Edit hors session interactive affiche le chemin du fichier du jour' {
        $r = Invoke-Tool 'note' @('-Edit')
        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -Match ([regex]::Escape((Get-Date).ToString('yyyy-MM-dd') + '.md') + '$')
    }

    It 'parle anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'note' } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match '(?s)Today.*Yesterday'
        $r.Output | Should -Not -Match 'Aujourd|dernières'
    }
}

Describe 'timer' {
    It 'décompte une durée courte et annonce la fin' {
        $start = Get-Date
        $r = Invoke-Tool 'timer' @('2s', '-Label', 'Thé', '-Quiet')
        $r.ExitCode | Should -Be 0
        ((Get-Date) - $start).TotalSeconds | Should -BeGreaterOrEqual 2
        $r.Output | Should -Match 'Thé'
        $r.Output | Should -Match '00:01'
        $r.Output | Should -Match '100 %'
        $r.Output | Should -Match 'Temps écoulé'
    }

    It 'comprend les formats de durée' {
        # Le parseur est extrait du script (son point d'entrée lancerait le minuteur).
        . (Join-Path (Join-Path (Join-Path $Root 'src') 'lib') 'PsTools.ps1')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Tools 'timer.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertFrom-TimerDuration' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        ConvertFrom-TimerDuration '90s' | Should -Be 90
        ConvertFrom-TimerDuration '25m' | Should -Be 1500
        ConvertFrom-TimerDuration '25' | Should -Be 1500
        ConvertFrom-TimerDuration '1h30' | Should -Be 5400
        ConvertFrom-TimerDuration '2m30s' | Should -Be 150
        ConvertFrom-TimerDuration '1h 5min' | Should -Be 3900
        ConvertFrom-TimerDuration '10:00' | Should -Be 600
        ConvertFrom-TimerDuration '1:00:00' | Should -Be 3600
        { ConvertFrom-TimerDuration 'abc' } | Should -Throw '*Durée non reconnue*'
        { ConvertFrom-TimerDuration '0s' } | Should -Throw
    }

    It 'refuse une durée nulle ou absente' {
        (Invoke-Tool 'timer' @('0s')).ExitCode | Should -Be 1
        $r = Invoke-Tool 'timer'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Précisez une durée'
    }

    It 'enchaîne les phases du Pomodoro' {
        $r = Invoke-Tool 'timer' @('-Pomodoro', '-Rounds', '2', '-Work', '1s', '-Break', '1s', '-LongBreak', '1s', '-Quiet')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '(?s)Travail.*séance 1/2.*Petite pause.*Travail.*séance 2/2.*Cycle terminé : 2 séance'
    }

    It 'chronomètre : un relevé hors session interactive' {
        $r = Invoke-Tool 'timer' @('-Stopwatch')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '00:00\.\d'
        $r.Output | Should -Match 'Temps total'
    }

    It 'parle anglais' {
        $env:PSTOOLS_LANG = 'en'
        try { $r = Invoke-Tool 'timer' @('1s', '-Quiet') } finally { $env:PSTOOLS_LANG = 'fr' }
        $r.Output | Should -Match "Time's up: Timer"
        $r.Output | Should -Not -Match 'Minuteur|écoulé'
    }
}
