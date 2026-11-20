# Tests Pester (v5+) des outils développeur gi, cheat et path.
# Aucun accès réseau : les modèles et fiches sont placés à l'avance dans le cache (-Offline),
# et le registre est remplacé par un fichier JSON (PSTOOLS_PATH_REGISTRY).
# Les tests réseau ne tournent que si PSTOOLS_NETWORK_TESTS est défini.
#   Invoke-Pester ./tests/DevTools.Tests.ps1

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tools = Join-Path (Join-Path $Root 'src') 'tools'
    $script:Shell = (Get-Process -Id $PID).Path
    $env:NO_COLOR = '1'
    $env:PSTOOLS_LANG = 'fr'   # les assertions portent sur les textes français ; l'anglais a ses propres tests
    $env:PSTOOLS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("pst-data-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:PSTOOLS_DATA -Force | Out-Null

    function Invoke-Tool {
        # Lance un outil dans un processus séparé ; retourne @{ Output; ExitCode }.
        param([string]$Name, [string[]]$Arguments = @())
        $file = Join-Path $script:Tools "$Name.ps1"
        # « $null | » ferme l'entrée standard : les outils qui lisent le pipeline n'attendent pas indéfiniment.
        $output = $null | & $script:Shell -NoProfile -File $file @Arguments 2>&1
        return @{ Output = (@($output) -join "`n"); ExitCode = $LASTEXITCODE }
    }

    function Import-ToolFunction {
        # Charge une fonction interne d'un outil (sans exécuter l'outil) pour la tester directement.
        param([string]$Tool, [string[]]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Tools "$Tool.ps1"), [ref]$null, [ref]$null)
        foreach ($n in $Name) {
            $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
            . ([scriptblock]::Create($fn.Extent.Text.Replace("function $n", "function global:$n")))
        }
    }

    function New-TempDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("pst-dev-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function Write-Utf8 {
        param([string]$File, [string]$Text)
        $dir = Split-Path -Parent $File
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($File, $Text, (New-Object Text.UTF8Encoding $false))
    }

    $script:NodeTemplate = @(
        '# Created by https://www.toptal.com/developers/gitignore/api/node'
        '# Edit at https://www.toptal.com/developers/gitignore?templates=node'
        ''
        '### Node ###'
        '# Logs'
        'logs'
        '*.log'
        'npm-debug.log*'
        ''
        '# Dependency directories'
        'node_modules/'
        ''
        '# End of https://www.toptal.com/developers/gitignore/api/node'
    ) -join "`n"
    Write-Utf8 (Join-Path (Join-Path $env:PSTOOLS_DATA 'gitignore') 'list.txt') "go,node,python`npythonvanilla,visualstudio,windows"
    Write-Utf8 (Join-Path (Join-Path (Join-Path $env:PSTOOLS_DATA 'gitignore') 'templates') 'node.gitignore') $script:NodeTemplate

    $script:TarFr = @(
        '# tar'
        ''
        '> Utilitaire d''archivage.'
        '> Plus d''informations : <https://www.gnu.org/software/tar/manual/tar.html>.'
        ''
        '- Crée une archive à partir de fichiers :'
        ''
        '`tar cf {{chemin/vers/cible.tar}} {{chemin/vers/fichier1}}`'
        ''
        '- Extrait une archive dans le répertoire actuel :'
        ''
        '`tar xf {{chemin/vers/source.tar}}`'
    ) -join "`n"
    $script:TarEn = $script:TarFr.Replace('Utilitaire d''archivage.', 'Archiving utility.').Replace('Crée une archive', 'Create an archive')
    $tldr = Join-Path (Join-Path $env:PSTOOLS_DATA 'cheat') 'tldr'
    Write-Utf8 (Join-Path $tldr 'tar.common.fr.md') $script:TarFr
    Write-Utf8 (Join-Path $tldr 'tar.common.en.md') $script:TarEn
    Write-Utf8 (Join-Path (Join-Path (Join-Path $env:PSTOOLS_DATA 'cheat') 'cheatsh') 'curl.txt') "# curl`n# Download a file`ncurl -O https://example.com/file`n"
}

