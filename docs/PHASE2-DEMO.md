# Review 2 demo run sheet (Section 8 of the brief)

Everything runs **from Mac 4 (Kunal)**, which reaches mac1 and mac3 over ssh; Kunal's screen is the main screen. Each
step is one script that performs the test and writes timestamped evidence. The evaluator may stop at any step: answer,
then continue. Times are from the 2026-11-25 runs.

## Before the slot (T-30 min)
```bash
cd ~/CN-Project && git pull                              # all three Macs (Vaibhav, Himanshu too)
caffeinate -dims                                         # every Mac, own tab: a sleeping Mac looks like "host down"
bash scripts/phase2/health.sh                            # one screen: IPs, records, services, pf off, standby off, A/B
export EVID=~/demo-day                                   # live runs write here, the committed evidence stays as it is
```
Expected state: records → 10.7.30.71 on both DNS servers, nginx on Mac 4, Backend A on mac3 + B on Mac 4, pf anchor
empty, standby nginx on mac3 stopped, both team DNS servers on every client, CA trusted everywhere.
If `sudo -n` asks for a password on any Mac: `sudo bash scripts/phase2/bootstrap-mac.sh` at that Mac (once).

## Run order

| # | Step | Who speaks | Run on Mac 4 | Point at | Ext | ≈ |
|---|---|---|---|---|---|---|
| 1 | Topology, roles, why the edge moved | Kunal | open `evidence/phase2/edge-move/00-why-the-edge-moved.md` | Mac 2 absent → edge on Mac 4; shared fate | | 1 min |
| 2 | All on the LAN | all | `for ip in 10.7.17.233 10.7.3.175 10.7.30.71; do ping -c 1 $ip; done` | replies, TTL 64 (same LAN) | | 30 s |
| 3 | Name, HTTPS, LB, caching | Vaibhav (client) | `bash scripts/phase2/baseline.sh` | TTL 30 + `SERVER: 10.7.17.233`; issuer `Team1 Local Root CA 2026-11`, no `-k`; A/B 5/5; 304 | | 40 s |
| 4 | Wireshark (Phase 1) | Kunal | `evidence/G-wireshark/` | DNS → TCP → TLS → HTTP/2 | | 1 min |
| 5 | **Fail one backend** | Himanshu | `bash scripts/phase2/D-failover.sh` | the `502,200` retry lines; B only while A is down; A back in ~3 s; then name the SPOF (Mac 4 = edge + B) | **D** | 80 s |
| 6 | **Service isolation** | Himanshu, Kunal | wait until no loop runs, then `bash scripts/phase2/C-apply.sh` → `bash scripts/phase2/C-test.sh` → `bash scripts/phase2/C-rollback.sh` | client `nc` **timed out** vs :3009 **refused**; edge/standby 200; HTTPS still A/B; rule counters; empty before/after diff | **C** | 1.5 min |
| 7 | **Backup DNS** | Vaibhav, Himanshu | `bash scripts/phase2/A-backup-dns.sh` | `SERVER: 10.7.3.175`, dig 1 s; app still 200; ICMP port unreachable → backup in the capture summary | **A** | 70 s |
| 7b | (if asked) do both DNS servers behave the same? | Vaibhav | `bash scripts/phase2/A-zone-check.sh` | mac3 forwards unknown team1.test names to 8.8.8.8 (known limitation) | A | 20 s |
| 8 | **Edge cutover + TTL** | all | `bash scripts/phase2/E-standby.sh up` → `bash scripts/phase2/E-cutover.sh` → `bash scripts/phase2/B-ttl-report.sh` | `server=` new while `curl->` old ("OS cache still has the old IP"); switch after ~20–38 s with 0 errors; mac3 flush = instant; the edges' logs per 5 s; the switch back; standby stopped last | **E, B** | 3.5 min |
| 9 | (if asked) Phase 1 failures | Kunal | `bash scripts/phase2/phase1-failures.sh 5` (or 1–4) | both backends down: TLS OK, **HTTP/2 502** from nginx = application failure, not DNS | | 40 s each |
| 10 | **Faculty fault** | all, out loud | client: `ssh mac1 bash -s < scripts/diagnose.sh` (or Vaibhav: `bash scripts/diagnose.sh`); edge: `bash scripts/diagnose-edge.sh` | the method in `docs/FAULTS.md`: resolver → dig → ping → nc → TLS → HTTP → edge→backend; say the layer before the script does | **F** | 5 min |
| 11 | Viva | each | see below | | | |

