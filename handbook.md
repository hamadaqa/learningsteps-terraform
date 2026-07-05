# LearningSteps Lockdown — Walkthrough

A five-day hands-on walkthrough. Each day, you harden one layer of a
shared web application (LearningSteps: a FastAPI + PostgreSQL app deployed on
Azure via Terraform). By the end of the week, the app is protected end to
end: locked-down management access, encrypted traffic with a web application
firewall, identity-based authentication, an isolated database, and automated
attack detection and response.

Deploy the environment once at the start of the week:

```
python3 deploy.py --password <db-password> --prefix <your-name> --location westeurope
```

This provisions the VM, database, networking, and monitoring stack, and
installs the baseline software used across the week (NPMplus, CrowdSec,
oauth2-proxy). **Wait time: 10-15 minutes** — a good point to start the
day's lecture content while it finishes.

`deploy.py` generates a fresh SSH key pair in the project folder on first
run (`.learningsteps_key` / `.learningsteps_key.pub`). It isn't checked
into git; each person running this gets their own. `deploy.py` itself uses
this key for its own automated setup steps, but every SSH/SCP command *you*
run by hand in this handbook uses the Entra ID identity from Day 1 instead
(via `az ssh config`) — not this key.

**On Windows**: run `python deploy.py` (not `python3`). For the rest of
this handbook, commands are shown in Bash — a PowerShell version is given
wherever the syntax actually differs (variable assignment/interpolation,
JSON body escaping). Where no PowerShell version is shown, either the
command has no shell-specific syntax at all, or it's a multi-line command
split only for readability with a trailing `\` — in PowerShell, replace
each trailing `\` with a backtick `` ` ``, or just join it onto one line;
the command itself is identical either way. Two universal gotchas: in
PowerShell, plain `curl` is aliased to `Invoke-WebRequest` (doesn't support
the same flags — always call `curl.exe` explicitly, as this handbook's
PowerShell blocks do); and any command shown running **on the VM** over
SSH is always a Linux Bash shell regardless of your own machine's OS — no
translation needed there.

---

## Day 1 — Locking Down Management Access

**Goal**: replace static SSH keys with identity-based login, and restrict
network access to your VM's management port.

Right now, anything on the internet can attempt to brute-force SSH on your
VM. Today you close that door two ways: authenticate with your Entra ID
identity instead of a key file, and restrict the network path to a trusted
IP entirely.

### Demo 1 — Entra ID SSH Login

Two of the three prerequisites for Entra ID SSH are already done for you —
`vm.tf` provisions the VM with a system-assigned managed identity
(`identity { type = "SystemAssigned" }`) and installs the
`AADSSHLoginForLinux` extension as part of `terraform apply`. Verify
either if you want to see it rather than take it on faith:
```
az vm identity show --resource-group <rg> --name <vm-name>
az vm extension list --resource-group <rg> --vm-name <vm-name> -o table
```
The one prerequisite that's genuinely *not* automated is the RBAC role —
being Owner (or even Contributor) on the subscription is **not** enough to
log into the VM's OS, since Azure separates managing cloud infrastructure
from logging into a machine. You have to grant that explicitly.

1. Grant yourself the **Virtual Machine Administrator Login** role, scoped
   to the VM resource (not the subscription):
   ```bash
   VM_ID=$(az vm show --resource-group <rg> --name <vm-name> --query id -o tsv)
   az role assignment create --assignee <your-email> \
     --role "Virtual Machine Administrator Login" --scope "$VM_ID"
   ```
   ```powershell
   $VM_ID = az vm show --resource-group <rg> --name <vm-name> --query id -o tsv
   az role assignment create --assignee <your-email> `
     --role "Virtual Machine Administrator Login" --scope $VM_ID
   ```
   This itself requires Owner or User Access Administrator on the
   subscription — if you don't have that, ask whoever does to run the
   command above for you.
2. Confirm the assignment landed — note the explicit `--scope` pointing at
   the VM; without it, `az role assignment list` silently returns an empty
   list even when the role is correctly assigned:
   ```bash
   az role assignment list --assignee <your-email> \
     --role "Virtual Machine Administrator Login" --scope "$VM_ID"
   ```
   ```powershell
   az role assignment list --assignee <your-email> `
     --role "Virtual Machine Administrator Login" --scope $VM_ID
   ```
3. Log in with Entra ID — no key file involved:
   ```
   az ssh vm --resource-group <rg> --name <vm-name>
   ```