AfterAll {
    if ($env:PSTOOLS_DATA -and (Test-Path $env:PSTOOLS_DATA)) { Remove-Item $env:PSTOOLS_DATA -Recurse -Force }
    Remove-Item Env:PSTOOLS_DATA, Env:PSTOOLS_PATH_REGISTRY, Env:PSTOOLS_TEST_WINDOWS, Env:PST_T_VAR -ErrorAction SilentlyContinue
}

Describe 'Aide des outils développeur' {
    It '<_> -Help répond en français et en anglais' -ForEach @('gitignore', 'cheat', 'paths') {
        $r = Invoke-Tool $_ @('-Help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'UTILISATION'
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-Tool $_ @('-Help') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.ExitCode | Should -Be 0
        $en.Output | Should -Match 'USAGE'
        $en.Output | Should -Not -Match '[éèàù]|UTILISATION'
    }
}

Describe 'gitignore' {
    It 'liste et filtre les modèles depuis le cache' {
        $r = Invoke-Tool 'gitignore' @('-List', 'py', '-Offline')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'pythonvanilla'
        $r.Output | Should -Not -Match '\bnode\b'
        $json = (Invoke-Tool 'gitignore' @('-List', '-Json', '-Offline')).Output | ConvertFrom-Json
        @($json).Count | Should -Be 6
    }

    It 'affiche un modèle et refuse un nom inconnu avec une suggestion' {
        $r = Invoke-Tool 'gitignore' @('node', '-Offline')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'node_modules/'
        $bad = Invoke-Tool 'gitignore' @('nod', '-Offline')
        $bad.ExitCode | Should -Be 1
        $bad.Output | Should -Match 'Modèle inconnu : « nod »'
        $bad.Output | Should -Match 'node'
    }

    It 'fusionne sans dupliquer, conserve le contenu existant et protège en non interactif' {
        $dir = New-TempDir
        $file = Join-Path $dir '.gitignore'
        $original = "mine/`r`n*.log`r`n"
        Write-Utf8 $file $original
        Push-Location $dir
        try {
            (Invoke-Tool 'gitignore' @('node', '-Write', '-Offline')).ExitCode | Should -Be 1      # pas de -Yes
            (Invoke-Tool 'gitignore' @('node', '-DryRun', '-Offline')).ExitCode | Should -Be 0
            [IO.File]::ReadAllText($file) | Should -BeExactly $original
            $r = Invoke-Tool 'gitignore' @('node', '-Write', '-Yes', '-Offline')
            $r.ExitCode | Should -Be 0
            $text = [IO.File]::ReadAllText($file)
            $text.StartsWith($original) | Should -BeTrue
            $lines = @($text -split "`r`n")
            @($lines | Where-Object { $_ -eq '*.log' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -eq 'node_modules/' }).Count | Should -Be 1
            $text | Should -Not -Match 'Created by'
            $text | Should -Not -Match "[^`r]`n"                                            # fins de ligne CRLF conservées
            $again = Invoke-Tool 'gitignore' @('node', '-Write', '-Yes', '-Offline')
            $again.Output | Should -Match 'rien à ajouter'
            [IO.File]::ReadAllText($file) | Should -BeExactly $text
        }
        finally { Pop-Location; Remove-Item $dir -Recurse -Force }
    }

    It 'omet les sections dont toutes les règles existent déjà' {
        Import-ToolFunction 'gitignore' 'Merge-GitIgnoreText'
        $addition = "### A ###`n# a`nx`n`n### B ###`n# only comments`n#`n`n# b`ny`n"
        $m = Merge-GitIgnoreText -Existing "x`n" -Addition $addition -Label 'a, b'
        $m.Rules | Should -Be 1
        $m.Text | Should -Not -Match '### A ###'
        $m.Text | Should -Match '### B ###'
        $m.Text | Should -Match '# only comments'
        $m.Text | Should -Match "(?m)^# gitignore: a, b"
        (Merge-GitIgnoreText -Existing "x`ny`n" -Addition $addition -Label 'a').Rules | Should -Be 0
    }

    It 'suggère des modèles d''après les fichiers du dépôt' {
        $dir = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $dir '.git'), (Join-Path $dir 'api') | Out-Null
        foreach ($f in 'package.json', 'go.mod', 'App.csproj', (Join-Path 'api' 'requirements.txt')) { Write-Utf8 (Join-Path $dir $f) '' }
        Push-Location $dir
        try {
            $r = Invoke-Tool 'gitignore'
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'gitignore node,visualstudio,python,go,\w+ -Write'
            $json = (Invoke-Tool 'gitignore' @('-Json')).Output | ConvertFrom-Json
            @($json | Where-Object { $_.Suggested } | ForEach-Object { $_.Name }) | Should -Contain 'python'
            ($json | Where-Object { $_.Name -eq 'python' }).Reason | Should -Be 'api/requirements.txt'
        }
        finally { Pop-Location; Remove-Item $dir -Recurse -Force }
        $outside = New-TempDir
        Push-Location $outside
        try { (Invoke-Tool 'gitignore').Output | Should -Match 'Pas de dépôt Git' }
        finally { Pop-Location; Remove-Item $outside -Recurse -Force }
    }

    It 'télécharge un vrai modèle' -Skip:(-not $env:PSTOOLS_NETWORK_TESTS) {
        $r = Invoke-Tool 'gitignore' @('python', '-Update')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '__pycache__'
    }
}

