# Installs the POS backend on a Windows Server. Run it once, from an elevated
# PowerShell, with the repository already copied onto the machine:
#
#     cd C:\pos\newpos\server
#     .\install.ps1
#
# It is idempotent — running it again repairs rather than duplicates. Every step
# can be skipped, because on a second server you often want only some of them.
#
# What it deliberately does NOT do: obtain a TLS certificate or configure a
# reverse proxy. That needs a hostname somebody owns and a decision about which
# proxy, and a script that guessed would produce a service that looks encrypted
# and is not. README.md, "Going to production", covers it.

[CmdletBinding()]
param(
    [string]$DbName = 'pos',
    [string]$DbUser = 'pos_app',
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 5432,
    [int]$Port = 8100,

    # Only needed when Python is somewhere the search below will not look.
    [string]$PythonExe,

    # The PostgreSQL superuser password, used once to create the role and
    # database. Prompted for if omitted; never written anywhere.
    [string]$PostgresPassword,

    # The application role's own password. Normally generated — supply it when
    # the role already exists (a re-run after env.local.ps1 was lost, or a
    # database somebody else provisioned), or for an unattended install.
    [string]$DbPassword,

    # Load the migrated customer catalog so the server has something to show.
    # Needs migration\out\transformed.json (it is in the handoff archive).
    [switch]$LoadDemoData,

    [switch]$SkipDatabase,
    [switch]$SkipService,
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$backend = Join-Path $root 'backend'

function Step($n) { Write-Host "`n=== $n" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Note($m) { Write-Host "    $m" -ForegroundColor Yellow }

# Runs an external program and fails on its exit code, not on its chatter.
#
# Windows PowerShell turns anything a native program writes to stderr into an
# error record, and under $ErrorActionPreference = 'Stop' that aborts the script.
# Plenty of well-behaved tools log to stderr on a completely successful run —
# alembic announces every migration there, pip warns about versions — so without
# this, a normal install stops on its own progress messages. Exit code is the
# only thing that actually says whether a program succeeded.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$What,
        [switch]$Quiet
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # ForEach-Object flattens the error records back into plain strings
        # before anything can treat them as failures.
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $Quiet) { $out | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray } }
    if ($code -ne 0) {
        if ($Quiet) { $out | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray } }
        throw "$What failed (exit $code)."
    }
    return $out
}

# A secret nobody chose and nobody has to remember. Base64url so it can sit in a
# connection string and a header without escaping.
function New-Secret([int]$bytes) {
    $b = New-Object byte[] $bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b)
    ([Convert]::ToBase64String($b)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

# ---------------------------------------------------------------- 0. checks
Step '0. Checking the machine'

$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not ($SkipService -and $SkipFirewall)) {
    throw "Run this from an elevated PowerShell. Creating the service and the firewall rule both need it (or pass -SkipService -SkipFirewall)."
}

if (-not (Test-Path (Join-Path $backend 'requirements.txt'))) {
    throw "$backend does not look like this project. Copy the whole repository, then run install.ps1 from inside its server\ folder."
}

# Finding Python on Windows is not "is it on PATH". `python` there is usually
# the Microsoft Store alias — a stub that prints an advert for the Store and
# exits — and it is on PATH for every user by default, so a naive check passes
# and then everything after it fails strangely. Try the real candidates in order
# and make each one prove it is an interpreter.
function Resolve-Python {
    $candidates = @()
    if ($PythonExe) { $candidates += $PythonExe }

    # The py launcher is the reliable one when it exists: it knows about every
    # installation on the machine and is never a Store stub.
    $launcher = (Get-Command py -ErrorAction SilentlyContinue).Source
    if ($launcher) {
        $fromLauncher = & $launcher -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $fromLauncher) { $candidates += $fromLauncher.Trim() }
    }

    foreach ($c in (Get-Command python, python3 -ErrorAction SilentlyContinue)) {
        $candidates += $c.Source
    }

    $candidates += Get-ChildItem -Path @(
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:LOCALAPPDATA\Python",
        'C:\Python*',
        'C:\Program Files\Python*'
    ) -Filter 'python.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }

    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        # The Store stub lives under WindowsApps and is a zero-byte reparse
        # point. Skipping by path is not enough — the version probe below is
        # what actually settles it — but it keeps the error messages honest.
        if ($c -like '*\WindowsApps\*') { continue }
        if (-not (Test-Path $c)) { continue }
        $v = & $c -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $v) { continue }
        if ([version]$v -lt [version]'3.12') { continue }
        $bits = & $c -c "import struct; print(struct.calcsize('P') * 8)" 2>$null
        if ($bits.Trim() -ne '64') { continue }
        return [pscustomobject]@{ Path = $c; Version = $v.Trim() }
    }
    return $null
}

