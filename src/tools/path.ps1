<#
.SYNOPSIS
    path — inspecte et répare la variable d'environnement PATH.
.DESCRIPTION
    Liste chaque dossier du PATH avec sa portée (Machine, Utilisateur ou session seule),
    son état (introuvable, doublon, sans exécutable) et son ordre ; indique quel
    programme l'emporte (« path which ») ; ajoute, retire ou nettoie des entrées.
    Les modifications portent sur le registre (HKCU\Environment, ou HKLM pour -Machine,
    qui exige un terminal administrateur) en conservant les %VARIABLES% telles quelles,
    puis Windows est prévenu du changement. Aucun accès réseau.
    Hors Windows, la liste de $env:PATH reste disponible en lecture seule.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Value,
    [switch]$Machine,
    [switch]$First,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'path'

if ($Help -or (Test-PstHelpArg (@($Command, $Value) + @($Rest)))) {
    Show-PstHelp -Name 'path' -Synopsis (L 'Inspecte et répare le PATH : portée, doublons, dossiers disparus.') `
        -Usage @(
            (L 'path                          chaque entrée, sa portée et son état'),
            (L 'path which <programme>        quelle copie l''emporte, et celles masquées'),
            (L 'path add <dossier> [-Machine] ajoute un dossier (fin du PATH, ou -First)'),
            (L 'path rm <dossier> [-Machine]  retire un dossier'),
            (L 'path clean [-DryRun] [-Yes]   retire les entrées disparues et les doublons')
        ) `
        -Options @(
            @('-Machine', (L 'Agit sur le PATH de tous les utilisateurs (terminal administrateur requis)')),
            @('-First', (L 'Avec « add » : place le dossier en tête, avant les autres')),
            @('-DryRun', (L 'Montre ce qui changerait, sans rien modifier')),
            @('-Yes', (L 'Ne demande pas de confirmation')),
            @('-Json', (L 'Sortie JSON (liste ou « which »), pour les scripts'))
        ) `
        -Examples @('path', 'path which python', 'path add C:\Tools\bin', 'path rm C:\Old\bin', 'path clean -DryRun') `
        -Notes @(
            (L 'Sans -Machine, seul le PATH Utilisateur est modifié : aucun droit administrateur requis.'),
            (L 'Les %VARIABLES% (ex. %USERPROFILE%) sont conservées telles quelles ; ancienne valeur sauvegardée dans le dossier de données.'),
            (L 'Un changement s''applique aux terminaux ouverts ensuite.')
        )
    exit 0
}

$isWin = [bool]$script:Pst.IsWindows
$sep = [string][IO.Path]::PathSeparator
if ($isWin) { $sep = ';' }
$g = $script:Pst.Glyph
# PSTOOLS_PATH_REGISTRY : réservé aux tests, fichier JSON { User; Machine } à la place du registre.
$testStore = $env:PSTOOLS_PATH_REGISTRY
$script:Code = 0

# ── Registre ─────────────────────────────────────────────────────────────────

function Get-PathKey {
    param([string]$Target, [switch]$Writable)
    if ($Target -eq 'Machine') {
        return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', [bool]$Writable)
    }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', [bool]$Writable)
}

