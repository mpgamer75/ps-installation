# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — assistant IA multi-fournisseurs
#  Chargée après PsTools.ps1 par « ask », « pst » et l'installeur.
#
#  Deux protocoles couvrent tous les fournisseurs :
#    - anthropic : API Messages d'Anthropic (Claude)
#    - openai    : API « chat/completions », reprise par OpenAI, Gemini, Mistral,
#                  Groq, DeepSeek, xAI, OpenRouter, Ollama, LM Studio...
#  Chaque requête est journalisée (jetons, coût, durée) dans usage.jsonl.
# ─────────────────────────────────────────────────────────────────────────────

# Tarifs standard en dollars US par million de jetons (entrée / sortie), relevés
# sur les pages officielles le 2026-11-20. Ils évoluent : « ask -Setup » permet de
# saisir un prix, et les prix connus d'OpenRouter sont lus en direct.
#   Long*  : tarif appliqué à toute la requête au-delà de LongAbove jetons d'entrée
#   Next   : changement de prix annoncé, appliqué automatiquement à partir de From
#   Peak   : tarif aux heures de pointe (DeepSeek)
$script:PstAiPricesDate = '2026-11-20'
$script:PstAiProviders = [ordered]@{
    anthropic  = @{
        Label = 'Anthropic Claude'; Hint = 'recommandé'; Protocol = 'anthropic'; BaseUrl = 'https://api.anthropic.com'
        EnvVar = 'ANTHROPIC_API_KEY'; KeyUrl = 'https://platform.claude.com/'; KeyRequired = $true; Default = 'claude-opus-5-5'
        Models = @(
            @{ Id = 'claude-opus-5-5'; Label = 'Claude Opus 5.5'; Note = 'excellent équilibre'; In = 4; Out = 20 }
            @{ Id = 'claude-sonnet-5-5'; Label = 'Claude Sonnet 5.5'; Note = 'rapide et économique'; In = 2; Out = 10 }
            @{ Id = 'claude-haiku-5-5'; Label = 'Claude Haiku 5.5'; Note = 'le plus rapide'; In = 0.10; Out = 0.50; LongAbove = 100000; LongIn = 0.50; LongOut = 2.50 }
            @{ Id = 'claude-fable-5-2'; Label = 'Claude Fable 5.2'; Note = 'le plus capable'; In = 8; Out = 40 }
            @{ Id = 'claude-opus-4-8'; Label = 'Claude Opus 4.8'; Hidden = $true; In = 5; Out = 25 }
        )
    }
    openai     = @{
        Label = 'OpenAI'; Hint = 'GPT'; Protocol = 'openai'; BaseUrl = 'https://api.openai.com/v1'
        EnvVar = 'OPENAI_API_KEY'; KeyUrl = 'https://platform.openai.com/api-keys'; KeyRequired = $true; Default = 'gpt-6.2-sol'; Reasoning = $true
        Models = @(
            @{ Id = 'gpt-6.2-sol'; Label = 'GPT-6.2 Sol'; Note = 'équilibré'; In = 2; Out = 10; LongAbove = 272000; LongIn = 4; LongOut = 15 }
            @{ Id = 'gpt-6.2-astra'; Label = 'GPT-6.2 Astra'; Note = 'le plus capable'; In = 8; Out = 40; LongAbove = 272000; LongIn = 16; LongOut = 60 }
            @{ Id = 'gpt-6.1-terra'; Label = 'GPT-6.1 Terra'; Note = 'rapide'; In = 1; Out = 5; LongAbove = 272000; LongIn = 2; LongOut = 7.5 }
            @{ Id = 'gpt-6-luna'; Label = 'GPT-6 Luna'; Note = 'très économique'; In = 0.10; Out = 0.50; LongAbove = 272000; LongIn = 0.20; LongOut = 0.75 }
            @{ Id = 'gpt-5.4-mini'; Label = 'GPT-5.4 mini'; In = 0.75; Out = 4.50 }
            @{ Id = 'gpt-5-nano'; Label = 'GPT-5 nano'; In = 0.05; Out = 0.40 }
        )
    }
    gemini     = @{
        Label = 'Google Gemini'; Hint = 'offre gratuite disponible'; Protocol = 'openai'; BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai'
        EnvVar = 'GEMINI_API_KEY'; KeyUrl = 'https://aistudio.google.com/apikey'; KeyRequired = $true; Default = 'gemini-4-hydrogen'
        Models = @(
            @{ Id = 'gemini-4-hydrogen'; Label = 'Gemini 4 Hydrogen'; Note = 'équilibré'; In = 1.5; Out = 7.5 }
            @{ Id = 'gemini-4-neon'; Label = 'Gemini 4 Neon'; Note = 'le plus capable'; In = 3; Out = 15 }
            @{ Id = 'gemini-4-carbon'; Label = 'Gemini 4 Carbon'; In = 2; Out = 10; Next = @{ From = '2026-12-01'; In = 4; Out = 20 } }
            @{ Id = 'gemini-3.8-flash'; Label = 'Gemini 3.8 Flash'; Note = 'rapide'; In = 0.75; Out = 3.75; Next = @{ From = '2027-01-01'; In = 1.5; Out = 7.5 } }
            @{ Id = 'gemini-3.5-flash-lite'; Label = 'Gemini 3.5 Flash-Lite'; Note = 'très économique'; In = 0.30; Out = 2.50 }
        )
    }
    mistral    = @{
        Label = 'Mistral AI'; Hint = 'hébergé en Europe'; Protocol = 'openai'; BaseUrl = 'https://api.mistral.ai/v1'
        EnvVar = 'MISTRAL_API_KEY'; KeyUrl = 'https://console.mistral.ai/api-keys'; KeyRequired = $true; Default = 'mistral-large-4'
        Models = @(
            @{ Id = 'mistral-large-4'; Label = 'Mistral Large 4'; Note = 'le plus capable'; In = 0.70; Out = 2.10 }
            @{ Id = 'mistral-small-2603'; Label = 'Mistral Small 4'; Note = 'rapide'; In = 0.15; Out = 0.60 }
            @{ Id = 'ministral-8b-2512'; Label = 'Ministral 8B'; Note = 'très économique'; In = 0.15; Out = 0.15 }
        )
    }
    groq       = @{
        Label = 'Groq'; Hint = 'réponses quasi instantanées'; Protocol = 'openai'; BaseUrl = 'https://api.groq.com/openai/v1'
        EnvVar = 'GROQ_API_KEY'; KeyUrl = 'https://console.groq.com/keys'; KeyRequired = $true; Default = 'openai/gpt-oss-120b'
        Models = @(
            @{ Id = 'openai/gpt-oss-120b'; Label = 'GPT-OSS 120B'; Note = 'équilibré'; In = 0.15; Out = 0.60 }
            @{ Id = 'openai/gpt-oss-20b'; Label = 'GPT-OSS 20B'; Note = 'très économique'; In = 0.075; Out = 0.30 }
            @{ Id = 'qwen/qwen3.8-27b'; Label = 'Qwen 3.8 27B'; Note = 'aperçu'; In = 0.80; Out = 4 }
        )
    }
    deepseek   = @{
        Label = 'DeepSeek'; Hint = 'très économique'; Protocol = 'openai'; BaseUrl = 'https://api.deepseek.com/v1'
        EnvVar = 'DEEPSEEK_API_KEY'; KeyUrl = 'https://platform.deepseek.com/api_keys'; KeyRequired = $true; Default = 'deepseek-flash'
        Models = @(
            @{ Id = 'deepseek-flash'; Label = 'DeepSeek Flash'; Note = 'rapide'; In = 0.15; Out = 0.60; Peak = @{ In = 0.30; Out = 1.20 } }
            @{ Id = 'deepseek-v4-pro'; Label = 'DeepSeek V4 Pro'; Note = 'le plus capable'; In = 0.66; Out = 1.98; Peak = @{ In = 1.32; Out = 3.96 } }
        )
    }
    xai        = @{
        Label = 'xAI Grok'; Hint = ''; Protocol = 'openai'; BaseUrl = 'https://api.x.ai/v1'
        EnvVar = 'XAI_API_KEY'; KeyUrl = 'https://console.x.ai/team/default/api-keys'; KeyRequired = $true; Default = 'grok-4.3'
        Models = @(
            @{ Id = 'grok-4.3'; Label = 'Grok 4.3'; Note = 'équilibré'; In = 1.25; Out = 2.50; LongAbove = 200000; LongIn = 2.50; LongOut = 5 }
            @{ Id = 'grok-4.7'; Label = 'Grok 4.7'; Note = 'le plus capable'; In = 2; Out = 6; LongAbove = 200000; LongIn = 4; LongOut = 12 }
        )
    }
    openrouter = @{
        Label = 'OpenRouter'; Hint = 'des centaines de modèles, une seule clé'; Protocol = 'openai'; BaseUrl = 'https://openrouter.ai/api/v1'
        EnvVar = 'OPENROUTER_API_KEY'; KeyUrl = 'https://openrouter.ai/settings/keys'; KeyRequired = $true; Default = 'anthropic/claude-sonnet-5.5'; LivePrices = $true
        Models = @()
    }
    ollama     = @{
        Label = 'Ollama'; Hint = 'local, gratuit, hors ligne'; Protocol = 'openai'; BaseUrl = 'http://localhost:11434/v1'
        EnvVar = ''; KeyUrl = 'https://ollama.com/download'; KeyRequired = $false; Default = ''; Free = $true
        Models = @()
    }
    custom     = @{
        Label = 'Autre service compatible OpenAI'; Hint = 'LM Studio, vLLM, passerelle d''entreprise...'; Protocol = 'openai'; BaseUrl = ''
        EnvVar = ''; KeyUrl = ''; KeyRequired = $false; Default = ''; Custom = $true
        Models = @()
    }
}

