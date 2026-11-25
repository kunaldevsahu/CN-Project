# Phase 2 setup: Harden & Recover

Builds on the Phase 1 network; nothing is rebuilt. Do the steps in this order: each one assumes the previous one works.
Run `docs/RUNBOOK.md` first (IPs unchanged, A/B alternating) before starting.

## As built (2026-11-25): read this first
Pranav's **Mac 2 was not available** for Phase 2, so the **edge moved to Mac 4** (Kunal) and Mac 1 became the main test
client. The steps further down are the original plan (edge on Mac 2) and are kept for the reasoning; where they name
Mac 2 / 10.7.30.229, read Mac 4 / 10.7.30.71. What was actually done, and the script for each part:

| Part | As built | Script / file |
|---|---|---|
| One-time per Mac | passwordless `sudo -n` for 10 programs, trust the CA, `team1.hosts` owned by the user | `sudo bash scripts/phase2/bootstrap-mac.sh` (at each Mac) |
| TLS | new CA "Team1 Local Root CA 2026-11" + edge cert on Mac 4; standby cert for mac3 from the same CA | `certs/make-certs.sh`, `certs/make-standby-cert.sh` |
| Edge | nginx on Mac 4 as a user LaunchAgent (`brew services start nginx`), config `nginx/phase2/team1.conf` (A = 10.7.3.175:3001, B = 127.0.0.1:3002) | `scripts/phase2/edge-move-check.sh pre\|post` |
| Records | app/api → 10.7.30.71, both DNS servers at once | `scripts/phase2/set-record-both.sh <name> <ip>` |
| Standby edge | nginx on mac3 **as root** (Local Network privacy blocks a user-level nginx over ssh), config `nginx/phase2/team1-standby.conf` | `scripts/phase2/E-standby.sh up\|down\|check` |
| Ext A–F tests | one script each, evidence in `evidence/phase2/<ext>/` | see `docs/PHASE2-DEMO.md` and `evidence/phase2/README.md` |
| pf (Ext C) | anchor `com.apple/team1`, only `sudo -n /sbin/pfctl`; `fw-on.sh`/`fw-off.sh` are superseded | `C-apply.sh`, `C-test.sh`, `C-rollback.sh` |
| Diagnosis | PASS/FAIL per layer from a client; edge-side checks | `scripts/diagnose.sh`, `scripts/diagnose-edge.sh`, `scripts/phase2/F-drill.sh` |

## Phase 2 roles (as built)

| Machine | Member | IP | Phase 1 role | Phase 2 |
|---|---|---|---|---|
| Mac 1 | Vaibhav | 10.7.17.233 | dnsmasq primary + client | primary DNS (`team1.hosts`, TTL 30) · **main test client** |
| Mac 2 | Pranav | 10.7.30.229 | nginx edge (primary) | **not available**; its role moved to Mac 4 |
| Mac 3 | Himanshu | 10.7.3.175 | Backend A :3001 | **backup DNS** (Ext A) · **standby edge** (Ext E) · pf rule on 3001 (Ext C) |
| Mac 4 | Kunal | 10.7.30.71 | Backend B :3002 + capture client | **primary edge (nginx :443)** + Backend B · runs all test scripts · pf rule on 3002 (Ext C) |

Trade-offs (say them in the viva): **Mac 4 is edge + Backend B** (shared fate: if it dies, the edge and one backend go
together). **Mac 3 is a shared failure domain**: Backend A, the backup DNS and the standby edge. Mac 1 is both client and
primary DNS, so its own lookups go over `lo0` (captures on mac1 use `-i pktap,en0,lo0`).

Paths assume Apple-silicon Homebrew (`/opt/homebrew`). On an Intel Mac replace with `/usr/local` in the configs.

---

## Step 1 · Move both DNS servers to the Phase 2 config (Ext A + B groundwork)

