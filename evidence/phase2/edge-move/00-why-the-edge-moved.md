# 00 · Why the edge moved from Mac 2 to Mac 4

Date: 2026-11-25 · Written on Mac 4 (Kunals-MacBook-Pro-3, 10.7.30.71)

## What happened
- Pranav's Mac 2 (10.7.30.229), the Phase 1 edge, is not available for Phase 2.
- Its TLS key (`team1.key`) and the CA key (`rootCA.key`) existed only on Mac 2. A private key never leaves
  the Mac that made it, so no other Mac could serve `app.team1.test` with that certificate.
- On 2026-11-25 the DNS servers disagreed: Mac 1 answered `app.team1.test → 10.7.3.175`, Mac 3 answered
  `→ 10.7.30.229` (a dead edge). Mac 1 also trusted an older "Team1 Local Root CA" (Oct 2) than Mac 3 / Mac 4 (Oct 5).

## What we did
1. New CA `Team1 Local Root CA 2026-11` and a new edge certificate for `app.team1.test` / `api.team1.test`,
   made on Mac 4 with `certs/make-certs.sh` (output: `01-make-certs.txt`). `rootCA.key` stays on Mac 4, git-ignored.
2. nginx installed on Mac 4; config `nginx/phase2/team1.conf` (upstream A = 10.7.3.175:3001, B = 127.0.0.1:3002,
   `X-Edge: mac4-primary`).
3. Every client trusts the new CA (one `security add-trusted-cert` per Mac).
4. `app` and `api` records changed to 10.7.30.71 on both DNS servers with `dns/phase2/set-record.sh`.

## New roles
| Mac | Member | IP | Roles |
|---|---|---|---|
| Mac 1 | Vaibhav | 10.7.17.233 | primary DNS · main test client |
| Mac 3 | Himanshu | 10.7.3.175 | backup DNS · Backend A :3001 · standby edge (Ext E) |
| Mac 4 | Kunal | 10.7.30.71 | **primary edge (nginx :443)** · Backend B :3002 |

## Trade-off
Mac 4 is now edge **and** Backend B: one shared failure domain. If Mac 4 goes down, both the edge and one backend
are gone, and Backend A alone cannot help because nothing is left to proxy to it. Only the Ext E standby edge
on Mac 3 (DNS cutover) can bring the service back. Mac 3 was already a shared failure domain (Backend A + backup DNS + standby edge).
