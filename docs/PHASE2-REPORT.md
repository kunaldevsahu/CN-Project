# Phase 2 Final Report · Team 1 · Private Network Service Platform

Members: Vaibhav (Mac 1) · Pranav (Mac 2, not available for Phase 2) · Himanshu (Mac 3) · Kunal (Mac 4)
Domain: `team1.test` · LAN: college Wi-Fi 10.7.0.0/19 · Measurements: 2026-11-25 · Review 2 date: ____

All numbers below were measured on 2026-11-25 and come from `evidence/phase2/` (index: `evidence/phase2/README.md`).
Every test is a script in `scripts/phase2/` that can be re-run live. Read the learning paragraphs before the viva and
put them in your own words where needed.

## 1. What changed from Phase 1

| Area | Phase 1 | Phase 2 | Why |
|---|---|---|---|
| **Edge** | nginx on Mac 2 (Pranav), 10.7.30.229 | nginx on **Mac 4 (Kunal), 10.7.30.71**, which also runs Backend B | Mac 2 was not available; its private keys could not be moved (`evidence/phase2/edge-move/`) |
| TLS | CA + cert made on Mac 2 | new CA **"Team1 Local Root CA 2026-11"** made on Mac 4; edge cert + a separate standby cert from the same CA; CA trusted on every Mac | the old CA key stayed on Mac 2; mac1 also trusted an older CA than the others |
| DNS servers | dnsmasq on Mac 1 only | + **backup on Mac 3**; clients list `10.7.17.233 10.7.3.175` | Mac 1 down = every lookup failed in Phase 1 |
| DNS records | `host-record=` lines, restart, TTL 60 s | `team1.hosts` + SIGHUP, **TTL 30 s**; `set-record.sh`, `set-record-both.sh` (both servers in the same second) | scripted, visible, identical record changes |
| Backend exposure | 3001/3002 open to the whole LAN | pf anchor `com.apple/team1` on Mac 3/Mac 4: only the edges may connect (applied for tests, then rolled back) | clients must go through the edge |
| nginx failover | `max_fails=1 fail_timeout=10s` | shared `zone` (128k), `max_fails=2 fail_timeout=5s`, retry on `error timeout http_502 http_503`, `proxy_connect_timeout 2s`, max 2 tries | bounded, fast failover and recovery |
| Observability | `X-Backend` header | + `X-Edge`, `X-Upstream`, `X-Upstream-Status`; per-request log with upstream, status per try and ms timestamp | see retries and which edge answered |
| Standby edge | none | nginx on Mac 3 (`X-Edge: mac3-standby`), same settings, own key/cert, used for a DNS cutover | Ext E |
| Troubleshooting | manual RUNBOOK list | `diagnose.sh` (PASS/FAIL per layer, exit code = failing layer), `diagnose-edge.sh`, drills | Ext F |
| Operations | commands typed by hand | one re-runnable script per test, writing timestamped evidence; passwordless `sudo -n` only for 10 named programs | repeatable demo day |

Topology as built:
```
                          ┌── DNS :53 ──► Mac 1  dnsmasq PRIMARY   10.7.17.233  (Vaibhav, also the test client)
Client (Mac 1 / Mac 3) ───┤
                          └── DNS :53 ──► Mac 3  dnsmasq BACKUP    10.7.3.175   (Himanshu)
        │
        └── HTTPS :443 ──► app.team1.test (TTL 30) ──► Mac 4 nginx PRIMARY edge 10.7.30.71 (Kunal)
                                                      (Mac 3 nginx STANDBY edge 10.7.3.175 after a DNS cutover)
                                                         ├─ HTTP :3001 ─► Mac 3 Backend A   [pf: edge 10.7.30.71 only]
                                                         └─ HTTP :3002 ─► Mac 4 Backend B   [pf: 127.0.0.1 + standby 10.7.3.175]
```

## 2. Results

