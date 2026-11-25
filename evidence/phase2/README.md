# Phase 2 evidence (2026-11-25)

Every `.txt` starts with a header (title, date, which Mac ran it, the script and its arguments) and prints each command
before its output: `$ ` = Mac 4 (where the scripts run), `[mac1]$ ` / `[mac3]$ ` = that Mac over ssh. Loop lines are
timestamped. `.pcap` files open in Wireshark. Each folder is produced by the script named in its heading; re-running a
script overwrites its folder (demo day: `EVID=~/demo-day bash scripts/phase2/<script>.sh` writes elsewhere).
Main test client = mac1 (Vaibhav, 10.7.17.233). Edge = Mac 4 (Kunal, 10.7.30.71). Results summary: `docs/PHASE2-REPORT.md` §2.

## Setup · the edge moved to Mac 4 (`edge-move/`, `scripts/phase2/edge-move-check.sh`, `set-record-both.sh`)
| File | What it proves |
|---|---|
| `00-why-the-edge-moved.md` | Why the edge moved from Mac 2 (absent) to Mac 4; new roles; shared-fate trade-off |
| `01-make-certs.txt` | New CA `Team1 Local Root CA 2026-11` + edge cert (SAN app/api), chain verifies |
| `02-pre-dns-check.txt` | Before any DNS change: nginx -t OK, :443 listening, cert chain OK, mac1 `--resolve` → 10 × 200 A/B via `mac4-primary` (CA not yet trusted on mac1, so `--cacert`, never `-k`) |
| `03-set-record.txt` | app/api → 10.7.30.71 on BOTH DNS servers in the same second, both answer TTL 30 |
| `04-post-dns-check.txt` | mac1 by name: both servers + system resolver = 10.7.30.71, HTTPS trusted via the keychain only, 10 × 200 A/B |

## Baseline (`baseline/`, `baseline.sh`)
| File | What it proves |
|---|---|
| `01-dns.txt` | Plain `dig` on mac1: NOERROR, `aa`, TTL 30, `SERVER: 10.7.17.233`; dscacheutil agrees |
| `02-https.txt` | :80 → 301 to HTTPS; TLS 1.3 + HTTP/2, issuer `Team1 Local Root CA 2026-11`, `ssl_verify_result=0` without `-k` |
| `03-lb-loop.txt` | 10 timestamped requests: strict A/B alternation, A=5 B=5, all via `mac4-primary` |
| `04-cache-304.txt` | `/api/status` no-store; `/api/cached` `public, max-age=60` + identical ETag from A and B; `If-None-Match` → 304, wrong ETag → 200 |

## A · Backup DNS (`A/`, `A-backup-dns.sh`, `A-zone-check.sh`)
| File | What it proves |
|---|---|
| `00-events.txt` | Primary DNS stopped 15:45:42 / started 15:46:06 with `brew services` on mac1 |
| `01-baseline.txt` | mac3 resolver order (10.7.17.233, 10.7.3.175); both servers same record; dig `SERVER: 10.7.17.233` |
| `02-primary-down-client.txt` | Primary down: mac3 and mac1 plain dig → `SERVER: 10.7.3.175` (1.05 s); HTTPS 8/8 × 200 |
| `03-mac3-client-dns-icmp.pcap` | pktap on mac3: query → ICMP port unreachable from mac1 → same query to the backup → answer |
| `04-pcap-summary.txt` | The capture decoded, only packets about app.team1.test (ICMP matched to our queries by source port) |
| `05-restore.txt` | Primary back: `SERVER: 10.7.17.233`, 0.04 s |
| `06-summary.txt` | Numbers: 1.01 s from primary to backup for plain dig; 5 ICMP, 8 answers from the backup |
| `07-zone-config-check.txt`, `08-mac3-upstream.pcap` | mac3 forwards unknown team1.test names to 8.8.8.8 (no `local=/team1.test/`), mac1 answers itself |
| `09-notes.md` | Results + viva points (ICMP = fast failover, identical records, launchd KeepAlive, config gap) |

## B · TTL and a controlled record change (`B/`, `B-ttl-report.sh`, built from the E run)
| File | What it proves |
|---|---|
| `01-ttl-from-E.txt` | TTL 30; both servers changed in the same second; server new vs client cached for 21.3 s; flush = instant; mac1 re-asks every ~37.7 s |

## C · Service isolation with pf (`C/`, `C-apply.sh` → `C-test.sh` → `C-rollback.sh`)
| File | What it proves |
|---|---|
| `00-before-mac3.txt`, `00-before-mac4.txt` | pf before isolation: `-si` (mac3 Disabled, Mac 4 Enabled), `-sr`, empty anchor |
| `01-apply.txt` | `pfctl -E` (reference token) + anchor `com.apple/team1` loaded on both, rules listed |
| `02-tests.txt` | mac1 → :3001/:3002 time out (3.03 s), :3009 refused; edge/standby → backends 200; HTTPS A/B 8/8; block-rule counters 3 and 5 |
| `03-mac1-client-nc-blocked.pcap` | Client side: SYN retransmits to 3001/3002 with no reply; 3009 → RST |
| `04-mac3-en0-syn-dropped.pcap`, `05-mac4-en0-syn-dropped.pcap` | Backend side: the SYNs arrive, nothing is sent back (pf drop) |
| `06-pcap-summary.txt` | The three captures decoded |
| `07-rollback.txt` | Anchor flushed, token released, pf left as it was (mac3 off, Mac 4 on); nc works again |
| `08-before-after-diff.txt` | Empty diffs: main ruleset, anchor, Enabled/Disabled state, `/etc/pf.conf` |
| `09-notes.md` | Results + viva points (timeout vs refused, BPF before pf, reference token, keep-state caveat) |