Describe 'cheat' {
    It 'affiche une fiche tldr en cache, en français ou en anglais' {
        $r = Invoke-Tool 'cheat' @('tar', '-Offline')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Utilitaire d''archivage'
        $r.Output | Should -Match 'Crée une archive'
        $r.Output | Should -Match 'tar cf \{\{chemin/vers/cible.tar\}\}'
        $r.Output | Should -Match 'gnu.org/software/tar'
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-Tool 'cheat' @('TAR', '-Offline') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.Output | Should -Match 'Archiving utility'
        $en.Output | Should -Not -Match 'Utilitaire'
    }

    It 'produit du JSON exploitable' {
        $json = (Invoke-Tool 'cheat' @('tar', '-Offline', '-Json')).Output | ConvertFrom-Json
        $json.Found | Should -BeTrue
        $json.Language | Should -Be 'fr'
        @($json.Examples).Count | Should -Be 2
        $json.Examples[1].Command | Should -Be 'tar xf {{chemin/vers/source.tar}}'
    }

    It 'analyse le Markdown tldr et colore les paramètres' {
        Import-ToolFunction 'cheat' 'ConvertFrom-TldrMarkdown', 'ConvertTo-PageName'
        $p = ConvertFrom-TldrMarkdown ("# git rebase`n`n> Reapply commits.`n> More information: <https://git-scm.com/docs/git-rebase>.`n`n- Rebase:`n`n``git rebase {{branch}}``")
        $p.Title | Should -Be 'git rebase'
        $p.Description | Should -Be 'Reapply commits.'
        $p.Info | Should -Be 'https://git-scm.com/docs/git-rebase'
        $p.Examples[0].Description | Should -Be 'Rebase:'
        $p.Examples[0].Command | Should -Be 'git rebase {{branch}}'
        ConvertTo-PageName @('git', 'rebase') | Should -Be 'git-rebase'
        ConvertTo-PageName @('Get-ChildItem') | Should -Be 'get-childitem'
    }

    It 'utilise cheat.sh en cache et cherche dans les fiches' {
        $r = Invoke-Tool 'cheat' @('curl', '-Source', 'cheatsh', '-Offline')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'curl -O https://example.com/file'
        $s = Invoke-Tool 'cheat' @('-Search', 'archive')
        $s.ExitCode | Should -Be 0
        $s.Output | Should -Match 'tar'
        $s.Output | Should -Match '1 fiche\(s\) trouvée\(s\)'
        (Invoke-Tool 'cheat' @('-Search', 'introuvablexyz')).Output | Should -Match 'Aucune fiche en cache'
    }

    It 'explique clairement quand rien n''est trouvé' {
        $r = Invoke-Tool 'cheat' @('commandeinconnue', '-Offline')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Aucune fiche en cache pour « commandeinconnue »'
        $r.Output | Should -Match 'ask "comment utiliser commandeinconnue \?"'
    }

    It 'télécharge une vraie fiche tldr' -Skip:(-not $env:PSTOOLS_NETWORK_TESTS) {
        $r = Invoke-Tool 'cheat' @('git', 'rebase', '-Update')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'git rebase'
    }
}

