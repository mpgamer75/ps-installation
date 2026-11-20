<#
.SYNOPSIS
    dev — couteau suisse du développeur : identifiants, mots de passe, empreintes, encodages, JSON, JWT, dates.
.DESCRIPTION
    Tout est calculé localement : rien n'est envoyé sur Internet.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Value,
    # Reçoit le pipeline ; l'ensemble des lignes est lu plus bas via `$input.
    [Parameter(ValueFromPipeline = $true)][object]$InputObject,
    [switch]$Decode,
    [ValidateSet('MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512')][string]$Algo = 'SHA256',
    [int]$Length = 20,
    [int]$Count = 1,
    [switch]$Copy,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$piped = @($input)
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'dev'
$g = $script:Pst.Glyph

if ($Help -or -not $Command -or (Test-PstHelpArg (@($Command, $Value) + @($Rest)))) {
    Show-PstHelp -Name 'dev' -Synopsis (L 'Les petits outils du quotidien, sans ouvrir un site web.') `
        -Usage @((L 'dev <outil> [valeur] [options]')) `
        -Options @(
            @('uuid [-Count n]', (L 'Identifiants uniques (GUID)')),
            @('pass [-Length n] [-Count n]', (L 'Mots de passe aléatoires robustes')),
            @((L 'hash <fichier|texte> [-Algo]'), (L 'Empreinte SHA256 (ou MD5, SHA1, SHA384, SHA512)')),
            @((L 'b64 <texte> [-Decode]'), (L 'Encodage / décodage Base64')),
            @((L 'url <texte> [-Decode]'), (L 'Encodage / décodage d''URL')),
            @((L 'json <fichier>'), (L 'Valide et met en forme du JSON (accepte aussi le pipeline)')),
            @((L 'jwt <jeton>'), (L 'Décode un jeton JWT (sans vérifier la signature)')),
            @((L 'epoch [valeur]'), (L 'Horodatage Unix <-> date lisible')),
            @('-Copy', (L 'Copie le résultat dans le presse-papiers'))
        ) `
        -Examples @('dev uuid', 'dev pass -Length 32 -Copy', 'dev hash .\setup.exe', (L 'dev b64 "bonjour"'), 'dev epoch 1767225600', 'Get-Content data.json | dev json')
    if ($Help -or $Command) { exit 0 } else { exit 1 }
}

if (-not $Value -and $piped.Count) { $Value = (@($piped | ForEach-Object { [string]$_ }) -join "`n") }

function Write-Result {
    # Résultat brut sur la sortie standard (réutilisable dans un pipeline), copie optionnelle.
    param([string[]]$Lines)
    $Lines | ForEach-Object { Write-Output $_ }
    if ($Copy) {
        try { Set-Clipboard -Value ($Lines -join "`r`n"); Write-Host (Paint ("  $($g.Ok) " + (L 'copié dans le presse-papiers')) 'Dim') }
        catch { Write-Host (Paint ("  $($g.Warn) " + (L 'presse-papiers indisponible')) 'Warn') }
    }
}

function Stop-Usage {
    param([string]$Message)
    Write-PstStatus err $Message
    exit 1
}

function ConvertFrom-Base64Url {
    param([string]$Text)
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

function Format-Json {
    # Indentation homogène sous PowerShell 5.1 et 7, avec couleurs si le terminal le permet.
    param([string]$Json)
    $compact = ($Json | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress)
    $sb = New-Object System.Text.StringBuilder
    $depth = 0; $inString = $false; $escape = $false
    foreach ($ch in $compact.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false } elseif ($ch -eq '\') { $escape = $true } elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        switch ($ch) {
            '"' { $inString = $true; [void]$sb.Append($ch) }
            { $_ -eq '{' -or $_ -eq '[' } { $depth++; [void]$sb.Append($ch).Append("`n").Append('  ' * $depth) }
            { $_ -eq '}' -or $_ -eq ']' } { $depth--; [void]$sb.Append("`n").Append('  ' * $depth).Append($ch) }
            ',' { [void]$sb.Append($ch).Append("`n").Append('  ' * $depth) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($ch) }
        }
    }
    $pretty = $sb.ToString() -replace '\{\s+\}', '{}' -replace '\[\s+\]', '[]'
    if (-not $script:Pst.Ansi) { return $pretty }
    $e = $script:Pst.Esc
    $key = $script:Pst.Theme.Accent; $str = $script:Pst.Theme.Ok; $num = $script:Pst.Theme.Warn
    $pretty = [regex]::Replace($pretty, '("(?:[^"\\]|\\.)*")(\s*:)?|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)', {
            param($m)
            if ($m.Groups[1].Success) {
                if ($m.Groups[2].Success) { return "$e[38;2;$($key[0]);$($key[1]);$($key[2])m$($m.Groups[1].Value)$e[0m$($m.Groups[2].Value)" }
                return "$e[38;2;$($str[0]);$($str[1]);$($str[2])m$($m.Groups[1].Value)$e[0m"
            }
            return "$e[38;2;$($num[0]);$($num[1]);$($num[2])m$($m.Value)$e[0m"
        })
    return $pretty
}

switch -Regex ($Command.ToLower()) {
    '^(uuid|guid)$' {
        Write-Result @(1..([Math]::Max(1, $Count)) | ForEach-Object { [Guid]::NewGuid().ToString() })
        break
    }
    '^(pass|password|pwd)$' {
        if ($Length -lt 8 -or $Length -gt 256) { Stop-Usage (L 'La longueur doit être comprise entre 8 et 256.') }
        # Générateur cryptographique ; caractères ambigus (0/O, 1/l/I) écartés.
        $sets = @('abcdefghijkmnopqrstuvwxyz', 'ABCDEFGHJKLMNPQRSTUVWXYZ', '23456789', '!@#$%&*-_=+?')
        $all = ($sets -join '')
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $pick = {
            param([string]$Chars)
            $buffer = New-Object byte[] 4
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % $Chars.Length)
            do { $rng.GetBytes($buffer); $n = [BitConverter]::ToUInt32($buffer, 0) } while ($n -ge $limit)
            return $Chars[[int]($n % $Chars.Length)]
        }
        $result = @(1..([Math]::Max(1, $Count)) | ForEach-Object {
                $chars = New-Object System.Collections.ArrayList
                foreach ($set in $sets) { [void]$chars.Add((& $pick $set)) }          # au moins un de chaque famille
                while ($chars.Count -lt $Length) { [void]$chars.Add((& $pick $all)) }
                for ($i = $chars.Count - 1; $i -gt 0; $i--) {                          # mélange de Fisher-Yates
                    $buffer = New-Object byte[] 4
                    $rng.GetBytes($buffer)
                    $j = [int]([BitConverter]::ToUInt32($buffer, 0) % ($i + 1))
                    $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
                }
                -join $chars
            })
        $rng.Dispose()
        Write-Result $result
        break
    }
    '^hash$' {
        if (-not $Value) { Stop-Usage (L 'Indiquez un fichier ou un texte : dev hash <fichier|texte>') }
        $hasher = [Security.Cryptography.HashAlgorithm]::Create($Algo)
        try {
            if (Test-Path -LiteralPath $Value -PathType Leaf) {
                $fs = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Value).ProviderPath)
                try { $bytes = $hasher.ComputeHash($fs) } finally { $fs.Dispose() }
            }
            else { $bytes = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
        }
        finally { $hasher.Dispose() }
        Write-Result @(-join ($bytes | ForEach-Object { $_.ToString('x2') }))
        break
    }
    '^(b64|base64)$' {
        if (-not $Value) { Stop-Usage (L 'Indiquez un texte : dev b64 <texte> [-Decode]') }
        try {
            if ($Decode) { Write-Result @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value.Trim()))) }
            else { Write-Result @([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))) }
        }
        catch { Stop-Usage (L 'Ce texte n''est pas du Base64 valide.') }
        break
    }
    '^url$' {
        if (-not $Value) { Stop-Usage (L 'Indiquez un texte : dev url <texte> [-Decode]') }
        if ($Decode) { Write-Result @([Uri]::UnescapeDataString($Value.Replace('+', ' '))) }
        else { Write-Result @([Uri]::EscapeDataString($Value)) }
        break
    }
    '^json$' {
        if (-not $Value) { Stop-Usage (L 'Indiquez un fichier ou passez le JSON par le pipeline : dev json <fichier>') }
        $text = $Value
        if ($Value.Length -lt 260 -and (Test-Path -LiteralPath $Value -PathType Leaf)) { $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Value).ProviderPath) }
        try { $pretty = Format-Json $text }
        catch { Stop-Usage (L 'JSON invalide : {0}' $_.Exception.Message) }
        Write-Host $pretty
        if ($Copy) { try { Set-Clipboard -Value ($pretty -replace "$([char]27)\[[0-9;]*m", '') } catch { $null = $_ } }
        break
    }
    '^jwt$' {
        if (-not $Value) { Stop-Usage (L 'Indiquez un jeton : dev jwt <jeton>') }
        $parts = $Value.Trim() -split '\.'
        if ($parts.Count -lt 2) { Stop-Usage (L 'Ce texte ne ressemble pas à un jeton JWT (en-tête.contenu.signature).') }
        try { $header = ConvertFrom-Base64Url $parts[0]; $payload = ConvertFrom-Base64Url $parts[1] }
        catch { Stop-Usage (L 'Jeton JWT illisible.') }
        Write-Host (Paint (L '  En-tête') 'Accent' -Bold); Write-Host (Format-Json $header)
        Write-Host (Paint (L '  Contenu') 'Accent' -Bold); Write-Host (Format-Json $payload)
        try {
            $claims = $payload | ConvertFrom-Json
            foreach ($claim in 'iat', 'nbf', 'exp') {
                if ($null -eq $claims.$claim) { continue }
                $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.$claim).LocalDateTime
                $note = ''
                if ($claim -eq 'exp') {
                    if ($when -lt (Get-Date)) { $note = Paint (L '  expiré depuis {0}' (Format-PstDuration ((Get-Date) - $when))) 'Err' }
                    else { $note = Paint (L '  valide encore {0}' (Format-PstDuration ($when - (Get-Date)))) 'Ok' }
                }
                Write-Host ('  ' + (Paint (Format-PstPad $claim 5) 'Dim') + $when.ToString((L 'dd/MM/yyyy HH:mm:ss'), (Get-PstCulture)) + $note)
            }
        }
        catch { $null = $_ }
        Write-Host (Paint ("  $($g.Warn) " + (L 'signature non vérifiée : ne faites pas confiance à ce contenu sans validation.')) 'Dim')
        break
    }
    '^(epoch|time|date)$' {
        if (-not $Value) {
            Write-Result @([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            break
        }
        if ($Value -match '^\d{9,13}$') {
            $n = [long]$Value
            if ($Value.Length -gt 10) { $moment = [DateTimeOffset]::FromUnixTimeMilliseconds($n) } else { $moment = [DateTimeOffset]::FromUnixTimeSeconds($n) }
            Write-Host ('  ' + (Paint (Format-PstPad 'Local' 7) 'Accent') + $moment.LocalDateTime.ToString((L 'dddd d MMMM yyyy HH:mm:ss'), (Get-PstCulture)))
            Write-Host ('  ' + (Paint (Format-PstPad 'UTC' 7) 'Accent') + $moment.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))
            break
        }
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse($Value, [ref]$parsed)) { Write-Result @([string]([DateTimeOffset]$parsed).ToUnixTimeSeconds()) }
        else { Stop-Usage (L 'Valeur non reconnue : « {0} » (horodatage Unix ou date).' $Value) }
        break
    }
    default { Stop-Usage (L 'Outil inconnu : « {0} » {1} voir « dev -Help »' $Command $g.Dot) }
}
