[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.McpClient.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zotero-mcp-client-test-" + [guid]::NewGuid().ToString("N")
)
$profileRoot = Join-Path $tempRoot "Zotero\Zotero\Profiles\fake.default"
$prefsPath = Join-Path $profileRoot "prefs.js"
$oldAppData = $env:APPDATA
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

try {
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    [IO.File]::WriteAllText(
        $prefsPath,
        'user_pref("extensions.zotero.codexZoteroMcpBearerToken", "secret-token");',
        [Text.UTF8Encoding]::new($false)
    )
    $env:APPDATA = $tempRoot
    $module = Import-Module -Name $modulePath -Force -PassThru
    $captured = $null
    $transport = {
        param($Request, $BearerToken, $Endpoint)
        $script:captured = [pscustomobject]@{
            request = $Request
            token = $BearerToken
            endpoint = $Endpoint
        }
        '{"jsonrpc":"2.0","id":1,"result":{"isError":false}}'
    }
    $result = & $module {
        param($Adapter)
        Invoke-LlmForZoteroMcp `
            -ToolName "zotero_script" `
            -Arguments ([pscustomobject]@{ script = "return 1" }) `
            -TransportAdapter $Adapter
    } $transport
    Assert-True ($result.result.isError -eq $false) "the client should return a parsed RPC object"
    Assert-True ($captured.request.method -eq "tools/call") "the client should send tools/call"
    Assert-True ($captured.request.params.name -eq "zotero_script") "the tool name should be preserved"
    Assert-True ($captured.request.params.arguments.script -eq "return 1") "arguments should stay object-valued"
    Assert-True ($captured.token -eq "secret-token") "the active profile token should reach only the transport"
    Assert-True ($captured.endpoint -match "^http://127\.0\.0\.1") "the default endpoint should stay loopback"

    $invalidEndpointFailed = $false
    try {
        & $module {
            Invoke-LlmForZoteroMcp `
                -ToolName "zotero_script" `
                -Arguments @{} `
                -Endpoint "https://example.com/llm-for-zotero/mcp" `
                -TransportAdapter { "{}" }
        }
    }
    catch {
        $invalidEndpointFailed = $true
    }
    Assert-True $invalidEndpointFailed "non-loopback endpoints must be rejected before transport"

    $invalidJsonFailed = $false
    try {
        & $module {
            Invoke-LlmForZoteroMcp `
                -ToolName "zotero_script" `
                -Arguments @{} `
                -TransportAdapter { "not-json" }
        }
    }
    catch {
        $invalidJsonFailed = $_.Exception.Message -eq "llm-for-zotero MCP returned invalid JSON"
    }
    Assert-True $invalidJsonFailed "invalid transport JSON should fail without echoing credentials"
    Write-Output "All $passed MCP-client assertions passed."
}
finally {
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