function Get-PstAiProvider {
    param([string]$Id)
    if (-not $Id -or -not $script:PstAiProviders.Contains($Id)) { return $null }
    return $script:PstAiProviders[$Id]
}

function Format-PstMoney {
    # Montant en dollars, avec assez de décimales pour les très petits coûts.
    param([double]$Usd)
    if ($Usd -eq 0) { return '0 $' }
    if ([Math]::Abs($Usd) -lt 0.01) { return ('{0:N4} $' -f $Usd) }
    return ('{0:N2} $' -f $Usd)
}

function Format-PstTokens {
    param([double]$Count)
    if ($Count -ge 1000000) { return ('{0:N1} M' -f ($Count / 1000000)) }
    if ($Count -ge 10000) { return ('{0:N0} k' -f ($Count / 1000)) }
    return ('{0:N0}' -f $Count)
}

# ── Réglages et clés ─────────────────────────────────────────────────────────

function Get-PstAiKey {
    # Clé d'un fournisseur : variable d'environnement, sinon clé enregistrée.
    # Retourne @{ Key; Source }.
    param([string]$Provider)
    $info = Get-PstAiProvider $Provider
    if ($info -and $info.EnvVar) {
        $fromEnv = [Environment]::GetEnvironmentVariable($info.EnvVar)
        if ($fromEnv) { return @{ Key = $fromEnv; Source = "variable $($info.EnvVar)" } }
    }
    $stored = Get-PstSecret "ai.$Provider"
    if ($stored) { return @{ Key = $stored; Source = 'enregistrée (chiffrée pour votre compte)' } }
    if ($Provider -eq 'anthropic') {
        # Clé de la version 2.1 (ask.json), reprise telle quelle.
        $legacy = Read-PstJsonFile (Join-Path (Get-PstDataDir) 'ask.json')
        if ($legacy -is [hashtable] -and $legacy.Key) {
            try {
                $secure = ConvertTo-SecureString -String ([string]$legacy.Key) -ErrorAction Stop
                return @{ Key = (New-Object System.Net.NetworkCredential '', $secure).Password; Source = 'enregistrée (version précédente)' }
            }
            catch { $null = $_ }
        }
    }
    return @{ Key = $null; Source = '' }
}