Total for 1–8 ≈ 11 minutes.

## If something goes wrong on the day
| Symptom | Quick fix (Mac 4 unless noted) |
|---|---|
| `sudo: a password is required` | at that Mac: `sudo bash scripts/phase2/bootstrap-mac.sh` |
| a backend is down | `source scripts/phase2/lib.sh; backend start A` (or `B`) |
| record points to the wrong IP | `bash scripts/phase2/set-record-both.sh app.team1.test 10.7.30.71` |
| a DNS server is down | on that Mac: `sudo -n /opt/homebrew/bin/brew services start dnsmasq` |
| nginx down on Mac 4 | `/opt/homebrew/bin/nginx -t && /opt/homebrew/bin/brew services start nginx` |
| standby only uses Backend A (`No route to host` to B) | it must run as root: `bash scripts/phase2/E-standby.sh down; bash scripts/phase2/E-standby.sh up` |
| pf still on after C | `bash scripts/phase2/C-rollback.sh` |
| client still on the old IP after a change | expected for up to ~38 s; or flush: `sudo -n /usr/bin/dscacheutil -flushcache; sudo -n /usr/bin/killall -HUP mDNSResponder` |
| an IP changed (DHCP) | `docs/RUNBOOK.md`: records, nginx upstreams, pf rules, `scripts/phase2/lib.sh` |
| anything else | `ssh mac1 bash -s < scripts/diagnose.sh`: it names the first failing layer |

## Viva prep: Phase 2 questions each of us should be able to answer
1. Difference between a DNS failure and an application failure, and the first command that tells them apart (`dig`: no answer vs an answer and then a 502).
2. Why did failover to the backup DNS take ~1 s and not longer? (Mac 1 was up and answered with ICMP port unreachable; a powered-off Mac 1 would mean a timeout first.)
3. Why must both DNS servers have identical records **and** configuration? What did our zone check show? (mac3 forwards unknown team1.test names upstream.)
4. What does TTL control and who enforces it? Why did `dig` show the new IP before curl did? Why did mac1 take up to ~38 s with a TTL of 30?
5. Why lower the TTL *before* a migration and keep the old edge running *after* the change?
6. Why do browsers sometimes stick to the old edge even longer? (own DNS cache, kept-alive TCP/HTTP2 connections)
7. Passive vs active health checks. What do `max_fails`, `fail_timeout` and `proxy_next_upstream` each do? Why did A come back after 3.3 s and not instantly?
8. What did `x-upstream-status: 502, 200` mean? When would it be `504, 200`? Why did each failed try cost 0.4–0.9 s (two SYN/RST rounds: ECN, then plain)?
9. Why doesn't nginx retry a failed POST on the other backend by default?
10. What is still a single point of failure (Mac 4 = edge + Backend B), and three ways to remove it (VRRP/keepalived virtual IP, health-checked DNS failover, anycast / managed LB).
11. pf: why "timed out" for a blocked client but "connection refused" for a closed port? Why does the backend's tcpdump still show the SYN? What breaks if the edge's IP changes?
12. Why did rollback release a *token* instead of `pfctl -d` on Mac 4? (pf was already enabled by other software.)
13. Why does the standby edge have its own key and certificate, and why didn't any client need changes?
14. Why does the standby nginx on mac3 run as root? (macOS Local Network privacy: "No route to host" with no packet sent.)
15. Is Mac 3 a risk? (shared failure domain: Backend A + backup DNS + standby edge)
