# WAF Lab: Apache + ModSecurity on AWS (Without Docker)

## What This Project Does

This project sets up a **Web Application Firewall (WAF)** using two EC2 instances on AWS. One instance runs Apache with ModSecurity as the security gate. The other instance runs Nginx with the actual website. All traffic must pass through the WAF before it reaches the website.

```
Internet → [Instance A: Apache + ModSecurity + CrowdSec] → VPN Tunnel → [Instance B: Nginx + Website]
```

**Instance A (WAF)** — the security guard. It inspects every request using ModSecurity and the OWASP Core Rule Set (CRS), blocks attacks, and forwards clean traffic to the backend.

**Instance B (Backend)** — the actual web server. It runs Nginx with your website (static, Laravel, Django, etc.). It has no public web ports — it can only be reached through the VPN tunnel from Instance A.

---

## What It Protects Against

| Attack Type | How It's Blocked |
|---|---|
| SQL Injection (`' OR 1=1--`) | ModSecurity + CRS rule 942xxx |
| Cross-Site Scripting (XSS) | ModSecurity + CRS rule 941xxx |
| Path Traversal (`/etc/passwd`) | ModSecurity + CRS rule 930xxx |
| Remote Code Execution | ModSecurity + CRS rule 932xxx |
| Automated Scanners (sqlmap, Nikto) | CRS scanner detection rules |
| Brute-Force Login Attempts | CrowdSec + Fail2ban |
| Known Bad IPs | CrowdSec community blocklist |
| Small-to-Medium Request Floods | CrowdSec rate limiting + iptables |
| Direct Backend Access | Backend hidden behind VPN — no public web ports |

---

## What It Cannot Protect Against (Limitations)