function Get-PstAiSettings {
    # Fournisseur et modèle actifs, avec reprise des réglages de la version 2.1.
    $config = Get-PstConfig
    $ai = $config.ai
    if (-not $ai.provider) {
        $legacy = Read-PstJsonFile (Join-Path (Get-PstDataDir) 'ask.json')
        $ai.provider = 'anthropic'
        if ($legacy -is [hashtable]) {
            if ($legacy.Model) { $ai.model = [string]$legacy.Model }
            if ($legacy.Effort) { $ai.effort = [string]$legacy.Effort }
        }
        else {
            # Sans configuration : premier fournisseur dont la clé est déjà dans l'environnement.
            foreach ($id in $script:PstAiProviders.Keys) {
                $p = $script:PstAiProviders[$id]
                if ($p.EnvVar -and [Environment]::GetEnvironmentVariable($p.EnvVar)) { $ai.provider = $id; break }
            }
        }
    }
    $provider = Get-PstAiProvider $ai.provider
    if (-not $provider) { $ai.provider = 'anthropic'; $provider = Get-PstAiProvider 'anthropic' }
    if (-not $ai.model) { $ai.model = $provider.Default }
    $baseUrl = $provider.BaseUrl
    if ($ai.baseUrl -and ($provider.Custom -or $ai.provider -eq 'ollama')) { $baseUrl = [string]$ai.baseUrl }
    if (-not $baseUrl) { $baseUrl = '' }
    return @{
        Provider = [string]$ai.provider; Model = [string]$ai.model; Effort = [string]$ai.effort
        Budget = [double]$ai.budget; BaseUrl = $baseUrl.TrimEnd('/'); Prices = $ai.prices
    }
}

# ── Prix ─────────────────────────────────────────────────────────────────────

function Get-PstAiPrice {
    # Prix applicable à une requête. Retourne @{ In; Out; Known; Free }.
    param([string]$Provider, [string]$Model, [double]$InputTokens = 0, [DateTime]$At = (Get-Date))
    $info = Get-PstAiProvider $Provider
    if ($info -and $info.Free) { return @{ In = 0; Out = 0; Known = $true; Free = $true } }
    $config = Get-PstConfig
    $custom = $config.ai.prices["$Provider/$Model"]
    if ($custom -is [hashtable] -and $null -ne $custom.in) { return @{ In = [double]$custom.in; Out = [double]$custom.out; Known = $true } }
    if ($info) {
        foreach ($m in $info.Models) {
            if ($m.Id -ne $Model) { continue }
            $in = [double]$m.In; $out = [double]$m.Out
            if ($m.Next -and $At -ge [DateTime]::Parse($m.Next.From, [Globalization.CultureInfo]::InvariantCulture)) { $in = [double]$m.Next.In; $out = [double]$m.Next.Out }
            if ($m.Peak) {
                # Heures de pointe DeepSeek : 01h-04h et 06h-10h UTC, du lundi au vendredi.
                $utc = $At.ToUniversalTime()
                $weekday = $utc.DayOfWeek -ne 'Saturday' -and $utc.DayOfWeek -ne 'Sunday'
                if ($weekday -and (($utc.Hour -ge 1 -and $utc.Hour -lt 4) -or ($utc.Hour -ge 6 -and $utc.Hour -lt 10))) { $in = [double]$m.Peak.In; $out = [double]$m.Peak.Out }
            }
            if ($m.LongAbove -and $InputTokens -gt $m.LongAbove) { $in = [double]$m.LongIn; $out = [double]$m.LongOut }
            return @{ In = $in; Out = $out; Known = $true }
        }
    }
    # Prix lus en direct (OpenRouter), mis en cache lors de la configuration.
    $cached = Read-PstJsonFile (Join-Path (Get-PstDataDir) "prices-$Provider.json")
    if ($cached -is [hashtable] -and $cached[$Model] -is [hashtable]) { return @{ In = [double]$cached[$Model].in; Out = [double]$cached[$Model].out; Known = $true } }
    return @{ In = 0; Out = 0; Known = $false }
}

function Get-PstAiCost {
    param($Price, [double]$InputTokens, [double]$OutputTokens)
    return ($InputTokens * $Price.In + $OutputTokens * $Price.Out) / 1000000
}

# ── HTTP ─────────────────────────────────────────────────────────────────────

function Initialize-PstHttp {
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
}

function Get-PstErrorMessage {
    # Extrait le message d'une réponse d'erreur, quel que soit le format du fournisseur.
    param([string]$Raw)
    if (-not $Raw) { return '' }
    try {
        $data = $Raw | ConvertFrom-Json
        if ($data -is [array]) { $data = $data[0] }
        if ($data.error.message) { return [string]$data.error.message }
        if ($data.error -is [string]) { return $data.error }
        if ($data.message) { return [string]$data.message }
        if ($data.detail) { return [string]$data.detail }
    }
    catch { $null = $_ }
    if ($Raw.Length -gt 300) { return $Raw.Substring(0, 300) + '...' }
    return $Raw
}

function Invoke-PstHttp {
    # Requête HTTP. Avec -OnLine, lit la réponse ligne à ligne (flux SSE) au fil de l'eau.
    # Retourne @{ Status; Error; Body }.
    param([string]$Method = 'GET', [string]$Url, [hashtable]$Headers = @{}, [string]$Body, [scriptblock]$OnLine, [hashtable]$Context, [int]$TimeoutSeconds = 600)
    Initialize-PstHttp
    $result = @{ Status = 0; Error = ''; Body = '' }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)), $Url
    foreach ($h in $Headers.Keys) { if ($Headers[$h]) { $request.Headers.TryAddWithoutValidation($h, [string]$Headers[$h]) | Out-Null } }
    if ($Body) { $request.Content = New-Object System.Net.Http.StringContent $Body, ([Text.Encoding]::UTF8), 'application/json' }
    $response = $null; $reader = $null
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $result.Status = [int]$response.StatusCode
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object IO.StreamReader $stream, ([Text.Encoding]::UTF8)
        if (-not $response.IsSuccessStatusCode) {
            $raw = $reader.ReadToEnd()
            $result.Error = Get-PstErrorMessage $raw
            if (-not $result.Error) { $result.Error = "HTTP $($result.Status)" }
            return $result
        }
        if ($OnLine) {
            while ($null -ne ($line = $reader.ReadLine())) {
                & $OnLine $line $Context
                if ($Context.Stop) { break }
            }
        }
        else { $result.Body = $reader.ReadToEnd() }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $result.Error = $inner.Message
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
    return $result
}