Describe 'paths' {
    BeforeAll {
        $script:Base = New-TempDir
        foreach ($d in 'first', 'a', 'b', 'noexe', 'new') { New-Item -ItemType Directory -Path (Join-Path $Base $d) | Out-Null }
        foreach ($f in (Join-Path 'a' 'tool.exe'), (Join-Path 'b' 'tool.cmd'), (Join-Path 'noexe' 'readme.txt')) { Write-Utf8 (Join-Path $Base $f) '' }
        $script:A = Join-Path $Base 'a'; $script:B = Join-Path $Base 'b'; $script:Missing = Join-Path $Base 'missing'
        $script:Store = Join-Path $Base 'registry.json'
        $env:PST_T_VAR = $Base
        $script:VarA = '%PST_T_VAR%' + [IO.Path]::DirectorySeparatorChar + 'a'

        function Set-Store {
            param([string]$User, [string]$Machine)
            Write-Utf8 $script:Store (ConvertTo-Json -InputObject @{ User = $User; Machine = $Machine })
        }
        function Get-Store { return (Get-Content $script:Store -Raw | ConvertFrom-Json) }
        function Invoke-PathTool {
            # Mode Windows simulé : registre dans un fichier, PATH de session séparé par « ; ».
            param([string[]]$Arguments = @(), [string[]]$Session = @())
            $saved = $env:PATH
            $env:PSTOOLS_TEST_WINDOWS = '1'; $env:PSTOOLS_PATH_REGISTRY = $script:Store
            if ($Session.Count) { $env:PATH = (@((Join-Path $script:Base 'first')) + $Session) -join ';' }
            try { return (Invoke-Tool 'paths' $Arguments) }
            finally { $env:PATH = $saved; Remove-Item Env:PSTOOLS_TEST_WINDOWS, Env:PSTOOLS_PATH_REGISTRY -ErrorAction SilentlyContinue }
        }
    }
    AfterAll { Remove-Item $script:Base -Recurse -Force -ErrorAction SilentlyContinue }

    It 'décrit chaque entrée : portée, doublon, dossier introuvable, sans exécutable, pas encore actif' {
        Set-Store -User "$($script:VarA);$($script:Missing);$(Join-Path $Base 'new')" -Machine $script:B
        $r = Invoke-PathTool @('-Json') @($script:B, $script:A, $script:Missing, $script:A, (Join-Path $Base 'noexe'))
        $r.ExitCode | Should -Be 0
        $entries = @($r.Output | ConvertFrom-Json)
        $byPath = @{}
        foreach ($e in $entries) { if (-not $byPath.ContainsKey($e.Path)) { $byPath[$e.Path] = $e } }
        $byPath[$script:B].Scope | Should -Be 'Machine'
        $byPath[$script:A].Scope | Should -Be 'User'
        $byPath[$script:A].Status | Should -Be 'ok'
        $byPath[$script:Missing].Status | Should -Be 'missing'
        $byPath[(Join-Path $Base 'noexe')].Status | Should -Be 'noexe'
        $byPath[(Join-Path $Base 'noexe')].Scope | Should -Be 'Session'
        @($entries | Where-Object { $_.Status -eq 'duplicate' }).Count | Should -Be 1
        $pending = @($entries | Where-Object { -not $_.Active })
        $pending.Count | Should -Be 1
        $pending[0].Path | Should -Be (Join-Path $Base 'new')
        $text = (Invoke-PathTool @() @($script:A, $script:Missing, $script:A)).Output
        $text | Should -Match 'introuvable'
        $text | Should -Match 'doublon de n°'
        $text | Should -Match 'paths clean -DryRun'
    }

    It 'which indique la copie qui l''emporte et celles masquées' {
        Set-Store -User '' -Machine ''
        $r = Invoke-PathTool @('which', 'tool', '-Json') @($script:B, $script:A)
        $r.ExitCode | Should -Be 0
        $w = $r.Output | ConvertFrom-Json
        $w.Winner.File | Should -Be (Join-Path $script:B 'tool.cmd')
        @($w.Shadowed).Count | Should -Be 1
        $w.Shadowed[0].File | Should -Be (Join-Path $script:A 'tool.exe')
        $none = Invoke-PathTool @('which', 'absentxyz') @($script:A)
        $none.ExitCode | Should -Be 1
        $none.Output | Should -Match 'introuvable dans le PATH'
    }

    It 'add ajoute en fin ou en tête en conservant les %VARIABLES% et refuse les doublons' {
        Set-Store -User "$($script:VarA);C:\Keep Me" -Machine $script:B
        $r = Invoke-PathTool @('add', (Join-Path $Base 'new'))
        $r.ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly "$($script:VarA);C:\Keep Me;$(Join-Path $Base 'new')"
        (Invoke-PathTool @('add', $script:B)).Output | Should -Match 'Déjà présent dans le PATH Machine'
        (Invoke-PathTool @('add', $script:A)).Output | Should -Match 'Déjà présent dans le PATH Utilisateur'
        $first = Join-Path $Base 'first'
        (Invoke-PathTool @('add', $first, '-First', '-DryRun')).ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly "$($script:VarA);C:\Keep Me;$(Join-Path $Base 'new')"
        (Invoke-PathTool @('add', $first, '-First')).ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly "$first;$($script:VarA);C:\Keep Me;$(Join-Path $Base 'new')"
        $ghost = Join-Path $Base 'ghost'
        (Invoke-PathTool @('add', $ghost)).ExitCode | Should -Be 1                                  # dossier absent, pas de -Yes
        (Get-Store).User | Should -Not -Match 'ghost'
        (Invoke-PathTool @('add', $ghost, '-Yes')).ExitCode | Should -Be 0
        (Get-Store).User | Should -Match 'ghost$'
    }

    It 'refuse proprement le PATH Machine sans droits administrateur' -Skip:($IsWindows -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Set-Store -User '' -Machine $script:B
        $r = Invoke-PathTool @('add', $script:A, '-Machine')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'terminal administrateur'
        (Get-Store).Machine | Should -BeExactly $script:B
    }

    It 'rm retire une entrée désignée sous sa forme développée et garde le reste intact' {
        Set-Store -User "C:\Keep Me;$($script:VarA);;C:\Other" -Machine $script:B
        (Invoke-PathTool @('rm', $script:A)).ExitCode | Should -Be 1                                # pas de -Yes
        (Invoke-PathTool @('rm', $script:A, '-DryRun')).ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly "C:\Keep Me;$($script:VarA);;C:\Other"
        (Invoke-PathTool @('rm', $script:A, '-Yes')).ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly 'C:\Keep Me;;C:\Other'
        $r = Invoke-PathTool @('rm', $script:B, '-Yes')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'ajoutez -Machine'
    }

    It 'clean retire introuvables, doublons et vides du PATH Utilisateur après confirmation' {
        $user = "$($script:VarA);$($script:Missing);;$($script:B);$($script:A)$([IO.Path]::DirectorySeparatorChar);%PST_UNDEFINED_VAR%\x"
        Set-Store -User $user -Machine $script:B
        $dry = Invoke-PathTool @('clean', '-DryRun')
        $dry.ExitCode | Should -Be 0
        $dry.Output | Should -Match 'dossier introuvable'
        $dry.Output | Should -Match 'déjà dans le PATH Machine'
        $dry.Output | Should -Match 'variable inconnue'
        (Invoke-PathTool @('clean')).ExitCode | Should -Be 1                                        # non interactif sans -Yes
        (Get-Store).User | Should -BeExactly $user
        (Invoke-PathTool @('clean', '-Yes')).ExitCode | Should -Be 0
        (Get-Store).User | Should -BeExactly "$($script:VarA);%PST_UNDEFINED_VAR%\x"
        (Get-Store).Machine | Should -BeExactly $script:B
        (Get-Content (Join-Path $env:PSTOOLS_DATA 'path-backup.log') -Raw) | Should -Match ([regex]::Escape($user))
        (Invoke-PathTool @('clean')).Output | Should -Match 'déjà propre'
        $env:PSTOOLS_LANG = 'en'
        try { $en = Invoke-PathTool @('clean') } finally { $env:PSTOOLS_LANG = 'fr' }
        $en.Output | Should -Match 'User PATH already clean'
    }

    It 'hors Windows, liste $env:PATH en lecture seule' -Skip:($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
        $saved = $env:PATH
        $env:PATH = (@($script:A, $script:Missing, $script:A, $saved) -join [IO.Path]::PathSeparator)
        try { $r = Invoke-Tool 'paths'; $add = Invoke-Tool 'paths' @('add', $script:B) }
        finally { $env:PATH = $saved }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'introuvable'
        $r.Output | Should -Match 'lecture seule'
        $add.ExitCode | Should -Be 1
        $add.Output | Should -Match 'lecture seule'
    }
}
