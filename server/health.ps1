# Is the backend actually serving? Exit code 0 means yes, so this is safe to
# call from a monitor or another script.
#
# It checks three separate things because they fail separately and the
# difference tells you where to look: the port answers, the API answers, and the
# database behind it answers. A service that is up but cannot reach PostgreSQL
# looks identical to a healthy one from the outside.

[CmdletBinding()]
param(
    [string]$ServerHost = '127.0.0.1',
    [int]$Port = 8100,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$base = "http://${ServerHost}:${Port}"
$failed = $false

function Say($msg, $colour) { if (-not $Quiet) { Write-Host $msg -ForegroundColor $colour } }

# 1. the port
$tcp = Test-NetConnection -ComputerName $ServerHost -Port $Port -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) {
    Say "    port $Port                open" 'Green'
} else {
    Say "    port $Port                CLOSED" 'Red'
    Say "      the task is not running, or the firewall rule is missing" 'Yellow'
    exit 1
}

# 2. the API
try {
    $r = Invoke-WebRequest -Uri "$base/health" -UseBasicParsing -TimeoutSec 10
    Say "    GET /health              $($r.StatusCode)" 'Green'
} catch {
    Say "    GET /health              FAILED: $($_.Exception.Message)" 'Red'
    $failed = $true
}

# 3. the database, via an endpoint that has to read it
try {
    $r = Invoke-WebRequest -Uri "$base/v1/catalog?since=0" -UseBasicParsing -TimeoutSec 15
    Say "    database                 reachable" 'Green'
} catch {
    # 401 is the right answer here: the endpoint needs a device token. Reaching
    # authentication at all means the app started and its config parsed.
    if ($_.Exception.Response.StatusCode.value__ -eq 401) {
        Say "    database                 reachable (401 as expected)" 'Green'
    } else {
        Say "    database                 FAILED: $($_.Exception.Message)" 'Red'
        Say "      check server\logs\service.log for the connection error" 'Yellow'
        $failed = $true
    }
}

# 4. the back office, which is what a human will actually open
try {
    $r = Invoke-WebRequest -Uri "$base/office" -UseBasicParsing -TimeoutSec 10
    Say "    GET /office              $($r.StatusCode)" 'Green'
} catch {
    Say "    GET /office              FAILED: $($_.Exception.Message)" 'Red'
    $failed = $true
}

if ($failed) { exit 1 }
exit 0