function Get-PstAiHeaders {
    param([string]$Provider, [string]$Key)
    $info = Get-PstAiProvider $Provider
    if ($info.Protocol -eq 'anthropic') { return @{ 'x-api-key' = $Key; 'anthropic-version' = '2026-10-21' } }
    $headers = @{}
    if ($Key) { $headers['Authorization'] = "Bearer $Key" }
    if ($Provider -eq 'openrouter') { $headers['HTTP-Referer'] = 'https://github.com/mpgamer75/ps-installation'; $headers['X-Title'] = 'ps-tools' }
    return $headers
}

# ── Modèles disponibles (vérifie aussi la clé) ───────────────────────────────

function Get-PstAiModels {
    # Liste les modèles accessibles avec cette clé. Retourne @{ Ok; Status; Error; Models; Prices }.
    param([string]$Provider, [string]$Key, [string]$BaseUrl)
    $info = Get-PstAiProvider $Provider
    if (-not $BaseUrl) { $BaseUrl = $info.BaseUrl }
    $BaseUrl = $BaseUrl.TrimEnd('/')
    $url = "$BaseUrl/models"
    if ($info.Protocol -eq 'anthropic') { $url = "$BaseUrl/v1/models?limit=100" }
    $response = Invoke-PstHttp -Url $url -Headers (Get-PstAiHeaders $Provider $Key) -TimeoutSeconds 20
    $result = @{ Ok = $false; Status = $response.Status; Error = $response.Error; Models = @(); Prices = @{} }
    if ($response.Error) { return $result }
    try { $data = $response.Body | ConvertFrom-Json } catch { $result.Error = 'réponse illisible'; return $result }
    $items = @()
    if ($data.data) { $items = @($data.data) } elseif ($data.models) { $items = @($data.models) } elseif ($data -is [array]) { $items = @($data) }
    $skip = 'embed|tts|whisper|dall-e|image|audio|realtime|moderation|transcri|speech|search|computer-use|sora|rerank|ocr|guard'
    foreach ($m in $items) {
        $id = [string]$m.id
        if (-not $id) { $id = [string]$m.name }
        $id = $id -replace '^models/', ''
        if (-not $id -or $id -match $skip) { continue }
        $result.Models += $id
        if ($m.pricing -and $null -ne $m.pricing.prompt) {
            # OpenRouter : prix en dollars par jeton, convertis par million.
            try { $result.Prices[$id] = @{ in = [double]$m.pricing.prompt * 1000000; out = [double]$m.pricing.completion * 1000000 } } catch { $null = $_ }
        }
    }
    $result.Models = @($result.Models | Sort-Object -Unique)
    $result.Ok = $true
    return $result
}

# ── Requête ──────────────────────────────────────────────────────────────────

function Invoke-PstAiRequest {
    # Envoie une question et diffuse la réponse via -OnText. Retourne
    # @{ Text; In; Out; Cost; CostKnown; Estimated; Model; StopReason; Error; Status; Ms; Provider }.
    param(
        [string]$Provider, [string]$Model, [string]$System, [string]$User,
        [string]$Effort = 'low', [string]$Key, [string]$BaseUrl, [scriptblock]$OnText
    )
    $info = Get-PstAiProvider $Provider
    if (-not $BaseUrl) { $BaseUrl = $info.BaseUrl }
    $BaseUrl = $BaseUrl.TrimEnd('/')
    $started = [Diagnostics.Stopwatch]::StartNew()
    $ctx = @{ Text = (New-Object System.Text.StringBuilder); In = 0; Out = 0; Cost = $null; Model = $Model; StopReason = ''; Error = ''; Stop = $false; OnText = $OnText }
    $headers = Get-PstAiHeaders $Provider $Key

    if ($info.Protocol -eq 'anthropic') {
        $body = [ordered]@{ model = $Model; max_tokens = 16000; stream = $true; system = $System; messages = @(@{ role = 'user'; content = $User }) }
        if ($Model -match '^claude-(fable|mythos|opus|sonnet|haiku)-5|^claude-opus-4-[5-8]|^claude-sonnet-4-6') { $body.output_config = @{ effort = $Effort } }
        # Repli côté serveur si le modèle décline la demande (modèles qui le prennent en charge).
        if ($Model -match '^claude-(opus-5|fable-5|sonnet-5-5)') { $body.fallbacks = 'default'; $headers['anthropic-beta'] = 'server-side-fallback-2026-07-01' }
        $url = "$BaseUrl/v1/messages"
        $onLine = {
            param($line, $c)
            if (-not $line.StartsWith('data:')) { return }
            try { $evt = $line.Substring(5).Trim() | ConvertFrom-Json } catch { return }
            switch ([string]$evt.type) {
                'message_start' {
                    $u = $evt.message.usage
                    if ($u) { $c.In = [double]$u.input_tokens + [double]$u.cache_read_input_tokens + [double]$u.cache_creation_input_tokens }
                    if ($evt.message.model) { $c.Model = [string]$evt.message.model }
                }
                'content_block_delta' {
                    if ($evt.delta.type -eq 'text_delta') {
                        $chunk = [string]$evt.delta.text
                        [void]$c.Text.Append($chunk)
                        if ($c.OnText) { & $c.OnText $chunk }
                    }
                }
                'message_delta' {
                    if ($evt.delta.stop_reason) { $c.StopReason = [string]$evt.delta.stop_reason }
                    if ($evt.usage.output_tokens) { $c.Out = [double]$evt.usage.output_tokens }
                }
                'error' { $c.Error = [string]$evt.error.message }
            }
        }
    }
    else {
        $body = [ordered]@{
            model = $Model; stream = $true
            messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
            stream_options = @{ include_usage = $true }
        }
        if ($Provider -eq 'openai' -and $Model -match '^(gpt-[5-9]|o\d)') {
            $map = @{ low = 'low'; medium = 'medium'; high = 'high'; xhigh = 'high'; max = 'high' }
            $body.reasoning_effort = $map[$Effort]
        }
        $url = "$BaseUrl/chat/completions"
        $onLine = {
            param($line, $c)
            if (-not $line.StartsWith('data:')) { return }
            $payload = $line.Substring(5).Trim()
            if ($payload -eq '[DONE]') { $c.Stop = $true; return }
            try { $evt = $payload | ConvertFrom-Json } catch { return }
            if ($evt.error) { $c.Error = Get-PstErrorMessage $payload; return }
            if ($evt.model) { $c.Model = [string]$evt.model }
            $choice = @($evt.choices)[0]
            if ($choice) {
                $chunk = $choice.delta.content
                if ($chunk -is [string] -and $chunk) {
                    [void]$c.Text.Append($chunk)
                    if ($c.OnText) { & $c.OnText $chunk }
                }
                switch ([string]$choice.finish_reason) {
                    'length' { $c.StopReason = 'max_tokens' }
                    'content_filter' { $c.StopReason = 'refusal' }
                    { $_ -and -not $c.StopReason } { $c.StopReason = 'end_turn' }
                }
            }
            # Jetons : « usage » (OpenAI, Gemini, DeepSeek, OpenRouter, xAI) ou « x_groq.usage ».
            $u = $evt.usage
            if (-not $u -and $evt.x_groq) { $u = $evt.x_groq.usage }
            if ($u) {
                if ($null -ne $u.prompt_tokens) { $c.In = [double]$u.prompt_tokens }
                if ($null -ne $u.completion_tokens) { $c.Out = [double]$u.completion_tokens }
                if ($null -ne $u.cost) { $c.Cost = [double]$u.cost }
            }
        }
    }

    $status = 0; $errorText = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $json = $body | ConvertTo-Json -Depth 8
        $response = Invoke-PstHttp -Method 'POST' -Url $url -Headers $headers -Body $json -OnLine $onLine -Context $ctx
        $status = $response.Status; $errorText = $response.Error
        if (-not $errorText) { break }
        if ($ctx.Text.Length -gt 0) { break }   # réponse déjà commencée : pas de nouvel essai
        if ($status -eq 400 -and $body.Contains('stream_options') -and $errorText -match 'stream_options|include_usage|unrecognized|unknown') {
            $body.Remove('stream_options'); $attempt--; continue   # service qui refuse cette option
        }
        if (@(408, 429, 500, 502, 503, 504, 529) -notcontains $status) { break }
        Start-Sleep -Seconds (2 * $attempt)
    }
    if (-not $errorText -and $ctx.Error) { $errorText = $ctx.Error }

    $text = $ctx.Text.ToString()
    $estimated = $false
    if (-not $errorText -and $ctx.Out -eq 0 -and $text) {
        # Service muet sur les jetons : estimation (environ 4 caractères par jeton).
        $ctx.In = [Math]::Ceiling(($System.Length + $User.Length) / 4)
        $ctx.Out = [Math]::Ceiling($text.Length / 4)
        $estimated = $true
    }
    $price = Get-PstAiPrice $Provider $ctx.Model $ctx.In
    if (-not $price.Known -and $ctx.Model -ne $Model) { $price = Get-PstAiPrice $Provider $Model $ctx.In }
    $cost = 0.0; $costKnown = $price.Known
    if ($null -ne $ctx.Cost) { $cost = [double]$ctx.Cost; $costKnown = $true }
    elseif ($price.Known) { $cost = Get-PstAiCost $price $ctx.In $ctx.Out }

    return @{
        Text = $text; In = $ctx.In; Out = $ctx.Out; Cost = $cost; CostKnown = $costKnown; Estimated = $estimated
        Model = $ctx.Model; Provider = $Provider; StopReason = $ctx.StopReason; Error = $errorText; Status = $status
        Ms = [int]$started.ElapsedMilliseconds
    }
}