**Mac 1 (Vaibhav)** and then **Mac 3 (Himanshu)**, identical steps:
```bash
cd ~/CN-Project                                   # this repo
brew install dnsmasq                              # Mac 3 only, Mac 1 already has it
cp $(brew --prefix)/etc/dnsmasq.conf ~/dnsmasq.conf.phase1 2>/dev/null   # rollback copy
cp dns/phase2/dnsmasq.conf  $(brew --prefix)/etc/dnsmasq.conf
cp dns/phase2/team1.hosts   $(brew --prefix)/etc/team1.hosts
$(brew --prefix)/sbin/dnsmasq --test --conf-file=$(brew --prefix)/etc/dnsmasq.conf   # syntax check OK.
sudo brew services restart dnsmasq                # Mac 3: "start" the first time
dig @127.0.0.1 app.team1.test +noall +answer      # app.team1.test. 30 IN A 10.7.30.229
dig @127.0.0.1 google.com +short                  # still forwards upstream
```
Watch queries arrive: `tail -f /opt/homebrew/var/log/dnsmasq.log`

**Clients list both servers** (Kunal; also Himanshu):
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.17.233 10.7.3.175
networksetup -getdnsservers Wi-Fi
scutil --dns | grep -A3 'resolver #1'             # nameserver[0] 10.7.17.233, nameserver[1] 10.7.3.175
dig @10.7.3.175 app.team1.test +short            # backup answers the same: 10.7.30.229
```

## Step 2 · Extension A · Backup DNS failover

Evidence folder: `evidence/phase2/A-backup-dns/`

1. Kunal: Wireshark on `en0`, capture filter `udp port 53 or icmp`.
2. Baseline: `dig app.team1.test` → `;; SERVER: 10.7.17.233#53`.
3. Vaibhav stops the primary: `sudo brew services stop dnsmasq`
4. Kunal:
   ```bash
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   dig app.team1.test                      # ;; SERVER: 10.7.3.175#53 , answer 10.7.30.229
   dscacheutil -q host -a name app.team1.test
   for i in 1 2 3 4; do curl -si https://app.team1.test/api/status | grep -i x-backend; done   # A B A B
   ```
   Himanshu's `tail -f` on the backup log shows Kunal's queries arriving.
5. In Wireshark: query to 10.7.17.233 → **ICMP port unreachable** (Mac 1 is up, nothing on port 53) → same query to 10.7.3.175 → answer.
   Optional second run: Vaibhav turns Wi-Fi **off** instead. Now there is no ICMP, just a timeout (~2–5 s) before the backup is tried. *Service down = fast failover; host down = slow failover.*
6. Contrast with an application failure: restart dnsmasq on Mac 1, stop **both** backends: `dig` still answers, curl gets `502`. *DNS failure: the name stops resolving. App failure: name resolves, TCP/TLS to the edge work, the service behind it is gone.*
7. Restore: `sudo brew services start dnsmasq` (Mac 1), restart backends.

Note: macOS (mDNSResponder) does not strictly use "first server, then second". It may query both and prefer whichever answers faster. That is why both servers must hold **identical** records.

## Step 3 · Extension C · Backend isolation (pf)

Evidence folder: `evidence/phase2/C-isolation/`

1. **Before**: from Kunal and Vaibhav, show the backends are directly reachable (this is the hole we are closing):
   ```bash
   nc -vz -G 3 10.7.3.175 3001; nc -vz -G 3 10.7.30.71 3002      # both succeed
   ```
2. Turn isolation on (the script saves a rollback copy to `~/team1-pf-backup/` first):
   ```bash
   cd ~/CN-Project/firewall
   sudo bash fw-on.sh A      # Himanshu (Mac 3)
   sudo bash fw-on.sh B      # Kunal (Mac 4)
   ```
3. **After**:
   | From | Command | Expected |
   |---|---|---|
   | Vaibhav (client) | `nc -vz -G 3 10.7.3.175 3001` | `Operation timed out` |
   | Vaibhav (client) | `nc -vz -G 3 10.7.30.71 3002` | `Operation timed out` |
   | Kunal (client) | `nc -vz -G 3 10.7.3.175 3001` | `Operation timed out` |
   | Pranav (edge) | `curl -i http://10.7.3.175:3001/api/status` and `:3002` on 10.7.30.71 | `200`, X-Backend A / B |
   | Kunal (client) | `for i in 1 2 3 4; do curl -si https://app.team1.test/api/status \| grep -i x-backend; done` | A B A B through the edge |
4. Dropped-packet proof on the backend: `sudo tcpdump -n -e -i pflog0` while Vaibhav retries `nc` → `rule … block in … 10.7.17.233.xxxxx > 10.7.3.175.3001: Flags [S]`.
   Show the loaded rules: `sudo pfctl -a com.apple/team1 -sr`.
