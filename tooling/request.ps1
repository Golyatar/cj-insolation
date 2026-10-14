param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('instances', 'status', 'reload', 'check', 'raycast', 'geometry_test', 'inspect', 'entities', 'selection', 'select', 'create', 'edit', 'move', 'delete', 'save', 'stop')]
    [string]$Command,
    [string]$InstanceId,
    [string]$ArgsJson = '{}',
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$bridgeQueue = Join-Path $PSScriptRoot 'runtime\instances'
if ($Command -eq 'instances') {
    $instances = @(Get-ChildItem -LiteralPath $bridgeQueue -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Join-Path $_.FullName 'session.json'
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    })
    if ($instances.Count -eq 0) { '[]' } else { $instances | ConvertTo-Json -Depth 8 }
    return
}
if (-not $InstanceId -or $InstanceId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'Pass -InstanceId returned by the instances command.'
}
$bridgeQueue = Join-Path $bridgeQueue $InstanceId
$sessionPath = Join-Path $bridgeQueue 'session.json'
if (-not (Test-Path -LiteralPath $sessionPath)) {
    throw 'Bridge is not loaded. See tooling/README.md.'
}
$bridgeSession = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $bridgeSession.running) { throw 'Bridge is stopped.' }
if (([DateTimeOffset]::UtcNow - [DateTimeOffset]$bridgeSession.updated_at).TotalSeconds -gt 10) {
    throw 'Bridge heartbeat is stale. SketchUp may be closed, busy, or blocked by a dialog.'
}
$bridgeArgs = ConvertFrom-Json -InputObject $ArgsJson
if ($null -eq $bridgeArgs -or $bridgeArgs -isnot [pscustomobject]) { throw 'ArgsJson must be a JSON object.' }
$requestId = [Guid]::NewGuid().ToString()
$requestPath = Join-Path $bridgeQueue "$requestId.request.json"
$responsePath = Join-Path $bridgeQueue "$requestId.response.json"
$expiryTime = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$requestData = [ordered]@{
    protocol = 1
    id = $requestId
    session_id = $bridgeSession.session_id
    expires_at = $expiryTime.ToString('o')
    command = $Command
    args = $bridgeArgs
}
$utf8Plain = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$requestPath.tmp", ($requestData | ConvertTo-Json -Depth 16), $utf8Plain)
Move-Item -LiteralPath "$requestPath.tmp" -Destination $requestPath
while ([DateTimeOffset]::UtcNow -lt $expiryTime) {
    if (Test-Path -LiteralPath $responsePath) {
        $responseText = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8
        $responseData = $responseText | ConvertFrom-Json
        if ($responseData.id -ne $requestId -or $responseData.session_id -ne $bridgeSession.session_id) {
            throw 'Response identity mismatch.'
        }
        $responseText
        if (-not $responseData.ok) { throw 'SketchUp command failed; see error in JSON response.' }
        if ($responseData.result.PSObject.Properties.Name -contains 'passed' -and -not $responseData.result.passed) {
            throw 'SketchUp tests completed with failures; see checks in JSON response.'
        }
        return
    }
    Start-Sleep -Milliseconds 100
}
throw "Timed out. Request: $requestId. Check its response before retrying a command with side effects; an already started command may still finish."