function Get-PstAiErrorHint {
    # Message clair pour une erreur de requête.
    param($Result, [string]$Provider)
    $info = Get-PstAiProvider $Provider
    switch ($Result.Status) {
        401 { return 'Clé d''API refusée. Vérifiez-la avec « ask -Setup ».' }
        403 { return "Accès refusé : $($Result.Error)" }
        404 { return "Modèle ou adresse introuvable ($($Result.Error)). Choisissez un autre modèle avec « ask -Setup »." }
        402 { return "Crédit insuffisant sur le compte $($info.Label) : $($Result.Error)" }
        429 { return 'Limite de requêtes ou de crédit atteinte. Réessayez dans un instant.' }
    }
    if ($Result.Status -ge 500) { return "Le service $($info.Label) est momentanément indisponible ($($Result.Status)). Réessayez dans un instant." }
    if ($Result.Status -eq 0) {
        if ($Provider -eq 'ollama') { return "Ollama ne répond pas ($($Result.Error)). Lancez l'application Ollama ou « ollama serve »." }
        return "Connexion impossible : $($Result.Error)"
    }
    return "Requête refusée ($($Result.Status)) : $($Result.Error)"
}

# ── Journal de consommation ──────────────────────────────────────────────────

function Add-PstAiUsage {
    param($Result, [string]$Source = 'ask')
    $entry = [ordered]@{
        t = (Get-Date).ToString('s'); p = $Result.Provider; m = $Result.Model; i = [int]$Result.In; o = [int]$Result.Out
        c = [Math]::Round([double]$Result.Cost, 6); k = [bool]$Result.CostKnown; e = [bool]$Result.Estimated; ms = $Result.Ms; s = $Source
    }
    $line = ($entry | ConvertTo-Json -Compress) + "`n"
    try { [IO.File]::AppendAllText((Join-Path (Get-PstDataDir) 'usage.jsonl'), $line, (New-Object Text.UTF8Encoding $false)) } catch { $null = $_ }
}

function Get-PstAiUsage {
    $file = Join-Path (Get-PstDataDir) 'usage.jsonl'
    $entries = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $file)) { return , $entries }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if (-not $line.Trim()) { continue }
        try {
            $e = $line | ConvertFrom-Json
            [void]$entries.Add([pscustomobject]@{
                    Time = [DateTime]::Parse($e.t, [Globalization.CultureInfo]::InvariantCulture); Provider = [string]$e.p; Model = [string]$e.m
                    In = [double]$e.i; Out = [double]$e.o; Cost = [double]$e.c; Known = [bool]$e.k; Ms = [double]$e.ms; Source = [string]$e.s
                })
        }
        catch { $null = $_ }
    }
    return , $entries
}

function Measure-PstAiUsage {
    param($Entries)
    $sum = @{ Count = 0; In = 0.0; Out = 0.0; Cost = 0.0; Unknown = 0 }
    foreach ($e in $Entries) {
        $sum.Count++; $sum.In += $e.In; $sum.Out += $e.Out; $sum.Cost += $e.Cost
        if (-not $e.Known) { $sum.Unknown++ }
    }
    return $sum
}

