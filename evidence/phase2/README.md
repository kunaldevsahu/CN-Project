# Phase 2 evidence

## Index: file → what it proves → extension
Every `.txt` starts with a header (title, date, which Mac ran it, the script) and prints each command before its output.
Scripts live in `scripts/phase2/` and are re-run live on demo day. Main client = Mac 1 (Vaibhav); scripts run on Mac 4.

| File | What it proves | Ext |
|---|---|---|
| `edge-move/00-why-the-edge-moved.md` | Why the edge moved from Mac 2 (absent) to Mac 4; new roles; shared-fate trade-off | setup |
| `edge-move/01-make-certs.txt` | New CA `Team1 Local Root CA 2026-11` + edge cert (SAN app/api), chain verifies | setup, E |
| `edge-move/02-pre-dns-check.txt` | Before any DNS change: nginx -t OK, :443 listening, cert chain OK, mac1 → `--resolve` → 10 × 200 A/B via `mac4-primary` (CA not yet trusted on mac1, so `--cacert`, never `-k`) | setup |
| `edge-move/03-set-record.txt` | app/api → 10.7.30.71 on BOTH DNS servers at 15:01:50, both answer TTL 30 | setup, B |
| `edge-move/04-post-dns-check.txt` | mac1 by name: dig both servers + system resolver = 10.7.30.71, HTTPS trusted via keychain only, 10 × 200 A/B | setup |
| `baseline/01-dns.txt` | Plain `dig` on mac1: NOERROR, `aa`, TTL 30, `SERVER: 10.7.17.233`; dscacheutil agrees | baseline, A, B |
| `baseline/02-https.txt` | HTTP :80 → 301 to HTTPS; TLS 1.3 + HTTP/2, cert issuer `Team1 Local Root CA 2026-11`, `ssl_verify_result=0` without `-k` | baseline |
| `baseline/03-lb-loop.txt` | 10 timestamped requests: strict A/B alternation, A=5 B=5, all via `mac4-primary` | baseline, D |
| `baseline/04-cache-304.txt` | `/api/status` no-store; `/api/cached` `public, max-age=60` + identical ETag from A and B; `If-None-Match` → 304 (both backends), wrong ETag → 200 | baseline |
| `D/00-events.txt` | When Backend A was stopped (SIGINT) / restarted (nohup) on mac3, captures started/stopped (ms) | D |
| `D/01-en0-edge-A-3001.pcap` | Edge ↔ A: FIN when A exits, SYN→RST (refused) ×4 attempts, first SYN-ACK when nginx retries A | D |
| `D/02-lo0-edge-B-3002.pcap` | Edge ↔ B over loopback: one kept-alive connection carrying all 41 B requests | D |
| `D/03-client-loop.txt` | mac1, 60 s: 57/57 × 200; B only while A down; 4 × `502,200` retries; A back after 3.3 s | D |
| `D/04-nginx-error-excerpt.txt` | 4 × `connect() failed (61: Connection refused)` to 10.7.3.175:3001 | D |
| `D/05-nginx-access-excerpt.txt` | Per-request upstream + status per try (`t=$msec` edge clock) | D |
| `D/06-upstream-config.txt` | Upstream block, failover directives in force, Phase 1 → Phase 2 config diff | D |
| `D/07-pcap-summary.txt` | Requests to A 9/0/11 and to B 7/24/10 (before/down/after); RST and ECN-retry detail | D |
| `D/08-summary.txt` | Computed results: A=0 while down (27.3 s), 4 retries, recovery 3.3 s | D |
| `D/09-spof-note.md` | Results of both runs, viva explanation, single point of failure (Mac 4 = edge + B) and fixes | D |
| `D/run1/` | First run (52/52 × 200, recovery 3.8 s), kept for comparison; see its README for its known flaw | D |
| `C/00-before-mac3.txt`, `C/00-before-mac4.txt` | pf before isolation: `-si` (mac3 Disabled, Mac 4 Enabled), `-sr`, empty anchor | C |
| `C/01-apply.txt` | `pfctl -E` (token) + anchor `com.apple/team1` loaded on both, rules listed | C |
| `C/02-tests.txt` | mac1 → :3001/:3002 time out (3.03 s), :3009 refused; edge/standby → backends 200; HTTPS A/B 8/8; block-rule counters 3 and 5 | C |
| `C/03-mac1-client-nc-blocked.pcap` | Client side: SYN retransmits to 3001/3002 with no reply; 3009 → RST | C |
| `C/04-mac3-en0-syn-dropped.pcap`, `C/05-mac4-en0-syn-dropped.pcap` | Backend side: the SYNs arrive, nothing is sent back (pf drop) | C |
| `C/06-pcap-summary.txt` | The three captures decoded | C |
| `C/07-rollback.txt` | Anchor flushed, token released, pf left as it was (mac3 off, Mac 4 on); nc works again | C |
| `C/08-before-after-diff.txt` | Empty diffs: main ruleset, anchor, Enabled/Disabled state, `/etc/pf.conf` | C |
| `C/09-notes.md` | Results table + viva points (timeout vs refused, BPF before pf, token, keep-state caveat) | C |
| `E/01-make-standby-cert.txt` | Standby cert: same SANs + issuer, different serial (…D527 vs …D526) and key | E |
| `E/02-standby-up.txt` | Standby nginx on mac3 (root, see F fault 1) checked from mac1 with `--resolve`: trusted, `x-edge: mac3-standby`, A/B | E |
| `E/03-events.txt` | Timeline (ms): preflight, flush, capture, CUTOVER 15:34:24, RESTORE 15:35:37, standby stopped | E |
| `E/04-client-loop-cutover.txt` | mac1, 90 s: server answer vs IP curl used; old edge for 21.3 s after the change, then mac3-standby; 71/71 × 200 | E, B |
| `E/05-set-record-to-standby.txt` | Both DNS servers changed in the same second, both answer 10.7.3.175 | E, B |
| `E/06-mac3-as-client.txt` | Second client: cached → old edge; flush → new edge at once | E, B |
| `E/07-mac1-dns-443.pcap` | pktap (en0+lo0) on mac1: its own DNS lookups + TCP to each edge | E, B |
| `E/08-pcap-summary.txt` | mac1's own lookups every ~37.7 s (TTL 30); connections per edge | E, B |
| `E/09-edge-logs.txt` | Requests per 5 s on each edge: Mac 4 quiet after 19.9 s, mac3 from 21.2 s | E |
| `E/10-summary.txt` | All numbers: 0 failures, 21.3 s switch, 23.3 s back, cache explanation | E, B |
| `E/11-restore-set-record.txt`, `E/12-client-loop-restore.txt` | Record back to 10.7.30.71; mac1 back on mac4-primary after 23.3 s without a flush | E, B |
| `E/13-standby-down.txt` | Standby stopped only after the restore; :443 refused; DNS no longer points at it | E |
| `E/14-notes.md` | Results table + viva points (gradual switch, ~38 s cache on macOS, production order, own key/same CA) | E |
| `F/practice-log.md` | Real faults: Local Network privacy blocking nginx ("No route to host", no packet sent); ssh hang | F |
| `A/00-events.txt` | Primary DNS stopped 15:45:42 / started 15:46:06 with `brew services` on mac1 | A |
| `A/01-baseline.txt` | mac3 resolver order (10.7.17.233, 10.7.3.175); both servers same record; dig `SERVER: 10.7.17.233` | A |
| `A/02-primary-down-client.txt` | Primary down: mac3 and mac1 plain dig → `SERVER: 10.7.3.175` (1.05 s); HTTPS 8/8 × 200 | A |
| `A/03-mac3-client-dns-icmp.pcap` | pktap on mac3: query → ICMP port unreachable from mac1 → same query to the backup → answer | A |
| `A/04-pcap-summary.txt` | The capture decoded, only packets about app.team1.test (ICMP matched to our queries by port) | A |
| `A/05-restore.txt` | Primary back: `SERVER: 10.7.17.233`, 0.04 s | A |
| `A/06-summary.txt` | Numbers: 1.01 s from primary to backup for plain dig; 5 ICMP, 8 answers from the backup | A |
| `A/07-zone-config-check.txt`, `A/08-mac3-upstream.pcap` | mac3 forwards unknown team1.test names to 8.8.8.8 (no `local=/team1.test/`), mac1 answers itself | A |
| `A/09-notes.md` | Results + viva points (ICMP = fast failover, identical records, launchd KeepAlive, config gap) | A |
| `phase1-failures/00-summary.md` | The five Phase 1 failures on the Phase 2 system, Phase 1 vs Phase 2 table, DNS vs application failure | Phase 1 |
| `phase1-failures/01-wrong-dns-server.txt` | mac1 DNS = 8.8.8.8: NXDOMAIN, curl (6); ping + `--resolve` fine; restored | Phase 1 |
| `phase1-failures/02-wrong-ip-in-record.txt` | Record → 10.7.3.175 on both servers: refused, curl (7); restored | Phase 1 |
| `phase1-failures/03-wrong-port.txt` | :8443 refused, :443 fine | Phase 1 |
| `phase1-failures/04-one-backend-down.txt` | B stopped: 6/6 × 200 from A, `502, 200` retries, error.log; B restarted | Phase 1, D |
| `phase1-failures/05-both-backends-down.txt` | A + B stopped: TLS OK, HTTP/2 502 from nginx, `no live upstreams`; both restarted | Phase 1, A |
| `B/01-ttl-from-E.txt` | Built by `B-ttl-report.sh` from the Ext E run: TTL 30, both servers changed, server new vs client cached, flush = instant, ~37.7 s cache | B |

