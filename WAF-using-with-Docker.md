# Building a WAF-as-a-Service with Docker — Full Build Journal

**A complete, interview-ready walkthrough of how I built a Web Application Firewall on AWS using Docker, every problem I hit, why I made each decision, and how I fixed it.**

> This document is written so I (or anyone) can read it in front of an interviewer, copy-paste the commands, and reproduce a working WAF end to end. It covers **both** the hand-built approach (and why it failed) and the official-image approach (what actually shipped).

---

## Table of Contents

1. [What I Was Building](#1-what-i-was-building)
2. [The Architecture — Two Servers](#2-the-architecture--two-servers)
3. [Approach A: The Hand-Built Docker Image](#3-approach-a-the-hand-built-docker-image)
   - [Why Each File Exists](#why-each-file-exists-separately)
   - [The Dockerfile](#the-dockerfile)
   - [default-vhost.conf — why](#default-vhostconf--why-it-exists)
   - [modsecurity.conf — why](#modsecurityconf--why-it-exists)
   - [setup-crs.sh — why](#setup-crssh--why-it-exists)
   - [entrypoint.sh — why](#entrypointsh--why-it-exists)
4. [The Problems I Faced (and Fixes)](#4-the-problems-i-faced-and-fixes)
5. [Approach B: The Official OWASP Image (What Shipped)](#5-approach-b-the-official-owasp-image-what-shipped)
6. [Detection Mode vs Blocking Mode — Why Detection First](#6-detection-mode-vs-blocking-mode--why-detection-first)
7. [Reading the Logs](#7-reading-the-logs)
8. [How to Read an Audit Log Entry](#8-how-to-read-an-audit-log-entry)
9. [Testing the WAF](#9-testing-the-waf)
10. [Current Drawbacks / What's Missing](#10-current-drawbacks--whats-missing)
11. [Interview Cheat-Sheet](#11-interview-cheat-sheet)

---

## 1. What I Was Building

A **Web Application Firewall (WAF)** that sits in front of a web server and inspects every incoming HTTP request. Clean requests get forwarded to the real server; malicious ones (SQL injection, XSS, path traversal, etc.) get blocked before they ever reach the application.

**The analogy:** it's **airport security for a website**. Every visitor (HTTP request) walks through a scanner (ModSecurity + OWASP rules) before boarding the plane (reaching the backend app). Known threats get stopped at the checkpoint.

**Stack:**
- **Apache 2.4** — the reverse proxy (receives traffic, forwards it)
- **ModSecurity v2** — the WAF engine (the "scanner")
- **OWASP Core Rule Set (CRS)** — the rules that define what an attack looks like (the "watchlist")
- **Docker** — packages it all into one portable container
- **AWS EC2** — the servers

---

## 2. The Architecture — Two Servers

This is critical to understand, because I wasted time running commands on the wrong box.

```
        Internet (public users)
                 │
                 ▼  http://<WAF-PUBLIC-IP>
   ┌────────────────────────────┐
   │   WAF SERVER                │
   │   Private IP: 172.31.1.12   │   ← Docker + Apache + ModSecurity + CRS
   │   Public IP:  47.129.65.136 │   ← this is the ONLY public door
   │                             │
   │   Inspects every request    │
   └────────────────────────────┘
                 │
                 ▼  http://172.31.3.237  (private, proxied)
   ┌────────────────────────────┐
   │   BACKEND SERVER            │
   │   Private IP: 172.31.3.237  │   ← nginx (the actual web app)
   │   NO public IP exposed      │   ← only the WAF can reach it
   └────────────────────────────┘
```

**Why two servers?** The backend (`172.31.3.237`) has **no public IP** — the internet cannot reach it directly. The only way in is through the WAF. So even if an attacker learns the backend's address, they can't bypass the security gate.

**The mistake I made:** I kept SSH-ing from the WAF *into* the backend and running `docker` there. The backend has no Docker. **Always read the hostname in the prompt before running anything:**
- `root@ip-172-31-1-12` = **WAF box** → run Docker here
- `root@ip-172-31-3-237` = **backend box** → nginx only, no Docker
- To get back from the backend to the WAF: type `exit`

**Another subtle trap:** running `curl localhost` on the **backend** hits nginx *directly* and returns `200` — it bypasses the WAF entirely. You must test from the WAF box (or the WAF's public IP), where `localhost` = the WAF.

---

## 3. Approach A: The Hand-Built Docker Image

My first approach was to build everything myself from an Ubuntu base image. This is the "cook from raw ingredients" approach. It taught me a lot, but it hit version-compatibility walls (documented in Section 4). I'm keeping it here because **understanding why it failed is itself an interview answer.**

### Why Each File Exists Separately

A Docker image is built from small, single-responsibility pieces. Here's why I split it into 5 files instead of cramming everything into one:

| File | Job | Analogy |
|------|-----|---------|
| `Dockerfile` | The build recipe — what to install, what to copy, how to start | The **blueprint** for the whole machine |
| `default-vhost.conf` | Apache config — enable ModSecurity + reverse proxy to the backend | The **wiring diagram** (where traffic goes) |
| `modsecurity.conf` | ModSecurity engine settings — logging, body inspection, limits | The **scanner's settings** (sensitivity, what to record) |
| `setup-crs.sh` | Downloads & installs the OWASP rules at build time | The **watchlist delivery** (fetch the rules) |
| `entrypoint.sh` | Runs at container start — injects the backend URL + mode from env vars | The **ignition switch** (starts it with runtime settings) |

**Why separate?** Each file changes for a different reason. If I want to tweak logging, I touch `modsecurity.conf`. If I change the backend, the env var handles it via `entrypoint.sh`. This is the **single-responsibility principle** — one file, one job. It also lets Docker cache unchanged layers, so rebuilds are faster.

### The Dockerfile

```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Install Apache, ModSecurity, and modules ──
RUN apt-get update && apt-get install -y \
    apache2 \
    libapache2-mod-security2 \
    curl \
    git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Enable required Apache modules ──
RUN a2enmod \
    security2 \
    proxy \
    proxy_http \
    proxy_balancer \
    lbmethod_byrequests \
    headers \
    rewrite \
    ssl

# ── Copy configuration ──
COPY modsecurity.conf /etc/modsecurity/modsecurity.conf
COPY default-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY setup-crs.sh /tmp/setup-crs.sh
COPY entrypoint.sh /entrypoint.sh

# ── Install OWASP CRS ──
RUN chmod +x /tmp/setup-crs.sh && /tmp/setup-crs.sh

RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/log/modsecurity && \
    chown www-data:www-data /var/log/modsecurity

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
```

**Why `FROM ubuntu:22.04`?** A known, stable base. **This is also the root of my problems** — see Section 4.

**Why `a2enmod proxy proxy_http`?** Without these Apache modules, Apache can't act as a reverse proxy — it could only serve its own files, not forward to a backend.

**Why `ENTRYPOINT` instead of `CMD`?** The entrypoint script needs to run *every time the container starts* to inject the current backend URL and mode. The build happens once; the entrypoint runs on every `docker run`.

### default-vhost.conf — why it exists

```apache
<VirtualHost *:80>
    ServerName localhost

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined

    # ModSecurity on/off/detection — replaced at startup by entrypoint
    SecRuleEngine __MODSEC_MODE__

    # Reverse proxy — __BACKEND_URL__ replaced at startup by entrypoint
    ProxyPreserveHost On
    ProxyPass / __BACKEND_URL__/
    ProxyPassReverse / __BACKEND_URL__/

    RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"
    RequestHeader set X-Real-IP "%{REMOTE_ADDR}s"

    Header always unset X-Powered-By
    ServerSignature Off
</VirtualHost>
```

**Why this file?** This is where the two core behaviors live:
1. **`SecRuleEngine`** — turns the WAF on (the inspection)
2. **`ProxyPass` / `ProxyPassReverse`** — the reverse proxy (forwarding to the backend)

**Why the `__PLACEHOLDER__` values?** So the *same image* works for any client. The entrypoint swaps `__BACKEND_URL__` and `__MODSEC_MODE__` at startup using environment variables. Build once, reuse for every client.

**Why `X-Forwarded-For`?** Without it, the backend sees the WAF's IP as the "client." These headers pass the *real* visitor IP through, so the backend's logs are accurate.

**Why `ProxyPreserveHost On`?** It forwards the original `Host:` header, so a backend serving multiple domains knows which one was requested.

### modsecurity.conf — why it exists

```apache
SecRuleEngine DetectionOnly

SecRequestBodyAccess On
SecRequestBodyLimit 13107200
SecRequestBodyLimitAction Reject

SecResponseBodyAccess Off

# Audit logging — the "security camera footage"
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLogParts ABCDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/modsecurity/modsec_audit.log

SecTmpDir /tmp/
SecDataDir /tmp/

SecPcreMatchLimit 100000
SecPcreMatchLimitRecursion 100000

IncludeOptional /etc/modsecurity/crs/crs-setup.conf
IncludeOptional /etc/modsecurity/crs/rules/*.conf
```

**Why this file?** It configures the *engine itself* — separate from the rules (CRS) and separate from Apache's routing (vhost).

Key settings explained:
- **`SecAuditEngine RelevantOnly`** — only logs requests that triggered a rule, not every single request (which would fill the disk)
- **`SecAuditLogParts ABCDEFHZ`** — controls what goes in the log (A=headers, B=request headers, H=matched rules, etc.)
- **`SecResponseBodyAccess Off`** — don't inspect responses; saves CPU. A reverse-proxy WAF mostly cares about *incoming* attacks.
- **`SecPcreMatchLimit`** — caps regex processing to prevent a ReDoS (regex denial-of-service) attack against the rules themselves

### setup-crs.sh — why it exists

```bash
#!/bin/bash
set -e

CRS_VERSION="3.3.5"
CRS_DIR="/etc/modsecurity/crs"

echo "[*] Downloading OWASP CRS v${CRS_VERSION}..."
cd /tmp
curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VERSION}.tar.gz" \
  -o crs.tar.gz
tar xzf crs.tar.gz

mkdir -p "${CRS_DIR}"
cp -r "coreruleset-${CRS_VERSION}/rules" "${CRS_DIR}/"
cp "coreruleset-${CRS_VERSION}/crs-setup.conf.example" "${CRS_DIR}/crs-setup.conf"

# Remove a rule file that needs a newer ModSecurity than Ubuntu ships
rm -f "${CRS_DIR}/rules/REQUEST-922-MULTIPART-ATTACK.conf"

sed -i 's/^#\s*SecAction.*id:900000.*/SecAction "id:900000,phase:1,pass,t:none,nolog,setvar:tx.blocking_paranoia_level=1"/' \
  "${CRS_DIR}/crs-setup.conf"

mkdir -p "${CRS_DIR}/rules"
touch "${CRS_DIR}/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
touch "${CRS_DIR}/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf"

rm -rf /tmp/crs.tar.gz /tmp/coreruleset-*
echo "[*] OWASP CRS v${CRS_VERSION} installed."
```

**Why a separate script?** The rule set is downloaded from GitHub at build time. Keeping this in its own script keeps the Dockerfile clean and makes the CRS version easy to change (one line: `CRS_VERSION`).

**Why `set -e`?** If any command fails, the whole script stops immediately — so a broken download doesn't produce a half-built image that silently fails later.

**What's the paranoia level?** `1` = catches obvious attacks (SQLi, XSS, RCE) with few false positives. Levels go up to `4` (paranoid, lots of false positives). Always start at 1.

### entrypoint.sh — why it exists

```bash
#!/bin/bash
set -e

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8080}"
MODSEC_MODE="${MODSEC_MODE:-DetectionOnly}"

echo "Backend: ${BACKEND_URL} | ModSec: ${MODSEC_MODE}"

# Replace placeholders in the vhost with runtime values
sed -i "s|__BACKEND_URL__|${BACKEND_URL}|g" /etc/apache2/sites-available/000-default.conf
sed -i "s|__MODSEC_MODE__|${MODSEC_MODE}|g" /etc/apache2/sites-available/000-default.conf

apachectl configtest

# Start Apache in the foreground (keeps the container alive)
exec apachectl -D FOREGROUND
```

**Why this file?** Docker images are built once but run many times, with different settings each time. The entrypoint is the bridge between **build time** (fixed) and **run time** (variable). It reads the environment variables you pass with `docker run -e ...` and bakes them into the config just before Apache starts.

**Why `exec apachectl -D FOREGROUND`?**
- `-D FOREGROUND` — keeps Apache in the foreground. Docker needs the main process to stay running; if Apache daemonized to the background, the container would immediately exit (Docker thinks "nothing's running, shut down").
- `exec` — replaces the shell with Apache, so Apache becomes PID 1 and receives Docker's stop signals correctly.
- **The analogy:** `-D FOREGROUND` is telling Apache "don't go to the back office — stay at the front desk with the lights on, or the building auto-locks."

---

## 4. The Problems I Faced (and Fixes)

This is the most valuable section for an interview — real debugging, not a happy path.

### Problem 1: `Unknown variable: &MULTIPART_PART_HEADERS`

**Error:**
```
AH00526: Syntax error on line 44 of REQUEST-922-MULTIPART-ATTACK.conf:
Error creating rule: Unknown variable: &MULTIPART_PART_HEADERS
```

**Root cause:** A **version mismatch**. OWASP CRS v4.x uses a variable (`MULTIPART_PART_HEADERS`) that only exists in ModSecurity **v2.9.6+**. But Ubuntu 22.04's `libapache2-mod-security2` package ships an **older** ModSecurity that doesn't know that variable.

**The analogy:** CRS 4.x is a new app that needs Android 14, but Ubuntu's repo gave me Android 12.

**Fix attempt 1:** Downgrade CRS to v3.3.5. → **Still failed** — even 3.3.5 includes that multipart rule file.

**Fix attempt 2:** Delete the single offending rule file in `setup-crs.sh`:
```bash
rm -f "${CRS_DIR}/rules/REQUEST-922-MULTIPART-ATTACK.conf"
```
This works but is a hacky band-aid — I'd be playing whack-a-mole with every incompatible rule.

**The real lesson:** Ubuntu's packaged ModSecurity is simply too old to pair cleanly with modern CRS. **This is why I switched to the official image (Section 5).** In an interview, this is the key insight: *"I learned that hand-assembling version-sensitive security components is fragile; the maintained official image solves the compatibility problem at the source."*

### Problem 2: `Connection reset by peer` on port 80

**Error:**
```
curl -I http://localhost
curl: (56) Recv failure: Connection reset by peer
```
...yet `docker ps` showed the container **`Up (healthy)`**.

**Root cause:** A **port mismatch**. The official OWASP image runs Apache as a *non-root user*, so inside the container it listens on port **8080** (HTTP) and **8443** (HTTPS), not 80. My `-p 80:80` mapped the host's port 80 to the container's port 80 — but **nothing was listening on container port 80**. The healthcheck passed because it checks internally on 8080.

**The evidence:** the boot log mentioned `localhost:8443` — a hint that it uses high ports.

**Fix:** map host 80 → container **8080**:
```bash
-p 80:8080
```

**The analogy:** `-p 80:8080` is a mail-forwarding rule — "anything arriving at the building's front door (host port 80) goes to apartment 8080 (where Apache actually lives)." Before, I was forwarding mail to an empty apartment (port 80).

### Problem 3: Running commands on the wrong server

**Error:**
```
root@ip-172-31-3-237:~# docker rm -f waf
Command 'docker' not found
```

**Root cause:** I was SSH'd from the WAF box *into* the backend box. The backend has no Docker. Every command landed on the wrong machine.

**Fix:** Type `exit` to return to the WAF (`172.31.1.12`). **Always read the prompt hostname first.**

### Problem 4: `curl localhost` on the backend returned 200 (bypassing the WAF)

**Symptom:** A SQLi test returned `200 OK` instead of `403`.

**Root cause:** I ran `curl localhost` on the **backend** box, where `localhost` = nginx directly — the request never went through the WAF.

**Fix:** Test from the WAF box (`localhost` = WAF) or from the WAF's public IP. This also revealed a real security gap: the backend answers direct requests, so it **must** be locked down by security group (see Section 10).

---

## 5. Approach B: The Official OWASP Image (What Shipped)

After the version wars, I switched to the **official OWASP ModSecurity-CRS image**. The OWASP team maintains it with Apache + ModSecurity + CRS all correctly version-matched — the "order the finished dish" approach instead of cooking from raw ingredients.

**It has reverse-proxy and env-var support built in**, which is exactly what I was hand-building. So I kept my entire design (reverse proxy, env-driven backend, DetectionOnly→On workflow) with **zero version maintenance**.

### The one command that replaced the whole custom build

```bash
docker run -d \
  --name waf \
  -p 80:8080 \
  -e BACKEND="http://172.31.3.237" \
  -e MODSEC_RULE_ENGINE="On" \
  -e PARANOIA=1 \
  -e SERVER_NAME="localhost" \
  --restart unless-stopped \
  owasp/modsecurity-crs:apache
```

### Environment variables (the official image)

| What it controls | Env var | Values |
|------------------|---------|--------|
| Backend to protect | `BACKEND` | `http://172.31.3.237` (any IP/URL) |
| Detection vs blocking | `MODSEC_RULE_ENGINE` | `DetectionOnly` / `On` / `Off` |
| Rule strictness | `PARANOIA` | `1` – `4` |
| Domain Apache answers for | `SERVER_NAME` | `localhost` or a real domain |

### Reusing for multiple clients

Same image, swap one value:
```bash
# Client A
docker run -d --name waf-clientA -p 80:8080 \
  -e BACKEND="http://CLIENT_A_IP" -e MODSEC_RULE_ENGINE="On" \
  --restart unless-stopped owasp/modsecurity-crs:apache
```

### Verify it booted clean

```bash
docker logs waf
```
Look for:
```
ModSecurity for Apache/2.9.15 ... configured
Detected CRS config file version: v4
AH00094: Command line: 'httpd -D FOREGROUND'
```

> **Note:** red `ssl:error` / `ssl_stapling` lines on boot are **harmless** — they're about OCSP stapling on the built-in self-signed cert for port 8443. On HTTP it's irrelevant; in production you'd mount a real cert.

---

## 6. Detection Mode vs Blocking Mode — Why Detection First

| Mode | Behavior | When to use |
|------|----------|-------------|
| `DetectionOnly` | Logs attacks but **lets them through** | Onboarding a new client — watch before acting |
| `On` | **Blocks** attacks (returns 403) | Production — after tuning false positives |
| `Off` | WAF disabled | Troubleshooting only |

**Why run DetectionOnly FIRST on a real client?**

A WAF can mistakenly flag *legitimate* traffic — a **false positive**. Imagine a client's blog where someone writes a post containing the word `SELECT`, or a developer pastes code into a form. A strict rule might read that as SQL injection and **block a real customer**.

If you turn on blocking from day one, you discover these false positives *after* you've already broken real users.

**The safe rollout:**
```
Week 1-2:  DetectionOnly  →  watch logs, learn normal traffic,
                             write exclusion rules for false positives
Week 3+:   On              →  block, confident you won't hurt real users
```

**The analogy:** DetectionOnly is a **new security guard spending two weeks watching the lobby** before he's allowed to stop anyone — he learns which regulars are staff vs. intruders. Turn him loose on day one and he might tackle the CEO.

**For my portfolio demo**, since the backend is my own test nginx, I used `On` immediately — the point was to *see* the 403 block as proof it works.

---

## 7. Reading the Logs

There are **three log types**, each answering a different question. In the official image, all stream to `docker logs`.

| Log | Question it answers | Analogy |
|-----|---------------------|---------|
| **Access log** | "Who visited, and what did they request?" | The **guest sign-in book** (every visitor) |
| **Error log** | "Why was this request blocked?" | The **incident report** (one-line verdict) |
| **Audit log** | "Full forensic detail of the attack + which rules fired" | The **security camera footage** (the evidence) |

### Commands

```bash
# All container logs (access + error + audit stream here)
docker logs waf

# Follow live (run this, then fire an attack from another window)
docker logs -f waf

# Just the blocks / attacks
docker logs waf 2>&1 | grep -i "denied\|forbidden\|critical"

# A specific attack family (942 = SQL injection)
docker logs waf 2>&1 | grep "942" | tail -5

# Block decisions only (949110 = the rule that issues the 403)
docker logs waf 2>&1 | grep "949110"
```

### CRS rule-ID families (useful to know)

| ID range | Attack type |
|----------|-------------|
| `941xxx` | XSS (Cross-Site Scripting) |
| `942xxx` | SQL Injection |
| `930xxx` | Path Traversal / LFI |
| `932xxx` | Remote Command Execution |
| `949110` | The final "block decision" (anomaly score exceeded) |
| `980170` | The summary scoreboard |

---

## 8. How to Read an Audit Log Entry

This is the real SQLi block from my test. Three rules fire as a team:

### Rule 1 — The detector (`id 942100`)
```
detected SQLi using libinjection with fingerprint 's&sos'
Matched Data: s&sos found within ARGS:id: 1' OR '1'='1
[id "942100"] [severity "CRITICAL"] [tag "attack-sqli"]
```
This is the **smoke detector that smelled smoke**. It caught `1' OR '1'='1` in the `id` parameter.
- `Matched Data` = **the exact payload** the attacker sent (gold for forensics)
- `severity CRITICAL` = how dangerous
- `libinjection` = the engine that reduced the attack to a known-bad signature

### Rule 2 — The judge (`id 949110`)
```
Access denied with code 403 (phase 2).
Operator GE matched 5 at TX:blocking_inbound_anomaly_score
[msg "Inbound Anomaly Score Exceeded (Total Score: 5)"]
```
Where the **actual block happens**. CRS uses a **scoring system**: the SQLi scored `5`, the threshold is `5`, so `5 >= 5` → **403**. `GE` = "greater-than-or-equal."

### Rule 3 — The reporter (`id 980170`)
```
Anomaly Scores: (SQLI=5, XSS=0, RFI=0, LFI=0, RCE=0 ... COMBINED_SCORE=5)
```
The **incident scoreboard** — scored 5 on SQLi, zero on everything else. Total 5. Blocked.

### The JSON record (the full case file)

| Field | Example | Meaning |
|-------|---------|---------|
| `remote_address` | `172.17.0.1` | Who sent it |
| `request_line` | `GET /?id=1' OR '1'='1` | The exact request |
| `status` | `403` | What the WAF did |
| `intercepted` | `true` | Confirms **blocked**, not just logged |
| `unique_id` | `avuNobGe8mOX...` | Case number tying all 3 rule messages to one request |
| `engine_mode` | `ENABLED` | Blocking mode is on |

### The ONE concept to remember

**CRS blocks on a cumulative *anomaly score*, not single rules.** Each suspicious thing adds points; cross the threshold (default 5) and you're blocked. A request that's *slightly* odd in three ways (2+2+2=6) gets blocked even if no single rule screams "attack." **Cumulative suspicion** — like a bouncer who lets one red flag slide but not three.

---

## 9. Testing the WAF

```bash
# Normal request — should return the backend (Server: nginx), 200
curl -I http://localhost

# SQL injection — blocked in On mode (Server: Apache), 403
curl -i "http://localhost/?id=1%27%20OR%20%271%27=%271"

# XSS
curl -i "http://localhost/?q=<script>alert(1)</script>"

# Path traversal
curl -i "http://localhost/../../../../etc/passwd"
```

**The tell-tale sign of a block:** the response header says **`Server: Apache`** (the WAF answered) instead of **`Server: nginx`** (the backend answered). If you see `Server: Apache` + `403`, the attack never reached your app.

| Request | Mode `On` result | `Server:` header |
|---------|------------------|------------------|
| Normal | `200 OK` | `nginx` (backend answered) |
| SQLi | `403 Forbidden` | `Apache` (WAF blocked) |

---

## 10. Current Drawbacks / What's Missing

Honesty for the interview — this is a working WAF, but **not yet production-hardened**. Known gaps:

### 1. No monitoring / observability system (biggest gap)
Right now, logs just sit in `docker logs`. There is **no dashboard, no alerting, no metrics**. I can't see attack trends over time, get notified of a spike, or visualize what's being blocked.

**What production needs:** ship the ModSecurity audit logs into a monitoring stack — e.g.
- **ELK / OpenSearch** (Elasticsearch + Logstash + Kibana) for searchable dashboards
- **Grafana + Loki** for log visualization and alerting
- **Prometheus** for metrics (requests/sec, block rate)
- A **SIEM** for security correlation

Without this, I'm flying blind — the WAF blocks attacks, but no one is *watching* the blocks.

### 2. Logs don't persist across container restarts
Logs live inside the container and vanish if it's removed. Fix — mount a host volume:
```bash
docker run -d --name waf -p 80:8080 \
  -e BACKEND="http://172.31.3.237" \
  -e MODSEC_RULE_ENGINE="On" -e PARANOIA=1 -e SERVER_NAME="localhost" \
  -e MODSEC_AUDIT_LOG=/var/log/modsec/audit.log \
  -v /var/log/waf:/var/log/modsec \
  --restart unless-stopped \
  owasp/modsecurity-crs:apache
```
Then logs persist at `/var/log/waf/audit.log` on the host.

### 3. Backend is not locked down
`172.31.3.237` still answers direct requests, meaning the WAF can be bypassed. **Fix:** set the backend's security group to allow inbound port 80 **only from the WAF** (`172.31.1.12` or the WAF's security group ID).

### 4. No HTTPS/TLS on the WAF
Traffic between client and WAF is plain HTTP. Production needs a real TLS cert (Let's Encrypt) mounted into the container.

### 5. No false-positive tuning yet
Running at paranoia 1 with no exclusion rules. A real client's app would need its false positives tuned out during the DetectionOnly phase.

### 6. Single point of failure
One WAF container on one EC2. Production would want multiple WAF instances behind a load balancer for high availability.

---

## 11. Interview Cheat-Sheet

**Q: What did you build?**
A reverse-proxy WAF on AWS — Apache + ModSecurity + OWASP CRS in Docker. It inspects every HTTP request and blocks attacks (SQLi, XSS, etc.) before they reach the backend web server.

**Q: Why a reverse proxy?**
The WAF sits between the internet and the app. The app has a private IP with no public exposure — the only way in is through the WAF, so attackers can't bypass it.

**Q: What was the hardest problem?**
A version mismatch: Ubuntu's packaged ModSecurity was too old for modern OWASP CRS (`MULTIPART_PART_HEADERS` error). I learned that hand-assembling version-sensitive security tools is fragile, and switched to the maintained official OWASP image, which solves compatibility at the source while keeping my architecture.

**Q: How does ModSecurity decide to block?**
It uses an **anomaly scoring system**, not single rules. Each suspicious pattern adds points; when the total crosses the threshold (default 5), the request gets a 403. This catches attacks that are subtly malicious in several small ways.

**Q: Why DetectionOnly before blocking?**
To avoid false positives breaking real traffic. You observe for 1–2 weeks, tune exclusions, then switch to blocking.

**Q: Biggest weakness of your current setup?**
No monitoring/observability — logs aren't shipped to a dashboard or alerting system. Next step is an ELK or Grafana+Loki stack so attacks are visible and alertable, not just sitting in `docker logs`.

**Q: How do you reuse it for multiple clients?**
Same image, change one environment variable (`BACKEND`). Build once, deploy per client.

---

## Appendix — Full Working Commands (Copy-Paste)

```bash
# ── On the WAF server (172.31.1.12) ──

# Pull & run in BLOCKING mode, proxying to the backend
docker run -d \
  --name waf \
  -p 80:8080 \
  -e BACKEND="http://172.31.3.237" \
  -e MODSEC_RULE_ENGINE="On" \
  -e PARANOIA=1 \
  -e SERVER_NAME="localhost" \
  --restart unless-stopped \
  owasp/modsecurity-crs:apache

# Verify boot
docker logs waf

# Test normal traffic (expect 200, Server: nginx)
curl -I http://localhost

# Test SQLi (expect 403, Server: Apache)
curl -i "http://localhost/?id=1%27%20OR%20%271%27=%271"

# See the block in the audit log
docker logs waf 2>&1 | grep "942" | tail -5

# ── Switch to DetectionOnly (for onboarding a real client) ──
docker rm -f waf
docker run -d --name waf -p 80:8080 \
  -e BACKEND="http://172.31.3.237" \
  -e MODSEC_RULE_ENGINE="DetectionOnly" \
  -e PARANOIA=1 -e SERVER_NAME="localhost" \
  --restart unless-stopped \
  owasp/modsecurity-crs:apache
```

---

*Built on AWS EC2 with Docker. WAF engine: ModSecurity 2.9.15. Rules: OWASP CRS v4.30.0.*