| Limitation | Why | Workaround |
|---|---|---|
| Large DDoS (gigabit-level floods) | A single EC2 instance's network link fills up before the WAF can inspect anything | Put Cloudflare or AWS Shield Advanced in front |
| Application Logic Bugs (e.g., user A sees user B's data by changing `?order=102`) | The request looks normal to the WAF — it's a code problem | Fix in application code |
| Stolen Credentials | A login with a real stolen password looks like a normal login | Use MFA in the application |
| Zero-Day Attacks | CRS only knows published attack patterns | Keep CRS updated, raise paranoia level for sensitive apps |
| Server-Level Vulnerabilities (unpatched OS, weak SSH) | The WAF only inspects web traffic, not the OS | Harden the server separately |
| Single Point of Failure | One WAF instance means one failure point | Add a second WAF behind a load balancer for high availability |

---

## Architecture

### Network Layout

```
┌─────────────────────────────────────────────────────────┐
│                        AWS VPC                          │
│                                                         │
│  ┌──────────────────────┐    ┌───────────────────────┐  │
│  │   Instance A (WAF)   │    │  Instance B (Backend) │  │
│  │                      │    │                       │  │
│  │  Apache 2.4          │    │  Nginx                │  │
│  │  ├── ModSecurity v2  │    │  └── Website           │  │
│  │  ├── OWASP CRS       │    │      (Laravel/static) │  │
│  │  ├── mod_proxy        │    │                       │  │
│  │  ├── CrowdSec        │    │  Listens ONLY on      │  │
│  │  └── Fail2ban        │    │  WireGuard tunnel IP   │  │
│  │                      │    │  (10.0.0.2:80)        │  │
│  │  WireGuard: 10.0.0.1 │◄──►│  WireGuard: 10.0.0.2 │  │
│  │  Public IP: Elastic  │    │  Public IP: SSH only  │  │
│  └──────────────────────┘    └───────────────────────┘  │
│                                                         │
│  Security Groups:                                       │
│  A: 80, 443 from internet │ 22 from your IP             │
│  B: 51820/udp from A │ 22 from your IP │ NO 80/443      │
└─────────────────────────────────────────────────────────┘
```

### How the Reverse Proxy Works

Apache on Instance A uses `mod_proxy` and `mod_proxy_http` to forward requests to Instance B. The backend is reached through a **WireGuard VPN tunnel** using Instance B's **private tunnel IP** (`10.0.0.2`), not its public IP.

```apache
<VirtualHost *:80>
    ServerName shop.example.com

    # ModSecurity inspects the request first
    SecRuleEngine On

    # Clean requests are forwarded to the backend through the VPN tunnel
    ProxyPass        / http://10.0.0.2/
    ProxyPassReverse / http://10.0.0.2/
</VirtualHost>
```

**Why the tunnel IP instead of a public IP?**
- Traffic between the WAF and backend is encrypted inside the WireGuard tunnel.
- The backend's web port is only open on the tunnel interface — attackers cannot reach it directly from the internet.
- Even if someone discovers Instance B's public IP, ports 80 and 443 are closed.

---

## How Logging and Monitoring Works

### Three Log Files

| Log File | What It Contains | Use Case |
|---|---|---|
| `/var/log/apache2/access.log` | Every request: IP, URL, status code, user agent | See total traffic, spot 403 spikes |
| `/var/log/apache2/error.log` | One-line ModSecurity alerts: rule ID, message | Quick search for which rules are firing |
| `/var/log/apache2/modsec_audit.log` | Full JSON evidence: request headers, body, matched data, score | Deep investigation, client reports |

### How to Find Blocked Requests

**In On mode** — search for rule 949110 (the rule that triggers the actual block):
```bash
grep "949110" /var/log/apache2/error.log
```

**In DetectionOnly mode** — the same rule 949110 still fires, but it only logs without blocking. This shows requests that *would have been blocked*:
```bash
grep "949110" /var/log/apache2/error.log
```

**Find the most triggered rules:**
```bash
grep -oP 'id "\K[0-9]+' /var/log/apache2/error.log | sort | uniq -c | sort -rn | head
```

**Get full details of a specific request using its unique ID:**
```bash
grep "UNIQUE_ID_HERE" /var/log/apache2/modsec_audit.log | jq .
```

### Monitoring Stack

```
Apache/ModSecurity logs → Grafana Alloy → Loki ──┐
                                                  ├── Grafana Dashboard
node_exporter (CPU, RAM, disk) → Prometheus ──────┘
```

- **Grafana Alloy** (replaces Promtail): reads log files and ships them to Loki.
- **Loki**: stores logs, lets you query them with LogQL.
- **Prometheus + node_exporter**: collects WAF server metrics (CPU, memory, network).
- **Grafana**: displays everything in one dashboard.

### What the Grafana Dashboard Shows

| Panel | Query (LogQL) | Purpose |
|---|---|---|
| Attacks blocked per hour | `sum(count_over_time({job="modsecurity"} \|= "949110" [1h]))` | Show overall attack volume |
| Top attacking IPs | `sum by (client_ip) (count_over_time({job="modsecurity"} \| json [1h]))` | Identify repeat offenders |
| Top triggered rule IDs | Filter and count by `ruleId` from JSON logs | See what types of attacks are happening |
| WAF CPU and memory | `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes` | Monitor WAF server health |

---

## How to Tell If It's Working

A properly working WAF produces three things for every attack:

1. **A 403 in the browser** — the attacker sees "Forbidden"
2. **An audit log entry** — the full evidence with rule ID and score
3. **A spike on the Grafana dashboard** — visible proof for the client

If any of the three is missing, something in the chain is broken.

### Quick Test

```bash
# This should return 403 Forbidden
curl -i "http://YOUR_WAF_IP/?id=1' OR 1=1--"

# This should return 200 OK (normal request)
curl -i "http://YOUR_WAF_IP/"
```

---

## How CrowdSec Adds Protection

CrowdSec reads the ModSecurity audit log and Apache access log. When it spots an attacker (e.g., an IP that triggered 50 SQL injection rules in one minute), it adds a firewall rule to drop that IP completely — before the request even reaches Apache.

```
Without CrowdSec:
  Attacker → Apache → ModSecurity checks every request → 403

With CrowdSec:
  Attacker → iptables drops the IP immediately → never reaches Apache
```

CrowdSec also shares a **community blocklist** — known bad IPs reported by thousands of other CrowdSec users worldwide. So an IP that attacked a server in France gets blocked on your server before it even tries.

---

## Tuning: Handling False Positives

### The Process

1. Start with `SecRuleEngine DetectionOnly` — nothing is blocked, everything is logged.
2. Browse the site yourself: log in, submit forms, upload files, save posts in admin.
3. Search for your own IP in the logs — if your normal actions triggered rules, those are false positives.
4. Search for rule 949110 to find all requests that would have been blocked.
5. Write narrow exclusion rules (one rule, one field, one page).
6. Switch to `SecRuleEngine On`.

### Exclusion Example

If rule 942100 keeps triggering on the `comment` field of `/blog/post-comment`:

```apache
# Bad: disables the rule for the entire site
# SecRuleRemoveById 942100

# Good: skips only this field on this page
SecRule REQUEST_URI "@beginsWith /blog/post-comment" \
    "id:10001,phase:1,pass,nolog,ctl:ruleRemoveTargetById=942100;ARGS:comment"
```

### How to Tell False Positives from Real Attacks

| False Positive (normal user) | Real Attack |
|---|---|
| Many different IPs, same rule, same normal page | One IP, many different rules, unusual pages |
| Normal browser (Chrome, Firefox) | Scanner user agent (sqlmap, Nikto) |
| Score just above the threshold (5-6) | Score very high (20+) |
| Normal data like "I'll select the best one" | Obvious payload like `' OR 1=1--` |

---

## Technologies Used

| Tool | Role |
|---|---|
| AWS EC2 | Two instances (WAF + Backend) |
| Apache 2.4 | Reverse proxy + WAF host |
| ModSecurity v2 (mod_security2) | WAF engine |
| OWASP CRS v4 | Attack detection ruleset |
| Nginx | Backend web server |
| WireGuard | VPN tunnel between WAF and backend |
| CrowdSec | IP reputation + automatic banning |
| Fail2ban | Brute-force protection |
| Grafana | Dashboard and visualization |
| Loki | Log storage |
| Grafana Alloy | Log shipper |
| Prometheus + node_exporter | Server metrics |
| Let's Encrypt | HTTPS on the WAF |

---

## Author

**Masba Uddin Rumi **
Senior System Administrator | Infrastructure & Security Engineer
[GitHub](https://github.com/MasbaIUBAT) · [LinkedIn](https://linkedin.com/in/masba-uddin-rumi)
