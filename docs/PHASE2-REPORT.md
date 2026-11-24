# Phase 2 Final Report · Team 1 · Private Network Service Platform

Members: Vaibhav (Mac 1) · Pranav (Mac 2) · Himanshu (Mac 3) · Kunal (Mac 4)
Domain: `team1.test` · LAN: college Wi-Fi 10.7.0.0/19 · Review 2 date: ____

> **DRAFT.** Sections marked ▢ need our real outputs/timings from the evidence folder. Rewrite the learning paragraphs in our own words before submitting; the viva will test them.

## 1. What changed from Phase 1

| Area | Phase 1 | Phase 2 | Why |
|---|---|---|---|
| DNS servers | dnsmasq on Mac 1 only | + identical backup on Mac 3; clients list both | Mac 1 off = every lookup failed (seen in Phase 1) |
| DNS records | `host-record=` lines, restart to change, TTL 60 s | `team1.hosts` file + SIGHUP reload, TTL 30 s, `set-record.sh` | quick, scripted, visible record changes |
| Backend exposure | 3001/3002 open to the whole LAN | pf on Mac 3/4: only the edge(s) may connect | clients must go through the edge |
| nginx failover | `max_fails=1 fail_timeout=10s`, retry on error/timeout/502/503 | + 504, `proxy_next_upstream_tries 2`, 5 s read/send timeouts | bounded, fast failover |
| Observability | `X-Backend` header | + `X-Edge`, `X-Upstream`, `X-Upstream-Status`, per-request upstream log | see retries and which edge served |
| Edge | Mac 2 only | + warm standby nginx on Mac 3 (own cert, same CA, same config file) | DNS-based edge migration |
| Troubleshooting | manual RUNBOOK list | `diagnose.sh`, `diagnose-edge.sh`, fault drill table | systematic layer-by-layer diagnosis |

Updated topology:
```
                         ┌── DNS :53 ──► Mac 1  dnsmasq PRIMARY    10.7.16.0
Client (Mac 4 / Mac 1) ──┤
                         └── DNS :53 ──► Mac 3  dnsmasq BACKUP     10.7.18.211
        │
        └── HTTPS :443 ──► app.team1.test ──► Mac 2 nginx PRIMARY edge 10.7.21.121
                                             (Mac 3 nginx STANDBY edge, after cutover)
                                                   ├─ HTTP :3001 ─► Mac 3 Backend A  [pf: edges only]
                                                   └─ HTTP :3002 ─► Mac 4 Backend B  [pf: edges only]
```

## 2. Resilience tests and results

| Test | Procedure | Expected | Observed ▢ | Evidence |
|---|---|---|---|---|
| A · Primary DNS stopped | stop dnsmasq on Mac 1, client resolves | answered by 10.7.18.211, app works | | `A-backup-dns/` |
| A · Primary DNS host off | Mac 1 Wi-Fi off | answered by backup after ≈__ s timeout | | |
| A · DNS vs app failure | both backends stopped | dig OK, curl 502 | | |
| B · Record change, TTL 30 s | `set-record.sh` on both servers | server answer changes at once; client cache after ≤30 s | client switched after __ s | `B-ttl/` |
| B · Manual flush | flush right after change | immediate | | |
| C · Isolation | pf on Mac 3/4 | client `nc` timeout; edge 200; app A/B | | `C-isolation/` |
| C · Rollback | `fw-off.sh` | direct access restored, pf.conf unchanged | | |
| D · Backend A stopped | Ctrl+C on Mac 3 | no failed request; `502, 200` retry, then B only | | `D-failover/` |
| D · Backend A host off | Mac 3 Wi-Fi off | `504, 200`, request ≈2 s | | |
| D · Recovery | restart A | A back within ≤10 s | after __ s | |
| E · Edge cutover | record → 10.7.18.211, both edges up | cached client on Mac 2 ≤30 s, new lookup on Mac 3, 0 failures | | `E-cutover/` |
| E · Early shutdown (optional) | stop Mac 2 at change time | cached clients fail until TTL expiry | | |