function Get-PstAiMonthCost {
    $start = (Get-Date).Date.AddDays(1 - (Get-Date).Day)
    return (Measure-PstAiUsage @((Get-PstAiUsage) | Where-Object { $_.Time -ge $start })).Cost
}

function Format-PstAiFooter {
    # Ligne de bilan affichée après chaque réponse.
    param($Result, [double]$Budget = 0)
    $g = $script:Pst.Glyph
    $approx = ''
    if ($Result.Estimated) { $approx = '~' }
    $parts = @($Result.Model, ("$approx$(Format-PstTokens $Result.In) $($g.Pointer) $approx$(Format-PstTokens $Result.Out) jetons"))
    if ($Result.CostKnown) { $parts += Format-PstMoney $Result.Cost } else { $parts += 'prix inconnu' }
    $parts += ('{0:N1} s' -f ($Result.Ms / 1000))
    $line = Paint ($g.H * 2 + ' ' + ($parts -join " $($g.Dot) ")) 'Dim'
    if ($Budget -gt 0) {
        $month = Get-PstAiMonthCost
        $pct = $month / $Budget * 100
        $color = 'Dim'
        if ($pct -ge 100) { $color = 'Err' } elseif ($pct -ge 80) { $color = 'Warn' }
        $line += Paint "  $($g.Dot) ce mois : $(Format-PstMoney $month) / $(Format-PstMoney $Budget)" $color
    }
    return $line
}

function Show-PstAiUsage {
    # Tableau de bord de consommation : périodes, modèles, coût par jour, budget.
    $settings = Get-PstAiSettings
    $entries = Get-PstAiUsage
    $width = Get-PstWidth -Max 92
    Show-PstHeader -Tool 'ask' -Subtitle 'consommation'
    if ($entries.Count -eq 0) {
        Write-PstStatus info 'Aucune requête enregistrée pour l''instant. Essayez : ask "bonjour"'
        Write-Host ''
        return
    }
    $now = Get-Date
    $monthStart = $now.Date.AddDays(1 - $now.Day)
    $periods = [ordered]@{
        'Aujourd''hui'      = @($entries | Where-Object { $_.Time -ge $now.Date })
        '7 derniers jours'  = @($entries | Where-Object { $_.Time -ge $now.Date.AddDays(-6) })
        'Ce mois-ci'        = @($entries | Where-Object { $_.Time -ge $monthStart })
        'Depuis le début'   = @($entries)
    }
    $rows = @(); $unknown = $false
    foreach ($name in $periods.Keys) {
        $m = Measure-PstAiUsage $periods[$name]
        if ($m.Unknown) { $unknown = $true }
        $cost = Format-PstMoney $m.Cost
        if ($m.Unknown) { $cost += '*' }
        $rows += , @($name, [string]$m.Count, (Format-PstTokens $m.In), (Format-PstTokens $m.Out), (Paint $cost 'Title' -Bold))
    }
    $lines = Format-PstTable -Columns @(
        @{ Name = 'Période'; Width = 18 }, @{ Name = 'Requêtes'; Width = 9; Right = $true }, @{ Name = 'Entrée'; Width = 9; Right = $true },
        @{ Name = 'Sortie'; Width = 9; Right = $true }, @{ Name = 'Coût'; Width = 12; Right = $true }
    ) -Rows $rows
    $month = Measure-PstAiUsage $periods['Ce mois-ci']
    if ($settings.Budget -gt 0) {
        $pct = $month.Cost / $settings.Budget * 100
        $color = Get-PstLevelColor $pct 80 100
        $lines += ''
        $lines += (Format-PstPad 'Budget mensuel' 18) + (Format-PstBar $pct 24 -Color $color) + ' ' + (Paint ('{0:N0} %' -f $pct) $color -Bold) + (Paint "  $(Format-PstMoney $month.Cost) sur $(Format-PstMoney $settings.Budget)" 'Dim')
    }
    Format-PstBox -Title 'Résumé' -Lines $lines -Width $width | Write-PstLine

    # Coût par jour sur 30 jours
    $days = @()
    for ($d = 29; $d -ge 0; $d--) {
        $day = $now.Date.AddDays(-$d)
        $days += (Measure-PstAiUsage @($entries | Where-Object { $_.Time.Date -eq $day })).Cost
    }
    $peak = ($days | Measure-Object -Maximum).Maximum
    $spark = (Paint (Format-PstSparkline $days -Width 30) 'Accent') + (Paint "   pic : $(Format-PstMoney $peak) / jour" 'Dim')
    Format-PstBox -Title 'Coût par jour (30 jours)' -Lines @($spark) -Width $width | Write-PstLine

    # Par modèle, ce mois-ci
    $byModel = @($periods['Ce mois-ci'] | Group-Object { "$($_.Provider)|$($_.Model)" } | ForEach-Object {
            $m = Measure-PstAiUsage $_.Group
            $parts = $_.Name -split '\|', 2
            [pscustomobject]@{ Provider = $parts[0]; Model = $parts[1]; Stats = $m }
        } | Sort-Object { $_.Stats.Cost } -Descending)
    if ($byModel.Count) {
        $modelWidth = [Math]::Max(12, $width - 56)
        $rows = @()
        foreach ($b in $byModel) {
            $label = $b.Provider
            $p = Get-PstAiProvider $b.Provider
            if ($p) { $label = $p.Label }
            $cost = Format-PstMoney $b.Stats.Cost
            if ($b.Stats.Unknown) { $cost += '*' }
            $modelName = $b.Model
            if (-not $modelName) { $modelName = '?' }
            $rows += , @((Limit-PstText $modelName $modelWidth), (Paint (Limit-PstText $label 16) 'Dim'), [string]$b.Stats.Count, (Format-PstTokens ($b.Stats.In + $b.Stats.Out)), $cost)
        }
        Format-PstBox -Title 'Ce mois-ci, par modèle' -Lines (Format-PstTable -Columns @(
                @{ Name = 'Modèle'; Width = $modelWidth }, @{ Name = 'Fournisseur'; Width = 16 }, @{ Name = 'Req.'; Width = 5; Right = $true },
                @{ Name = 'Jetons'; Width = 8; Right = $true }, @{ Name = 'Coût'; Width = 11; Right = $true }
            ) -Rows $rows) -Width $width | Write-PstLine
    }
    if ($unknown) { Write-Host (Paint '  * certaines requêtes ont un prix inconnu (non compté) : renseignez-le avec « ask -Setup ».' 'Dim') }
    Write-Host (Paint "  Coûts calculés avec les tarifs publics relevés le $($script:PstAiPricesDate) ; votre facture fait foi." 'Dim')
    Write-Host ''
}

