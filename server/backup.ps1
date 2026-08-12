# Backs up the database and the secrets.
#
# Both, because they are useless apart. A restored database whose POS_JWT_SECRET
# has changed has invalidated every enrolled device in the branch, and a device
# cannot simply be re-enrolled without breaking its ZATCA hash chain — its
# invoices are signed under an identity the chain has to keep describing. Losing
# env.local.ps1 is therefore closer to losing the database than it looks.
#
#     .\backup.ps1              run once now
#     .\backup.ps1 -Install     schedule it nightly at 02:30
#
# Off-machine is your job. A backup on the same disk as the thing it backs up is
# a copy, not a backup — put $Destination on a share or sync it to storage.

[CmdletBinding()]
param(
    [string]$Destination,
    [int]$KeepDays = 30,
    [switch]$Install,
    [string]$TaskName = 'POS backend backup'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Destination) { $Destination = Join-Path $here 'backups' }

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Destination `"$Destination`" -KeepDays $KeepDays" `
        -WorkingDirectory $here
    $trigger = New-ScheduledTaskTrigger -Daily -At 2:30am
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Description 'Nightly pg_dump of the POS database plus its secrets.' | Out-Null
    Write-Host "Scheduled nightly at 02:30, writing to $Destination" -ForegroundColor Green
    Write-Host "Point -Destination at a share or synced folder; the same disk is not a backup." -ForegroundColor Yellow
    return
}

$envFile = Join-Path $here 'env.local.ps1'
if (-not (Test-Path $envFile)) { throw "$envFile not found." }
. $envFile

if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$out = Join-Path $Destination $stamp
New-Item -ItemType Directory -Path $out | Out-Null

# --- the database ---------------------------------------------------------
# postgresql+asyncpg://user:pass@host:port/db
if ($env:POS_DATABASE_URL -notmatch '^postgresql') {
    # A SQLite deployment is a demo, but a demo people rely on is still worth
    # copying, and VACUUM INTO is the only way to copy one that is being written.
    $path = $env:POS_DATABASE_URL -replace '^.*:///', ''
    $vpy = Join-Path $here '.venv\Scripts\python.exe'
    & $vpy -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('VACUUM INTO ?',(sys.argv[2],))" `
        $path (Join-Path $out 'database.db')
    Write-Host "SQLite snapshot -> $out\database.db" -ForegroundColor Green
} else {
    # POS_ADMIN_DATABASE_URL, not POS_DATABASE_URL. The application role is
    # subject to Row Level Security, and pg_dump refuses to run under it rather
    # than produce a dump with every tenant's rows silently filtered out.
    # install.ps1 creates a BYPASSRLS role for exactly this.
    $dbUrl = if ($env:POS_ADMIN_DATABASE_URL) { $env:POS_ADMIN_DATABASE_URL } else {
        Write-Host "POS_ADMIN_DATABASE_URL is not set — falling back to POS_DATABASE_URL." -ForegroundColor Yellow
        Write-Host "If pg_dump fails with 'query would be affected by row-level security policy'," -ForegroundColor Yellow
        Write-Host "re-run install.ps1 to create the backup role." -ForegroundColor Yellow
        $env:POS_DATABASE_URL
    }

    if ($dbUrl -notmatch '://([^:]+):([^@]+)@([^:/]+):?(\d*)/(.+)$') {
        throw "could not read the database URL."
    }
    $u = $Matches[1]; $p = $Matches[2]; $h = $Matches[3]
    $prt = if ($Matches[4]) { $Matches[4] } else { '5432' }
    $db = $Matches[5]

    $pgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue).Source
    if (-not $pgDump) {
        $pgDump = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending |
                  ForEach-Object { Join-Path $_.FullName 'bin\pg_dump.exe' } |
                  Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $pgDump) { throw "pg_dump not found." }

    $env:PGPASSWORD = $p
    # Custom format: compressed, and restorable table by table, which is what
    # you want at 3am when only one thing needs putting back.
    #
    # The output is read through ForEach-Object because Windows PowerShell turns
    # a native program's stderr into error records, and pg_dump reports progress
    # there on a completely successful run. Exit code is the thing that says
    # whether it worked.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $dumpOut = & $pgDump -h $h -p $prt -U $u -d $db -Fc -f (Join-Path $out 'database.dump') 2>&1 |
                   ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        $dumpOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        throw "pg_dump failed with $code"
    }
    $size = [math]::Round((Get-Item (Join-Path $out 'database.dump')).Length / 1KB)
    Write-Host "pg_dump -> $out\database.dump  ($size KB)" -ForegroundColor Green
}

# --- the secrets ----------------------------------------------------------
Copy-Item $envFile (Join-Path $out 'env.local.ps1')
Write-Host "secrets  -> $out\env.local.ps1" -ForegroundColor Green

# --- retention ------------------------------------------------------------
$cutoff = (Get-Date).AddDays(-$KeepDays)
Get-ChildItem $Destination -Directory |
    Where-Object { $_.CreationTime -lt $cutoff } |
    ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
        Write-Host "removed old backup $($_.Name)" -ForegroundColor DarkGray
    }

Write-Host "`nRestore:  pg_restore -h <host> -U <user> -d <db> --clean database.dump" -ForegroundColor Cyan