## D · HA failover in nginx (`D/`, `D-failover.sh`)
| File | What it proves |
|---|---|
| `00-events.txt` | When Backend A was stopped (SIGINT) / restarted (nohup) on mac3; captures started/stopped (ms) |
| `01-en0-edge-A-3001.pcap` | Edge ↔ A: FIN when A exits, SYN→RST (refused) on 4 attempts, first SYN-ACK when nginx retries A |
| `02-lo0-edge-B-3002.pcap` | Edge ↔ B over loopback: one kept-alive connection carrying all 41 B requests |
| `03-client-loop.txt` | mac1, 60 s: 57/57 × 200; B only while A was down; 4 × `502,200` retries; A back after 3.3 s |
| `04-nginx-error-excerpt.txt` | 4 × `connect() failed (61: Connection refused)` to 10.7.3.175:3001 |
| `05-nginx-access-excerpt.txt` | Per-request upstream + status per try (`t=$msec`, edge clock) |
| `06-upstream-config.txt` | Upstream block and failover directives in force; Phase 1 → Phase 2 config diff |
| `07-pcap-summary.txt` | Requests to A 9/0/11 and to B 7/24/10 (before/down/after); RST and ECN-retry detail |
| `08-summary.txt` | Computed results: A=0 while down (27.3 s), 4 retries, recovery 3.3 s |
| `09-spof-note.md` | Both runs, viva explanation, single point of failure (Mac 4 = edge + B) and how to remove it |
| `run1/` | First run (52/52 × 200, recovery 3.8 s), kept for comparison; its README explains its known flaw |

## E · Edge migration by DNS cutover (`E/`, `E-standby.sh up` → `E-cutover.sh`)
| File | What it proves |
|---|---|
| `01-make-standby-cert.txt` | Standby cert: same SANs + issuer, different serial (…D527 vs …D526) and key |
| `02-standby-up.txt` | Standby nginx on mac3 (root, see F real fault 1), checked from mac1 with `--resolve`: trusted, `x-edge: mac3-standby`, A/B |
| `03-events.txt` | Timeline (ms): preflight, flush, capture, CUTOVER 15:34:24, RESTORE 15:35:37, standby stopped |
| `04-client-loop-cutover.txt` | mac1, 90 s: server answer vs IP curl used; old edge for 21.3 s after the change, then mac3-standby; 71/71 × 200 |
| `05-set-record-to-standby.txt` | Both DNS servers changed in the same second, both answer 10.7.3.175 |
| `06-mac3-as-client.txt` | Second client: cached → old edge; flush → new edge at once |
| `07-mac1-dns-443.pcap` | pktap (en0 + lo0) on mac1: its own DNS lookups + TCP to each edge |
| `08-pcap-summary.txt` | mac1's own lookups every ~37.7 s (TTL 30); connections per edge |
| `09-edge-logs.txt` | Requests per 5 s on each edge: Mac 4 quiet after 19.9 s, mac3 from 21.2 s |
| `10-summary.txt` | All numbers: 0 failures, 21.3 s switch, 23.3 s back, cache explanation |
| `11-restore-set-record.txt`, `12-client-loop-restore.txt` | Record back to 10.7.30.71; mac1 back on mac4-primary after 23.3 s without a flush |
| `13-standby-down.txt` | Standby stopped only after the restore; :443 refused; DNS no longer points at it |
| `14-notes.md` | Results + viva points (gradual switch, ~38 s cache on macOS, production order, own key/same CA) |

## F · Troubleshooting (`F/`, `scripts/diagnose.sh`, `scripts/diagnose-edge.sh`, `F-drill.sh`)
| File | What it proves |
|---|---|
| `practice-log.md` | 3 real faults (Local Network privacy blocking nginx, ssh hang, root `nginx -t` chown) + the 4 layer drills with results and lessons |
| `00-diagnose-healthy.txt` | `diagnose.sh` on mac1, healthy: DNS PASS \| TCP PASS \| TLS PASS \| HTTP PASS |
| `01-drill-dns.txt` | Wrong record → `DNS FAIL` (exit 1), confirmed with `set-record.sh --show`, fixed, PASS again |
| `02-drill-tcp.txt` | nginx stopped → `TCP FAIL` refused (exit 2), fixed, PASS again |
| `03-drill-tls.txt` | Cert for wrong.test → `TLS FAIL` curl (60) (exit 3), fixed, PASS again |
| `04-drill-http.txt` | Both backends down → `HTTP FAIL` 502 (exit 4); `diagnose-edge.sh` shows both refused; fixed, PASS again |

## Phase 1 failure demos on the Phase 2 system (`phase1-failures/`, `phase1-failures.sh`)
| File | What it proves |
|---|---|
| `00-summary.md` | The five Phase 1 failures again, Phase 1 vs Phase 2 table, DNS vs application failure |
| `01-wrong-dns-server.txt` | mac1 DNS = 8.8.8.8: NXDOMAIN, curl (6); ping + `--resolve` fine; restored |
| `02-wrong-ip-in-record.txt` | Record → 10.7.3.175 on both servers: refused, curl (7); restored |
| `03-wrong-port.txt` | :8443 refused, :443 fine |
| `04-one-backend-down.txt` | B stopped: 6/6 × 200 from A, `502, 200` retries, error.log; B restarted |
| `05-both-backends-down.txt` | A + B stopped: TLS OK, HTTP/2 502 from nginx, `no live upstreams`; both restarted |

Not committed on purpose: private keys (`*.key`), CSRs, `rootCA.srl` (`.gitignore`).
