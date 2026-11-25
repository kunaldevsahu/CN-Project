# Ext F · Practice log (real faults met while building Phase 2, and practice drills)

Method every time (docs/FAULTS.md): **DNS → TCP (`nc -vz`) → TLS (`openssl s_client`) → app / nginx error log**,
stop at the first layer that fails. Each entry: symptom → what each layer showed → cause → fix → lesson.

---

## Real fault 1 · Standby edge on mac3 could not reach Backend B ("No route to host")
**When:** 2026-11-25 15:27–15:31 · **Found by:** `scripts/phase2/E-standby.sh up` (Stage 5, Ext E)

**Symptom.** Through the standby (`curl --resolve app.team1.test:443:10.7.3.175` from mac1) every request returned 200,
but always from Backend A. Requests that tried B showed `x-upstream: 10.7.30.71:3002, 10.7.3.175:3001`: B failed and
nginx retried on A, so the client never saw an error. The failover hid the fault, and only the evidence headers showed it.

| Layer | Check (on mac3 unless noted) | Result |
|---|---|---|
| DNS | not involved: the upstream is an IP address | n/a |
| TCP | `nc -vz -G 3 10.7.30.71 3002` from mac3's ssh shell | `succeeded` |
| HTTP direct | `curl http://10.7.30.71:3002/api/status` from mac3's ssh shell | `200` in 0.02 s |
| Backend B | `lsof -iTCP:3002` on Mac 4, pf anchor on Mac 4 | listening on `*:3002`; anchor empty (Ext C rolled back) |
| nginx error log | `/opt/homebrew/var/log/nginx/error.log` on mac3 | `connect() to 10.7.30.71:3002 failed (65: No route to host)`; access log `urt=0.000` = failed instantly |
| Packets | `tcpdump -i en0 'tcp port 3002 or arp'` on mac3 while nginx tried B | **no SYN from nginx at all** and no ARP for 10.7.30.71; only the control curl's connection appears |
| ARP / ping | `arp -n 10.7.30.71`, `ping` | valid entry; 0 % loss (7–200 ms jitter on the campus Wi-Fi) |

**Cause.** The connection never left the host, and curl from the same Mac worked, so the kernel refused nginx's
`connect()` locally. That is **macOS Local Network privacy** (macOS 15+): a process that isn't allowed "Local Network"
access gets `EHOSTUNREACH` ("No route to host") for other hosts on the LAN, while loopback and the Mac's own IP still work
(Backend A on mac3 = own IP = lo0, which is why A kept working). nginx was started by us **over ssh as a normal user**, so it
had no permission and nobody was at mac3 to click "Allow". curl run over ssh is attributed to sshd (an Apple binary) and
is allowed.

**Fix.** Run the standby nginx as root: `sudo -n /opt/homebrew/bin/nginx` (allowed by our sudo rule; workers run as
`nobody`). Immediately A/B alternation, no errors (`evidence/phase2/E/02-standby-up.txt`). `E-standby.sh` now always
starts/stops it with `sudo -n`. Alternative without root: Himanshu allows nginx in System Settings → Privacy & Security
→ Local Network (needs someone at the Mac).

**Probably the same thing on Mac 4.** The primary edge logged `connect() to 10.7.3.175:3001 failed (65: No route to host)`
once at 15:01:41, six seconds after nginx was restarted under launchd, and then worked. Most likely the same permission
check, answered on Mac 4 (someone at the Mac / an earlier grant). Not a Wi-Fi blip as first written in the D notes.

**Lessons.** (1) "No route to host" with **no packet on the wire** is a local policy decision, not the network. Check with
tcpdump before blaming Wi-Fi. (2) Failover can hide a broken backend: all requests were 200. Always look at which backend
answered (`X-Upstream`) and at the error log, not only at the status code. (3) Something that works from your shell can still
fail from a daemon: different process, different permissions.

---

## Real fault 2 · Script hang: `nginx` started over ssh kept the session open (~95 s)
**When:** 2026-11-25 15:25–15:27 · **Symptom:** `E-standby.sh up` took ~100 s; mac3's nginx logged the first request
95 s after it was started. **Cause:** the nginx daemon inherited the ssh session's stdout/stderr; ssh waits until every
holder closes them. **Fix:** start daemons over ssh with `</dev/null >/dev/null 2>&1` (same rule as `nohup … &` for the
backends). After the fix: 12 s for the whole start + check.

