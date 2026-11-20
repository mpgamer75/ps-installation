# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — intégration au shell (chargée depuis le profil PowerShell)
#
#  Activation :  pst shell on        Désactivation :  pst shell off
#
#  Apporte : une invite informative, un historique plus malin, des raccourcis
#  clavier, des commandes façon Unix et des favoris de dossiers.
#  Règle d'or : ne jamais écraser ce que l'utilisateur a déjà (invite
#  personnalisée, alias ou commandes existants). Réglages : « pst setup »,
#  ou ces variables, prioritaires :
#    PSTOOLS_NO_PROMPT=1   garder l'invite actuelle
#    PSTOOLS_NO_ALIASES=1  ne pas définir les commandes façon Unix
#    PSTOOLS_NO_KEYS=1     ne pas toucher aux raccourcis clavier
# ─────────────────────────────────────────────────────────────────────────────

if ($Host.Name -ne 'ConsoleHost' -and $Host.Name -ne 'Visual Studio Code Host') { return }

$global:PstShell = @{
    Root    = Split-Path -Parent $PSScriptRoot
    Esc     = [string][char]27
    Ansi    = [bool]$Host.UI.SupportsVirtualTerminal -and -not $env:NO_COLOR
    IsAdmin = $false
    DataDir = $null
}
try {
    if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) {
        $global:PstShell.IsAdmin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}
catch { $null = $_ }
if ($env:PSTOOLS_DATA) { $global:PstShell.DataDir = $env:PSTOOLS_DATA }
elseif ($env:LOCALAPPDATA) { $global:PstShell.DataDir = Join-Path (Join-Path $env:LOCALAPPDATA 'ps-tools') 'data' }
else { $global:PstShell.DataDir = Join-Path (Join-Path (Join-Path $HOME '.local') 'share') 'ps-tools' }

# Réglages choisis dans l'assistant (pst setup) ; les variables PSTOOLS_NO_* restent prioritaires.
$pstSettings = @{ theme = 'nuit'; prompt = $true; keys = $true; aliases = $true }
try {
    $pstConfigFile = Join-Path $global:PstShell.DataDir 'config.json'
    if (Test-Path -LiteralPath $pstConfigFile) {
        $pstConfig = [IO.File]::ReadAllText($pstConfigFile) | ConvertFrom-Json
        if ($pstConfig.theme) { $pstSettings.theme = [string]$pstConfig.theme }
        if ($pstConfig.shell) {
            foreach ($name in 'prompt', 'keys', 'aliases') { if ($null -ne $pstConfig.shell.$name) { $pstSettings[$name] = [bool]$pstConfig.shell.$name } }
        }
    }
}
catch { $null = $_ }
if ($env:PSTOOLS_THEME) { $pstSettings.theme = $env:PSTOOLS_THEME }
if ($env:PSTOOLS_NO_PROMPT) { $pstSettings.prompt = $false }
if ($env:PSTOOLS_NO_KEYS) { $pstSettings.keys = $false }
if ($env:PSTOOLS_NO_ALIASES) { $pstSettings.aliases = $false }

# Couleurs de l'invite selon le thème (mêmes palettes que les outils).
$pstPalettes = @{
    nuit  = @{ Path = @(86, 182, 255); Git = @(178, 132, 255); Ok = @(80, 220, 140); Err = @(255, 95, 110); Dim = @(125, 133, 150); Admin = @(255, 190, 80) }
    ocean = @{ Path = @(64, 200, 224); Git = @(96, 140, 255); Ok = @(70, 220, 170); Err = @(255, 100, 120); Dim = @(120, 140, 160); Admin = @(255, 200, 90) }
    ambre = @{ Path = @(255, 176, 59); Git = @(255, 122, 89); Ok = @(170, 220, 110); Err = @(255, 92, 82); Dim = @(150, 140, 125); Admin = @(255, 214, 102) }
    clair = @{ Path = @(0, 105, 190); Git = @(125, 60, 200); Ok = @(0, 135, 70); Err = @(200, 35, 55); Dim = @(105, 112, 128); Admin = @(175, 100, 0) }
    mono  = @{ Path = @(215, 215, 215); Git = @(175, 175, 175); Ok = @(200, 200, 200); Err = @(255, 255, 255); Dim = @(120, 120, 120); Admin = @(235, 235, 235) }
}
$global:PstShell.Colors = $pstPalettes[$pstSettings.theme]
if (-not $global:PstShell.Colors) { $global:PstShell.Colors = $pstPalettes.nuit }