# ── Assistant de configuration ───────────────────────────────────────────────

function Invoke-PstAiSetup {
    # Choix du fournisseur, de la clé, du modèle et du budget. N'enregistre rien :
    # retourne les choix (ou $null si l'utilisateur passe) pour Save-PstAiSetup.
    param([string[]]$Steps = @(), [int]$StepIndex = 0, [string]$Caption = 'assistant IA')
    if (-not (Test-PstInteractive)) { return $null }   # la saisie d'une clé demande un terminal
    $g = $script:Pst.Glyph
    $current = Get-PstAiSettings
    $frame = {
        param([string]$Title, [string]$Text = '')
        Show-PstWizardFrame -Steps $Steps -Current $StepIndex -Title $Title -Text $Text -Caption $Caption
    }

    # 1. Fournisseur
    & $frame 'Assistant IA' 'La commande « ask », le raccourci Alt+A et « fix » utilisent l''IA de votre choix. Vous fournissez votre propre clé d''API : la consommation (jetons et coût) est suivie à chaque requête. Aucun envoi n''a lieu sans que vous lanciez une commande.'
    $ids = @($script:PstAiProviders.Keys)
    $labels = @($ids | ForEach-Object { $script:PstAiProviders[$_].Label }) + @('Configurer plus tard')
    $hints = @($ids | ForEach-Object {
            $p = $script:PstAiProviders[$_]
            $h = $p.Hint
            $k = Get-PstAiKey $_
            if ($k.Key) { if ($h) { $h += ' · ' }; $h += 'clé trouvée' }
            $h
        }) + @('« pst setup » à tout moment')
    $default = [Math]::Max(0, [array]::IndexOf($ids, $current.Provider))
    $pick = Read-PstChoice -Title 'Quel fournisseur d''IA ?' -Items $labels -Hints $hints -Default $default
    if ($pick -lt 0) { return 'back' }
    if ($pick -ge $ids.Count) { return $null }
    $providerId = $ids[$pick]
    $provider = $script:PstAiProviders[$providerId]
    $choice = @{ Provider = $providerId; Key = $null; KeyChanged = $false; BaseUrl = ''; Model = ''; Budget = $current.Budget; Price = $null; LivePrices = $null }

    # 2. Adresse (services locaux ou compatibles)
    if ($provider.Custom -or $providerId -eq 'ollama') {
        Write-Host ''
        $defaultUrl = $provider.BaseUrl
        if (-not $defaultUrl) { $defaultUrl = 'http://localhost:1234/v1' }
        if ($current.Provider -eq $providerId -and $current.BaseUrl) { $defaultUrl = $current.BaseUrl }
        $choice.BaseUrl = Read-PstText -Prompt 'Adresse de l''API (se termine en général par /v1)' -Default $defaultUrl -Validate { param($v) $v -match '^https?://' } -ErrorMessage 'Adresse attendue, par exemple http://localhost:1234/v1'
    }
    $baseUrl = $provider.BaseUrl
    if ($choice.BaseUrl) { $baseUrl = $choice.BaseUrl }

    # 3. Clé
    $existing = Get-PstAiKey $providerId
    $key = $existing.Key
    if ($provider.KeyRequired -or $provider.Custom) {
        Write-Host ''
        $askKey = $true
        if ($existing.Key) {
            $keep = Read-PstChoice -Title "Une clé $($provider.Label) est déjà disponible ($($existing.Source))." -Items @('L''utiliser', 'En saisir une autre')
            if ($keep -lt 0) { return 'back' }
            $askKey = ($keep -eq 1)
        }
        while ($askKey) {
            if ($provider.KeyUrl) { Write-PstStatus info "Créez une clé sur $($provider.KeyUrl)" }
            $label = 'Collez votre clé d''API (saisie masquée)'
            if (-not $provider.KeyRequired) { $label = 'Clé d''API (Entrée si le service n''en demande pas)' }
            $typed = Read-PstText -Prompt $label -Secret
            if (-not $typed -and $provider.KeyRequired) {
                $retry = Read-PstChoice -Title 'Aucune clé saisie.' -Items @('Réessayer', 'Revenir au choix du fournisseur')
                if ($retry -ne 0) { return 'back' }
                continue
            }
            $key = $typed; $choice.Key = $typed; $choice.KeyChanged = $true
            $askKey = $false
        }
    }

    # 4. Vérification et modèles disponibles
    Write-Host ''
    $live = Show-PstSpinner 'Vérification auprès du service' { Get-PstAiModels -Provider $providerId -Key $key -BaseUrl $baseUrl }
    if ($live.Ok) {
        Write-PstStatus ok "Connexion réussie $($g.Dot) $($live.Models.Count) modèle(s) disponible(s)"
        if ($live.Prices.Count) { $choice.LivePrices = $live.Prices }
    }
    elseif ($live.Status -eq 401 -or $live.Status -eq 403) {
        Write-PstStatus err "Clé refusée par $($provider.Label)."
        $next = Read-PstChoice -Title 'Que faire ?' -Items @('Saisir une autre clé', 'La garder quand même', 'Revenir au choix du fournisseur')
        if ($next -eq 0) { return (Invoke-PstAiSetup -Steps $Steps -StepIndex $StepIndex -Caption $Caption) }
        if ($next -ne 1) { return 'back' }
    }
    else {
        $why = $live.Error
        if ($providerId -eq 'ollama' -and $live.Status -eq 0) { $why = 'Ollama ne répond pas : lancez l''application Ollama' }
        Write-PstStatus warn "Vérification impossible ($why). La configuration sera tout de même enregistrée."
    }

    # 5. Modèle
    Write-Host ''
    $models = @(); $modelLabels = @(); $modelHints = @()
    foreach ($m in $provider.Models) {
        if ($m.Hidden) { continue }
        $models += $m.Id; $modelLabels += $m.Id
        $price = Get-PstAiPrice $providerId $m.Id
        $hint = ('{0} / {1} par M jetons' -f (Format-PstMoney $price.In), (Format-PstMoney $price.Out))
        if ($m.Note) { $hint = "$($m.Note) $($g.Dot) $hint" }
        if ($m.Id -eq $provider.Default) { $hint = "recommandé $($g.Dot) $hint" }
        if ($live.Ok -and $live.Models.Count -and $live.Models -notcontains $m.Id) { $hint += " $($g.Dot) absent de votre compte" }
        $modelHints += $hint
    }
    $extra = @($live.Models | Where-Object { $models -notcontains $_ })
    if ($providerId -eq 'openrouter') {
        # Les plus courants d'abord, puis le reste par ordre alphabétique.
        $preferred = @('anthropic/', 'openai/', 'google/', 'mistralai/', 'deepseek/', 'x-ai/', 'meta-llama/')
        $extra = @($extra | Sort-Object { $id = $_; $rank = 99; for ($i = 0; $i -lt $preferred.Count; $i++) { if ($id.StartsWith($preferred[$i])) { $rank = $i; break } }; '{0:D2}{1}' -f $rank, $id })
    }
    $limit = 25
    foreach ($id in ($extra | Select-Object -First $limit)) {
        $models += $id; $modelLabels += $id
        if ($live.Prices[$id]) { $modelHints += ('{0} / {1} par M jetons' -f (Format-PstMoney $live.Prices[$id].in), (Format-PstMoney $live.Prices[$id].out)) }
        elseif ($provider.Free) { $modelHints += 'gratuit (local)' }
        else { $modelHints += 'prix non référencé' }
    }
    $modelLabels += 'Saisir un autre identifiant...'
    $modelHints += $(if ($extra.Count -gt $limit) { "$($extra.Count - $limit) autre(s) modèle(s) disponibles" } else { '' })
    $defaultModel = $provider.Default
    if ($current.Provider -eq $providerId -and $current.Model) { $defaultModel = $current.Model }
    $index = [Math]::Max(0, [array]::IndexOf($models, $defaultModel))
    if ($models.Count -eq 0) { $index = 0 }
    $pickModel = Read-PstChoice -Title 'Quel modèle utiliser par défaut ?' -Items $modelLabels -Hints $modelHints -Default $index
    if ($pickModel -lt 0) { return 'back' }
    if ($pickModel -lt $models.Count) { $choice.Model = $models[$pickModel] }
    else {
        $choice.Model = Read-PstText -Prompt 'Identifiant du modèle' -Default $defaultModel -Validate { param($v) [bool]$v } -ErrorMessage 'Identifiant requis.'
    }

    # 6. Prix d'un modèle non référencé
    $price = Get-PstAiPrice $providerId $choice.Model
    if (-not $price.Known -and -not ($choice.LivePrices -and $choice.LivePrices[$choice.Model])) {
        Write-Host ''
        Write-PstStatus info 'Prix inconnu pour ce modèle : indiquez-le pour suivre le coût (Entrée pour passer).'
        $number = { param($v) (-not $v) -or ($v -replace ',', '.') -match '^\d+(\.\d+)?$' }
        $in = Read-PstText -Prompt 'Prix entrée, en $ par million de jetons' -Validate $number -ErrorMessage 'Nombre attendu, par exemple 2.5'
        if ($in) {
            $out = Read-PstText -Prompt 'Prix sortie, en $ par million de jetons' -Validate $number -ErrorMessage 'Nombre attendu, par exemple 10'
            if ($out) { $choice.Price = @{ in = [double]($in -replace ',', '.'); out = [double]($out -replace ',', '.') } }
        }
    }

    # 7. Budget
    if (-not $provider.Free) {
        Write-Host ''
        $budgetDefault = ''
        if ($current.Budget -gt 0) { $budgetDefault = [string]$current.Budget }
        $budget = Read-PstText -Prompt 'Budget mensuel en $ (alerte quand il approche ; Entrée = aucun, 0 = retirer)' -Default $budgetDefault -Validate { param($v) (-not $v) -or ($v -replace ',', '.') -match '^\d+(\.\d+)?$' } -ErrorMessage 'Montant attendu, par exemple 10'
        if ($budget) { $choice.Budget = [double]($budget -replace ',', '.') }
    }
    return $choice
}

