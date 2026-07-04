# LearningSteps Lockdown — Course Handbook

A five-day hands-on security course. Each day, you harden one layer of a
shared web application (LearningSteps: a FastAPI + PostgreSQL app deployed on
Azure via Terraform). By the end of the week, the app is protected end to
end: locked-down management access, identity-based authentication, an
isolated database, encrypted traffic with a web application firewall, and
automated attack detection and response.

Deploy the environment once at the start of the week:

```
python3 deploy.py --password <db-password> --prefix <your-name> --location westeurope
```

This provisions the VM, database, networking, and monitoring stack, and
installs the baseline software used across the week (NPMplus, CrowdSec,
oauth2-proxy). Expect the full run to take 10-15 minutes — a good time to
start the day's lecture content while it finishes.

---

## Day 1 — Locking Down Management Access

**Goal**: replace static SSH keys with identity-based login, and restrict
network access to your VM's management port.

Right now, anything on the internet can attempt to brute-force SSH on your
VM. Today you close that door two ways: authenticate with your Entra ID
identity instead of a key file, and restrict the network path to a trusted
IP entirely.

### Demo

1. Confirm you have the **Virtual Machine Administrator Login** role on the
   VM:
   ```
   az role assignment list --assignee <your-email> --role "Virtual Machine Administrator Login"
   ```
2. Log in with Entra ID — no key file involved:
   ```
   az ssh vm --resource-group <rg> --name <vm-name>
   ```
3. Open `network.tf` and restrict the `allow-ssh` rule's
   `source_address_prefix` from `"*"` to your own IP:
   ```
   curl -s ifconfig.me
   ```
   Update the rule, then `terraform apply`. The change takes effect
   immediately — a connection from any other IP will now be refused.

### Troubleshooting

- **`az ssh` fails with "AuthorizationFailed"**: you need Owner or User
  Access Administrator on the subscription to grant yourself the "Virtual
  Machine Administrator Login" role. Ask whoever manages the subscription to
  run:
  ```
  az role assignment create --assignee <your-email> \
    --role "Virtual Machine Administrator Login" \
    --scope <vm-resource-id>
  ```

---

## Day 2 — Identity-Based API Access

**Goal**: require a valid Entra ID identity token before any request reaches
the application, replacing anonymous access to the API.

Anyone who can reach the VM's app port can currently read, write, or delete
data with no accountability. Today you put an identity gate in front of it —
this is the same "static credential vs. identity" upgrade as Day 1, applied
to the application layer instead of SSH.

### Demo

