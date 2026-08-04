# Run the full PixelPoint -> new POS catalog migration.
#
#   .\run.ps1                      # migrate into out\pos_test.db
#   .\run.ps1 -Db C:\tmp\pos.db    # somewhere else
#
# Extraction needs 32-bit Python (the SQL Anywhere ODBC driver here is 32-bit
# only); everything after that runs on the normal 64-bit interpreter.

param(
    [string]$Db      = "$PSScriptRoot\out\pos_test.db",
    [string]$Tenant  = '11111111-1111-4111-8111-111111111111',
    [string]$Company = '22222222-2222-4222-8222-222222222222',
    [string]$Branch  = '33333333-3333-4333-8333-333333333333',
    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'

$py32 = 'C:\Users\user\AppData\Local\Python\pythoncore-3.14-32\python.exe'
$py64 = 'C:\Users\user\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$out  = Join-Path $PSScriptRoot 'out'
$schema = Join-Path $PSScriptRoot '..\docs\sqlite_schema.sql'

New-Item -ItemType Directory -Force $out | Out-Null

# Source credentials come from a local env file that stays OUT of version
# control (it is gitignored). Copy env.example.ps1 to env.local.ps1 and fill
# it in. Hardcoding the password here once put it a `git push` away from
# being public.
$envFile = Join-Path $PSScriptRoot 'env.local.ps1'
if (-not (Test-Path $envFile)) {
    throw "missing $envFile - copy env.example.ps1 to env.local.ps1 and set the source DB credentials"
}
. $envFile
if (-not $env:SQLA_UID -or -not $env:SQLA_PWD) {
    throw "env.local.ps1 must set SQLA_UID and SQLA_PWD"
}

Write-Host "`n[1/4] extract  (32-bit Python)" -ForegroundColor Cyan
& $py32 "$PSScriptRoot\extract.py" --out "$out\extracted.json"
if ($LASTEXITCODE -ne 0) { throw "extract failed" }

Write-Host "`n[2/4] transform" -ForegroundColor Cyan
& $py64 "$PSScriptRoot\transform.py" --in "$out\extracted.json" --out "$out\transformed.json" `
    --tenant $Tenant --company $Company --branch $Branch
if ($LASTEXITCODE -ne 0) { throw "transform failed" }

Write-Host "`n[3/4] load" -ForegroundColor Cyan
if ($Fresh -and (Test-Path $Db)) { Remove-Item $Db }
& $py64 "$PSScriptRoot\load_sqlite.py" --in "$out\transformed.json" --db $Db --schema $schema
if ($LASTEXITCODE -ne 0) { throw "load failed" }

Write-Host "`n[4/4] verify" -ForegroundColor Cyan
& $py64 "$PSScriptRoot\verify.py" --extract "$out\extracted.json" --db $Db
if ($LASTEXITCODE -ne 0) { throw "VERIFICATION FAILED - do not use this database" }

Write-Host "`ndone -> $Db" -ForegroundColor Green
