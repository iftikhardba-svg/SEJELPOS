# Template. `install.ps1` writes the real one next to this as `env.local.ps1`
# with generated secrets, and that file is gitignored — the same arrangement as
# migration/env.local.ps1.
#
# Never commit env.local.ps1. Anyone holding POS_JWT_SECRET can mint a device
# token for any tenant.

# ---------------------------------------------------------------- database
# PostgreSQL is what a server runs. Row Level Security is what keeps one
# customer out of another's sales, and SQLite has no such thing — on SQLite the
# isolation tests do not fail, they *skip*, which is worse.
$env:POS_DATABASE_URL = 'postgresql+asyncpg://pos_app:CHANGE-ME@127.0.0.1:5432/pos'

# ----------------------------------------------------------------- secrets
# At least 32 bytes. The service refuses to start on PostgreSQL with the
# built-in development secret, deliberately: it is published in the source.
$env:POS_JWT_SECRET = 'CHANGE-ME'

# Provisioning over the API (creating enrolment codes). At least 24 characters.
# Leave it unset to switch API provisioning off entirely — the back office does
# not need it; it has its own per-tenant login.
$env:POS_ADMIN_TOKEN = 'CHANGE-ME'

# A separate login with BYPASSRLS, for the two jobs the application role cannot
# do: pg_dump (which refuses rather than write a dump with every tenant's rows
# filtered out) and provisioning a new customer (creating a tenant has no tenant
# context for a policy to check). The service must never use this URL.
$env:POS_ADMIN_DATABASE_URL = 'postgresql://pos_app_admin:CHANGE-ME@127.0.0.1:5432/pos'

# ------------------------------------------------------------------ listen
# 0.0.0.0 so tablets on the LAN can reach it. Put a reverse proxy with TLS in
# front before anything leaves the building — see README.md, "Going to
# production".
$env:POS_BIND = '0.0.0.0'
$env:POS_PORT = '8100'

# One worker is right for a single restaurant. Raise it when a branch's tablets
# make the CPU the limit, not before — every worker is a separate process with
# its own connection pool.
$env:POS_WORKERS = '1'