## 3. Troubleshooting findings (Extension F)

Method: resolver config → DNS → IP → TCP → TLS → HTTP → edge→backend, stopping at the first failure (`docs/FAULTS.md`).

| Drill / fault | First symptom | How we localised it | Layer | Fix | Time |
|---|---|---|---|---|---|
| ▢ | | | | | |
| ▢ | | | | | |
| ▢ | | | | | |
| Faculty fault (Review 2) ▢ | | | | | |

What we learned from the drills ▢ (e.g. "refused vs timed out was the fastest clue"; "dig and curl disagreeing always meant cache or /etc/hosts").

## 4. Learning summary (one paragraph per extension)

**A · Backup DNS.** DNS is a dependency of every request, so a single resolver is a single point of failure even when every server behind it is healthy. With two servers configured, the client's resolver retries the second when the first fails. How fast depends on *how* it fails: a stopped dnsmasq on a live host returns ICMP port unreachable and failover is immediate, while a powered-off host returns nothing and the client must wait for a timeout. A DNS failure means the name cannot be turned into an address, so nothing after it even starts. An application failure means DNS, TCP and TLS all succeed and the edge reports the problem (502). Both servers must serve identical data, because macOS may use either at any time.

**B · TTL.** The TTL is set by the server but enforced by every cache along the way, here the macOS mDNSResponder. Changing the record changes the server's answer instantly (`dig` asks the server directly), but clients keep the cached answer until it expires, so a change reaches clients gradually over one TTL. Flushing the cache forces a new lookup. In production, operators lower the TTL well before a migration so the switchover window is short, then raise it again afterwards to reduce query load.

**C · Service isolation.** The backends should only be reachable through the edge, which is where TLS, logging and load balancing happen. pf rules on the backend Macs allow TCP to 3001/3002 only from the edge IPs and silently drop everything else. A blocked client therefore sees a timeout, unlike a stopped service, which answers with a RST ("connection refused"). Because the rule trusts a source IP, an edge whose IP changes is locked out too: the network layer and the security policy are coupled. Our rules sit in their own anchor with a saved backup, so rollback is one command and leaves `/etc/pf.conf` untouched. Cloud equivalent: security groups that allow the backend port only from the load balancer's security group.

**D · HA failover.** nginx open source does passive health checking: it notices failures on real requests, marks the server down for `fail_timeout`, and with `proxy_next_upstream` retries the same idempotent request on the other backend, so the client still gets 200. The `X-Upstream-Status` header made this visible (`502, 200` for a refused connection, `504, 200` for a host that did not answer within the 2 s connect timeout). Active health checks, as in NGINX Plus, HAProxy or cloud load balancers, probe backends on a timer instead. The remaining single point of failure is the edge on Mac 2 and its address in DNS. Removing it needs redundant edges plus a shared virtual IP (VRRP/keepalived or CARP), health-checked DNS failover (Route 53 failover records), or anycast and a managed load balancer.

**E · Edge migration.** A standby edge with the same configuration and its own certificate from the same CA can take over without any client change, because clients trust the CA and the name, not a specific server or IP. Moving traffic is a DNS change, so it is gradual: cached clients keep using the old edge for up to one TTL while fresh lookups go to the new one. The old edge must therefore keep running until the TTL has expired. Browsers can stay on the old edge even longer through their own DNS caches and reused connections. This is the manual version of what blue/green cut-overs and DNS failover do in production.

**F · Troubleshooting.** ▢ (write after the drills and the review: our method, what the faculty fault was, how we found the layer, what we would do faster next time).

## 5. Known limitations
- Mac 3 is a shared failure domain (Backend A + backup DNS + standby edge).
- Edge failover is manual (a DNS change), not automatic.
- DHCP addresses: an IP change breaks DNS records, nginx upstreams and pf rules (RUNBOOK covers the fix).
- The `X-Upstream*` headers leak internal addresses; fine for a lab, removed in production.