**Note**: the app itself is running on the VM (`127.0.0.1:8000`) but has no
public entry point at all yet — that's Day 2's job. You won't be able to
reach it from outside the VM until then.

### Demo 2 — Restrict SSH to a Trusted IP

Open `network.tf` and restrict the `allow-ssh` rule's
`source_address_prefix` from `"*"` to your own IP:
```
curl -s -4 ifconfig.me
```
The `-4` matters: on a dual-stack machine, plain `ifconfig.me` can return
your IPv6 address, but the VM's public IP is IPv4-only — an IPv6 source
prefix silently locks you out of SSH once applied.
Update the rule, then `terraform apply` (**wait time: under a minute**). The
change takes effect immediately — a connection from any other IP will now
be refused.

### Troubleshooting

- **`az ssh` fails with "AuthorizationFailed"**: the role-assignment
  command in Demo 1 itself failed silently, or was run without Owner/User
  Access Administrator — see step 1 above.
- **`az ssh` connection times out**: this is Demo 2's NSG restriction, not
  RBAC — check your current IP still matches the `allow-ssh` rule.

---

## Day 2 — Encryption and a Web Application Firewall

**Goal**: stand up the app's public entry point, encrypt all traffic to it,
and add a web application firewall that blocks known attack patterns before
anything else gets layered on top.

The app currently has no public entry point at all. Today you create one,
close the "plaintext" gap with real TLS, and add a WAF that blocks SQL
injection and XSS payloads before they reach the application.

**Already done for you**: Docker, NPMplus, and CrowdSec are all installed
and running by the time you start Day 2 — `deploy.py` runs
`scripts/setup-npmplus.sh` over SSH right after `terraform apply`. Nothing
is *wired up* yet (no Proxy Host, no TLS, WAF disabled) — that's today's
work — but the software itself doesn't need installing. Verify it's there:
```
ssh -F azssh_config <vm-ip> "sudo docker ps"
```
You should see `npmplus` and `crowdsec` containers already running.

### Demo 1 — Confirm the App Is Alive, But Not Exposed

Yesterday's SSH lockdown means you already have an identity-verified
channel to the VM — reuse it to confirm the app itself is fine, without
exposing anything publicly yet:
```bash
az ssh config --resource-group <rg> --name <vm-name> --file azssh_config
ssh -F azssh_config -L 8000:localhost:8000 <vm-ip>
```
```powershell
az ssh config --resource-group <rg> --name <vm-name> --file azssh_config
ssh -F azssh_config -L 8000:localhost:8000 <vm-ip>
```
Then, in another terminal (or your browser): `curl.exe http://localhost:8000/entries`
(plain `curl` on macOS/Linux). You should see the seeded journal entries as
JSON. This confirms the app deployed and is running correctly — it's just
not reachable from the internet yet, because nothing routes to it. That's
what the rest of today fixes.

### Demo 2 — Access the NPMplus Admin Panel

