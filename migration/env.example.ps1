# Copy this file to env.local.ps1 and fill in the real values.
# env.local.ps1 is gitignored — credentials never go into the repository.

$env:SQLA_UID    = 'dba'
$env:SQLA_PWD    = ''            # source database password
$env:SQLA_DSN    = ''
$env:SQLA_DRIVER = 'SQL Anywhere 16'
$env:SQLA_SERVER = 'PixelSQLbase'
$env:SQLA_DBN    = 'PixelSQLbase'