| Test | How (script) | Expected | Observed | Evidence |
|---|---|---|---|---|
| Baseline DNS | `baseline.sh` | answer from the primary, TTL 30 | `NOERROR`, `aa`, TTL 30, `SERVER: 10.7.17.233` | `baseline/01` |
| Baseline HTTPS | `baseline.sh` | trusted without `-k` | TLS 1.3, HTTP/2, `ssl_verify_result=0`; :80 → 301 to https | `baseline/02` |
| Load balancing | `baseline.sh` | A/B alternate | 10 requests, strict alternation, **A=5 B=5** | `baseline/03` |
| Caching | `baseline.sh` | Cache-Control, ETag, 304 | `/api/status` no-store; `/api/cached` max-age=60, **same ETag from A and B**; `If-None-Match` → **304** | `baseline/04` |
| **A** · primary DNS stopped | `A-backup-dns.sh` | answered by the backup, app works | plain dig `SERVER: 10.7.3.175` in **1.05 s** (0.04 s normally); **8/8 × 200** from mac3 and mac1 | `A/02`, `A/06` |
| A · on the wire | pktap on mac3 | ICMP, then backup | query → **ICMP port unreachable** from Mac 1 → same DNS id to the backup **1.01 s later** → answer | `A/03`, `A/04` |
| A · zone ownership | `A-zone-check.sh` | both servers alike | **not alike:** mac3 forwards unknown `team1.test` names to 8.8.8.8 (no `local=/team1.test/`) | `A/07`, `A/08` |
| **B** · record change, TTL 30 | from the E run (`B-ttl-report.sh`) | server changes at once, client after its cache expires | both servers changed in the same second; server answered the new IP at once, mac1 stayed on the old one for **21.3 s** | `B/01`, `E/04` |
| B · manual flush | mac3 as client | immediate | cached → old edge; after `dscacheutil -flushcache` → new edge **at once** | `E/06` |
| B · client cache lifetime | pcap on mac1 | ≈ TTL | mac1 looked the name up only every **37.7 s** (37.75 / 37.65 / 37.73) with TTL 30 | `E/08` |
| **C** · isolation on | `C-apply.sh` + `C-test.sh` | client blocked, edges allowed | mac1 → :3001 and :3002 **timed out (3.03 s)**; unfiltered :3009 refused; edge → A, edge → B, standby → B **200**; HTTPS **8/8** A/B | `C/02` |
| C · dropped, not refused | captures | SYN arrives, no reply | SYNs arrive on mac3/Mac 4, **0 replies**; block-rule counters 3 and 5 = the SYNs | `C/04–06` |
| C · rollback | `C-rollback.sh` | original state | main-ruleset diff **empty**, anchor empty, mac3 Disabled→Disabled, Mac 4 Enabled→Enabled (only our token released), `/etc/pf.conf` identical | `C/07`, `C/08` |
| **D** · Backend A stopped | `D-failover.sh` (60 s loop) | no failed request, B only while A is down | **57/57 × 200**; A down 27.3 s: **A=0, B=24**; **4** requests retried (`502, 200`) | `D/03`, `D/08` |
| D · recovery | same | A back within ~5 s | A served again **3.3 s** after the restart (run 1: 3.8 s) | `D/08`, `D/run1` |
| D · on the wire | pcap on Mac 4 | refused | A's FIN when it exits; each retry = SYN→RST twice (ECN, then plain); one kept-alive connection carried all 41 B requests | `D/07` |
| **E** · edge cutover | `E-standby.sh up`, `E-cutover.sh` | old edge ≤ TTL, then new, 0 errors | **71/71 × 200**; mac1 moved to mac3-standby **21.3 s** after the change; Mac 4's log quiet after 19.9 s, mac3's from 21.2 s | `E/04`, `E/09`, `E/10` |
| E · restore (no flush) | same | back after ≤ cache lifetime | **33/33 × 200**, back on mac4-primary **23.3 s** after the restore; standby stopped only afterwards | `E/12`, `E/13` |
| **F** · diagnose healthy | `diagnose.sh` on mac1 | all PASS | DNS PASS · TCP PASS · TLS PASS · HTTP PASS | `F/00` |
| F · four drills | `F-drill.sh` | first failing layer named | DNS (exit 1), TCP refused (2), TLS curl 60 (3), HTTP 502 (4); fixed and PASS again in 14–28 s | `F/01–04` |
| Phase 1 failures | `phase1-failures.sh` | same as Phase 1 | wrong DNS → curl 6; wrong IP → refused, curl 7; wrong port → refused; B down → 6/6 × 200 via A; both down → **TLS OK, HTTP/2 502** | `phase1-failures/` |

## 3. Troubleshooting findings (Extension F)

Method every time: resolver config → **DNS → TCP (`nc -vz`) → TLS (`openssl s_client`) → HTTP → edge→backend**, stop at
the first layer that fails (`docs/FAULTS.md`, `scripts/diagnose.sh`).

**Real faults we hit while building Phase 2** (details: `evidence/phase2/F/practice-log.md`)