Open an SSH tunnel to the NPMplus admin panel (its GUI is deliberately not
exposed to the internet — same principle as Day 1's SSH lockdown). Keep
using the Entra ID identity from Day 1 rather than dropping back to the
static key — `az ssh vm` itself doesn't support `-L`, but `az ssh config`
generates an SSH config file wired to your ephemeral Entra certificate,
which a plain `ssh -F` can then tunnel through:
```
az ssh config --resource-group <rg> --name <vm-name> --file azssh_config
ssh -F azssh_config -L 8081:localhost:81 <vm-ip>
```
Browse to `https://localhost:8081` and log in.

(The static key still exists — `deploy.py` uses it for its own automated
SSH calls — but there's no reason to fall back to it for anything a human
runs interactively.)

### Demo 3 — Create the Proxy Host

Create a Proxy Host for the app: domain = your VM's FQDN, forward to
`127.0.0.1:8000`. Leave TLS off for now — that's the next demo.

Via API instead of the GUI:
```bash
curl -sk -c npm.cookies -X POST https://localhost:8081/api/tokens \
  -H "Content-Type: application/json" \
  -d '{"identity":"admin@learningsteps.local","secret":"LearningSteps123!"}'

curl -sk -X POST https://localhost:8081/api/nginx/proxy-hosts \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"domain_names":["<domain>"],"forward_scheme":"http","forward_host":"127.0.0.1","forward_port":8000,"locations":[]}'
```
The `"locations": []` field must be included explicitly — omitting it
breaks the Auth Request step you'll wire up on Day 3.

### Demo 4 — Confirm the Unencrypted Gap

Request the app over plain HTTP and note the response is fully readable in
transit — an open port is not the same thing as an encrypted connection:
```
curl -i "http://<domain>/entries"
```

### Demo 5 — Enable Real TLS

In the NPMplus GUI, open the Proxy Host's SSL tab, choose "Request a new SSL
Certificate," select Let's Encrypt, and save. NPMplus handles the
domain-verification challenge and certificate storage automatically.
**Wait time: well under a minute** for issuance. Confirm:
```
curl -i https://<domain>/entries
```
returns a valid, browser-trusted certificate, and that plain HTTP now
redirects to HTTPS.

Via API instead:
```bash
CERT_ID=$(curl -sk -X POST https://localhost:8081/api/nginx/certificates \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"provider":"letsencrypt","domain_names":["<domain>"],"meta":{"dns_challenge":false}}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

curl -sk -X PUT https://localhost:8081/api/nginx/proxy-hosts/<id> \
  -b npm.cookies -H "Content-Type: application/json" \
  -d "{\"certificate_id\":$CERT_ID,\"ssl_forced\":true}"
```
```powershell
$CERT_ID = curl.exe -sk -X POST https://localhost:8081/api/nginx/certificates `
  -b npm.cookies -H "Content-Type: application/json" `
  -d '{"provider":"letsencrypt","domain_names":["<domain>"],"meta":{"dns_challenge":false}}' `
  | python -c "import sys,json;print(json.load(sys.stdin)['id'])"

curl.exe -sk -X PUT https://localhost:8081/api/nginx/proxy-hosts/<id> `
  -b npm.cookies -H "Content-Type: application/json" `
  -d ('{"certificate_id":' + $CERT_ID + ',"ssl_forced":true}')
```

### Demo 6 — Enable the Web Application Firewall

First show the gap: send known attack payloads and note they pass straight
through:
```
curl -i "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
curl -i "https://<domain>/entries?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

Enable the WAF (CrowdSec, running the OWASP Core Rule Set). `azureuser`
isn't in the `docker` group, so this needs `sudo`:
```
sudo docker exec crowdsec cscli bouncers add npmplus
```
This prints an API key — it's shown exactly once and not retrievable
afterward, so copy it now. Paste that same value into `API_KEY` below:
```
sudo nano /opt/npmplus/crowdsec/crowdsec.conf
#   ENABLED=true
#   API_URL=http://127.0.0.1:8080
#   APPSEC_URL=http://127.0.0.1:7422
#   API_KEY=<the key cscli just printed>
cd /opt/npmplus && sudo docker compose restart npmplus
```
**Wait time: 1-2 minutes** for the container restart.

Re-send the same payloads — both now return `403`, no authentication needed
(there's no identity gate in front of the app yet — that's Day 3). Inspect
the block with:
```
sudo docker exec crowdsec cscli alerts list
```

**Worth flagging**: CrowdSec shares detected attack signals with its
community threat-intel blocklist by default. Check `cscli console status`,
and `cscli console disable` to opt out — a "read the fine print on security
tools" moment regardless of which way you decide to leave it.

**Keep this test in mind for Day 3** — once you layer an identity gate in
front of the app, re-running these exact payloads unauthenticated no longer
returns `403`. That's not a WAF regression; it's a lesson in defense-in-depth
ordering, covered explicitly in Day 3.

### Troubleshooting

- **NPMplus's own admin panel starts returning 403s after enabling the
  WAF**: the WAF protects the entire proxy instance, including NPMplus's own
  admin interface, and the SSH tunnel's traffic reaches it as `127.0.0.1` —
  a single anomalous-looking admin request is enough to get that source
  banned. This can recur every time you re-enable the WAF and immediately
  make more admin API calls through the tunnel, not just the first time.
  `sudo docker exec crowdsec cscli decisions list` may not show it (this ban
  can live in the bouncer's local cache rather than CrowdSec's own decision
  store) — the reliable fix, confirmed by testing, is to disable and
  restart:
  ```
  sudo sed -i 's/^ENABLED=.*/ENABLED=false/' /opt/npmplus/crowdsec/crowdsec.conf
  cd /opt/npmplus && sudo docker compose restart npmplus
  ```
  Make your admin changes, then flip it back to `ENABLED=true` and restart
  again.
- **A previously-blocked IP still gets 403'd on a clean request**: after
  enough attack attempts, CrowdSec may issue a longer-lived ban for that IP,
  independent of any single request's content. This is expected — the IP is
  banned outright, not still being flagged request-by-request. Check bans
  and remove your own if you get caught by it while testing:
  ```
  sudo docker exec crowdsec cscli decisions list
  sudo docker exec crowdsec cscli decisions delete --ip <your-ip>
  ```

---

## Day 3 — Identity-Based API Access

**Goal**: require a valid Entra ID identity token before any request reaches
the application, replacing anonymous access to the API.

Anyone who can reach the app right now can read, write, or delete data with
no accountability. Today you put an identity gate in front of it — the same
"static credential vs. identity" upgrade as Day 1, applied to the
application layer instead of SSH. Because TLS is already live from Day 2,
this is also the day you'll complete a real, full interactive browser
login — Entra requires an HTTPS reply URL, which only exists from Day 2
onward.

**Already done for you**: the oauth2-proxy binary and its systemd unit are
already installed on the VM (`scripts/setup-oauth2-proxy.sh`, run by
`deploy.py`) — but the service is deliberately **not started**, since the
whole point of today is filling in real Entra ID credentials rather than
using placeholders. Verify it's installed but idle:
```
ssh -F azssh_config <vm-ip> "systemctl is-active oauth2-proxy"
```
Expect `inactive` (or `failed`) until you complete Demo 2 below — that's
correct, not broken.

### Demo 1 — Register an Entra ID Application

```bash
APP_ID=$(az ad app create --display-name learningsteps-oauth2-proxy \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
az ad app update --id $APP_ID --identifier-uris api://$APP_ID
az ad sp create --id $APP_ID
SECRET=$(az ad app credential reset --id $APP_ID --query password -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```
```powershell
$APP_ID = az ad app create --display-name learningsteps-oauth2-proxy `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
az ad app update --id $APP_ID --identifier-uris "api://$APP_ID"
az ad sp create --id $APP_ID
$SECRET = az ad app credential reset --id $APP_ID --query password -o tsv
$TENANT_ID = az account show --query tenantId -o tsv
```
`az ad app create` only creates the Application object — it does **not**
create a Service Principal, and without one the app can't act as a
sign-in/token audience in this tenant at all (`az ad sp show --id $APP_ID`
404s until you run `az ad sp create`).

Also required — force v2.0-format access tokens for this app:
```bash
OBJECT_ID=$(az ad app show --id $APP_ID --query id -o tsv)
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --body '{"api":{"requestedAccessTokenVersion":2}}'
```
```powershell
$OBJECT_ID = az ad app show --id $APP_ID --query id -o tsv
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" `
  --body '{"api":{"requestedAccessTokenVersion":2}}'
```
Without this, tokens issued for `api://$APP_ID` default to
**v1.0-format** (`"iss": "https://sts.windows.net/<tenant>/"`, `"ver":
"1.0"`). oauth2-proxy is configured with the v2.0 issuer URL
(`https://login.microsoftonline.com/<tenant>/v2.0`) and rejects a v1.0
token outright. This is unrelated to `OAUTH2_PROXY_OIDC_EXTRA_AUDIENCES` or
`SKIP_JWT_BEARER_TOKENS` — both can be configured correctly and the login
in Demo 4 will still fail without this token-version fix.

Also required — expose an API scope, and register the reply URL that
oauth2-proxy will redirect to after login:
```bash
SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --body "{\"api\":{\"oauth2PermissionScopes\":[{\"id\":\"$SCOPE_ID\",\"adminConsentDescription\":\"Access as user\",\"adminConsentDisplayName\":\"access_as_user\",\"isEnabled\":true,\"type\":\"User\",\"userConsentDescription\":\"Access as user\",\"userConsentDisplayName\":\"access_as_user\",\"value\":\"access_as_user\"}]}}"

az ad app update --id $APP_ID --web-redirect-uris "https://<domain>/oauth2/callback"
```
```powershell
$SCOPE_ID = python -c "import uuid; print(uuid.uuid4())"
$body = @{
    api = @{
        oauth2PermissionScopes = @(@{
            id = $SCOPE_ID
            adminConsentDescription = "Access as user"
            adminConsentDisplayName = "access_as_user"
            isEnabled = $true
            type = "User"
            userConsentDescription = "Access as user"
            userConsentDisplayName = "access_as_user"
            value = "access_as_user"
        })
    }
} | ConvertTo-Json -Depth 5
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" --body $body

az ad app update --id $APP_ID --web-redirect-uris "https://<domain>/oauth2/callback"
```
Without an exposed scope, requesting a token for `api://$APP_ID` fails
outright with `AADSTS650057: Invalid resource` — `az ad app create` does
not add one by default. Without the reply URL registered, the real
browser login in Demo 4 fails
with `AADSTS500113: No reply address is registered for the application`.
The reply URL must be `https://` (Entra rejects non-HTTPS reply URLs except
`localhost`) — which is why this step waited until TLS was already live
from Day 2.

**Wait time**: allow a minute after `az ad sp create` before testing tokens
— Entra ID directory replication can lag briefly for a brand-new Service
Principal.

### Demo 2 — Configure and Start oauth2-proxy

Everything in this demo runs **on the VM**, over SSH — it's a Linux bash
shell regardless of whether your own machine is Windows, macOS, or Linux,
so no PowerShell version applies here. Carry over `$APP_ID`, `$SECRET`,
and `$TENANT_ID` from Demo 1 (their actual values, however your local
shell holds them) into the commands below.

On the VM, fill in the empty fields in `/etc/oauth2-proxy/oauth2-proxy.env`
with `sed` — don't overwrite the whole file. `setup-oauth2-proxy.sh`
already pre-populated `OAUTH2_PROXY_COOKIE_SECRET` and
`OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS`; replacing the file wholesale wipes
them and oauth2-proxy refuses to start (`missing setting: cookie-secret`):
```
sudo sed -i \
  -e "s#^OAUTH2_PROXY_CLIENT_ID=.*#OAUTH2_PROXY_CLIENT_ID=$APP_ID#" \
  -e "s#^OAUTH2_PROXY_CLIENT_SECRET=.*#OAUTH2_PROXY_CLIENT_SECRET=$SECRET#" \
  -e "s#^OAUTH2_PROXY_OIDC_ISSUER_URL=.*#OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0#" \
  -e "s#^OAUTH2_PROXY_OIDC_EXTRA_AUDIENCES=.*#OAUTH2_PROXY_OIDC_EXTRA_AUDIENCES=api://$APP_ID#" \
  /etc/oauth2-proxy/oauth2-proxy.env
```
Set `--redirect-url=https://<domain>/oauth2/callback` in
`/etc/systemd/system/oauth2-proxy.service` — `setup-oauth2-proxy.sh`
pre-populated it with a `REPLACE_WITH_DOMAIN` placeholder, so a single sed
does it:
```
sudo sed -i "s#REPLACE_WITH_DOMAIN#<domain>#" /etc/systemd/system/oauth2-proxy.service
sudo systemctl daemon-reload
sudo systemctl enable --now oauth2-proxy
```

### Demo 3 — Wire Identity Enforcement into NPMplus

In the NPMplus GUI, open the Proxy Host's **Auth Request** tab, select
**oauth2proxy**, and save. This wires identity enforcement in front of the
app with no application code changes and no hand-written proxy config —
worth opening the generated nginx config on the VM afterward to see what the
dropdown just built for you.

Via API instead — the field is `npmplus_auth_request` on the proxy host
object (`"none"`, `"oauth2proxy"`, and a handful of other supported auth
backends), and the upstream it points at is already fixed by
`AUTH_REQUEST_OAUTH2PROXY_UPSTREAM` (set on the NPMplus container by
`setup-npmplus.sh`), so a single PUT is enough:
```bash
curl -sk -X PUT https://localhost:8081/api/nginx/proxy-hosts/<id> \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"npmplus_auth_request":"oauth2proxy"}'
```

### Demo 4 — Test the Identity Gate

- `curl -i https://<domain>/` → redirected to Microsoft sign-in
  (unauthenticated).
- `curl -i -H "Authorization: Bearer garbage" https://<domain>/` → also
  redirected (a malformed token doesn't get a free pass).
- Visit `https://<domain>/` in a browser, complete the Microsoft login, land
  on the app with a valid session — **confirmed working end-to-end by live
  test**. This is the real proof the identity gate works; it only works now
  because TLS (Day 2) makes the HTTPS reply URL possible.

Keep that same browser tab open — the rest of the authenticated checks in
this project (Day 3 Demo 5, Day 4, Day 5) just mean visiting a URL directly
in that tab rather than curling it. The browser carries the session cookie
automatically.

### Demo 5 — Re-test Day 2's WAF Now That Identity Is Layered On

Day 2 confirmed the WAF blocks these payloads with a `403`. Send the exact
same payload again, unauthenticated:
```
curl -i "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
```
You'll get a `302` redirect to login, not a `403`. The Auth Request check
runs before the WAF check on the same location — an unauthenticated
attacker gets redirected to sign-in instead of blocked, so the attempt never
shows up as a WAF hit. To confirm the WAF is still active behind the gate,
paste the same URL into the browser tab you logged in with (Demo 4) —
the session cookie goes along automatically:
```
https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users
```
This should render a `403 Forbidden` page.

**Discussion point**: the WAF is still
protecting you, just against attackers who already have (or stole) a valid
session — arguably the more realistic threat, but also a real narrowing of
what the WAF actually sees. Layering security controls changes what each one
covers, not just adding coverage on top.

### Troubleshooting

- **No `identifier-uri add` subcommand**: use
  `az ad app update --id $APP_ID --identifier-uris api://$APP_ID`.
- **NPMplus admin panel returns "Permission Denied" shortly after a
  restart**: log in again to get a fresh session — this doesn't mean your
  configuration was lost.

---

## Day 4 — Data Isolation

**Goal**: understand why the database has no public IP at all (Azure Private
Link — reachable only from inside the virtual network), and practice a safe,
backup-first migration by recreating it.

**Note on this baseline**: unlike Day 2 and Day 3 (where the software is
pre-installed but left *unwired* for the live demo), `postgresql.tf` already
deploys the database fully private — delegated subnet, private DNS zone,
`public_network_access_enabled = false` — from the very first
`python3 deploy.py` run at the start of the week. There is no earlier
"public database" phase to migrate away from; `terraform apply` against an
unmodified `postgresql.tf` at this point in the walkthrough is a no-op. The goal
of this exercise is thus **why** the database is architected this way, and
giving you a real, disruptive backup-then-recreate to practice on — not
walking a live public→private transition that doesn't exist in this repo's
baseline. Verify the private-by-default setting yourself rather than take
it on faith:
```
az postgres flexible-server show --resource-group <rg> --name psql-<prefix> \
  --query "{network:network.publicNetworkAccess}"
```

### Demo 1 — Back Up the Database

Back up the current database **via the VM** (the DB has no public IP, so the
dump has to run over SSH, not directly from your laptop) and pull the result
down to your own machine — don't leave your only copy on the VM. Reuse the
Entra ID identity from Day 1 rather than the static key (regenerate the
`az ssh config` file if it's been a while — the embedded certificate is
short-lived):
```bash
az ssh config --resource-group <rg> --name <vm-name> --file azssh_config

ssh -F azssh_config <vm-ip> \
  'pg_dump "postgresql://psqladmin@<db-fqdn>/learning_journal?sslmode=require"' \
  > learningsteps_backup.sql
```
```powershell
az ssh config --resource-group <rg> --name <vm-name> --file azssh_config

ssh -F azssh_config <vm-ip> `
  'pg_dump "postgresql://psqladmin@<db-fqdn>/learning_journal?sslmode=require"' `
  > learningsteps_backup.sql
```
Confirm the file is non-empty and contains real table data before
proceeding — there's no undo once the next step runs (the app comes seeded
with a couple of sample journal entries at deploy time specifically so this
backup isn't just an empty schema). Pulling it to your laptop (rather than
leaving it in `/tmp` on the VM) matters here: a bad Day 4 practice run can
end up recreating more than just the database (see Demo 2's callout), so
treat the VM as disposable too.

**Prerequisite**: the VM's default `postgresql-client` package (Ubuntu
22.04) is v14, but the server runs PostgreSQL 16 — `pg_dump` refuses to dump
a *newer* major server version ("aborting because of server version
mismatch"). `scripts/cloud-init.yaml` installs `postgresql-client-16` from
the PGDG apt repo instead of the distro default; confirm with
`pg_dump --version` before proceeding if in doubt.

### Demo 2 — Recreate the Database (Backup-First Practice)

Force a destroy-and-recreate of the database server, to practice the
backup-first discipline on a real (not hypothetical) operation:
```
terraform apply -replace="azurerm_postgresql_flexible_server.main"
```
This destroys and recreates the same (already-private) server. **Wait time:
5-8 minutes**, during which the app on the VM cannot reach the database at
all.

**A serious interaction to know about, already fixed in this repo**:
`vm.tf`'s `custom_data` used to interpolate
`azurerm_postgresql_flexible_server.main.fqdn` directly. Replacing the
database resource made that value "known after apply," which — because any
`custom_data` change forces VM replacement — cascaded into destroying and
recreating **the entire VM** too, wiping Docker/NPMplus/CrowdSec/oauth2-proxy
completely (none of that is reprovisioned by cloud-init — only by
`deploy.py`'s one-time SSH setup scripts). `vm.tf` now builds the connection
string from the statically-known server name
(`psql-${var.prefix}.postgres.database.azure.com`) instead of the live
resource attribute, removing that dependency — a database-only `-replace`
now leaves the VM untouched.

### Demo 3 — Restore and Verify Isolation

Restore from the VM (the only machine that can reach the database):
```bash
scp -F azssh_config learningsteps_backup.sql <vm-ip>:/tmp/
ssh -F azssh_config <vm-ip> \
  "psql \"<connection-string>\" -f /tmp/learningsteps_backup.sql"
```
```powershell
scp -F azssh_config learningsteps_backup.sql <vm-ip>:/tmp/
ssh -F azssh_config <vm-ip> `
  'psql "<connection-string>" -f /tmp/learningsteps_backup.sql'
```
(PowerShell's single-quoted strings are literal, so the inner double quotes
don't need escaping at all — cleaner than bash here.)

Verify the lockdown: a connection attempt from your laptop should fail to
resolve the database's hostname at all, while the app (running on the VM,
inside the same virtual network) keeps working normally once restored.

### Demo 4 — Confirm the App Recovered

Check that the app is actually serving data again, not just that the server
exists — visit `https://<domain>/entries` in your logged-in browser tab and
confirm you see the seeded sample entries come back, not just an empty
list.

If the public endpoint still fails after restore, restart the API service
to force a fresh DNS resolution and connection:
```
ssh -F azssh_config <vm-ip> "sudo systemctl restart learningsteps"
```

### Troubleshooting

- **Database connection times out from your laptop after the migration** —
  this is expected. Your laptop is outside the virtual network and has no
  route to the private address space; only resources inside the VNet (like
  the VM) can reach it.
- **`terraform apply` (with no `-replace`) reports no changes** — this is
  expected in this baseline; see the note above. Use `-replace` to force
  the practice recreate.

---

## Day 5 — Visibility and Automated Response

**Goal**: ship logs to a central security platform, detect an attack
pattern automatically, and respond to it without a human in the loop.

Every layer built so far is a static defense. Today closes the loop: traffic
logs flow into Microsoft Sentinel, an analytics rule watches for attack
patterns, and — when one fires — a Logic App automatically blocks the
attacker at the network level. **Heads up on timing**: between log
ingestion delay and the analytics rule's 5-minute cycle, this day has more
built-in waiting than any other — kick off Demo 3 early (e.g. right after a
break) rather than saving it for the last few minutes of the session.

**Already done for you**: unlike every prior day, none of today's
infrastructure needs building — it's all provisioned by `sentinel.tf`
(Log Analytics Workspace, Data Collection Rule, the scheduled analytics
rule, the automation rule, and the Logic App playbook that runs the
NSG block) plus the log forwarder installed by
`scripts/setup-json-logging.sh` via `deploy.py`. Today is entirely about
*triggering and verifying* an already-complete pipeline, not building one.
See those two files if you want to know exactly how any piece works
before demoing it.

### Demo 1 — Confirm Log Forwarding

Confirm the log forwarder is running on the VM:
```
sudo systemctl status npmplus-log-forwarder --no-pager
```
Generate some traffic and confirm it's captured locally first — this is the
fastest way to debug anything that doesn't show up later in Sentinel.
Visit `https://<domain>/entries` in your logged-in browser tab, then:
```
sudo journalctl -t nginx --since '1 min ago'
```

### Demo 2 — Validate Log Ingestion

Confirm the logs are landing in Log Analytics. **Wait time: 3-5 minutes**
after first traffic. Run the query either in the portal (Log Analytics
workspace `law-<prefix>` → **Logs**, paste the query, **Run**) or from the
CLI:
```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group <rg> --workspace-name law-<prefix> \
  --query customerId -o tsv)

az monitor log-analytics query -w $WORKSPACE_ID -o table \
  --analytics-query 'Syslog | where ProcessName == "nginx" | take 5'
```
```powershell
$WORKSPACE_ID = az monitor log-analytics workspace show `
  --resource-group <rg> --workspace-name law-<prefix> `
  --query customerId -o tsv

az monitor log-analytics query -w $WORKSPACE_ID -o table `
  --analytics-query 'Syslog | where ProcessName == "nginx" | take 5'
```
(Demo 4 below reuses this same `$WORKSPACE_ID` variable — the multi-line
KQL query itself is identical in both shells, single-quoted strings
spanning multiple lines work the same way in PowerShell as in Bash.)

### Demo 3 — Run the Attack Simulation

Fire the "Final Test" attack simulation with a valid authenticated session
(see Day 3 Demo 5 on why unauthenticated won't trigger the WAF at all): in
your logged-in browser tab, load this URL 6 times in a row (refresh 6
times):
```
https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users
```
All six should render a `403 Forbidden` page (the WAF must already be
enabled from Day 2).

### Demo 4 — Validate the Detection Query

Run the detection query directly, before waiting on the scheduled rule
(same portal Logs blade, or CLI reusing `$WORKSPACE_ID` from Demo 2):
```
az monitor log-analytics query -w $WORKSPACE_ID -o table --analytics-query '
Syslog
| where ProcessName == "nginx"
| extend log = parse_json(SyslogMessage)
| extend StatusCode = toint(log.status)
| extend ClientIP   = tostring(log.remote_addr)
| where StatusCode == 403
| where ClientIP != "127.0.0.1"
| summarize WafBlocks = count() by ClientIP
| where WafBlocks >= 5
'
```

### Demo 5 — Wait for the Automated Incident

**Wait time: up to 5 minutes** (the analytics rule runs on a 5-minute
schedule). Check **Sentinel → Incidents** for "WAF Attack — High Volume
403s from Single IP."

### Demo 6 — Verify the Automated Block

Confirm the automation rule triggered the response playbook, and — this is
the part that actually matters — **verify the block works, not just that a
rule was created**. **Wait time: roughly another minute** after the
incident appears, for the Logic App to run:
```
az network nsg rule list --resource-group <rg> --nsg-name nsg-<prefix> -o table
```
Then confirm from the attacking IP that `curl`/`ssh` to the VM now time out
at the network level (not just return an app-level error). A rule existing
and a rule actually blocking traffic are two different claims — always
check both.

**If the attacking IP is your own** (true whenever you're running the
simulation from your own machine), this block also cuts off your own
SSH/GUI-tunnel access to the VM. Remove the auto-created
`sentinel-block-<ip>` NSG rule once you've confirmed the block works, to
restore your own access:
```
az network nsg rule delete --resource-group <rg> --nsg-name nsg-<prefix> --name sentinel-block-<ip>
```

### Troubleshooting

- **Nothing appears in Sentinel after several minutes**: validate the raw
  KQL query manually first (Demo 4) — if it returns rows, the scheduled
  rule will fire on its next 5-minute cycle; if it returns nothing, the
  problem is upstream of Sentinel (check Demo 1's local log output first).
- **A retest right after a successful block seems to fail strangely**: check
  `sudo docker exec crowdsec cscli decisions list` — the attacking IP may
  already be under a longer CrowdSec ban independent of the NSG rule, which
  will make all its requests fail rather than just the malicious-looking
  ones.
- **Re-running the attack simulation (e.g. a second take, or a rehearsal
  run) doesn't create a new NSG block, and nothing looks wrong** —
  confirmed live: Sentinel's default alert grouping merges a new alert from
  the same rule into an existing **open** incident (status `New`/`Active`)
  instead of creating a fresh one, if one from an earlier run is still open.
  The automation rule only triggers on incident *creation*, not on an
  existing incident being updated — so the playbook silently does not fire,
  with no error anywhere. Check for this before assuming the pipeline is
  broken:
  ```
  az sentinel incident list --resource-group <rg> --workspace-name law-<prefix> -o table
  ```
  If the most recent matching incident is still `New`, close it, then
  re-run the attack:
  ```
  az sentinel incident update --resource-group <rg> --workspace-name law-<prefix> \
    --incident-id <id> --status Closed --classification BenignPositive \
    --classification-reason SuspiciousButExpected --classification-comment "rehearsal cleanup"
  ```
