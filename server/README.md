# Putting the POS on a Windows Server

The backend, PostgreSQL and the back office run on the server. The till, the
kitchen screen and the order board **do not** — they are the Flutter app running
on tablets and counter PCs, and they reach the server over the network. Building
that app still needs a workstation with Flutter and Visual Studio on it; a
server never needs either.

So: **one thing moves to the server — `backend/`, with a database under it.**

---

## What you need first

| | |
|---|---|
| **Windows Server** | 2019 or newer. Windows 10/11 Pro works identically for a demo box. |
| **Python 3.14, 64-bit** | Tick **Add python.exe to PATH** during installation. |
| **PostgreSQL 17** | `winget install PostgreSQL.PostgreSQL.17`. Note the `postgres` password it asks for — the installer needs it once. |
| **A fixed IP or hostname** | Tablets are configured with it. A server whose address moves takes every till with it. |

Not needed on the server: Flutter, Visual Studio, the Android SDK, the 32-bit
ODBC bridge. Those belong on the workstation that builds the app and re-runs
the PixelPoint extract.

---

## Step by step

### 1. Copy the project onto the server

From the handoff archive (`newpos-handoff.zip`), or straight from GitHub if the
server can reach it:

```powershell
git clone -b pos https://github.com/iftikhardba-svg/Demo.git C:\pos\newpos
```

Either way you want `C:\pos\newpos\` containing `backend\`, `server\`,
`migration\` and the rest. If you cloned, also copy `migration\out\` from the
archive — it is the customer's data and is deliberately not in git.

### 2. Run the installer

Elevated PowerShell, from inside `server\`:

```powershell
cd C:\pos\newpos\server
.\install.ps1 -LoadDemoData
```

It asks once for the PostgreSQL `postgres` password, and then does everything
else: a private Python environment, the dependencies, the `pos_app` role and
`pos` database, generated secrets written to `env.local.ps1`, the schema
migrated to head, the customer catalog loaded, a firewall rule, the service
registered to start at boot, and a health check to prove it answers.

**Write down the back-office login it prints at the end.** The password is
generated and stored nowhere.

Leave off `-LoadDemoData` for an empty server. Useful switches:
`-Port`, `-DbName`, `-DbUser`, `-SkipDatabase` (database lives on another
machine), `-SkipService`, `-SkipFirewall`.

### 3. Check it

```powershell
.\health.ps1
```

Four green lines: the port is open, `/health` answers, the database is
reachable, and `/office` loads. Then open the back office from another machine
on the network:

```
http://<server>:8100/office
```

If it loads there but not on the server itself, the firewall rule is the thing
to look at; if the reverse, the tablets will not connect either.

### 4. Point a till at it

On the tablet or counter PC, in the back office: **Devices → new enrolment
code**, choosing the role (`pos`, `kds` or `cds`) and, for a kitchen screen, its
station. Then either type the code into the app's enrolment screen, or from a
workstation:

```powershell
cd C:\projects\newpos\app
dart run tool\enrol_device.dart http://<server>:8100 <code>
```

The device stores the server address, its token and the seller identity, and
from then on it works offline and syncs when it can.

### 5. Turn on backups

```powershell
.\backup.ps1 -Install -Destination \\fileserver\backups\pos
```

Nightly at 02:30: a `pg_dump` plus a copy of `env.local.ps1`, keeping 30 days.

**Point it off the machine.** A backup on the same disk as the database is a
copy, not a backup. And keep the secrets copy — a restored database whose
`POS_JWT_SECRET` has changed has invalidated every device in the branch, and a
device cannot simply be re-enrolled without breaking its ZATCA hash chain.

---

## Running it day to day

```powershell
Start-ScheduledTask   -TaskName 'POS backend'
Stop-ScheduledTask    -TaskName 'POS backend'
Get-ScheduledTaskInfo -TaskName 'POS backend'

