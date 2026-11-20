<#
.SYNOPSIS
    serve — serveur web local instantané pour le dossier courant.
.DESCRIPTION
    Équivalent de « python -m http.server ». Écoute sur localhost uniquement,
    donc sans droits administrateur ni règle de pare-feu. L'option -Lan ouvre
    le serveur au réseau local et demande, sous Windows, une session administrateur.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [ValidateRange(1, 65535)][int]$Port = 8080,
    [switch]$Open,
    [switch]$Lan,
    [ValidateRange(0, 100000)][int]$MaxRequests = 0,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'serve'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'serve' -Synopsis (L 'Sert un dossier en HTTP, le temps d''un test.') `
        -Usage @((L 'serve [dossier] [-Port <n>] [-Open] [-Lan]')) `
        -Options @(
            @((L 'Dossier').ToLowerInvariant(), (L 'Dossier à servir (défaut : dossier courant)')),
            @('-Port <n>', (L 'Port d''écoute (défaut : 8080 ; le suivant libre est pris si occupé)')),
            @('-Open', (L 'Ouvre le navigateur')),
            @('-Lan', (L 'Accessible depuis le réseau local (administrateur requis sous Windows)'))
        ) `
        -Examples @('serve', 'serve .\dist -Port 3000 -Open') `
        -Notes @((L 'Touche : Q pour arrêter. index.html est servi automatiquement s''il existe.'))
    exit 0
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\', '/')
$g = $script:Pst.Glyph

if ($Lan -and $script:Pst.IsWindows -and -not (Test-PstAdmin)) {
    Write-PstStatus err (L 'Ouvrir le serveur au réseau (-Lan) demande un terminal administrateur.')
    Write-PstStatus info (L 'Sans -Lan, le serveur fonctionne sans droits particuliers sur http://localhost.')
    exit 1
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.mjs' = 'text/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'; '.md' = 'text/plain; charset=utf-8'
    '.xml' = 'application/xml'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'
    '.webp' = 'image/webp'; '.ico' = 'image/x-icon'; '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.pdf' = 'application/pdf'; '.wasm' = 'application/wasm'
    '.mp4' = 'video/mp4'; '.webm' = 'video/webm'; '.mp3' = 'audio/mpeg'; '.csv' = 'text/csv; charset=utf-8'; '.map' = 'application/json'
}

$listener = $null
$hostName = 'localhost'
if ($Lan) { $hostName = '+' }
for ($try = 0; $try -lt 20; $try++) {
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add("http://${hostName}:$($Port + $try)/")
    try { $candidate.Start(); $listener = $candidate; $Port = $Port + $try; break }
    catch { $candidate.Close() }
}
if (-not $listener) { Write-PstStatus err (L 'Aucun port libre entre {0} et {1}.' $Port ($Port + 19)); exit 1 }

$url = "http://localhost:$Port/"
Show-PstHeader -Tool 'serve' -Subtitle (Split-Path -Leaf $root)
$info = @(
    ((Paint (Format-PstPad (L 'Adresse') 9) 'Accent') + (Paint $url 'Ok' -Bold)),
    ((Paint (Format-PstPad (L 'Dossier') 9) 'Accent') + (Limit-PstText $root 70))
)
if ($Lan) { $info += (Paint (Format-PstPad (L 'Réseau') 9) 'Accent') + (Paint (L 'ouvert au réseau local') 'Warn') } else { $info += (Paint (Format-PstPad (L 'Portée') 9) 'Accent') + (L 'cette machine uniquement') }
Format-PstBox -Lines $info | Write-PstLine
Write-Host (Paint ('  ' + (L 'Q pour arrêter')) 'Dim')
Write-Host ''
if ($Open) { try { Start-Process $url } catch { $null = $_ } }

