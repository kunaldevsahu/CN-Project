# Team 1 · Private Network Service Platform

Computer Networks course project. A client resolves `app.team1.test` through our own DNS server, connects over HTTPS to an nginx edge, and is load-balanced across two Express backends. Everything runs on four MacBooks on one LAN; no cloud.

```
Client (Mac 1 / Mac 4)
  └─ DNS query :53 ──────────► Mac 1  dnsmasq   10.7.16.0      (Vaibhav)
  └─ HTTPS :443 ─────────────► Mac 2  nginx     10.7.21.121    (Kevish)   TLS terminates here
                                  ├─ HTTP :3001 ► Mac 3  Backend A  10.7.18.211  (Himanshu)
                                  └─ HTTP :3002 ► Mac 4  Backend B  10.7.16.48   (Kunal)
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

The architecture document (topology, request flow, layer mapping, packet evidence) is a separate shared doc.

## Endpoints

| Endpoint | Response | Cache-Control |
|---|---|---|
| `GET /` | `{"service","backend","host","message":"running"}` | – |
| `GET /api/status` | `{"backend":"A","status":"ok","time":…}` | `no-store` |
| `GET /api/cached` | Same body on both backends (same ETag) | `public, max-age=60` |

Every response carries `X-Backend: A` or `X-Backend: B`.

## Quick start
See `docs/SETUP.md`. Before every session, run `docs/RUNBOOK.md`.

## Security note
Never commit `rootCA.key`, `team1.key` or `team1.csr`. Only `rootCA.pem` is distributed to clients.