$py = Resolve-Python
if (-not $py) {
    throw @"
No usable Python found.

This needs a real 64-bit Python 3.12 or newer. If typing 'python' opens the
Microsoft Store, that is the alias stub, not an interpreter — install Python
from python.org (tick 'Add python.exe to PATH'), or turn the alias off under
Settings > Apps > Advanced app settings > App execution aliases.

Already have one somewhere unusual? Pass it:
    .\install.ps1 -PythonExe 'C:\Python314\python.exe'
"@
}
Ok "Python $($py.Version) at $($py.Path)"

# ------------------------------------------------------------ 1. virtualenv
Step '1. Python environment'

$venv = Join-Path $here '.venv'
$vpy = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $vpy)) {
    # Its own environment, not the machine's Python. A server that also runs
    # somebody's script must not be able to change what this service imports.
    Invoke-Native -Exe $py.Path -Arguments @('-m', 'venv', $venv) -What 'creating the virtual environment' -Quiet | Out-Null
    Ok "created $venv"
} else {
    Ok "reusing $venv"
}

Invoke-Native -Exe $vpy -Arguments @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip') -What 'upgrading pip' -Quiet | Out-Null
Invoke-Native -Exe $vpy -Arguments @('-m', 'pip', 'install', '--quiet', '-r', (Join-Path $backend 'requirements.txt')) -What 'pip install' -Quiet | Out-Null
Ok "dependencies installed from backend\requirements.txt"

# -------------------------------------------------------------- 2. database
Step '2. PostgreSQL'

# Decided before anything is created, because it changes what step 2 may do to
# existing roles: a kept env.local.ps1 holds passwords that must keep working.
$envFile = Join-Path $here 'env.local.ps1'
$envExists = Test-Path $envFile

# Read the parameter once, here, while it still holds what the caller passed.
# See the note in step 2 about case-insensitive variable names.
$suppliedPassword = $DbPassword

