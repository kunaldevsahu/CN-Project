# Ext A · 09 What the backup-DNS test proves (viva notes)

Date: 2026-11-25 · scripts: `scripts/phase2/A-backup-dns.sh` (+ `A-zone-check.sh`) · client: mac3 (and mac1)

| Measured (15:45–15:46) | Result | File |
|---|---|---|
| Client resolver order | mac3: 10.7.17.233, then 10.7.3.175 | `01` |
| Baseline | `SERVER: 10.7.17.233`, dig 0.04 s | `01`, `05` |
| Primary stopped (`brew services stop dnsmasq` on mac1) | plain dig: `SERVER: 10.7.3.175`, **1.05 s** (1.01 s from asking the primary to asking the backup, same DNS id) | `02`, `04` |
| Apps with the primary down | mac3: 4/4 × 200, name lookup 3–6 ms; mac1 (its own DNS down): 4/4 × 200 via the backup | `02` |
| On the wire | each query to 10.7.17.233 → ICMP *udp port 53 unreachable* from mac1 → same query to 10.7.3.175 → answer | `03`, `04` |
| Primary back (`brew services start`, again a boot-time LaunchDaemon) | `SERVER: 10.7.17.233` again | `05` |
| Zone ownership (side check) | mac1 answers `team1.test` names itself; mac3 **forwards unknown team1.test names to 8.8.8.8** (no `local=/team1.test/`) | `07`, `08` |

## Points to explain
- **DNS is a dependency of every request.** With one DNS server, stopping dnsmasq would make every lookup fail even though
  the edge and both backends are fine. Listing two servers on the clients removes that single point of failure.
- **Why only ~1 s:** mac1 (host up, service down) answers the query with ICMP *port unreachable*, so the client knows at
  once. If Mac 1 were switched off, nothing would answer and the client would wait for its timeout (several seconds)
  before trying the backup: *service down = fast failover, host down = slow failover.*
- **The OS resolver is smarter than plain dig.** After the first failure mDNSResponder went straight to the backup (curl's
  name lookup took 3–6 ms). macOS doesn't strictly use "first server, then second"; it may use whichever answers.
  That is why **both servers must hold identical records** (set-record-both.sh changes both in the same second).
- **mac1 is a client and a DNS server.** It lists itself first, so with its dnsmasq down it also used the backup.
- **Restart with `brew services`, not pkill.** dnsmasq is a launchd daemon with KeepAlive: a killed process comes straight back.
  Our "outage" therefore has to stop the service (`brew services stop`), and `start` puts it back at boot as well.
- **The two servers are NOT identical yet:** mac3's dnsmasq.conf lacks `local=/team1.test/` (+ `no-hosts`, query log).
  For a name we don't have, mac1 answers NXDOMAIN itself, mac3 asks 8.8.8.8 (captured) and returns the root zone's
  answer. Internal names leak to the internet, answers are slower, and the two servers behave differently, which is the
  thing a backup must not do. Fix: give mac3 the repo's `dns/phase2/dnsmasq.conf` (keeping its listen-address lines).
- **DNS failure vs application failure:** here DNS failed and the app kept working through the backup. When both backends
  are down (Phase 1 failure demos, stage 7) the name resolves, TCP and TLS work, and the edge answers 502.

Note: the first run of this script (15:42) also captured mac3 forwarding `AAAA? app.team1.test` to 8.8.8.8. That run's
files were overwritten by the clean re-run; `07`/`08` reproduce the same forwarding on purpose.