5. **Rollback** (required): `sudo bash fw-off.sh` on both. Re-run the step 1 `nc` lines → succeed again.

Talking points: *timeout* (pf drops the SYN silently) vs *connection refused* (host replies RST because nothing listens). The rule matches on **source IP**, so if Pranav's IP changes the edge is locked out too (→ 504). The macOS Application Firewall (System Settings) filters per *app*, not per source IP, which is why we use pf.

Leave isolation **on** for the rest of Phase 2 if you like; the edges are allowed. Turn it off before Phase 1-style direct backend tests.

## Step 4 · Extension D · HA failover in nginx

Evidence folder: `evidence/phase2/D-failover/`

**Pranav (Mac 2)**, install the Phase 2 edge config:
```bash
mv $(brew --prefix)/etc/nginx/servers/team1.conf ~/team1.conf.phase1     # rollback copy, OUTSIDE servers/
cp ~/CN-Project/nginx/phase2/team1.conf $(brew --prefix)/etc/nginx/servers/team1.conf
sudo nginx -t && sudo brew services restart nginx
```
**Kunal**:
```bash
curl -sI https://app.team1.test/api/status | grep -iE 'x-backend|x-edge|x-upstream'
bash ~/CN-Project/scripts/lb-check.sh 30 1 | tee ~/P2-D-lbcheck.txt      # leave running
```
While it runs:
1. Himanshu stops Backend A (Ctrl+C). Watch for the one line where `x-upstream` = `10.7.3.175:3001, 10.7.30.71:3002` and `x-up-status` = `502, 200`: nginx tried A, got refused, **retried the same request on B**, client still got 200. Then only B for 10 s (A marked down), then nginx tests A again on a real request, fails, B again.
2. Himanshu restarts A (`BACKEND=A PORT=3001 node server.js`). Within ≤10 s A reappears: A B A B.
3. Second variant (timeout instead of refusal): Himanshu turns Mac 3's **Wi-Fi off** (backend "host down"). Now nobody answers the SYN, so the failed attempt usually shows `504, 200` and that request takes ≈2 s (`proxy_connect_timeout`). If macOS gives up on ARP first you may see `502, 200` with error.log saying `Host is down`; either way the client gets 200. Turn Wi-Fi back on.
4. Pranav shows the per-request log: `tail -f /opt/homebrew/var/log/nginx/team1-access.log`.

Talking points: open-source nginx does **passive** health checks (learns from real failures: `max_fails`/`fail_timeout`); **active** checks (probe `/api/status` every N s) need NGINX Plus, HAProxy or a cloud LB (AWS ALB target-group health checks). Remaining **single point of failure: the edge on Mac 2** (and its IP in DNS). Removing it needs two edges plus one of: a floating virtual IP with VRRP/keepalived or CARP, several A records with health-checked DNS (Route 53 failover routing), or anycast/a managed cloud load balancer. Extension E is the manual, DNS-based version of that.

## Step 5 · Standby edge on Mac 3 (groundwork for Ext E)

**Pranav (Mac 2)** issues the standby its own certificate from the same CA:
```bash
cd ~/CN-Project/certs && bash make-standby-cert.sh      # needs rootCA.pem + rootCA.key from Phase 1
```
AirDrop **only** `team1-standby.crt` and `team1-standby.key` to Himanshu.

**Himanshu (Mac 3)**:
```bash
brew install nginx
mkdir -p $(brew --prefix)/etc/nginx/certs $(brew --prefix)/etc/nginx/servers
cp ~/Downloads/team1-standby.crt $(brew --prefix)/etc/nginx/certs/team1.crt
cp ~/Downloads/team1-standby.key $(brew --prefix)/etc/nginx/certs/team1.key
chmod 600 $(brew --prefix)/etc/nginx/certs/team1.key; rm ~/Downloads/team1-standby.*
cp ~/CN-Project/nginx/phase2/team1.conf $(brew --prefix)/etc/nginx/servers/team1.conf   # SAME file as Mac 2
sudo nginx -t && sudo brew services start nginx
```
**Kunal**, test the standby *without touching DNS*:
```bash
curl -si --resolve app.team1.test:443:10.7.3.175 https://app.team1.test/api/status | grep -iE '^HTTP|x-edge|x-backend'
# HTTP/2 200, x-edge: <Mac 3 hostname>, no certificate warning: the client trusts the CA, not a specific cert
```
If pf isolation is on, Mac 4's rule already allows 10.7.3.175 (standby edge) to reach :3002.