$psql = $null
if (-not $SkipDatabase) {
    $psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
    if (-not $psql) {
        $found = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending |
                 ForEach-Object { Join-Path $_.FullName 'bin\psql.exe' } |
                 Where-Object { Test-Path $_ } |
                 Select-Object -First 1
        $psql = $found
    }
    if (-not $psql) {
        throw "psql not found. Install PostgreSQL 17 (winget install PostgreSQL.PostgreSQL.17), then run this again — or pass -SkipDatabase if the database already exists elsewhere."
    }
    Ok "psql at $psql"

    if (-not $PostgresPassword) {
        $sec = Read-Host "    PostgreSQL 'postgres' superuser password" -AsSecureString
        $PostgresPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }

    # $appPassword, not $dbPassword: PowerShell variable names are
    # case-insensitive, so a local `$dbPassword` IS the `-DbPassword` parameter.
    # Assigning a generated secret to it made every re-run look as though the
    # caller had supplied a password, so the branch below reset the role to a
    # value env.local.ps1 did not have — and the service could no longer log in.
    # It cost an afternoon; do not reintroduce it by renaming this back.
    $appPassword = if ($suppliedPassword) { $suppliedPassword } else { New-Secret 24 }
    $env:PGPASSWORD = $PostgresPassword

    # Idempotent: create only what is missing. A re-run must not reset the
    # password of a role the running service is already using — unless one was
    # passed in, which is how you recover from a lost env.local.ps1.
    $base = @('-h', $DbHost, '-p', "$DbPort", '-U', 'postgres')

    $roleExists = (Invoke-Native -Exe $psql -Arguments ($base + @('-tAc', "SELECT 1 FROM pg_roles WHERE rolname='$DbUser'")) -What 'querying roles' -Quiet) -join ''
    if ($roleExists.Trim() -eq '1' -and $suppliedPassword) {
        Invoke-Native -Exe $psql -Arguments ($base + @('-c', "ALTER ROLE $DbUser PASSWORD '$appPassword'")) -What 'setting the role password' -Quiet | Out-Null
        Note "role $DbUser already existed — password reset to the one supplied"
    } elseif ($roleExists.Trim() -eq '1') {
        Note "role $DbUser already exists — leaving its password alone"
        $appPassword = $null
    } else {
        Invoke-Native -Exe $psql -Arguments ($base + @('-c', "CREATE ROLE $DbUser LOGIN PASSWORD '$appPassword'")) -What "creating the role $DbUser" -Quiet | Out-Null
        Ok "created role $DbUser"
    }

    $dbExists = (Invoke-Native -Exe $psql -Arguments ($base + @('-tAc', "SELECT 1 FROM pg_database WHERE datname='$DbName'")) -What 'querying databases' -Quiet) -join ''
    if ($dbExists.Trim() -eq '1') {
        Note "database $DbName already exists"
    } else {
        Invoke-Native -Exe $psql -Arguments ($base + @('-c', "CREATE DATABASE $DbName OWNER $DbUser")) -What "creating the database $DbName" -Quiet | Out-Null
        Ok "created database $DbName"
    }

    # A role for the two jobs the application role cannot do, both because Row
    # Level Security is doing exactly what it should:
    #
    #  - **Backups.** pg_dump as pos_app refuses to run rather than write a dump
    #    that silently omits every row the policies hide. That refusal is right:
    #    a backup missing all the data looks like a good one until you restore
    #    it.
    #  - **Provisioning a tenant.** Creating a customer has no tenant context to
    #    run under — the tenant is what is being created — so the INSERT into
    #    `company` violates the policy. RLS is meant to stop the *application*
    #    reaching across tenants, not the tool that sets them up.
    #
    # BYPASSRLS is the honest way to say "this one may see every tenant", and
    # keeping it on a separate login means the service itself never can.
    # Membership of pos_app is what lets it touch objects pos_app owns.
    $adminUser = "${DbUser}_admin"
    $adminPassword = New-Secret 24
    $adminExists = (Invoke-Native -Exe $psql -Arguments ($base + @('-tAc', "SELECT 1 FROM pg_roles WHERE rolname='$adminUser'")) -What 'querying roles' -Quiet) -join ''
    if ($adminExists.Trim() -eq '1') {
        if ($envExists) {
            # env.local.ps1 is being kept, and it holds this role's password.
            # Resetting it here would leave the two disagreeing and break every
            # backup from tonight onwards — silently, since nothing reads a
            # backup until it is needed.
            Note "provisioning role $adminUser already exists — leaving its password alone"
            $adminPassword = $null
        } else {
            Invoke-Native -Exe $psql -Arguments ($base + @('-c', "ALTER ROLE $adminUser PASSWORD '$adminPassword'")) -What 'resetting the provisioning role password' -Quiet | Out-Null
            Note "provisioning role $adminUser already existed — password reset (env.local.ps1 is being rewritten)"
        }
    } else {
        Invoke-Native -Exe $psql -Arguments ($base + @('-c', "CREATE ROLE $adminUser LOGIN BYPASSRLS PASSWORD '$adminPassword'")) -What "creating the role $adminUser" -Quiet | Out-Null
        Ok "created role $adminUser (BYPASSRLS, for backups and provisioning)"
    }
    Invoke-Native -Exe $psql -Arguments ($base + @('-c', "GRANT $DbUser TO $adminUser")) -What 'granting membership to the provisioning role' -Quiet | Out-Null

    Remove-Item Env:\PGPASSWORD
} else {
    Note 'skipped'
}

# ---------------------------------------------------------- 3. env.local.ps1
Step '3. Configuration and secrets'