function global:Test-PstFree {
    # Vrai si aucun alias, fonction ou programme ne porte déjà ce nom.
    param([string]$Name)
    return -not (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

# ── Invite ───────────────────────────────────────────────────────────────────

function global:Get-PstGitBranch {
    # Lit .git/HEAD en remontant l'arborescence : instantané, sans lancer git.
    $dir = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    for ($i = 0; $i -lt 40 -and $dir; $i++) {
        $git = Join-Path $dir '.git'
        if (Test-Path -LiteralPath $git) {
            try {
                if (Test-Path -LiteralPath $git -PathType Leaf) {
                    # Arbre de travail secondaire ou sous-module : « gitdir: <chemin> »
                    $pointer = (Get-Content -LiteralPath $git -TotalCount 1) -replace '^gitdir:\s*', ''
                    if (-not [IO.Path]::IsPathRooted($pointer)) { $pointer = Join-Path $dir $pointer }
                    $git = $pointer
                }
                $head = Get-Content -LiteralPath (Join-Path $git 'HEAD') -TotalCount 1 -ErrorAction Stop
                if ($head -match '^ref: refs/heads/(.+)$') { return $Matches[1] }
                if ($head.Length -ge 7) { return $head.Substring(0, 7) }
            }
            catch { $null = $_ }
            return $null
        }
        $dir = [IO.Path]::GetDirectoryName($dir)      # $null une fois la racine atteinte
    }
    return $null
}

function global:Get-PstPromptText {
    # Construit l'invite ; séparé de « prompt » pour pouvoir être testé.
    param([bool]$Success = $true, [int]$ExitCode = 0)
    $s = $global:PstShell
    $e = $s.Esc
    $paint = {
        param([string]$Text, [int[]]$Rgb, [switch]$Bold)
        if (-not $s.Ansi) { return $Text }
        # Attention : les noms de variables ignorent la casse ($bold serait le paramètre $Bold).
        $weight = ''
        if ($Bold) { $weight = '1;' }
        return "$e[${weight}38;2;$($Rgb[0]);$($Rgb[1]);$($Rgb[2])m$Text$e[0m"
    }

    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    $path = $location.Path
    if ($HOME -and $path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { $path = '~' + $path.Substring($HOME.Length) }
    $parts = @($path -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -gt 4) {
        # Chemin long : on garde le début et les deux derniers dossiers.
        $lead = ''
        if ($path.StartsWith('/')) { $lead = '/' }
        $path = $lead + $parts[0] + [IO.Path]::DirectorySeparatorChar + '…' + [IO.Path]::DirectorySeparatorChar + ($parts[($parts.Count - 2)..($parts.Count - 1)] -join [IO.Path]::DirectorySeparatorChar)
    }

    $line = ''
    if ($s.IsAdmin) { $line += (& $paint 'admin' $s.Colors.Admin -Bold) + ' ' }
    $line += & $paint $path $s.Colors.Path -Bold

    $branch = Get-PstGitBranch
    if ($branch) { $line += ' ' + (& $paint "git:$branch" $s.Colors.Git) }

    # Durée de la dernière commande, si elle a pris un moment.
    $last = Get-History -Count 1
    if ($last -and $last.Id -ne $s.LastId) {
        $s.LastId = $last.Id
        $took = ($last.EndExecutionTime - $last.StartExecutionTime).TotalSeconds
        if ($took -ge 2) {
            if ($took -ge 60) { $label = '{0}m {1:00}s' -f [int][Math]::Floor($took / 60), [int]($took % 60) }
            else { $label = '{0:N1}s' -f $took }
            $line += ' ' + (& $paint $label $s.Colors.Dim)
        }
        if (-not $Success) {
            $code = ''
            if ($ExitCode -ne 0) { $code = " $ExitCode" }
            $line += ' ' + (& $paint "×$code" $s.Colors.Err -Bold)
        }
    }

    $mark = '>'
    $color = $s.Colors.Ok
    if (-not $Success) { $color = $s.Colors.Err }
    $osc = ''
    if ($s.Ansi -and $location.Provider.Name -eq 'FileSystem') {
        # Indique le dossier courant au terminal : un nouvel onglet ou volet s'ouvre au même endroit.
        $osc = "$e]9;9;`"$($location.ProviderPath)`"$e\"
    }
    return "$osc`n$line`n" + (& $paint $mark $color -Bold) + ' '
}

$pstDefaultPrompt = $false
try { $pstDefaultPrompt = ((Get-Command prompt -ErrorAction Stop).Definition -match 'PS \$\(\$executionContext\.SessionState\.Path\.CurrentLocation\)') } catch { $pstDefaultPrompt = $true }
if ($pstSettings.prompt -and $pstDefaultPrompt) {
    function global:prompt {
        $ok = $?
        $code = $global:LASTEXITCODE
        $text = Get-PstPromptText -Success $ok -ExitCode ([int]$code)
        try { $Host.UI.RawUI.WindowTitle = (Split-Path -Leaf $ExecutionContext.SessionState.Path.CurrentLocation.Path) } catch { $null = $_ }
        $global:LASTEXITCODE = $code
        return $text
    }
}

# ── Historique et raccourcis clavier (PSReadLine) ────────────────────────────

if ($pstSettings.keys -and (Get-Module -Name PSReadLine)) {
    try {
        Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd -BellStyle None -MaximumHistoryCount 10000
        # Flèches : parcourt l'historique en filtrant sur ce qui est déjà tapé.
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
        Set-PSReadLineKeyHandler -Key 'Ctrl+d' -Function DeleteCharOrExit
        # Ne garde pas dans l'historique les lignes qui contiennent visiblement un secret.
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$line)
            return ($line -notmatch '(?i)(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*\S')
        }
    }
    catch { $null = $_ }
    try {
        # Suggestions tirées de l'historique (PSReadLine 2.2+, livré avec PowerShell 7.2+).
        if ((Get-Module PSReadLine).Version -ge [Version]'2.2.0' -and $global:PstShell.Ansi) {
            Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ListView
        }
    }
    catch { $null = $_ }

    try {
        # Alt+A : transforme la phrase tapée en commande, grâce à « ask ».
        Set-PSReadLineKeyHandler -Key 'Alt+a' -BriefDescription 'PstAsk' -Description 'ps-tools : transformer la ligne en commande (IA)' -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            $tool = Join-Path (Join-Path $global:PstShell.Root 'tools') 'ask.ps1'
            $result = $null
            try { $result = (& $tool -Cmd -Raw $line 6>$null | Select-Object -Last 1) } catch { $result = $null }
            if ($LASTEXITCODE -eq 0 -and $result) {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert(([string]$result).TrimStart('#').Trim())
            }
            else { [Microsoft.PowerShell.PSConsoleReadLine]::Ding() }
        }
        # Alt+S : préfixe la ligne par « sudo » (ou la dernière commande si la ligne est vide).
        Set-PSReadLineKeyHandler -Key 'Alt+s' -BriefDescription 'PstSudo' -Description 'ps-tools : relancer en administrateur' -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ([string]::IsNullOrWhiteSpace($line)) {
                $previous = Get-History -Count 1
                if ($previous) { [Microsoft.PowerShell.PSConsoleReadLine]::Insert('sudo ' + $previous.CommandLine) }
            }
            elseif ($line -notmatch '^\s*sudo\b') {
                [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition(0)
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert('sudo ')
                [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 5)
            }
        }
        # Alt+C : copie la ligne en cours dans le presse-papiers.
        Set-PSReadLineKeyHandler -Key 'Alt+c' -BriefDescription 'PstCopy' -Description 'ps-tools : copier la ligne' -ScriptBlock {
            $line = $null; $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            if ($line) { try { Set-Clipboard -Value $line } catch { $null = $_ } }
        }
        # Alt+G : état Git du dossier courant, sans perdre la ligne en cours.
        Set-PSReadLineKeyHandler -Key 'Alt+g' -BriefDescription 'PstGit' -Description 'ps-tools : état Git (gst)' -ScriptBlock {
            [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert('gst')
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    }
    catch { $null = $_ }
}

# ── Commandes façon Unix ─────────────────────────────────────────────────────
# Définies seulement si le nom est libre : Git pour Windows, WSL ou vos propres
# alias gardent toujours la priorité.

if ($pstSettings.aliases) {
    if (Test-PstFree 'll') { function global:ll { Get-ChildItem -Force @args } }
    if (Test-PstFree 'la') { function global:la { Get-ChildItem -Force -Name @args } }
    if (Test-PstFree '..') { function global:.. { Set-Location .. } }
    if (Test-PstFree '...') { function global:... { Set-Location ../.. } }
    if (Test-PstFree '....') { function global:.... { Set-Location ../../.. } }

    if (Test-PstFree 'mkcd') {
        function global:mkcd {
            param([Parameter(Mandatory = $true)][string]$Path)
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Set-Location -LiteralPath $Path
        }
    }
    if (Test-PstFree 'touch') {
        function global:touch {
            # Crée le fichier s'il manque, sinon met à jour sa date de modification.
            foreach ($file in $args) {
                if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).LastWriteTime = Get-Date }
                else { New-Item -ItemType File -Path $file | Out-Null }
            }
        }
    }
    if (Test-PstFree 'which') {
        function global:which {
            param([Parameter(Mandatory = $true)][string]$Name)
            foreach ($c in @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)) {
                switch ($c.CommandType) {
                    'Alias' { "$($c.Name) -> $($c.Definition)  (alias)" }
                    'Function' { "$($c.Name)  (fonction)" }
                    'Cmdlet' { "$($c.Name)  (cmdlet, $($c.Source))" }
                    default { $c.Source }
                }
            }
        }
    }
    if (Test-PstFree 'grep') {
        function global:grep {
            # grep <motif> [fichiers...]   ou   <commande> | grep <motif>
            param([Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
                [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Path,
                [Parameter(ValueFromPipeline = $true)]$InputObject)
            begin { $buffer = New-Object System.Collections.ArrayList }
            process { if ($null -ne $InputObject) { [void]$buffer.Add($InputObject) } }
            end {
                if ($Path) { Select-String -Pattern $Pattern -Path $Path }
                else { $buffer | Out-String -Stream | Select-String -Pattern $Pattern }
            }
        }
    }
    if (Test-PstFree 'head') {
        function global:head {
            param([Parameter(Position = 0)][string]$Path, [Alias('n')][int]$Lines = 10, [Parameter(ValueFromPipeline = $true)]$InputObject)
            begin { $buffer = New-Object System.Collections.ArrayList }
            process { if ($null -ne $InputObject) { [void]$buffer.Add($InputObject) } }
            end { if ($Path) { Get-Content -LiteralPath $Path -TotalCount $Lines } else { $buffer | Select-Object -First $Lines } }
        }
    }
    if (Test-PstFree 'tail') {
        function global:tail {
            param([Parameter(Position = 0)][string]$Path, [Alias('n')][int]$Lines = 10, [Alias('f')][switch]$Follow, [Parameter(ValueFromPipeline = $true)]$InputObject)
            begin { $buffer = New-Object System.Collections.ArrayList }
            process { if ($null -ne $InputObject) { [void]$buffer.Add($InputObject) } }
            end {
                if ($Path -and $Follow) { Get-Content -LiteralPath $Path -Tail $Lines -Wait }
                elseif ($Path) { Get-Content -LiteralPath $Path -Tail $Lines }
                else { $buffer | Select-Object -Last $Lines }
            }
        }
    }
    if (Test-PstFree 'df') {
        function global:df {
            Write-Host ('  {0,-8} {1,10} {2,10} {3,10} {4,6}' -f 'Lecteur', 'Taille', 'Utilisé', 'Libre', 'Util.')
            foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used -and ($_.Used + $_.Free) -gt 0 })) {
                $total = $d.Used + $d.Free
                Write-Host ('  {0,-8} {1,7:N1} Go {2,7:N1} Go {3,7:N1} Go {4,5:N0}%' -f $d.Name, ($total / 1GB), ($d.Used / 1GB), ($d.Free / 1GB), ($d.Used / $total * 100))
            }
        }
    }
    if (Test-PstFree 'open') {
        function global:open {
            # Ouvre un fichier, un dossier ou une adresse avec l'application par défaut.
            param([string]$Target = '.')
            if ($Target -match '^[a-z][a-z0-9+.-]*://') { Start-Process $Target } else { Invoke-Item -Path $Target }
        }
    }
    if (Test-PstFree 'sudo') {
        function global:sudo {
            # Exécute une commande dans une fenêtre administrateur (invite UAC), dans le même dossier.
            if (-not $args) { Write-Host '  Utilisation : sudo <commande>'; return }
            $shell = (Get-Process -Id $PID).Path
            $command = "Set-Location -LiteralPath '$((Get-Location).ProviderPath -replace "'", "''")'; $($args -join ' ')"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            try { Start-Process -FilePath $shell -Verb RunAs -ArgumentList '-NoExit', '-NoLogo', '-EncodedCommand', $encoded }
            catch { Write-Host "  Élévation annulée : $($_.Exception.Message)" }
        }
    }
    if (Test-PstFree 'reload') {
        function global:reload {
            # Relit le PATH du système (utile après une installation) puis le profil.
            $paths = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }
            if ($paths) { $env:PATH = ($paths -join ';') }
            if (Test-Path -LiteralPath $PROFILE.CurrentUserAllHosts) { . $PROFILE.CurrentUserAllHosts }
            Write-Host '  Environnement rechargé.'
        }
    }
}

# ── Favoris de dossiers ──────────────────────────────────────────────────────
#   mark [nom]   enregistre le dossier courant        jump <nom> (ou j)   y retourne
#   marks        liste les favoris                    unmark <nom>        en retire un
#   jump -       revient au dossier précédent

function global:Get-PstMarks {
    $file = Join-Path $global:PstShell.DataDir 'marks.json'
    $marks = @{}
    if (Test-Path -LiteralPath $file) {
        try {
            $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $data.PSObject.Properties) { $marks[$p.Name] = [string]$p.Value }
        }
        catch { $null = $_ }
    }
    return $marks
}

function global:Save-PstMarks {
    param([hashtable]$Marks)
    $dir = $global:PstShell.DataDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ordered = [ordered]@{}
    foreach ($k in ($Marks.Keys | Sort-Object)) { $ordered[$k] = $Marks[$k] }
    [IO.File]::WriteAllText((Join-Path $dir 'marks.json'), ($ordered | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

if (Test-PstFree 'mark') {
    function global:mark {
        param([string]$Name)
        $here = (Get-Location).ProviderPath
        if (-not $Name) { $Name = (Split-Path -Leaf $here).ToLower() -replace '[^a-z0-9_-]', '' }
        if (-not $Name) { Write-Host '  Donnez un nom au favori : mark <nom>'; return }
        $marks = Get-PstMarks
        $marks[$Name] = $here
        Save-PstMarks $marks
        Write-Host "  Favori « $Name » -> $here"
    }
}
if (Test-PstFree 'unmark') {
    function global:unmark {
        param([Parameter(Mandatory = $true)][string]$Name)
        $marks = Get-PstMarks
        if ($marks.ContainsKey($Name)) { $marks.Remove($Name); Save-PstMarks $marks; Write-Host "  Favori « $Name » retiré." }
        else { Write-Host "  Aucun favori « $Name »." }
    }
}
if (Test-PstFree 'marks') {
    function global:marks {
        $marks = Get-PstMarks
        if ($marks.Count -eq 0) { Write-Host '  Aucun favori. Dans un dossier : mark <nom>, puis jump <nom> depuis n''importe où.'; return }
        $width = 0
        foreach ($k in $marks.Keys) { $width = [Math]::Max($width, $k.Length) }
        foreach ($k in ($marks.Keys | Sort-Object)) { Write-Host ('  ' + $k.PadRight($width) + '  ' + $marks[$k]) }
    }
}
if (Test-PstFree 'jump') {
    function global:jump {
        param([string]$Name)
        if (-not $Name) { marks; return }
        if ($Name -eq '-') {
            if ($global:PstShell.Previous) { $target = $global:PstShell.Previous } else { Write-Host '  Pas de dossier précédent.'; return }
        }
        else {
            $marks = Get-PstMarks
            $target = $marks[$Name]
            if (-not $target) {
                # Tolérant : accepte un début de nom s'il est sans ambiguïté.
                $candidates = @($marks.Keys | Where-Object { $_ -like "$Name*" })
                if ($candidates.Count -eq 1) { $target = $marks[$candidates[0]] }
            }
            if (-not $target) { Write-Host "  Aucun favori « $Name ». Liste : marks"; return }
        }
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { Write-Host "  Le dossier n'existe plus : $target"; return }
        $global:PstShell.Previous = (Get-Location).ProviderPath
        Set-Location -LiteralPath $target
    }
    try {
        Register-ArgumentCompleter -CommandName jump, j, unmark -ParameterName Name -ScriptBlock {
            param($commandName, $parameterName, $wordToComplete)
            (Get-PstMarks).Keys | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object | ForEach-Object { $_ }
        }
    }
    catch { $null = $_ }
    if (Test-PstFree 'j') { Set-Alias -Name j -Value jump -Scope Global }
}

# ── Assistant ────────────────────────────────────────────────────────────────

if (Test-PstFree 'fix') {
    function global:fix {
        # Explique la dernière erreur et propose une correction, grâce à « ask ».
        $failure = $global:Error | Select-Object -First 1
        $previous = Get-History -Count 1
        if (-not $failure -and -not $previous) { Write-Host '  Rien à analyser : aucune commande ni erreur récente.'; return }
        $report = @()
        if ($previous) { $report += "Commande : $($previous.CommandLine)" }
        if ($failure) {
            $report += "Erreur : $($failure.ToString())"
            if ($failure.InvocationInfo -and $failure.InvocationInfo.PositionMessage) { $report += $failure.InvocationInfo.PositionMessage }
        }
        if ($global:LASTEXITCODE) { $report += "Code de sortie : $global:LASTEXITCODE" }
        $tool = Join-Path (Join-Path $global:PstShell.Root 'tools') 'ask.ps1'
        $report | & $tool 'Explique pourquoi cette commande a échoué et donne la commande corrigée.'
    }
}

Remove-Variable pstSettings, pstPalettes, pstConfig, pstConfigFile, pstDefaultPrompt -ErrorAction SilentlyContinue