function Send-Bytes {
    param($Response, [int]$Code, [string]$Type, [byte[]]$Bytes)
    $Response.StatusCode = $Code
    $Response.ContentType = $Type
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Get-Listing {
    param([string]$Dir, [string]$UrlPath)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode($t) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!doctype html><meta charset=utf-8><title>$(& $enc $UrlPath)</title><style>body{font:15px system-ui,sans-serif;max-width:860px;margin:40px auto;padding:0 16px;color:#1f2430}a{color:#2563eb;text-decoration:none}a:hover{text-decoration:underline}li{padding:4px 0;list-style:none;display:flex;justify-content:space-between;border-bottom:1px solid #eef0f4}span{color:#7d8596}ul{padding:0}</style><h2>$(& $enc $UrlPath)</h2><ul>")
    if ($UrlPath -ne '/') { [void]$sb.Append('<li><a href="../">../</a></li>') }
    $entry = New-Object IO.DirectoryInfo $Dir
    foreach ($d in ($entry.GetDirectories() | Sort-Object Name)) { [void]$sb.Append("<li><a href=""$([Uri]::EscapeDataString($d.Name))/"">$(& $enc $d.Name)/</a></li>") }
    foreach ($f in ($entry.GetFiles() | Sort-Object Name)) { [void]$sb.Append("<li><a href=""$([Uri]::EscapeDataString($f.Name))"">$(& $enc $f.Name)</a><span>$(Format-PstSize $f.Length)</span></li>") }
    [void]$sb.Append('</ul>')
    return [Text.Encoding]::UTF8.GetBytes($sb.ToString())
}

$interactive = Test-PstInteractive
if ($interactive) { try { [Console]::TreatControlCAsInput = $true } catch { $null = $_ } }
$served = 0
$pending = $listener.GetContextAsync()
try {
    while ($true) {
        if (-not $pending.Wait(250)) {
            if ($interactive) {
                $key = Read-PstKey -TimeoutMs 1
                if (Test-PstQuitKey $key) { break }
            }
            continue
        }
        $context = $pending.Result
        $pending = $listener.GetContextAsync()
        $request = $context.Request
        $response = $context.Response
        $code = 200
        $size = 0
        try {
            $urlPath = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
            $target = [IO.Path]::GetFullPath((Join-Path $root ($urlPath.TrimStart('/') -replace '/', [IO.Path]::DirectorySeparatorChar)))
            # Interdit de sortir du dossier servi (../).
            $inside = ($target -eq $root) -or $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            if ($request.HttpMethod -notin 'GET', 'HEAD') { $code = 405; Send-Bytes $response 405 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((L 'Méthode non autorisée'))) }
            elseif (-not $inside) { $code = 403; Send-Bytes $response 403 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((L 'Accès refusé'))) }
            elseif (Test-Path -LiteralPath $target -PathType Container) {
                $index = Join-Path $target 'index.html'
                if (-not $urlPath.EndsWith('/')) { $code = 301; $response.StatusCode = 301; $response.RedirectLocation = $request.Url.AbsolutePath + '/' }
                elseif (Test-Path -LiteralPath $index -PathType Leaf) { $bytes = [IO.File]::ReadAllBytes($index); $size = $bytes.Length; Send-Bytes $response 200 $mime['.html'] $bytes }
                else { $bytes = Get-Listing $target $urlPath; $size = $bytes.Length; Send-Bytes $response 200 'text/html; charset=utf-8' $bytes }
            }
            elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                $type = $mime[[IO.Path]::GetExtension($target).ToLower()]
                if (-not $type) { $type = 'application/octet-stream' }
                $response.StatusCode = 200
                $response.ContentType = $type
                $response.Headers['Cache-Control'] = 'no-cache'
                $fs = New-Object IO.FileStream $target, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite)
                try {
                    $size = $fs.Length
                    $response.ContentLength64 = $fs.Length
                    if ($request.HttpMethod -eq 'GET') { $fs.CopyTo($response.OutputStream) }
                }
                finally { $fs.Dispose() }
            }
            else { $code = 404; Send-Bytes $response 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((L 'Introuvable'))) }
        }
        catch { $code = 500; try { $response.StatusCode = 500 } catch { $null = $_ } }
        finally { try { $response.Close() } catch { $null = $_ } }

        $served++
        $color = 'Ok'
        if ($code -ge 500) { $color = 'Err' } elseif ($code -ge 400) { $color = 'Warn' } elseif ($code -ge 300) { $color = 'Accent' }
        Write-Host ('  ' + (Paint (Get-Date -Format 'HH:mm:ss') 'Dim') + '  ' + (Paint ([string]$code) $color -Bold) + '  ' + (Format-PstPad $request.HttpMethod 5) + (Limit-PstText $request.Url.PathAndQuery 60) + (Paint ("  " + (Format-PstSize $size)) 'Dim'))
        if ($MaxRequests -gt 0 -and $served -ge $MaxRequests) { break }
    }
}
finally {
    try { [Console]::TreatControlCAsInput = $false } catch { $null = $_ }
    $listener.Stop()
    $listener.Close()
}
Write-Host ''
Write-PstStatus info (L 'Serveur arrêté {0} {1} requête(s) servie(s).' $g.Dot $served)
Write-Host ''