| Fault | First symptom | How we localised it | Layer | Fix |
|---|---|---|---|---|
| Passwordless sudo did nothing on all three Macs | `sudo -n` asked for a password | `sudo -n -l`; the sudoers file literally said `USERNAME ALL=…` | host config | `bootstrap-mac.sh` (rule checked with `visudo -cf`) |
| DNS servers disagreed | mac1 answered 10.7.3.175, mac3 answered 10.7.30.229 | `dig @each server` | DNS data | `set-record-both.sh` on both at once |
| mac1 trusted a different CA | fingerprints differed | `security find-certificate -Z` per Mac | TLS trust | one new CA, trusted everywhere |
| `zone 64k` rejected | `nginx -t`: zone "team1_backends" is too small | tested sizes in a scratch config | edge config | 128k (16 KB pages on Apple silicon) |
| `set-record.sh` broken over ssh | would write `/etc/team1.hosts` | `brew` not on PATH in ssh shells | tooling | fall back to `/opt/homebrew` |
| **Standby edge could not reach Backend B** | all requests 200 but always from A; `x-upstream: 10.7.30.71:3002, 10.7.3.175:3001` | TCP from the shell OK, nginx error `No route to host`, **pcap: nginx never sent a SYN** | host policy (macOS Local Network privacy) | run the standby nginx as root (`sudo -n nginx`) |
| ssh hung ~95 s | `E-standby.sh up` slow | nginx's first request logged 95 s after start | tooling | daemons over ssh: `</dev/null >/dev/null 2>&1` |
| Edge temp folders owned by `nobody` | found by inspection | ctime matched our root `nginx -t` | edge host | recreate as the user; run `nginx -t` as nginx's owner |
| Backup DNS leaks names | `AAAA? app.team1.test` → 8.8.8.8 in a capture | `A-zone-check.sh`: root-zone SOA in mac3's answer | DNS config | **open:** add `local=/team1.test/` + `no-hosts` on mac3 |

**Practice drills** (`F-drill.sh`, one per layer)

| Drill | First symptom (diagnose.sh) | How we localised it | Layer | Fix | Inject → verified |
|---|---|---|---|---|---|
| wrong record (both DNS servers) | `DNS FAIL`: resolves to 10.7.3.175, edge is 10.7.30.71 | `set-record.sh --show` on mac1 + mac3 | DNS data | correct record on both | 18.4 s |
| nginx stopped | `TCP FAIL`: refused | `nc` refused, ping OK, `lsof :443` empty | TCP / edge service | `nginx -t`, start | 14.1 s |
| cert for `wrong.test` | `TLS FAIL`: curl 60, self signed | `openssl s_client` shows `CN=wrong.test` | TLS | restore config, reload | 15.3 s |
| both backends down | `HTTP FAIL`: 502 | `diagnose-edge.sh`: both backends refused; error.log | edge → backend | start backends | 27.8 s |
| Faculty fault (Review 2) ▢ | | | | | |

What we learned: **refused vs timed out** was the fastest clue every time (refused = host up, nothing listening;
timed out = nothing answered or a firewall dropped it). "No route to host" **with no packet on the wire** is a local
policy decision, not the network, so check with tcpdump before blaming Wi-Fi. Failover can hide a broken backend
(every request was 200), so always look at `X-Upstream` / the error log, not only the status code. Finding a fault took
1–7 s with the script; fixing it was dominated by restarts and caches.

## 4. Learning summary (one paragraph per extension)

**A · Backup DNS.** DNS is needed for every request, so a single DNS server is a single point of failure even when
every web server is healthy. With two servers configured, the client retries the second when the first fails. When we
stopped dnsmasq on Mac 1, Mac 1 itself answered each query with ICMP *port unreachable*, so the client knew at once:
plain `dig` reached the backup 1.01 s later, and macOS's own resolver went to the backup directly (3–6 ms). If Mac 1 had
been switched off, nothing would have answered and the client would have waited for a timeout instead. Because macOS
may ask either server, both must hold identical records. Our capture showed they also need identical *configuration*:
the backup forwarded unknown `team1.test` names to 8.8.8.8 because it lacked `local=/team1.test/`.

**B · TTL.** The TTL is set by the server but enforced by every cache. After a record change, `dig` (which asks the
server) showed the new address immediately, while curl went through macOS's cache and kept the old address. mac1 had
fetched the answer 17.8 s before the change and only asked again 37.75 s after that fetch: the switch took 21.3 s.
Across the whole test, macOS asked only every ~37.7 s although the TTL was 30 s, so the practical worst case on our
Macs is about 38 s. Flushing the cache made mac3 switch instantly. Operators therefore lower the TTL well before a
planned change and wait several TTLs before relying on it.

