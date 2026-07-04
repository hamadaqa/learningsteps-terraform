# LearningSteps Lockdown — Slide Update Reference

Reference for updating the Gamma deck to match the current course
architecture (NPMplus + CrowdSec replacing nginx + oauth2-proxy +
ModSecurity for Days 2 and 4; log pipeline adjusted for Day 5). Organized by
day, with concrete edits: what to remove, what to add, and what stays as-is.

---

## Day 1 — No changes

Entra ID SSH login and NSG lockdown are unaffected. Optional one-line
callback near the end of the NSG section, if it fits the pacing:

> "We're locking down port 22 today. Later in the course you'll see this
> exact same instinct applied to a different management port — deliberately
> not opening it to the internet."

Not required — skip if it doesn't fit.

---

## Day 2 — oauth2-proxy wiring moves to NPMplus

**Remove**: any slide showing raw nginx `auth_request` config — the
`auth_request /oauth2/auth;`, `error_page 401 = /oauth2/sign_in;`, and the
internal `location = /oauth2/auth` block. This is no longer hand-written.

**Keep unchanged**: the Entra ID app-registration walkthrough and the API
keys vs. identity tokens discussion — this is still the day's core lesson.

**Replace** the "install/configure oauth2-proxy" section with: oauth2-proxy
is pre-installed (binary + systemd unit, not started) as part of the initial
environment setup. The live demo is filling in
`/etc/oauth2-proxy/oauth2-proxy.env` with the app registration's client ID,
secret, and tenant issuer URL, then starting the service.

**Add a new slide** — "Wiring identity into the proxy": open the app's Proxy
Host in NPMplus, go to the **Auth Request** tab, select **oauth2proxy**,
save. Take a screenshot of the dropdown, and a before/after screenshot of
the generated nginx config on the VM (`/data/nginx/proxy_host/<id>.conf`
inside the NPMplus container) — this is the payoff moment: the exact
`auth_request` block students used to hand-write, generated from one
dropdown.

**Test sequence slide** — update commands only, same narrative: no token →
redirected to login; garbage token → redirected to login; real browser
login → app loads.

**Timing**: net faster than before — the nginx-config-editing portion is
now a ~2 minute GUI action, freeing up time for deeper OIDC/JWT discussion.

---

## Day 3 — No changes

PostgreSQL Private Link migration is unaffected by the front-door change.

---

## Day 4 — TLS + WAF via NPMplus + CrowdSec, rate limiting removed

**Structural change**: 4 steps become 3. Remove the entire rate-limiting
section.

### Step 1 — "port open ≠ encrypted" (same narrative, new mechanism)

**Remove**: hand-editing `listen 443 ssl;` with no real certificate.

**Replace with**: create a Proxy Host in NPMplus (domain, forward to
`127.0.0.1:8000`), leave TLS off. `curl` it over plain HTTP, point out the
response is fully readable in transit. Screenshot: the Proxy Host list
showing SSL off.

### Step 2 — Real TLS

**Remove**: `certbot certonly --webroot` and manual `ssl_certificate`
directives.

**Replace with**: Proxy Host → SSL tab → "Request a new SSL Certificate" →
Let's Encrypt → save. Same ACME challenge underneath, no manual steps.
Screenshot/diff: the generated nginx config before/after, showing the
injected `ssl_certificate` lines and the automatic HTTP→HTTPS redirect.

### Step 3 — Rate limiting: remove entirely

Remove the `limit_req_zone` explanation, the burst-request demo, and the 429
discussion. No replacement — call this out as a single spoken aside if
raised: "a production reverse proxy would normally rate-limit here; this
tool doesn't expose it as a simple control, which is itself worth noting
when evaluating a security tool before adopting it."

### Step 4 (renumber to Step 3) — WAF: ModSecurity+CRS → CrowdSec AppSec+CRS

**Remove**: the entire ModSecurity compile-from-source section — the nginx
module build, `libmodsecurity3`/`modsecurity-crs` packages, the
`SecRuleEngine On` edit. This was the most fragile part of the old stack.

**Replace with**:
1. Introduce CrowdSec: community-driven attack detection, with an AppSec
   component that does real-time payload inspection. It runs the actual
   OWASP Core Rule Set (confirmed — the `crowdsecurity/appsec-crs`
   collection is a genuine CRS port), so the "this is what real companies
   run" framing holds.
2. **New required slide — read the fine print**: CrowdSec shares detected
   attack signals with its community blocklist by default. Show `cscli
   console status` and the opt-out (`cscli console disable`). Frame as a
   general lesson in evaluating security tool defaults, not a CrowdSec
   callout specifically.
3. Show WAF-off state: both SQLi and XSS payloads pass through untouched.
4. Enable CrowdSec (commands in the handbook).
5. Re-send the same payloads — both now blocked with `403`.
6. Screenshot: `cscli alerts list` showing the blocked payload, and the
   per-host WAF toggle in the NPMplus GUI.

**New required slide — "layered defenses interact"**: once Day 2's identity
check is active on the same host, sending attack payloads *unauthenticated*
no longer shows the WAF block — it redirects to login instead, since the
identity check runs first on the same path. Reframe the demo: send the
payloads with a valid session (log in via browser first). This demonstrates
CrowdSec protecting authenticated users too, which is arguably the stronger
point — anonymous attackers were already stopped by Day 2's gate either way.

**Timing**: similar net time to before once rate limiting is removed — the
ModSecurity compile step it replaces was the slowest part of the old Day 4
(5-10 minutes of compiling on a small VM); CrowdSec's setup is faster,
freeing time for the "layered defenses" discussion.

---

## Day 5 — Log pipeline updates

**Conceptually unchanged**: nginx logs → syslog → Sentinel → automated
response. Concrete mechanics updated below.

**Remove**: any slide showing nginx writing JSON directly to syslog via
`access_log syslog:server=unix:/dev/log,...` — that specific directive
doesn't apply once the proxy runs in a container without extra plumbing.

**Add new slide — "Getting logs out of a container"** (a generally useful
lesson, not NPMplus-specific): the proxy writes access logs to a file on the
host (bind-mounted out of its container), and a small forwarder service
tails that file, converts each line to JSON, and forwards it to syslog. Good
moment to mention the alternative (Docker's built-in syslog logging driver)
and why it wouldn't have worked here — that driver only captures a
container's stdout, and these logs are written to a file inside the
container instead. A "read what the tool actually does before assuming"
moment.

**Update the KQL slide** to the current query:
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
Add a short callout on log deduplication: sending several identical-looking
requests in quick succession can silently collapse into fewer log lines than
requests sent — worth a slide on its own, since it generalizes to anyone
piping repeated log lines through syslog, not just this course.

**Update the "Final Test" slide's attack commands** — same payloads, now
against the current stack, and add the note that if Day 2's identity gate is
active, the payloads must be sent with a valid session (see Day 4).

**Add new slide — "the rule exists ≠ the rule works"**: the original Final
Test only checked that a block rule appeared. That's not sufficient — a
network firewall evaluates rules in priority order and stops at the first
match, so a correctly-created block rule can still be silently overridden by
an earlier, broader rule. Update the Final Test slide to require an actual
connectivity check after the block (the attacking IP's `curl`/`ssh` should
now time out, not just return an application-level error). This is a
strong, general lesson about firewall rule ordering, independent of this
course's specific stack.

**Timing**: unchanged scheduling (5-minute detection window). Add roughly
one extra minute of demo time to check the local log output on the VM before
waiting on Sentinel — the fastest way to tell whether a "nothing showed up"
problem is upstream of Sentinel or a genuine ingestion delay.
