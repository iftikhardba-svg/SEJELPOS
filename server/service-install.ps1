# Registers the backend as a Windows scheduled task that starts at boot and
# stays up.
#
# Why a scheduled task and not a real service: uvicorn is a Python process, and
# Windows services must speak the Service Control Manager protocol, so a real
# service needs a wrapper — NSSM or WinSW — which is another binary to download,
# license-check and keep patched on a customer's machine. A task with an
# AtStartup trigger, SYSTEM principal, no time limit and RestartCount gets the
# same three properties that matter: it starts without anyone logged in, it
# restarts if it dies, and it is managed with built-in tools. serve.ps1 does the
# per-crash supervision; this handles the case where the supervisor itself dies.
#
# If you would rather have a true service, NSSM works well:
#     nssm install PosBackend "<server>\.venv\Scripts\python.exe"
#     nssm set PosBackend AppDirectory "<repo>\backend"
# and everything else here still applies.

[CmdletBinding()]
param(
    [string]$TaskName = 'POS backend',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$serve = Join-Path $here 'serve.ps1'
$logs = Join-Path $here 'logs'

if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Path $logs | Out-Null }

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$serve`"" `
    -WorkingDirectory $here

$trigger = New-ScheduledTaskTrigger -AtStartup

# SYSTEM, because the service must run with nobody logged in. It reads
# env.local.ps1, which install.ps1 has already restricted to Administrators and
# SYSTEM.
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "    replaced the existing task" -ForegroundColor Yellow
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'POS sync backend (FastAPI/uvicorn). Supervised by server\serve.ps1.' | Out-Null

Write-Host "    registered scheduled task '$TaskName' (starts at boot, as SYSTEM)" -ForegroundColor Green

if ($Start) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "    started" -ForegroundColor Green
}

Write-Host @"

    Managing it:
      Start-ScheduledTask   -TaskName '$TaskName'
      Stop-ScheduledTask    -TaskName '$TaskName'
      Get-ScheduledTaskInfo -TaskName '$TaskName'
      Get-Content '$logs\service.log' -Tail 40 -Wait
"@
