# Runs the POS backend. This is what the Windows scheduled task starts at boot,
# and it is also the right way to start it by hand while watching the output.
#
# It supervises rather than just launching: uvicorn exiting is not the same as
# being told to stop, and a restaurant mid-service needs the service back, not
# an operator reading an event log. Repeated instant failures back off instead
# of spinning — a bad password does not get better by being retried 900 times a
# minute, and the log has to stay readable enough to show why.

[CmdletBinding()]
param(
    # Run once and return the exit code, instead of supervising. Use this when
    # you want to see a configuration error immediately.
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here          # ...\newpos
$log  = Join-Path $here 'logs'

if (-not (Test-Path $log)) { New-Item -ItemType Directory -Path $log | Out-Null }

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Output $line
    Add-Content -Path (Join-Path $log 'service.log') -Value $line -Encoding utf8
}

$envFile = Join-Path $here 'env.local.ps1'
if (-not (Test-Path $envFile)) {
    Write-Log "FATAL: $envFile not found. Run install.ps1 first."
    exit 2
}
. $envFile

$python = Join-Path $here '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    Write-Log "FATAL: $python not found. Run install.ps1 first."
    exit 2
}

$bind    = if ($env:POS_BIND)    { $env:POS_BIND }    else { '0.0.0.0' }
$port    = if ($env:POS_PORT)    { $env:POS_PORT }    else { '8100' }
$workers = if ($env:POS_WORKERS) { $env:POS_WORKERS } else { '1' }

$uvicornArgs = @(
    '-m', 'uvicorn', 'app.main:app',
    '--host', $bind,
    '--port', $port,
    '--workers', $workers,
    # Uvicorn's own access log goes to stdout, which the task redirects to a
    # file. Keep it: "which device pushed what, when" is the first question
    # asked when a till says it synced and the back office disagrees.
    '--log-level', 'info'
)

$backend = Join-Path $root 'backend'
Push-Location $backend
try {
    if ($Once) {
        Write-Log "starting once on ${bind}:${port} (workers=$workers)"
        & $python @uvicornArgs
        exit $LASTEXITCODE
    }

    $fastFailures = 0
    while ($true) {
        Write-Log "starting on ${bind}:${port} (workers=$workers)"
        $startedAt = Get-Date
        & $python @uvicornArgs
        $code = $LASTEXITCODE
        $ranFor = (Get-Date) - $startedAt

        # Under a minute means it did not really run — a bad connection string,
        # a port already taken, a refused configuration. Anything longer was a
        # working service that fell over, and deserves an immediate restart.
        if ($ranFor.TotalSeconds -lt 60) {
            $fastFailures++
        } else {
            $fastFailures = 0
        }

        $delay = [Math]::Min(300, [Math]::Pow(2, [Math]::Min($fastFailures, 8)))
        Write-Log ("exited with $code after {0:N0}s; restarting in {1:N0}s (consecutive fast failures: $fastFailures)" -f $ranFor.TotalSeconds, $delay)
        Start-Sleep -Seconds $delay
    }
} finally {
    Pop-Location
}