## Step 6 · Extension B · TTL and a controlled record change

Evidence folder: `evidence/phase2/B-ttl/`

TTL is 30 s (`local-ttl=30`). The change is made on **both** DNS servers with `dns/phase2/set-record.sh`.

1. Kunal starts the watcher and warms the cache:
   ```bash
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   bash ~/CN-Project/scripts/watch-dns.sh | tee ~/P2-B-ttl-watch.txt
   ```
   Also show the TTL in the answer: `dig app.team1.test +noall +answer` → `30 IN A 10.7.30.229`.
2. Vaibhav **and** Himanshu, at the same moment:
   ```bash
   bash ~/CN-Project/dns/phase2/set-record.sh app.team1.test 10.7.3.175
   ```
3. On Kunal's watcher: `server` flips to 10.7.3.175 immediately, `os-cache` (and `edge`) stay on the old value with `<- client cache still old` for up to 30 s, then flip.
4. Change it back (`set-record.sh app.team1.test 10.7.30.229` on both), and this time Kunal **flushes manually** right after: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` → the next line already shows the new IP, no waiting.
5. Optional: run step 2 on Mac 1 only, to show what happens when the two DNS servers disagree (clients get either answer). Fix by running it on Mac 3 too.

Why `dig` changes before the OS: `dig` sends its own query to the server every time and skips the Mac's cache. curl and browsers go through mDNSResponder, which keeps the answer for the TTL. (Browsers can also keep their own cache and reuse open connections, which is why we show this with curl.)

## Step 7 · Extension E · Edge migration by DNS cutover

Evidence folder: `evidence/phase2/E-cutover/`

Production order: lower the TTL well before the move → bring up the standby → change the record → leave the old edge running until the old TTL has expired → only then stop it.

1. Both edges running (Step 4 and Step 5). Kunal: `bash watch-dns.sh | tee ~/P2-E-cutover.txt` → edge = Mac 2's hostname.
2. Vaibhav: `curl -sI https://app.team1.test/api/status | grep -i x-edge` → Mac 2 (his cache is warm too).
3. Vaibhav **and** Himanshu: `set-record.sh app.team1.test 10.7.3.175`.
4. Observe:
   - Kunal's watcher: still Mac 2 for ≤30 s (cached), then Mac 3. **No failed request** because the old edge is still up while caches drain.
   - A *new* lookup goes straight to the standby: Vaibhav flushes his cache (`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`), curl again → x-edge: Mac 3. Same moment, two clients, two different edges.
   - Pranav: `tail -f /opt/homebrew/var/log/nginx/team1-access.log` stops receiving requests ~30 s after the change.
5. After 30 s+ Pranav may stop Mac 2's nginx (`sudo brew services stop nginx`) and nothing breaks.
6. Cut back: start nginx on Mac 2, `set-record.sh app.team1.test 10.7.30.229` on both DNS servers, wait 30 s.

Variation to show *why* you wait: stop Mac 2's nginx **immediately** after the record change → cached clients fail with `curl: (7) Failed to connect` until their TTL expires.

## Step 8 · Extension F · Practice the faculty-injected fault

See `docs/FAULTS.md`. Use `scripts/diagnose.sh` (client) and `scripts/diagnose-edge.sh` (edge). Do at least three drills where one member secretly injects a fault from the table and the others diagnose it out loud.

## Restore everything to the Phase 2 baseline after a session
```bash
# Mac 1 + Mac 3: records back to the primary edge
bash ~/CN-Project/dns/phase2/set-record.sh app.team1.test 10.7.30.229
# Mac 2 + Mac 3: nginx running; Mac 3 + Mac 4: backends running
# Mac 3 + Mac 4: sudo bash ~/CN-Project/firewall/fw-off.sh   (if you want isolation off)
# Kunal:
for i in 1 2 3 4; do curl -si https://app.team1.test/api/status | grep -iE 'x-backend|x-edge'; done
```
