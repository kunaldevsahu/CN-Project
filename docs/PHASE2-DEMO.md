# Review 2 demo run sheet (Section 8 of the brief)

Before the slot: RUNBOOK checks pass, both DNS servers on the Phase 2 config, both edges up, pf **off**, record points at Mac 2, every client cache flushed, terminals pre-opened with the commands below. Kunal drives the client screen; everyone else speaks for their own Mac. The evaluator may stop at any step: answer, then continue.

| # | Step | Who | Commands / what to point at | Ext |
|---|---|---|---|---|
| 1 | Topology + IP/service inventory | Vaibhav | Updated diagram (backup DNS + standby edge on Mac 3), `docs/PHASE2-SETUP.md` role table | |
| 2 | All on the LAN | all | `ipconfig getifaddr en0` each; `ping -c 2` the other three | |
| 3 | Resolve the name | Kunal | `dig app.team1.test` → 10.7.30.229, `SERVER: 10.7.17.233`, TTL 30 | |
| 4 | HTTPS by name, no warnings | Kunal | browser `https://app.team1.test/api/status` + `curl -v` (no `-k`) | |
| 5 | Load balancing | Kunal | `bash scripts/lb-check.sh 6` → A B A B, x-edge = Mac 2 | |
| 6 | Wireshark evidence | Kunal | `evidence/G-wireshark/phase1-full-flow.pcapng` + `G-packet-index.md` | |
| 7 | Caching | Kunal | `curl -I …/api/cached`; `If-None-Match` → 304 | |
| 8 | Fail one backend | Himanshu, Kunal | `lb-check.sh 20 1` running; Himanshu Ctrl+C on A → the retry line `502, 200`, then only B; restart A → A B again. Name the remaining SPOF (edge). | D |
| 9a | Backup DNS | Vaibhav, Himanshu | Vaibhav stops dnsmasq; Kunal flushes, `dig` → `SERVER: 10.7.3.175`; curl still works; Himanshu's `tail -f` log shows the queries | A |
| 9b | TTL + record change | Vaibhav, Himanshu, Kunal | `watch-dns.sh` running; both run `set-record.sh app.team1.test 10.7.3.175`; server column flips first, os-cache ≤30 s later; then flip back + manual flush = instant | B |
| 9c | Edge cutover | all | Same flip with both edges up: x-edge changes Mac 2 → Mac 3 with zero failed requests; Vaibhav (fresh lookup) on Mac 3 while Kunal still on Mac 2 | E |
| 9d | Service isolation | Himanshu, Kunal, Vaibhav | `fw-on.sh A` / `B`; Vaibhav `nc 3001/3002` time out; Pranav curl to backends 200; app still A B; `pfctl -a com.apple/team1 -sr`; `fw-off.sh` and show restored | C |
| 10 | Faculty fault | all | `docs/FAULTS.md` method, out loud: resolver → dig → ping → nc → curl -v (TLS) → HTTP status → edge-side checks | F |
| 11 | Viva | each | see below | |

## Viva prep: Phase 2 questions each of us should be able to answer
1. Difference between a DNS failure and an application failure, and the first command that tells them apart.
2. Why did failover to the backup DNS take longer when Mac 1 was switched off than when only dnsmasq was stopped? (ICMP port unreachable vs. silence/timeout)
3. Why must both DNS servers have identical records? What happens if only one is changed?
4. What does TTL control, and who enforces it: server or client? Why did `dig` show the new IP before `curl` did?
5. Why lower the TTL *before* a migration and keep the old server running *after* the change?
6. Why do browsers sometimes stick to the old edge even after the TTL? (own DNS cache, reused TCP/HTTP2 connections)
7. Passive vs active health checks. What do `max_fails`, `fail_timeout` and `proxy_next_upstream` each do?
8. What did `x-upstream-status: 502, 200` mean? When would it be `504, 200` instead?
9. Why doesn't nginx retry a failed POST on the other backend by default?
10. What is still a single point of failure, and three ways to remove it (VRRP/keepalived virtual IP, health-checked DNS failover, anycast / managed cloud LB).
11. pf: why "timed out" for a blocked client but "connection refused" for a stopped backend? Why a source-IP rule, and what breaks if the edge's IP changes?
12. Why does the standby edge have its own key and certificate, and why didn't any client need changes?
13. Is Mac 3 now a risk? (shared failure domain: Backend A + backup DNS + standby edge)