if ($envExists) {
    Note "env.local.ps1 already exists — keeping it, secrets and all"
    Note "delete it and re-run if you want fresh ones (every device must then re-enrol)"
} else {
    if (-not $appPassword) {
        # Either -SkipDatabase, or the role already existed and its password was
        # left alone. Either way this script does not know it and cannot write a
        # connection string without being told.
        if ($suppliedPassword) {
            $appPassword = $suppliedPassword
        } else {
            $appPassword = Read-Host "    password for the $DbUser database role (or re-run with -DbPassword)"
        }
    }
    $jwt = New-Secret 48
    $adminToken = New-Secret 24
    $url = "postgresql+asyncpg://${DbUser}:${appPassword}@${DbHost}:${DbPort}/${DbName}"
    $adminUrl = if ($adminPassword) {
        "postgresql://${DbUser}_admin:${adminPassword}@${DbHost}:${DbPort}/${DbName}"
    } else { '' }

    @"
# Generated by install.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). NOT IN GIT.
# Anyone holding POS_JWT_SECRET can mint a device token for any tenant.
# Changing it invalidates every enrolled device.

`$env:POS_DATABASE_URL = '$url'
`$env:POS_JWT_SECRET   = '$jwt'
`$env:POS_ADMIN_TOKEN  = '$adminToken'

# The BYPASSRLS role, for backups and for provisioning a new customer. The
# service itself must never use this — it is the one login that can see across
# tenants, which is precisely what Row Level Security exists to prevent.
`$env:POS_ADMIN_DATABASE_URL = '$adminUrl'

`$env:POS_BIND    = '0.0.0.0'
`$env:POS_PORT    = '$Port'
`$env:POS_WORKERS = '1'
"@ | Set-Content -Path $envFile -Encoding utf8

    # Not world-readable: it is a plaintext password file. SYSTEM because the
    # scheduled task runs as SYSTEM and has to read it, Administrators because
    # that is who maintains the server, and whoever is running this installer —
    # without that last one the script locks itself out of the file it just
    # wrote on the very next line, which is exactly what happened the first time.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl $envFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    foreach ($who in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', $me)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $who, 'FullControl', 'Allow')))
    }
    Set-Acl -Path $envFile -AclObject $acl
    Ok "wrote env.local.ps1 with generated secrets (SYSTEM, Administrators, $me)"
}

. $envFile

# ------------------------------------------------------------ 4. migrations
Step '4. Schema'

Push-Location $backend
try {
    Invoke-Native -Exe $vpy -Arguments @('-m', 'alembic', 'upgrade', 'head') -What 'alembic upgrade' -Quiet | Out-Null
    Ok 'schema is at head (tables, CHECK constraints and the RLS policies)'
} finally { Pop-Location }

# ------------------------------------------------------------- 5. demo data
if ($LoadDemoData) {
    Step '5. Demo catalog'
    $json = Join-Path $root 'migration\out\transformed.json'
    if (-not (Test-Path $json)) {
        Note "migration\out\transformed.json not found — skipping."
        Note "It is in the handoff archive under local-data\migration-out\."
    } else {
        # Loaded as the BYPASSRLS role, not the application role. Creating a
        # customer means inserting the tenant it would be scoped to, so there is
        # no tenant context for a policy to check and pos_app is refused. The
        # loader has only ever been run against SQLite, where RLS does not
        # exist, which is why this had never come up.
        if (-not $env:POS_ADMIN_DATABASE_URL) {
            throw "POS_ADMIN_DATABASE_URL is not set. Delete env.local.ps1 and re-run so the provisioning role is created, or load the catalog by hand."
        }
        $loadUrl = $env:POS_ADMIN_DATABASE_URL -replace '^postgresql://', 'postgresql+asyncpg://'

        $officePassword = New-Secret 12
        Push-Location (Join-Path $root 'migration')
        try {
            Invoke-Native -Exe $vpy -What 'load_backend.py' -Quiet -Arguments @(
                'load_backend.py', '--in', 'out/transformed.json',
                '--database-url', $loadUrl,
                '--tenant-slug', 'sejel', '--company', 'SEJEL Restaurant',
                '--branch', 'Olaya', '--branch-code', 'OLYA',
                '--vat-number', '310000000000003',
                '--office-email', 'owner@sejel.sa',
                '--office-password', $officePassword
            ) | Out-Null
            Ok 'catalog loaded (560 products, 64 screens, 34 sale types, the floor)'
            Note "back office login:  owner@sejel.sa  /  $officePassword"
            Note "write that down now — it is not stored anywhere."
        } finally { Pop-Location }
    }
}

# -------------------------------------------------------------- 6. firewall
if (-not $SkipFirewall) {
    Step '6. Firewall'
    $ruleName = "POS backend $Port"
    if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
        Note 'rule already present'
    } else {
        # Private and Domain only. A POS backend has no business answering the
        # public profile; when it needs to be reachable from outside, that goes
        # through a reverse proxy on 443, not this port.
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Private,Domain | Out-Null
        Ok "opened TCP $Port on the Private and Domain profiles"
    }
}

# --------------------------------------------------------------- 7. service
if (-not $SkipService) {
    Step '7. Service'
    & (Join-Path $here 'service-install.ps1') -Start
}

# ----------------------------------------------------------------- 8. proof
Step '8. Checking it answers'
if ($SkipService) {
    Note 'nothing to check — the service was skipped, so nothing is listening yet.'
    Note "start it in the foreground with:  .\serve.ps1 -Once"
} else {
    # The service was only just asked to start. Give it long enough to bind
    # before deciding it has failed.
    $ok = $false
    foreach ($attempt in 1..10) {
        Start-Sleep -Seconds 3
        & (Join-Path $here 'health.ps1') -Port $Port -Quiet
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    }
    & (Join-Path $here 'health.ps1') -Port $Port
    if (-not $ok) {
        Note 'not answering yet. server\logs\service.log will say why.'
    }
}

Write-Host @"

Done.

  Back office     http://<this-server>:$Port/office
  API docs        http://<this-server>:$Port/docs
  Logs            $here\logs\
  Configuration   $here\env.local.ps1   (secrets — back this up somewhere safe)

Next: set up nightly backups (backup.ps1 -Install), and read
README.md > "Going to production" before any customer tablet connects.
"@ -ForegroundColor Cyan
