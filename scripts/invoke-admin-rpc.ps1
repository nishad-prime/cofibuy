param(
    [string]$Project = 'hcvszabgtoeiinfuyoqn',
    [string]$Email = $env:COFIBUY_ADMIN_EMAIL,
    [string]$Password = $env:COFIBUY_ADMIN_PASSWORD,
    [Parameter(Mandatory = $true)]
    [string]$BodyFile,
    [string]$Function = 'admin_upsert_link',
    [string]$MatchSlug
)

# The owner sign-in is read from the environment, never from a literal. A password
# in this file would be committed: `.gitignore` covers `.env*` but not `scripts/`,
# so one `git add .` would put a live owner credential into history permanently.
#
#   $env:COFIBUY_ADMIN_EMAIL    = 'you@example.com'
#   $env:COFIBUY_ADMIN_PASSWORD = '...'
#
# The auth password is not the database password. `npm run db:push` wants the
# latter, as SUPABASE_DB_PASSWORD.

# Signs in as the owner and calls a security-definer admin RPC with that token.
#
# This exists because Windows PowerShell 5.1 cannot post these payloads with
# Invoke-RestMethod: it sends a string body using the system codepage, so the
# Bangla copy in the content becomes invalid UTF-8. PostgREST then fails to
# parse the body as JSON and reports a misleading PGRST202 instead of the real
# error. HttpClient with an explicit UTF-8 StringContent avoids that.
#
# -MatchSlug injects the existing row's id into `p_link` before posting. The
# upsert functions only reach their `on conflict (id)` branch when an id is
# present; without one they try to INSERT and collide on the unique slug.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$anonKey = $null
foreach ($line in (Get-Content (Join-Path $PSScriptRoot '..\.env.local'))) {
    if ($line -like 'VITE_SUPABASE_ANON_KEY=*') { $anonKey = $line.Split('=', 2)[1].Trim() }
}
if (-not $anonKey) { throw 'VITE_SUPABASE_ANON_KEY not found in .env.local' }

$client = New-Object System.Net.Http.HttpClient

function Invoke-Json {
    param($Method, $Uri, $Headers, $Content)

    $request = New-Object System.Net.Http.HttpRequestMessage($Method, $Uri)
    foreach ($entry in $Headers.GetEnumerator()) {
        [void]$request.Headers.TryAddWithoutValidation($entry.Key, $entry.Value)
    }
    if ($null -ne $Content) { $request.Content = $Content }

    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $response.IsSuccessStatusCode) {
        # Keep failures short: these payloads are large and the interesting part
        # is the status plus the first line of the error.
        $detail = if ($text.Length -gt 400) { $text.Substring(0, 400) + '...' } else { $text }
        throw "HTTP $([int]$response.StatusCode) on $Uri`n$detail"
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($Email) -or [string]::IsNullOrWhiteSpace($Password)) {
    throw 'COFIBUY_ADMIN_EMAIL and COFIBUY_ADMIN_PASSWORD must be set in the environment'
}

try {
    $login = Invoke-Json 'Post' "https://$Project.supabase.co/auth/v1/token?grant_type=password" `
        @{ apikey = $anonKey } `
        (New-Object System.Net.Http.StringContent(
            (@{ email = $Email; password = $Password } | ConvertTo-Json),
            [System.Text.Encoding]::UTF8, 'application/json'))

    $rpcHeaders = @{
        apikey           = $anonKey
        Authorization    = "Bearer $($login.access_token)"
        'Content-Profile' = 'api'
    }

    $invokeRpc = {
        param($Name, $Body)

        # PostgREST matches on the exact argument list, so a zero-argument
        # function must be called with no body at all; `{}` reads as one unknown
        # argument.
        $content = if ([string]::IsNullOrWhiteSpace($Body)) {
            $null
        } else {
            New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
        }

        Invoke-Json 'Post' "https://$Project.supabase.co/rest/v1/rpc/$Name" $rpcHeaders $content
    }

    # ReadAllText with an explicit UTF-8 decoder, not Get-Content: Windows
    # PowerShell 5.1 defaults Get-Content to the ANSI code page, which silently
    # corrupts the Bangla copy in this payload before it is ever posted.
    $body = [System.IO.File]::ReadAllText($BodyFile, [System.Text.Encoding]::UTF8)

    if ($MatchSlug) {
        $existing = & $invokeRpc 'admin_links' $null
        $match = $existing | Where-Object { $_.slug -eq $MatchSlug } | Select-Object -First 1
        if (-not $match) { throw "no existing link with slug '$MatchSlug'" }

        $payload = $body | ConvertFrom-Json
        $payload.p_link | Add-Member -NotePropertyName id -NotePropertyValue $match.id -Force
        $body = $payload | ConvertTo-Json -Depth 10 -Compress
    }

    $result = & $invokeRpc $Function $body
    if ($null -eq $result) {
        Write-Output "$Function returned no content"
    } else {
        $result | ConvertTo-Json -Depth 3 -Compress | Write-Output
    }
} finally {
    $client.Dispose()
}