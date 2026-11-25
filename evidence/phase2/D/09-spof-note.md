# Ext D · 09 What the failover test proves, and the single point of failure left

Date: 2026-11-25 · Mac 4 (Kunals-MacBook-Pro-3, 10.7.30.71) · test script `scripts/phase2/D-failover.sh`

## Result (two runs, same script)
| | Run 1 (15:09, `run1/`) | Run 2 (15:13, this folder) |
|---|---|---|
| Requests from mac1 / HTTP 200 | 52 / 52 | 57 / 57 |
| Requests served by A while A was down | 0* | 0 (edge clock, pcap window 27.3 s) |
| Requests that hit dead A and were retried on B (`502, 200`) | 4 | 4 |
| A back in the rotation after the restart command | 3.8 s | 3.3 s |
| Slowest request | 2.0 s | 1.5 s (a retried one) |

\* Run 1's summary counted one A response as "down" because it compared whole-second times from two different
clocks; that request reached A just before the kill. Run 2 classifies everything on the edge's own clock
(pcap + nginx `t=$msec`), which is why the script was changed.

## How it works (what to say in the viva)
- **Passive health checks.** Open-source nginx only learns from real requests. A refused connection to A
  (`connect() failed (61: Connection refused)` in `04-nginx-error-excerpt.txt`) counts as a failure. The request is
  retried on B (`proxy_next_upstream error timeout http_502 http_503`), so the client still gets 200.
  2 failures within 5 s (`max_fails=2 fail_timeout=5s`) take A out for 5 s. After that nginx tries A again on a
  real request, which is why retried requests show up every ~8 s while A is down (`03-client-loop.txt`).
- **Refused, not timed out.** A's Mac is up and nothing listens on 3001, so its kernel answers the SYN with a RST
  (`07-pcap-summary.txt`). macOS tries once with ECN (`[SEW]`) and once without (`[S]`), so each failed try costs
  2 RTTs over Wi-Fi (0.4–0.9 s). If A's Mac were off, the SYN would get no answer and nginx would wait
  `proxy_connect_timeout 2s`.
- **Recovery is not instant**, for the same passive reason: A was listening again ~0.8 s after the START command,
  but nginx only noticed when it next tried A (3.3 s).
- **Keep-alive to the backends.** The pcap shows nginx reusing ONE TCP connection to B for all 41 requests and one
  connection to A per lifetime of the process. When A exits, its kernel sends FIN on that connection
  (start of the down window).
- **A real, unplanned failover** happened at 15:01:41 during setup: `connect() to 10.7.3.175:3001 failed
  (65: No route to host)` in nginx's error.log (a Wi-Fi blip) and that request was served by B. Nobody noticed.

## Single point of failure that is left
Mac 4 is now **both the edge and Backend B** (Pranav's Mac 2 is absent). That is shared fate:
- If Mac 4 goes down, the edge (10.7.30.71, the only address in DNS) and Backend B disappear together.
  Backend A on Mac 3 is healthy but unreachable, because nothing proxies to it. Clients get timeouts until someone
  changes DNS to the standby edge on Mac 3 (Ext E), and even then only Backend A is left.
- Failover *between backends* is automatic (this test). Failover *of the edge* is manual and limited by the DNS TTL (30 s).
- Mac 3 is a second shared failure domain: Backend A + backup DNS + standby edge.

How production removes it:
1. **Two edges with a floating virtual IP**: VRRP (keepalived on Linux) or CARP (BSD). The backup edge takes over the
   VIP within ~1–3 s when it stops hearing the primary's advertisements. DNS keeps pointing at the VIP, so no TTL wait.
2. **Health-checked DNS**: several A records, or a primary/secondary pair with health checks (e.g. Route 53 failover
   routing) that remove a dead edge's record. Still limited by TTL and client caching.
3. **Anycast / a managed load balancer** (cloud LB in front of several edges), so no single box holds the address.
And keep edge and backends on different machines, so one failure doesn't take out two tiers.