1. Open an SSH tunnel to the NPMplus admin panel (its GUI is deliberately
   not exposed to the internet — same principle as Day 1's SSH lockdown):
   ```
   ssh -i .learningsteps_key -L 8081:localhost:81 azureuser@<vm-ip>
   ```
   Browse to `https://localhost:8081` and log in.

2. Create a Proxy Host for the app: domain = your VM's FQDN, forward to
   `127.0.0.1:8000`. Leave TLS off for now — that's Day 4.

3. Register an Entra ID application for the API:
   ```
   APP_ID=$(az ad app create --display-name learningsteps-oauth2-proxy \
       --sign-in-audience AzureADMyOrg \
       --query appId -o tsv)
   az ad app update --id $APP_ID --identifier-uris api://$APP_ID
   SECRET=$(az ad app credential reset --id $APP_ID --query password -o tsv)
   TENANT_ID=$(az account show --query tenantId -o tsv)
   ```

4. On the VM, configure oauth2-proxy (`/etc/oauth2-proxy/oauth2-proxy.env`):
   ```
   OAUTH2_PROXY_CLIENT_ID=$APP_ID
   OAUTH2_PROXY_CLIENT_SECRET=$SECRET
   OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0
   ```
   Set `--redirect-url=https://<domain>/oauth2/callback` in
   `/etc/systemd/system/oauth2-proxy.service`, then:
   ```
   sudo systemctl daemon-reload
   sudo systemctl enable --now oauth2-proxy
   ```

5. In the NPMplus GUI, open the Proxy Host's **Auth Request** tab, select
   **oauth2proxy**, and save. This wires identity enforcement in front of
   the app with no application code changes and no hand-written proxy
   config — worth opening the generated nginx config on the VM afterward to
   see what the dropdown just built for you.

6. Test:
   - `curl -i http://<domain>/` → redirected to Microsoft sign-in
     (unauthenticated).
   - `curl -i -H "Authorization: Bearer garbage" http://<domain>/` →
     also redirected (a malformed token doesn't get a free pass).
   - Visit `https://<domain>/` in a browser, complete the Microsoft login,
     land on the app with a valid session.

### Troubleshooting

- **No `identifier-uri add` subcommand**: use
  `az ad app update --id $APP_ID --identifier-uris api://$APP_ID`.
- **NPMplus admin panel returns "Permission Denied" shortly after a
  restart**: log in again to get a fresh session — this doesn't mean your
  configuration was lost.

---

## Day 3 — Data Isolation

**Goal**: move the database off the public internet entirely, using Azure's
Private Link, and practice a safe migration.

A publicly reachable database is a standing target. Today the database moves
into a private subnet with no public IP at all — reachable only from inside
the virtual network. Since this requires recreating the database server, you
also practice a proper backup-first migration.

### Demo

1. Back up the current database from the VM (acting as your access point):
   ```
   pg_dump "postgresql://psqladmin@<db-fqdn>/learning_journal?sslmode=require" \
     > learningsteps_backup.sql
   ```
   Confirm the file is non-empty and contains real table data before
   proceeding — there's no undo once the next step runs.

2. `terraform apply` with the updated `postgresql.tf` — this destroys the
   public database and recreates it inside a delegated subnet, resolvable
   only via a private DNS zone.

3. Restore from the VM (the only machine that can now reach the database):
   ```
   scp -i .learningsteps_key learningsteps_backup.sql azureuser@<vm-ip>:/tmp/
   ssh -i .learningsteps_key azureuser@<vm-ip> \
     "psql \"<connection-string>\" -f /tmp/learningsteps_backup.sql"
   ```

4. Verify the lockdown: a connection attempt from your laptop should fail to
   resolve the database's hostname at all, while the app (running on the VM,
   inside the same virtual network) keeps working normally.

### Troubleshooting

- **Database connection times out from your laptop after the migration** —
  this is expected. Your laptop is outside the virtual network and has no
  route to the private address space; only resources inside the VNet (like
  the VM) can reach it.

---

## Day 4 — Encryption and a Web Application Firewall

**Goal**: encrypt all traffic and add a web application firewall that blocks
known attack patterns.

Two gaps remain: traffic is still plaintext, and nothing inspects what's
actually being sent to the API. Today you close both — first with real TLS,
then with a WAF that blocks SQL injection and XSS payloads before they reach
the application.

### Demo

**Step 1 — confirm the gap.** With the Proxy Host from Day 2 still running
without TLS, request it over plain HTTP and note the response is fully
readable in transit — an open port is not the same thing as an encrypted
connection.

**Step 2 — real TLS.** In the NPMplus GUI, open the Proxy Host's SSL tab,
choose "Request a new SSL Certificate," select Let's Encrypt, and save.
NPMplus handles the domain-verification challenge and certificate storage
automatically. Confirm:
```
curl -i https://<domain>/entries
```
returns a valid, browser-trusted certificate, and that plain HTTP now
redirects to HTTPS.

**Step 3 — web application firewall.** First show the gap: send known attack
payloads and note they pass straight through:
```
curl -i "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
curl -i "https://<domain>/entries?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

Enable the WAF (CrowdSec, running the OWASP Core Rule Set):
```
docker exec crowdsec cscli bouncers add npmplus
# copy the printed API key immediately — it's shown once
sudo nano /opt/npmplus/crowdsec/crowdsec.conf
#   ENABLED=true
#   API_URL=http://127.0.0.1:8080
#   APPSEC_URL=http://127.0.0.1:7422
#   API_KEY=<paste key>
cd /opt/npmplus && docker compose restart npmplus
```

Re-send the same payloads — both now return `403`. Inspect the block with:
```
docker exec crowdsec cscli alerts list
```

**Important — test this authenticated.** Since Day 2's identity check runs
before the WAF check on the same path, an unauthenticated attack request
gets redirected to the login page rather than reaching the WAF at all — so
it won't show a `403`. To see the WAF in action, log in through the browser
first (or attach a valid session cookie to your `curl` calls) and send the
payloads with that session. This is a good discussion point: the WAF is
still protecting you, just against attackers who already have (or stole) a
valid session — arguably the more realistic threat.

**A note worth mentioning out loud**: CrowdSec shares detected attack
signals with its community threat-intel blocklist by default. Check
`cscli console status`, and `cscli console disable` to opt out. Worth
raising as a "read the fine print on security tools" moment regardless of
which way the class decides to leave it.

### Troubleshooting

- **NPMplus's own admin panel starts returning 403s after enabling the
  WAF**: the WAF protects the entire proxy instance, including NPMplus's own
  admin interface. Temporarily set `ENABLED=false` in
  `/opt/npmplus/crowdsec/crowdsec.conf` to make further admin changes, then
  re-enable.
- **A previously-blocked IP still gets 403'd on a clean request**: after
  enough attack attempts, CrowdSec may issue a longer-lived ban for that IP
  (`docker exec crowdsec cscli decisions list`), independent of any single
  request's content. This is expected — the IP is banned outright, not
  still being flagged request-by-request.

---

## Day 5 — Visibility and Automated Response

**Goal**: ship logs to a central security platform, detect an attack
pattern automatically, and respond to it without a human in the loop.

Every layer built so far is a static defense. Today closes the loop: traffic
logs flow into Microsoft Sentinel, an analytics rule watches for attack
patterns, and — when one fires — a Logic App automatically blocks the
attacker at the network level.

### Demo

1. Confirm the log forwarder is running on the VM:
   ```
   sudo systemctl status npmplus-log-forwarder --no-pager
   ```
2. Generate some traffic and confirm it's captured locally first — this is
   the fastest way to debug anything that doesn't show up later in Sentinel:
   ```
   curl -s https://<domain>/entries >/dev/null
   journalctl -t nginx --since '1 min ago'
   ```
3. Confirm the logs are landing in Log Analytics (usually 3-5 minutes after
   first traffic):
   ```kql
   Syslog | where ProcessName == "nginx" | take 5
   ```
4. Run the "Final Test" — fire the attack simulation with a valid
   authenticated session (see Day 4's note on why):
   ```
   for i in $(seq 1 6); do
     curl -s -o /dev/null -w "%{http_code}\n" \
       "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
   done
   ```
   All six should return `403` (the WAF must already be enabled from Day 4).

5. Validate the detection query directly, before waiting on the scheduled
   rule:
   ```kql
   Syslog
   | where ProcessName == "nginx"
   | extend log = parse_json(SyslogMessage)
   | extend StatusCode = toint(log.status)
   | extend ClientIP   = tostring(log.remote_addr)
   | where StatusCode == 403
   | summarize WafBlocks = count() by ClientIP
   | where WafBlocks >= 5
   ```
6. Wait for the scheduled analytics rule (checks every 5 minutes) to raise
   an incident: **Sentinel → Incidents** — look for "WAF Attack — High
   Volume 403s from Single IP."
7. Confirm the automation rule triggered the response playbook, and — this
   is the part that actually matters — **verify the block works, not just
   that a rule was created**:
   ```
   az network nsg rule list --resource-group <rg> --nsg-name nsg-<prefix> -o table
   ```
   Then confirm from the attacking IP that `curl`/`ssh` to the VM now time
   out at the network level (not just return an app-level error). A rule
   existing and a rule actually blocking traffic are two different claims —
   always check both.

### Troubleshooting

- **Nothing appears in Sentinel after several minutes**: validate the raw
  KQL query manually first (step 5) — if it returns rows, the scheduled rule
  will fire on its next 5-minute cycle; if it returns nothing, the problem
  is upstream of Sentinel (check step 2's local log output first).
- **A retest right after a successful block seems to fail strangely**: check
  `docker exec crowdsec cscli decisions list` — the attacking IP may already
  be under a longer CrowdSec ban independent of the NSG rule, which will
  make all its requests fail rather than just the malicious-looking ones.