function Save-PstAiSetup {
    # Enregistre les choix de Invoke-PstAiSetup.
    param([hashtable]$Choice)
    if (-not $Choice) { return }
    $config = Get-PstConfig
    $config.ai.provider = $Choice.Provider
    $config.ai.model = $Choice.Model
    $config.ai.budget = $Choice.Budget
    $config.ai.baseUrl = $Choice.BaseUrl
    if ($Choice.Price) { $config.ai.prices["$($Choice.Provider)/$($Choice.Model)"] = $Choice.Price }
    Save-PstConfig $config
    if ($Choice.KeyChanged) { Set-PstSecret "ai.$($Choice.Provider)" $Choice.Key }
    if ($Choice.LivePrices) { Write-PstJsonFile (Join-Path (Get-PstDataDir) "prices-$($Choice.Provider).json") $Choice.LivePrices }
}

function Test-PstAiSetup {
    # Petite requête de test, avec affichage de la réponse, des jetons et du coût.
    $settings = Get-PstAiSettings
    $key = (Get-PstAiKey $settings.Provider).Key
    Write-Host ''
    Write-Host ('  ' + (Paint 'Test : ' 'Dim')) -NoNewline
    $result = Invoke-PstAiRequest -Provider $settings.Provider -Model $settings.Model -Key $key -BaseUrl $settings.BaseUrl -Effort 'low' `
        -System 'Réponds en une phrase courte, en français.' -User 'Présente-toi en une phrase et dis que la configuration fonctionne.' `
        -OnText { param($t) Write-Host $t -NoNewline }
    Write-Host ''
    if ($result.Error) { Write-PstStatus err (Get-PstAiErrorHint $result $settings.Provider); return $false }
    Add-PstAiUsage $result 'test'
    Write-Host ('  ' + (Format-PstAiFooter $result $settings.Budget))
    return $true
}