Get-Content C:\pos\newpos\server\logs\service.log -Tail 40 -Wait
.\health.ps1
```

To watch it in the foreground while diagnosing something — this is also how you
see a configuration error immediately instead of in the log:

```powershell
Stop-ScheduledTask -TaskName 'POS backend'
.\serve.ps1 -Once
```

### Updating to a new version

```powershell
Stop-ScheduledTask -TaskName 'POS backend'
git -C C:\pos\newpos pull
.\install.ps1 -SkipDatabase
Start-ScheduledTask -TaskName 'POS backend'
.\health.ps1
```

`install.ps1` is idempotent: it reinstalls dependencies, runs any new
migrations, and leaves `env.local.ps1` and its secrets alone. Take a backup
first — `alembic upgrade` is not reversible in general.

---

## Going to production

Everything above gives you a working server on a trusted network. Four things
stand between that and a customer's live branch. None of them are optional, and
the installer deliberately does not guess at any of them.

**1. TLS, and a name.** Right now it serves plain HTTP on 8100, and a device
token crosses the network in a header. On a LAN behind a firewall that is a
considered risk; over the internet it is not defensible. Put a reverse proxy in
front on 443 — IIS with URL Rewrite + ARR, or Caddy, which obtains and renews
its own certificate in one line:

```
pos.yourcompany.sa {
    reverse_proxy 127.0.0.1:8100
}
```

Then close 8100 at the firewall and re-enrol devices against `https://…`. Do
this **before** enrolling, not after: the address is stored on the device.

**2. Secrets that were never on a laptop.** If the server was set up by copying
`env.local.ps1` from somewhere, generate fresh ones. Changing `POS_JWT_SECRET`
invalidates every enrolled device, so it is a thing to do on day zero.

**3. Real customer data, not the demo tenant.** The `-LoadDemoData` tenant is
SEJEL with a generated back-office password. For a live branch, run
`load_backend.py` with that customer's company, branch, VAT number and a
password the owner chooses — and resolve the **68 zero-priced products** first
(back office → Products → "Priced zero"). A product that rings at zero on a live
till is a loss nobody notices until the day's takings are counted.

**4. ZATCA.** Nothing in this project has been validated against ZATCA's
official SDK, and the deployment uses a placeholder CSID. Invoices will be
signed and will look right, and they will not be compliant. Fatoora sandbox
validation, real CSID onboarding, and replacing `FileKeyProvider` — which stores
the signing key as plaintext PEM — all have to happen before a real invoice is
issued to a real customer. See `docs/HANDOFF.md` §10.

Worth doing at the same time, though nothing breaks without them: PostgreSQL on
its own disk with WAL archiving if the branch is busy, and a second worker
(`POS_WORKERS`) only once the CPU is demonstrably the limit.

---

## When it does not work

**The task runs but nothing answers.** Almost always configuration, and
`logs\service.log` says which: a wrong database password, a port already taken,
or the service refusing to start because `POS_JWT_SECRET` is the published
development one. That refusal is deliberate — it is a check in
`backend/app/config.py`, and it only triggers on PostgreSQL, which is the
project's proxy for "this is not a developer's laptop".

**`serve.ps1` restarts in a loop.** It backs off up to five minutes after
repeated failures inside a minute, so the log stays readable. Read the first
failure, not the last.

**A till syncs but the back office shows nothing.** Check the tenant. Enrolment
codes are per-tenant, and a device enrolled against a different one will
push happily into a place nobody is looking at.

**`alembic upgrade` fails on a database somebody built by hand.** `real.db` and
`dev_e2e.db` are outside Alembic — they are created with `create_all` and carry
no version stamp, so they drift silently and cannot be upgraded. A server
database created by `install.ps1` is never in that state; if you inherit one
that is, `backend/tools/sync_dev_schema.py` is the tool.

**Devices cannot reach the server, but a browser can.** The firewall rule the
installer adds covers the Private and Domain profiles only. A network Windows
has decided is Public will be blocked — change the network's profile rather
than opening the Public one.
