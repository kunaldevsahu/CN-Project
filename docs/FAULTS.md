# Extension F · Faculty-injected fault: method and practice drills

## The method (say each step out loud)

Always go **bottom-up along the request path** and stop at the first layer that fails. Everything above a broken layer gives misleading symptoms.

| # | Question | Command (client unless noted) | Healthy answer |
|---|---|---|---|
| 0 | Which DNS servers am I asking? Any local override? | `scutil --dns \| grep -A3 'resolver #1'` · `grep team1 /etc/hosts` | 10.7.17.233, 10.7.3.175 · nothing |
| 1 | **DNS**: does the name resolve, to the right IP? | `dig app.team1.test` (look at `status`, `ANSWER`, `SERVER`) · `dscacheutil -q host -a name app.team1.test` | NOERROR, 10.7.30.229, both commands agree |
| 2 | **IP**: is that host reachable? | `ping -c 2 10.7.30.229` | replies (TTL 64 = same LAN) |
| 3 | **TCP**: is the service port open? | `nc -vz -G 3 10.7.30.229 443` | `succeeded` |
| 4 | **TLS**: does the handshake complete, is the cert trusted for this name? | `curl -v https://app.team1.test/ 2>&1 \| grep -E 'SSL\|subject\|issuer\|expire\|error'` | `SSL certificate verify ok` |
| 5 | **HTTP**: what does the edge answer? | `curl -si https://app.team1.test/api/status` | 200 + X-Backend |
| 6 | **Edge → backend** (edge Mac) | `bash scripts/diagnose-edge.sh` · `tail error.log` | both backends 200 |

`bash scripts/diagnose.sh` runs steps 0–5 plus a load-balancing check and names the first failing layer. Use it to confirm, but **explain the manual commands**: the marks are for the reasoning.

### Reading the symptom quickly

| What the client sees | Layer | Meaning |
|---|---|---|
| `curl: (6) Could not resolve host` | DNS | no answer at all: servers down/unreachable, client pointed at wrong server, name missing (NXDOMAIN) |
| resolves, but to an unexpected IP | DNS (data) | wrong record, stale client cache, or `/etc/hosts` override (dig right, curl wrong ⇒ /etc/hosts or cache) |
| `curl: (7) … Couldn't connect` quickly, `nc`: **refused** | TCP | host up, nothing listening on that port (nginx down, wrong port) |
| `curl: (28)` / `nc`: **timed out** | IP / TCP | host down/asleep, wrong IP, or a firewall dropping packets |
| `curl: (35)` | TLS | handshake failed: protocol/cipher mismatch, or not TLS on that port |
| `curl: (60)` | TLS (trust) | cert not trusted: CA removed from keychain, name not in SAN, expired, clock wrong |
| `HTTP 502` | edge → backend | edge OK; backends refused/reset (process stopped, bound to 127.0.0.1, wrong upstream port) |
| `HTTP 504` | edge → backend | edge OK; backends did not answer in time (asleep, wrong upstream IP, pf dropping the edge) |
| `HTTP 404` / wrong JSON | application / routing | request reached the wrong service or path |
| only `X-Backend: B` | edge → backend A | A down or unreachable from the edge; nginx failing over |

## Practice drills

One member injects a fault in secret; the others diagnose with the method above, out loud, against a timer (target: < 5 min). Undo after each drill and confirm A/B alternation.

| # | Inject (who / command) | Expected client symptom | Layer | Fix |
|---|---|---|---|---|
| 1 | Vaibhav **and** Himanshu: `sudo brew services stop dnsmasq` | `(6) Could not resolve host`; `dig` times out on both servers | DNS service | start dnsmasq |
| 2 | Vaibhav: `set-record.sh app.team1.test 10.7.30.71` (on both DNS Macs) | resolves to 10.7.30.71, `nc … 443` refused | DNS data | correct the record |
| 3 | Kunal's own Mac: `sudo networksetup -setdnsservers Wi-Fi 8.8.8.8` | NXDOMAIN from 8.8.8.8 | client DNS config | set both team servers back |
| 4 | Client: `echo "10.7.3.175 app.team1.test" \| sudo tee -a /etc/hosts` | `dig` correct, curl goes to Mac 3 (standby edge or refused) | client resolution (hosts file) | remove the line, flush cache |
| 5 | Pranav: `sudo brew services stop nginx` | `nc 443` refused, `(7)` | TCP / edge service | start nginx |
| 6 | Pranav: change `listen 443 ssl;` → `listen 8443 ssl;`, restart | `nc 443` refused, `nc 8443` succeeds | TCP port | restore 443 |
| 7 | Pranav: add a typo (remove a `;`) and try to restart | nginx doesn't start → refused; `sudo nginx -t` shows the line | edge config | fix syntax, `nginx -t` |
| 8 | Client: delete Team1 CA from System keychain (Keychain Access → System → "Team1 Local Root CA") | `(60) SSL certificate problem` | TLS trust | re-add `rootCA.pem` |
| 9 | Pranav: point `ssl_certificate` at a self-signed cert for another name (`openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=wrong.test -keyout /tmp/w.key -out /tmp/w.crt`) | `(60)` subject/SAN mismatch | TLS cert | restore team1.crt/key |
| 10 | Pranav: `ssl_protocols TLSv1.3;` · client tests with `curl --tls-max 1.2` | `(35)` handshake failure / protocol version alert | TLS version | restore TLSv1.2 TLSv1.3 |
| 11 | Pranav: change both upstream ports to 3005 | `502`; error.log `connect() failed (61: Connection refused)` | edge → backend (port) | restore 3001/3002 |
| 12 | Pranav: change Backend A's upstream IP to an unused one (10.7.3.250) | only B; first hit slow ≈2 s, `x-up-status: 504, 200` (or `502, 200` + `Host is down` in error.log) | edge → backend (IP) | restore IP |
| 13 | Himanshu: start Backend A with `app.listen(PORT, "127.0.0.1")` | only B; edge `curl 10.7.3.175:3001` refused, `curl 127.0.0.1:3001` on Mac 3 works | backend bind address | bind 0.0.0.0 |
| 14 | Himanshu + Kunal: pf on with the edge IP changed in the rule (`edges = "{ 10.7.30.99 }"`) | `504` for every request | firewall / isolation | fix the edge IP, or `fw-off.sh` |
| 15 | Vaibhav: `local-ttl=3600`, then a record change | clients keep the old IP for an hour | DNS TTL | lower TTL, flush client caches |
| 16 | Edge Mac: set the clock a year ahead (or cert expired) | `(60) certificate has expired / not yet valid` | TLS validity | correct the clock / reissue |

### Other things that have bitten us / might bite
- **DHCP gave a Mac a new IP** (see RUNBOOK): edge IP change ⇒ DNS record + **pf rules** on both backends; backend IP change ⇒ nginx upstream on **both** edges.
- **macOS Application Firewall** (System Settings → Network → Firewall) set to block incoming connections ⇒ the backup DNS or standby nginx on Mac 3 times out. Allow `dnsmasq` / `nginx` or turn it off for the demo.
- **Mac asleep** ⇒ looks like "host down" (timeouts). `caffeinate -dims` on DNS and edge Macs.
- Old copy of `team1.conf` left inside `servers/` ⇒ `duplicate upstream "team1_backends"` on `nginx -t`.