function Get-StoredPath {
    # Valeur brute (les %VARIABLES% ne sont pas développées).
    param([string]$Target)
    if ($testStore) {
        $data = Read-PstJsonFile $testStore
        if ($data -is [hashtable] -and $null -ne $data[$Target]) { return [string]$data[$Target] }
        return ''
    }
    if (-not $isWin) { return '' }
    $key = $null
    try {
        $key = Get-PathKey -Target $Target
        if ($null -eq $key) { return '' }
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    catch { return '' }
    finally { if ($key) { $key.Close() } }
}

function Set-StoredPath {
    # Écrit la valeur en REG_EXPAND_SZ (comme setup.ps1), sauvegarde l'ancienne, puis prévient Windows.
    param([string]$Target, [string]$NewValue)
    $old = Get-StoredPath $Target
    $backup = Join-Path (Get-PstDataDir) 'path-backup.log'
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [IO.File]::AppendAllText($backup, "$stamp`t$Target`t$old`n", (New-Object Text.UTF8Encoding $false))
    if ($testStore) {
        $data = Read-PstJsonFile $testStore
        if ($data -isnot [hashtable]) { $data = @{} }
        $data[$Target] = $NewValue
        Write-PstJsonFile $testStore $data
        return $backup
    }
    $key = Get-PathKey -Target $Target -Writable
    if ($null -eq $key) { throw (L 'Clé de registre inaccessible.') }
    try { $key.SetValue('Path', $NewValue, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
    # Écrire une variable via .NET diffuse WM_SETTINGCHANGE : les nouveaux terminaux voient le PATH.
    try {
        [Environment]::SetEnvironmentVariable('PSTOOLS_PATH_SYNC', [string](Get-Date).Ticks, 'User')
        [Environment]::SetEnvironmentVariable('PSTOOLS_PATH_SYNC', $null, 'User')
    }
    catch { $null = $_ }
    return $backup
}

# ── Analyse ──────────────────────────────────────────────────────────────────

function Split-PathValue {
    param([AllowEmptyString()][string]$Text)
    return @($Text -split [regex]::Escape($sep) | Where-Object { $_ -and $_.Trim() })
}

function Expand-PathEntry {
    param([string]$Raw)
    return [Environment]::ExpandEnvironmentVariables($Raw.Trim().Trim('"'))
}

function ConvertTo-PathKey {
    # Forme comparable : variables développées, sans guillemets ni séparateur final.
    param([string]$Raw)
    $p = (Expand-PathEntry $Raw).TrimEnd('\', '/')
    if (-not $p) { $p = (Expand-PathEntry $Raw) }
    if ($isWin) { return $p.ToLowerInvariant() }
    return $p
}

function Get-PathExt {
    $list = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
    if ($env:PATHEXT) { $list = $env:PATHEXT }
    return @($list -split ';' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
}

function Test-Executable {
    param([string]$File)
    if ($isWin) { return ((Get-PathExt) -contains ([IO.Path]::GetExtension($File).ToLowerInvariant())) }
    try { return (([int][IO.File]::GetUnixFileMode($File)) -band 0x49) -ne 0 } catch { return $true }
}

function Test-HasExecutable {
    param([string]$Dir)
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($Dir)) { if (Test-Executable $f) { return $true } }
        return $false
    }
    catch { return $true }   # illisible : on ne conclut pas
}

function Get-EntryStatus {
    # ok, unresolved (variable inconnue), missing, noexe.
    param([string]$Raw)
    $expanded = Expand-PathEntry $Raw
    if ($expanded -match '%[^%\s]+%') { return 'unresolved' }
    if (-not (Test-Path -LiteralPath $expanded -PathType Container)) { return 'missing' }
    if (-not (Test-HasExecutable $expanded)) { return 'noexe' }
    return 'ok'
}

function Get-PathReport {
    # Entrées dans l'ordre réellement utilisé (session), puis celles du registre pas encore actives.
    $machineKeys = @{}; $userKeys = @{}
    if ($isWin) {
        foreach ($e in (Split-PathValue (Get-StoredPath 'Machine'))) { $machineKeys[(ConvertTo-PathKey $e)] = $e }
        foreach ($e in (Split-PathValue (Get-StoredPath 'User'))) { $userKeys[(ConvertTo-PathKey $e)] = $e }
    }
    $report = New-Object System.Collections.ArrayList
    $seen = @{}
    $n = 0
    foreach ($raw in (Split-PathValue $env:PATH)) {
        $n++
        $key = ConvertTo-PathKey $raw
        $scope = 'Session'
        if ($machineKeys.ContainsKey($key)) { $scope = 'Machine' } elseif ($userKeys.ContainsKey($key)) { $scope = 'User' }
        $status = Get-EntryStatus $raw
        $dupOf = 0
        if ($seen.ContainsKey($key)) { $status = 'duplicate'; $dupOf = $seen[$key] } else { $seen[$key] = $n }
        [void]$report.Add([ordered]@{ Index = $n; Path = $raw; Expanded = (Expand-PathEntry $raw); Scope = $scope; Status = $status; DuplicateOf = $dupOf; Active = $true })
    }
    foreach ($pair in @(@('Machine', $machineKeys), @('User', $userKeys))) {
        foreach ($key in @($pair[1].Keys)) {
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 0
            $raw = $pair[1][$key]
            [void]$report.Add([ordered]@{ Index = 0; Path = $raw; Expanded = (Expand-PathEntry $raw); Scope = $pair[0]; Status = (Get-EntryStatus $raw); DuplicateOf = 0; Active = $false })
        }
    }
    return $report
}

function Get-ScopeLabel {
    param([string]$Scope)
    switch ($Scope) {
        'Machine' { return (L 'Machine') }
        'User' { return (L 'Utilisateur') }
        default { return (L 'Session') }
    }
}

function Get-StatusText {
    param($Entry)
    switch ($Entry.Status) {
        'ok' { $t = Paint (L 'ok') 'Ok' }
        'missing' { $t = Paint (L 'introuvable') 'Err' }
        'duplicate' { $t = Paint (L 'doublon de n° {0}' $Entry.DuplicateOf) 'Warn' }
        'noexe' { $t = Paint (L 'aucun exécutable') 'Dim' }
        'unresolved' { $t = Paint (L 'variable inconnue') 'Warn' }
        default { $t = $Entry.Status }
    }
    if (-not $Entry.Active) { $t += Paint (' ' + (L '(nouveau terminal)')) 'Accent2' }
    return $t
}

# ── Commandes ────────────────────────────────────────────────────────────────

function Show-PathList {
    $report = @(Get-PathReport)
    if ($Json) { ConvertTo-Json -InputObject @($report) -Depth 3; $script:Code = 0; return }
    $width = Get-PstWidth -Max 120
    Show-PstHeader -Tool 'path' -Subtitle (L '{0} entrée(s)' $report.Count)
    $rows = @()
    $dirW = [Math]::Max(24, $width - 54)
    foreach ($e in $report) {
        $num = [string]$e.Index
        if (-not $e.Active) { $num = '+' }
        $shown = $e.Path
        if ($shown.Length -gt $dirW) { $shown = $g.Ellipsis + $shown.Substring($shown.Length - $dirW + 1) }
        if ($e.Status -in 'missing', 'duplicate') { $shown = Paint $shown 'Dim' }
        $rows += , @($num, (Get-ScopeLabel $e.Scope), (Get-StatusText $e), $shown)
    }
    Format-PstTable -Columns @(
        @{ Name = (L 'N°'); Width = 3; Right = $true }, @{ Name = (L 'Portée'); Width = 11 }, @{ Name = (L 'État'); Width = 32 }, @{ Name = (L 'Dossier'); Width = $dirW }
    ) -Rows $rows | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    $missing = @($report | Where-Object { $_.Status -eq 'missing' }).Count
    $dups = @($report | Where-Object { $_.Status -eq 'duplicate' }).Count
    if ($missing -or $dups) {
        Write-PstStatus warn (L '{0} dossier(s) introuvable(s), {1} doublon(s).' $missing $dups)
        if ($isWin) { Write-Host (Paint ('    ' + (L '« path clean -DryRun » pour voir ce qui serait retiré du PATH Utilisateur.')) 'Dim') }
    }
    else { Write-PstStatus ok (L 'Aucun dossier introuvable ni doublon.') }
    if (@($report | Where-Object { -not $_.Active }).Count) { Write-PstStatus info (L 'Les entrées « + » sont enregistrées mais pas encore actives dans ce terminal.') }
    if (-not $isWin) { Write-PstStatus info (L 'Hors Windows : lecture seule (le PATH se règle dans le profil de votre shell).') }
    Write-Host ''
    $script:Code = 0; return
}

function Find-Program {
    # Toutes les copies d'un programme, dans l'ordre de recherche du PATH.
    param([string]$Name)
    $names = @($Name)
    if ($isWin) {
        $exts = Get-PathExt
        if ($exts -notcontains ([IO.Path]::GetExtension($Name).ToLowerInvariant())) { $names = @($exts | ForEach-Object { $Name + $_ }) }
    }
    $hits = @()
    $seen = @{}
    $n = 0
    foreach ($raw in (Split-PathValue $env:PATH)) {
        $n++
        $key = ConvertTo-PathKey $raw
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $dir = Expand-PathEntry $raw
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($candidate in $names) {
            $file = Join-Path $dir $candidate
            if ((Test-Path -LiteralPath $file -PathType Leaf) -and (Test-Executable $file)) { $hits += [ordered]@{ Index = $n; File = $file; Dir = $raw } }
        }
    }
    return $hits
}

function Show-Which {
    param([string]$Name)
    if (-not $Name) { Write-PstStatus err (L 'Indiquez un programme : path which <nom>'); $script:Code = 1; return }
    $hits = @(Find-Program $Name)
    $shell = @(Get-Command -Name $Name -CommandType Alias, Function, Cmdlet -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($Json) {
        $ps = $null
        if ($shell.Count) { $ps = [ordered]@{ Type = [string]$shell[0].CommandType; Definition = [string]$shell[0].Definition } }
        [ordered]@{ Name = $Name; Winner = @($hits | Select-Object -First 1); Shadowed = @($hits | Select-Object -Skip 1); PowerShell = $ps } | ConvertTo-Json -Depth 4
        if ($hits.Count) { $script:Code = 0; return } else { $script:Code = 1; return }
    }
    Show-PstHeader -Tool 'path' -Subtitle "which $Name"
    if (-not $hits.Count) {
        Write-PstStatus warn (L '« {0} » est introuvable dans le PATH.' $Name)
    }
    else {
        $w = $hits[0]
        Write-Host ('  ' + (Paint $g.Pointer 'Ok' -Bold) + ' ' + (Paint $w.File 'Title' -Bold) + (Paint ('  ' + (L 'n° {0} du PATH' $w.Index)) 'Dim'))
        if ($hits.Count -gt 1) {
            Write-Host ''
            Write-Host ('  ' + (Paint (L 'Copies masquées (jamais lancées par ce nom) :') 'Dim'))
            foreach ($h in @($hits | Select-Object -Skip 1)) { Write-Host ('    ' + (Paint $g.Dot 'Dim') + ' ' + $h.File + (Paint ('  ' + (L 'n° {0}' $h.Index)) 'Dim')) }
        }
    }
    if ($shell.Count) {
        Write-Host ''
        $c = $shell[0]
        $def = [string]$c.Definition
        if ($c.CommandType -eq 'Function') { $def = $c.Name }
        $shown = Limit-PstText ($def -replace '\s+', ' ') 40
        switch ([string]$c.CommandType) {
            'Alias' { Write-PstStatus info (L 'Dans PowerShell, l''alias « {0} » ({1}) passe avant le PATH.' $c.Name $shown) }
            'Function' { Write-PstStatus info (L 'Dans PowerShell, la fonction « {0} » passe avant le PATH.' $c.Name) }
            default { Write-PstStatus info (L 'Dans PowerShell, la cmdlet « {0} » passe avant le PATH.' $c.Name) }
        }
    }
    Write-Host ''
    if ($hits.Count) { $script:Code = 0; return }
    $script:Code = 1; return
}

function Assert-Writable {
    # Vrai si la portée visée peut être modifiée ; sinon explique pourquoi.
    param([string]$Target)
    if (-not $isWin) {
        Write-PstStatus err (L 'Hors Windows, path est en lecture seule : modifiez le PATH dans le profil de votre shell (~/.profile, ~/.bashrc...).')
        return $false
    }
    if ($Target -eq 'Machine' -and -not (Test-PstAdmin)) {
        Write-PstStatus err (L 'Le PATH Machine concerne tous les utilisateurs : il faut un terminal administrateur.')
        Write-Host (Paint ('    ' + (L 'Relancez la commande dans un terminal « Exécuter en tant qu''administrateur », ou omettez -Machine pour votre seul compte.')) 'Dim')
        return $false
    }
    return $true
}

function Confirm-Change {
    # Retourne $true si l'on peut écrire (confirmation, ou -Yes).
    param([string]$Question)
    if ($Yes) { return $true }
    if (-not (Test-PstInteractive)) { Write-PstStatus warn (L 'Session non interactive : ajoutez -Yes pour appliquer.'); return $false }
    return (Read-PstConfirm $Question)
}

function Write-Applied {
    param([string]$Target, [string]$NewValue)
    try { $backup = Set-StoredPath $Target $NewValue }
    catch { Write-PstStatus err (L 'Écriture impossible : {0}' $_.Exception.Message); return $false }
    Write-PstStatus ok (L 'PATH {0} mis à jour.' (Get-ScopeLabel $Target))
    Write-Host (Paint ('    ' + (L 'Ancienne valeur sauvegardée : {0}' $backup)) 'Dim')
    Write-Host (Paint ('    ' + (L 'Ouvrez un nouveau terminal pour en profiter.')) 'Dim')
    return $true
}

function Add-PathDir {
    param([string]$Dir, [string]$Target)
    if (-not $Dir) { Write-PstStatus err (L 'Indiquez un dossier : path add <dossier>'); $script:Code = 1; return }
    if (-not (Assert-Writable $Target)) { $script:Code = 1; return }
    $entry = $Dir.Trim().Trim('"')
    if ($entry -notmatch '%' -and (Test-Path -LiteralPath $entry -PathType Container)) { $entry = (Resolve-Path -LiteralPath $entry).ProviderPath }
    if ($entry.Length -gt 3) { $entry = $entry.TrimEnd('\', '/') }
    $key = ConvertTo-PathKey $entry
    Show-PstHeader -Tool 'path' -Subtitle ('add ' + (Get-ScopeLabel $Target))
    foreach ($scope in @($Target) + @(@('User', 'Machine') | Where-Object { $_ -ne $Target })) {
        foreach ($e in (Split-PathValue (Get-StoredPath $scope))) {
            if ((ConvertTo-PathKey $e) -eq $key) {
                Write-PstStatus info (L 'Déjà présent dans le PATH {0} : {1}' (Get-ScopeLabel $scope) $e)
                Write-Host ''
                $script:Code = 0; return
            }
        }
    }
    $proceed = $true
    if (-not (Test-Path -LiteralPath (Expand-PathEntry $entry) -PathType Container)) {
        Write-PstStatus warn (L 'Ce dossier n''existe pas (encore) : {0}' $entry)
        if (-not $DryRun) { $proceed = Confirm-Change (L 'L''ajouter quand même ?') }
    }
    if (-not $proceed) { Write-PstStatus info (L 'Annulé : PATH inchangé.'); Write-Host ''; $script:Code = 1; return }
    $old = Get-StoredPath $Target
    if ($First) { $new = $entry; if ($old.Trim()) { $new += $sep + $old } }
    elseif (-not $old.Trim()) { $new = $entry }
    elseif ($old.EndsWith($sep)) { $new = $old + $entry }
    else { $new = $old + $sep + $entry }
    $where = L 'en fin de PATH'
    if ($First) { $where = L 'en tête de PATH' }
    Write-PstStatus step (L 'Ajout au PATH {0} ({1}) : {2}' (Get-ScopeLabel $Target) $where $entry)
    if ($DryRun) { Write-PstStatus info (L 'Simulation : rien n''a été modifié.'); Write-Host ''; $script:Code = 0; return }
    if (-not (Write-Applied $Target $new)) { $script:Code = 1; return }
    $quoted = $entry -replace "'", "''"
    Write-Host (Paint ('    ' + (L 'Dans ce terminal : {0}' ('$env:PATH += ''' + $sep + $quoted + ''''))) 'Dim')
    Write-Host ''
    $script:Code = 0; return
}

function Remove-PathDir {
    param([string]$Dir, [string]$Target)
    if (-not $Dir) { Write-PstStatus err (L 'Indiquez un dossier : path rm <dossier>'); $script:Code = 1; return }
    if (-not (Assert-Writable $Target)) { $script:Code = 1; return }
    $key = ConvertTo-PathKey $Dir
    $old = Get-StoredPath $Target
    $segments = @($old -split [regex]::Escape($sep))
    $removed = @($segments | Where-Object { $_.Trim() -and ((ConvertTo-PathKey $_) -eq $key) })
    Show-PstHeader -Tool 'path' -Subtitle ('rm ' + (Get-ScopeLabel $Target))
    if (-not $removed.Count) {
        Write-PstStatus err (L 'Absent du PATH {0} : {1}' (Get-ScopeLabel $Target) $Dir)
        $other = 'Machine'
        if ($Target -eq 'Machine') { $other = 'User' }
        if (@(Split-PathValue (Get-StoredPath $other) | Where-Object { (ConvertTo-PathKey $_) -eq $key }).Count) {
            if ($other -eq 'Machine') { Write-PstStatus info (L 'Il figure dans le PATH Machine : ajoutez -Machine.') }
            else { Write-PstStatus info (L 'Il figure dans le PATH Utilisateur : relancez sans -Machine.') }
        }
        elseif (@(Split-PathValue $env:PATH | Where-Object { (ConvertTo-PathKey $_) -eq $key }).Count) {
            Write-PstStatus info (L 'Il n''existe que dans cette session (ajouté par un programme ou un profil).')
        }
        Write-Host ''
        $script:Code = 1; return
    }
    foreach ($r in $removed) { Write-Host ('  ' + (Paint '-' 'Err' -Bold) + ' ' + $r) }
    Write-Host ''
    if ($DryRun) { Write-PstStatus info (L 'Simulation : rien n''a été modifié.'); Write-Host ''; $script:Code = 0; return }
    if (-not (Confirm-Change (L 'Retirer {0} entrée(s) du PATH {1} ?' $removed.Count (Get-ScopeLabel $Target)))) { Write-PstStatus info (L 'Annulé : PATH inchangé.'); Write-Host ''; $script:Code = 1; return }
    $new = (@($segments | Where-Object { -not ($_.Trim() -and ((ConvertTo-PathKey $_) -eq $key)) }) -join $sep)
    if (-not (Write-Applied $Target $new)) { $script:Code = 1; return }
    Write-Host ''
    $script:Code = 0; return
}

function Get-CleanPlan {
    # Entrées à retirer d'une portée : vides, introuvables, doublons (y compris d'une entrée Machine).
    param([string]$Target)
    $old = Get-StoredPath $Target
    $machineKeys = @{}
    if ($Target -eq 'User') { foreach ($e in (Split-PathValue (Get-StoredPath 'Machine'))) { $machineKeys[(ConvertTo-PathKey $e)] = $true } }
    $seen = @{}
    $kept = @(); $drop = @(); $warn = @()
    $empty = 0
    foreach ($segment in @($old -split [regex]::Escape($sep))) {
        if (-not $segment.Trim()) { if ($old) { $empty++ }; continue }
        $key = ConvertTo-PathKey $segment
        $status = Get-EntryStatus $segment
        if ($status -eq 'unresolved') { $warn += $segment; $kept += $segment; $seen[$key] = $true; continue }
        if ($seen.ContainsKey($key)) { $drop += [ordered]@{ Path = $segment; Reason = 'duplicate' }; continue }
        if ($machineKeys.ContainsKey($key)) { $drop += [ordered]@{ Path = $segment; Reason = 'machine' }; continue }
        if ($status -eq 'missing') { $drop += [ordered]@{ Path = $segment; Reason = 'missing' }; continue }
        $seen[$key] = $true
        $kept += $segment
    }
    if ($empty -and $old.EndsWith($sep)) { $empty-- }   # un « ; » final est inoffensif
    return @{ Old = $old; New = ($kept -join $sep); Drop = $drop; Warn = $warn; Empty = [Math]::Max(0, $empty) }
}

function Invoke-Clean {
    param([string]$Target)
    if (-not (Assert-Writable $Target)) { $script:Code = 1; return }
    $plan = Get-CleanPlan $Target
    if ($Json) {
        [ordered]@{ Target = $Target; Remove = @($plan.Drop); Kept = @(Split-PathValue $plan.New); Unresolved = @($plan.Warn) } | ConvertTo-Json -Depth 4
        if ($DryRun -or -not $Yes) { $script:Code = 0; return }
    }
    if (-not $Json) { Show-PstHeader -Tool 'path' -Subtitle ('clean ' + (Get-ScopeLabel $Target)) }
    foreach ($w in $plan.Warn) { Write-PstStatus warn (L 'Conservé (variable inconnue ici, à vérifier) : {0}' $w) }
    if (-not $plan.Drop.Count -and -not $plan.Empty) {
        Write-PstStatus ok (L 'PATH {0} déjà propre : rien à retirer.' (Get-ScopeLabel $Target))
        Write-Host ''
        $script:Code = 0; return
    }
    if (-not $Json) {
        foreach ($d in $plan.Drop) {
            switch ($d.Reason) {
                'missing' { $why = L 'dossier introuvable' }
                'machine' { $why = L 'déjà dans le PATH Machine' }
                default { $why = L 'doublon' }
            }
            Write-Host ('  ' + (Paint '-' 'Err' -Bold) + ' ' + (Format-PstPad $d.Path 50) + '  ' + (Paint $why 'Dim'))
        }
        if ($plan.Empty) { Write-Host ('  ' + (Paint '-' 'Err' -Bold) + ' ' + (Paint (L '{0} entrée(s) vide(s)' $plan.Empty) 'Dim')) }
        Write-Host ''
        Write-PstStatus info (L '{0} entrée(s) retirée(s), {1} conservée(s) dans l''ordre d''origine.' ($plan.Drop.Count + $plan.Empty) @(Split-PathValue $plan.New).Count)
    }
    if ($DryRun) { Write-PstStatus info (L 'Simulation : rien n''a été modifié.'); Write-Host ''; $script:Code = 0; return }
    if (-not (Confirm-Change (L 'Appliquer ce nettoyage ?'))) { Write-PstStatus info (L 'Annulé : PATH inchangé.'); Write-Host ''; $script:Code = 1; return }
    if (-not (Write-Applied $Target $plan.New)) { $script:Code = 1; return }
    Write-Host ''
    $script:Code = 0; return
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

$target = 'User'
if ($Machine) { $target = 'Machine' }

switch -Regex (([string]$Command).ToLowerInvariant()) {
    '^$|^(list|ls|show)$' { Show-PathList; break }
    '^(which|where)$' { Show-Which $Value; break }
    '^add$' { Add-PathDir $Value $target; break }
    '^(rm|remove|del|delete)$' { Remove-PathDir $Value $target; break }
    '^(clean|fix)$' { Invoke-Clean $target; break }
    default {
        Write-PstStatus err (L 'Commande inconnue : « {0} » {1} voir « path -Help »' $Command $g.Dot)
        $script:Code = 1
    }
}
exit $script:Code