---

## Real fault 3 · I made the edge's temp folders unwritable (root `nginx -t`)
**When:** 2026-11-25 16:02 · **Found by:** checking file ownership after `scripts/diagnose-edge.sh` was changed to `sudo -n`.
**What happened.** The edge on Mac 4 runs nginx as the normal user. Running `sudo -n /opt/homebrew/bin/nginx -t` there
made nginx (as root) `chown` its temp folders in `/opt/homebrew/var/run/nginx/` to `nobody` (mode 700, ctime 16:02:32).
The user-level workers could then no longer write request bodies or big responses to disk. Our API answers are tiny,
so nothing failed yet. That is exactly the kind of fault that appears weeks later under load.
**Fix.** The folders were empty, and I own their parent, so `rmdir` them + `nginx -s reload` recreated them as
`kunaldevsahu`. `diagnose-edge.sh` now runs `nginx -t` as whoever owns the nginx master (root on mac3, the user on Mac 4).
**Lesson.** A "read-only" check run as root is not always read-only. Run tools as the same user as the service.

---

## Practice drills: one fault per layer (Stage 8, 2026-11-25 16:04–16:05)
Script: `scripts/phase2/F-drill.sh dns|tcp|tls|http` injects the fault, runs `scripts/diagnose.sh` on mac1, runs the
manual commands, fixes it and runs `diagnose.sh` again. The script injects the fault itself so it can be repeated; for the
viva, a teammate should inject one in secret and the others diagnose it out loud with the same method.
Healthy reference: `00-diagnose-healthy.txt` (DNS PASS | TCP PASS | TLS PASS | HTTP PASS).

| Drill (file) | Injected | diagnose.sh said | Confirmed by hand | Fix | Inject → verified |
|---|---|---|---|---|---|
| **DNS** (`01-drill-dns.txt`) | app/api → 10.7.3.175 on both DNS servers | `DNS FAIL`: "resolves to 10.7.3.175 but the edge is 10.7.30.71", exit 1 | `set-record.sh --show` on mac1 + mac3; `nc 10.7.3.175 443` refused | `set-record-both.sh … 10.7.30.71`, flush | 18.4 s |
| **TCP** (`02-drill-tcp.txt`) | `brew services stop nginx` on the edge | `TCP FAIL`: "connection REFUSED … nothing listening on 443", exit 2 | `nc` refused but ping OK; `lsof :443` empty; brew services shows nginx stopped | `nginx -t`, `brew services start nginx` | 14.1 s |
| **TLS** (`03-drill-tls.txt`) | edge config points at a self-signed cert for `wrong.test` | `TLS FAIL`: curl `(60)` self signed certificate, subject `CN=wrong.test`, exit 3 | `openssl s_client … \| openssl x509 -subject -issuer` | config restored from backup, `nginx -t`, reload | 15.3 s |
| **HTTP** (`04-drill-http.txt`) | both backends stopped | `HTTP FAIL`: 502 from the edge (DNS, TCP, TLS PASS), exit 4 | `diagnose-edge.sh`: both backends refused; error.log `connect() failed (61)` | start both backends, wait `fail_timeout` | 27.8 s |

**What the drills taught us**
- **Stop at the first failing layer.** In the DNS drill, TCP to the wrong IP is also refused, but that's a symptom: the
  cause is the record. With the expected edge built in (`EXPECT=10.7.30.71`), diagnose.sh names DNS instead of TCP.
- **Refused vs timed out** was the fastest clue every time: refused = the host answered and nothing listens (nginx stopped,
  wrong Mac); timed out = nothing answered (host off, pf drop, see Ext C).
- **TLS failures say *why*:** `(60)` with `self signed` / a different subject = wrong certificate; `(35)` would be a
  protocol or handshake problem. Always read the subject/issuer before touching the keychain.
- **502 means the network is fine up to the edge.** Look behind it with `diagnose-edge.sh` (edge → each backend) and the
  error log, not on the client.
- **Fix time is dominated by restarts and caches** (DNS cache flush, `fail_timeout` 5 s), not by finding the fault: diagnosis
  took 1–7 s with the script.
