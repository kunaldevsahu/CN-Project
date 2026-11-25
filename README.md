# Team 1 · Private Network Service Platform

Computer Networks course project. A client resolves `app.team1.test` through our own DNS server, connects over HTTPS to an nginx edge, and is load-balanced across two Express backends. Everything runs on four MacBooks on one LAN; no cloud.

```
Client (Mac 1 / Mac 4)
  └─ DNS query :53 ──────────► Mac 1  dnsmasq   10.7.17.233      (Vaibhav)
  └─ HTTPS :443 ─────────────► Mac 2  nginx     10.7.30.229    (Pranav)   TLS terminates here
                                  ├─ HTTP :3001 ► Mac 3  Backend A  10.7.3.175  (Himanshu)
                                  └─ HTTP :3002 ► Mac 4  Backend B  10.7.30.71   (Kunal)
```

## Repository layout

| Path | What |
|---|---|
| `backend/` | `server.js` (one file, A or B via env vars), `package.json` |
| `dns/dnsmasq.conf` | Mac 1 DNS config: zone `team1.test`, A records, upstream forwarding |
| `nginx/team1.conf` | Mac 2 edge: upstream pool, HTTP→HTTPS redirect, TLS, HTTP/2, failover |
| `certs/` | `ca.cnf`, `leaf.cnf`, `make-certs.sh` (keys are git-ignored) |
| `docs/SETUP.md` | Step-by-step setup and launch instructions per machine |
| `docs/RUNBOOK.md` | Session start, IP-change fixes, layer-by-layer diagnosis |
| `evidence/` | Terminal outputs from the build and failure tests, Wireshark captures, checklist |
| `dns/phase2/` | Phase 2 dnsmasq config (same file on primary Mac 1 and backup Mac 3), `team1.hosts` records, `set-record.sh` |
| `nginx/phase2/team1.conf` · `team1-standby.conf` | Phase 2 edge configs: primary on Mac 4, standby on Mac 3 (failover tuning, evidence headers, per-request upstream log) |
| `firewall/` | pf rules isolating the backends (loaded by `scripts/phase2/C-apply.sh`; `fw-on.sh` / `fw-off.sh` superseded) |
| `certs/make-standby-cert.sh` | Second leaf certificate for the standby edge, signed by the same CA |
| `scripts/` | `diagnose.sh` (client, PASS/FAIL per layer), `diagnose-edge.sh`, `watch-dns.sh` (TTL/cutover), `lb-check.sh` (failover) |
| `scripts/phase2/` | One script per Phase 2 test (run on Mac 4, writes timestamped evidence), `bootstrap-mac.sh`, `set-record-both.sh`, `health.sh`, shared `lib.sh` |
| `evidence/phase2/` | Phase 2 evidence per extension (A–F, baseline, edge move, Phase 1 failures); index in its `README.md` |
| `docs/PHASE2-SETUP.md` | Phase 2 build + test steps per extension (A–F) |
| `docs/PHASE2-DEMO.md` · `docs/FAULTS.md` · `docs/PHASE2-REPORT.md` | Review 2 run sheet (scripts, order, quick fixes, viva) · fault drills · final report with measured results |

The architecture document (topology, request flow, layer mapping, packet evidence) is a separate shared doc.

## Phase 2 additions

```
Client ── DNS :53 ──► Mac 1 dnsmasq (primary)  |  Mac 3 dnsmasq (backup)       Ext A, B
       └─ HTTPS :443 ► Mac 4 nginx (primary)   |  Mac 3 nginx (standby, DNS cutover)  Ext D, E
                          ├─ :3001 ► Mac 3 Backend A ┐ pf: only the edges may connect  Ext C
                          └─ :3002 ► Mac 4 Backend B ┘ (Mac 4's own nginx uses 127.0.0.1)
```
Pranav's Mac 2 was not available for Phase 2, so the edge moved to Mac 4 (`evidence/phase2/edge-move/`).

Start with `docs/PHASE2-SETUP.md`. Phase 1 configs are kept unchanged in `dns/dnsmasq.conf` and `nginx/team1.conf`.

## Endpoints

| Endpoint | Response | Cache-Control |
|---|---|---|
| `GET /` | `{"service","backend","host","message":"running"}` | – |
| `GET /api/status` | `{"backend":"A","status":"ok","time":…}` | `no-store` |
| `GET /api/cached` | Same body on both backends (same ETag) | `public, max-age=60` |

Every response carries `X-Backend: A` or `X-Backend: B`. In Phase 2 the edge adds `X-Edge` (which nginx answered), `X-Upstream` and `X-Upstream-Status` (backends tried, and their results).

## Quick start
See `docs/SETUP.md`. Before every session, run `docs/RUNBOOK.md`.

## Security note
Never commit `rootCA.key`, `team1.key` or `team1.csr`. Only `rootCA.pem` is distributed to clients.
