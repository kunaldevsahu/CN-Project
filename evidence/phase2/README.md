# Phase 2 evidence checklist

Same convention as Phase 1: terminal output pasted into a `.md` in the folder (with the prompt line, so it is clear whose Mac), plus screenshots named `<ext><n>-<what>.png`. The evaluator should find anything in 30 seconds.

## A-backup-dns/
- [ ] A1 `scutil --dns` on Kunal showing both nameservers
- [ ] A2 `dig app.team1.test` with `SERVER: 10.7.16.0` (baseline)
- [ ] A3 Vaibhav: `sudo brew services stop dnsmasq` + `sudo brew services list`
- [ ] A4 `dig app.team1.test` with `SERVER: 10.7.18.211` + curl A/B still working
- [ ] A5 Himanshu: `tail` of `/opt/homebrew/var/log/dnsmasq.log` showing Kunal's queries
- [ ] A6 Wireshark (`udp port 53 or icmp`): query → ICMP port unreachable → query to backup → answer. Save `P2-A-dns-failover.pcapng`
- [ ] A7 (optional) Mac 1 Wi-Fi off: timeout before failover
- [ ] A8 DNS vs application failure: dnsmasq up + both backends down → dig OK, curl 502

## B-ttl/
- [ ] B1 `dig app.team1.test +noall +answer` showing TTL 30
- [ ] B2 `set-record.sh` output from Mac 1 and Mac 3 (with timestamps)
- [ ] B3 `P2-B-ttl-watch.txt`: server flips first, os-cache flips ≤30 s later
- [ ] B4 Change back + manual flush: immediate change in the watcher
- [ ] B5 (optional) only one DNS server changed: inconsistent answers

## C-isolation/
- [ ] C1 Before: `nc` from a client to 3001/3002 succeeds
- [ ] C2 `fw-on.sh` output on Mac 3 and Mac 4 (rules listed, `Status: Enabled`)
- [ ] C3 After: `nc` from Vaibhav and Kunal time out
- [ ] C4 After: Pranav curl to both backends 200; client through the edge A/B
- [ ] C5 `tcpdump -i pflog0` showing a dropped SYN
- [ ] C6 `fw-off.sh` output + `nc` succeeds again (rollback proven)
- [ ] C7 copy of `~/team1-pf-backup/pf-rules-before.txt`

## D-failover/
- [ ] D1 `lb-check.sh` with A B A B and the X-Edge / X-Upstream headers
- [ ] D2 Backend A stopped: the `502, 200` retry line, then B only
- [ ] D3 nginx error.log + `team1-access.log` lines for the same moment
- [ ] D4 A restarted: alternation resumes (timestamps show ≤10 s)
- [ ] D5 Mac 3 Wi-Fi off: `504, 200`, ≈2 s request
- [ ] D6 Phase 1 vs Phase 2 `team1.conf` diff (`diff nginx/team1.conf nginx/phase2/team1.conf`)

## E-cutover/
- [ ] E1 Standby test with `--resolve … :10.7.18.211` (no cert warning, x-edge Mac 3)
- [ ] E2 `make-standby-cert.sh` output (different serial, same SANs, same issuer)
- [ ] E3 `P2-E-cutover.txt` watcher: Mac 2 → Mac 3 with no failed request
- [ ] E4 Two clients at the same moment on different edges (screenshot side by side)
- [ ] E5 Mac 2 access log going quiet after the TTL
- [ ] E6 (optional) old edge stopped too early: failures until TTL expiry

## F-troubleshooting/
- [ ] F1 `diagnose.sh` on a healthy system (all OK)
- [ ] F2–F4 Three practice drills: fault injected, `diagnose.sh` output, manual commands used, fix, time taken
- [ ] F5 Notes from the real faculty fault (fill in after the review)
