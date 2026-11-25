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

## Practice drills (one per layer) · to be filled in Stage 8
