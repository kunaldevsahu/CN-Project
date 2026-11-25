# Ext E · 14 What the edge migration proves (viva notes)

Date: 2026-11-25 · scripts: `scripts/phase2/E-standby.sh up` → `E-cutover.sh` (→ `E-standby.sh down` at the end)

| Measured (15:34–15:36) | Result | File |
|---|---|---|
| Requests from mac1 during the cutover / restore | 71 / 33, **0 non-200** | `04`, `12` |
| Record changed on both DNS servers | 15:34:24 → 25 (same second on mac1 and mac3), TTL 30 | `05` |
| DNS server answers the new IP | 15:34:26.6 (first loop line after the change) | `04` |
| mac1 actually connects to the new edge | 15:34:45.3 = **21.3 s after the change** | `04`, `10` |
| Last request on the old edge / first on the new | 19.9 s / 21.2 s after the change (edges' own logs) | `09` |
| mac3 as a client | cached → old edge; after `dscacheutil -flushcache` → new edge **at once** | `06` |
| Restore (no flush) | back on mac4-primary **23.3 s** after the record was restored | `12`, `10` |
| Time between mac1's own DNS lookups | **37.75, 37.65, 37.73 s** (TTL 30 s) | `08` |

## Points to explain
- **The switch is a DNS change, so it is gradual.** `dig` (asks the server) shows the new IP right away; curl goes through
  the OS cache and keeps the old IP until that cached answer is thrown away. Two clients at the same moment can be on
  different edges (mac3 after a flush vs mac1 still cached).
- **How long depends on how old the cached answer was.** mac1 had fetched the answer at 15:34:06, 17.8 s before the change,
  and only asked again at 15:34:43.95. A lookup just before the change would have kept it on the old edge for the whole cache lifetime.
- **macOS kept answers ~7.7 s past the TTL.** Three times in a row mac1 asked again only after ~37.7 s, although the loop
  asked every ~1.3 s and the TTL is 30 s. So "≤ TTL" is the theory. On these Macs the measured worst case is ~38 s, and
  browsers can add their own cache and keep connections open for longer still.
- **Production order:** lower the TTL well before → bring the standby up and test it with `--resolve` → change the record on
  all DNS servers at once → keep the old edge up for several TTLs → only then stop it. We stopped the standby only after the
  restore loop showed mac1 back on Mac 4 (`13-standby-down.txt` also checks that DNS no longer points at it).
- **Own key, same CA.** The standby has its own key and certificate (serial …D527 vs …D526) for the same names, signed by
  the same CA. Clients trust the CA, not a particular server, so nothing changed on any client. The CA key never left Mac 4,
  and the standby key was copied straight to mac3 and deleted here (`01`).
- **The standby runs as root on mac3.** A user-level nginx started over ssh was blocked by macOS Local Network privacy
  ("No route to host", no packet sent) from reaching Backend B on Mac 4 (`F/practice-log.md`, real fault 1).
- **Capturing DNS on mac1 needed pktap (en0 + lo0).** mac1 is its own primary DNS server, so its lookups go over loopback and
  never appear on en0. The capture also contains other hosts' lookups to mac1's dnsmasq (mac3 as a client, set-record's dig);
  the analysis keeps only queries sent by mac1 itself.
- **What this is not:** automatic failover. If Mac 4 had died, clients would have failed for up to ~38 s after somebody
  changed the record. A VRRP/keepalived virtual IP or health-checked DNS removes the human and most of the wait (see `D/09`).