---

# Original checklist (Mac 2-era plan, kept for reference until the final rewrite)

Same convention as Phase 1: terminal output pasted into a `.md` in the folder (with the prompt line, so it is clear whose Mac), plus screenshots named `<ext><n>-<what>.png`. The evaluator should find anything in 30 seconds.

## A-backup-dns/
- [ ] A1 `scutil --dns` on Kunal showing both nameservers
- [ ] A2 `dig app.team1.test` with `SERVER: 10.7.17.233` (baseline)
- [ ] A3 Vaibhav: `sudo brew services stop dnsmasq` + `sudo brew services list`
- [ ] A4 `dig app.team1.test` with `SERVER: 10.7.3.175` + curl A/B still working
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
- [ ] E1 Standby test with `--resolve … :10.7.3.175` (no cert warning, x-edge Mac 3)
- [ ] E2 `make-standby-cert.sh` output (different serial, same SANs, same issuer)
- [ ] E3 `P2-E-cutover.txt` watcher: Mac 2 → Mac 3 with no failed request
- [ ] E4 Two clients at the same moment on different edges (screenshot side by side)
- [ ] E5 Mac 2 access log going quiet after the TTL
- [ ] E6 (optional) old edge stopped too early: failures until TTL expiry

## F-troubleshooting/
- [ ] F1 `diagnose.sh` on a healthy system (all OK)
- [ ] F2–F4 Three practice drills: fault injected, `diagnose.sh` output, manual commands used, fix, time taken
- [ ] F5 Notes from the real faculty fault (fill in after the review)