**C · Service isolation.** pf rules on the backend Macs allow the backend ports only from the edge(s) and drop
everything else silently. A blocked client therefore sees a *timeout* (its SYNs arrive, captured on the backend, but
nothing is sent back), while a closed port is *refused* at once with a RST. The rule trusts a source IP, so an edge whose
DHCP address changes is locked out too: network addressing and security policy are coupled. Our rules live in their
own anchor, so rollback is one command and `/etc/pf.conf` is never edited. Restoring meant restoring the *original*
state, not just "pf off": Mac 4 had pf enabled by other software, so we only released our own reference. One caveat:
pf keeps state only for new connections, so a kept-alive connection that was open before pf was enabled gets blocked.
Cloud equivalent: a security group that allows the app port only from the load balancer's group.

**D · HA failover.** Open-source nginx does passive health checking: it learns from real requests. When Backend A
stopped, each request that hit it got a refused connection, nginx retried the same request on B, and the client still
got 200 (57/57). Two failures within 5 s took A out for 5 s; after the restart nginx only noticed A was back when it next
tried it (3.3 s). The packets also showed that nginx keeps connections to the backends open (one connection carried all
41 requests to B). Active checks (NGINX Plus, HAProxy, cloud load balancers) probe on a timer instead. The remaining single
point of failure is the edge: Mac 4 runs the edge **and** Backend B, so if Mac 4 fails, both go together. Removing it
needs a second edge plus a floating virtual IP (VRRP/keepalived), health-checked DNS failover, or anycast/a managed load
balancer.

**E · Edge migration.** A standby edge with the same configuration and its own certificate from the same CA took over
without any client change: clients trust the CA and the name, not a particular server. Moving traffic is a DNS change,
so it is gradual: during the cutover mac1 kept using the old edge for 21.3 s while mac3 (after a flush) was already on
the new one. The old edge must therefore stay up for at least one client cache lifetime (~38 s here, longer for browsers
that keep their own cache and connections). We changed the record on both DNS servers at once, kept both edges up during
the switch and the switch back, and stopped the standby only after the client was back: 0 failed requests in 104.

**F · Troubleshooting.** We diagnose bottom-up along the request path and stop at the first failing layer, because
everything above a broken layer shows misleading symptoms. `diagnose.sh` automates this and names the layer with
PASS/FAIL and an exit code; in the four drills it found the right layer every time. The most useful clues were *refused
vs timed out*, the certificate subject for TLS errors, and the X-Upstream header for problems behind the edge. Our hardest
real fault, the standby edge unable to reach Backend B, looked like a network error ("No route to host") but a capture
showed no packet ever left the Mac: macOS's Local Network privacy blocked nginx. ▢ (add the faculty fault after the review)

## 5. Known limitations
- **Mac 4 is the edge and Backend B (shared fate)**; Mac 3 is Backend A + backup DNS + standby edge. One Mac failing can take out two roles.
- **Edge failover is manual** (a DNS change) and limited by client caches (~38 s measured, TTL 30).
- **The backup DNS is not configured like the primary:** mac3 lacks `local=/team1.test/` and `no-hosts` and logs no queries; fix by deploying `dns/phase2/dnsmasq.conf` (keep its `listen-address` lines).
- The **standby nginx runs as root** because a user-level nginx started over ssh is blocked by macOS Local Network privacy; alternatively allow nginx under Privacy & Security → Local Network at the Mac.
- **DHCP addresses**: an IP change breaks DNS records, nginx upstreams and pf rules (RUNBOOK covers the fixes).
- The `X-Upstream*` headers expose internal addresses (fine for a lab, removed in production).
- The passwordless sudo rule (`/etc/sudoers.d/team1-demo`) includes `brew` and `tcpdump`, which are effectively root; remove it after the course.

## 6. Reproduce
Run on Mac 4 (ssh access to `mac1` and `mac3`), in this order: `baseline.sh` · `D-failover.sh` · `C-apply.sh` → `C-test.sh`
→ `C-rollback.sh` · `A-backup-dns.sh` (+ `A-zone-check.sh`) · `E-standby.sh up` → `E-cutover.sh` → `B-ttl-report.sh` ·
`phase1-failures.sh` · `F-drill.sh healthy|dns|tcp|tls|http`. One-time setup per Mac: `bootstrap-mac.sh`. Demo-day order:
`docs/PHASE2-DEMO.md`.
