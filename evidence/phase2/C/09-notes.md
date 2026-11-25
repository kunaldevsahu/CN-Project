# Ext C · 09 What the isolation test proves (viva notes)

Date: 2026-11-25 · scripts: `scripts/phase2/C-apply.sh` → `C-test.sh` → `C-rollback.sh` (run on Mac 4)

| Check | Result | File |
|---|---|---|
| pf before | mac3 **Disabled**, Mac 4 **Enabled** (already on for 5 days, other software); anchor empty on both | `00-before-*.txt` |
| mac1 → 10.7.3.175:3001 | `Operation timed out` after 3.03 s; 3 SYNs, no reply | `02`, `03`, `04` |
| mac1 → 10.7.30.71:3002 | `Operation timed out` after 3.03 s; 5 SYNs, no reply | `02`, `03`, `05` |
| mac1 → 10.7.3.175:3009 (no rule) | `Connection refused` (RST) | `02`, `03` |
| edge (Mac 4) → A, edge → B (127.0.0.1), standby (mac3) → B | 200 / 200 / 200 | `02` |
| HTTPS through the edge | 8/8 × 200, A/B alternating | `02` |
| pf counters on the block rule | mac3: 3 packets, Mac 4: 5 packets (= the SYNs in the captures) | `02` |
| Rollback | main ruleset diff empty, anchor empty, state Disabled→Disabled (mac3) and Enabled→Enabled (Mac 4), `/etc/pf.conf` identical, nc works again | `07`, `08` |

## Points to explain
- **Timed out vs refused.** `block drop` discards the SYN, so nothing comes back and the client retransmits
  (1 s apart, then faster) until `nc -G 3` gives up. A closed port without a rule is answered by the kernel with a RST
  (refused). macOS sends the first SYN with ECN (`[SEW]`) and retries once without it, which is why even the refusal
  took 1.4 s here.
- **The capture on the backend shows the SYN.** BPF (tcpdump) sees incoming packets before pf filters them, so the SYN
  shows up on mac3 / Mac 4, but no SYN-ACK and no RST ever leave. That proves the drop happened on the backend host.
- **Source-IP rule.** Only 10.7.30.71 (edge) may reach :3001, only 10.7.3.175 (standby edge) may reach :3002 from the LAN.
  Mac 4's own nginx uses 127.0.0.1 (lo0, always passed). If the edge's DHCP address changes, the edge is locked out too:
  nginx would mark A as failed (timeouts, `504` if both are blocked). The network address and the security policy are coupled.
- **Rollback must restore the original state, not just "pf off".** Mac 4 had pf enabled by other software, so the rollback
  only releases **our** reference token (`pfctl -X`) and pf stays enabled ("1 more pf enable reference(s) remaining").
  mac3's pf was disabled before; releasing our token was the last reference, so pf switched itself off.
- **Caveat for demo day.** pf added `flags S/SA keep state` to the pass rules: only new connections create state.
  A connection that was already open when pf was turned on has no state, so its packets hit the block rule. nginx keeps
  upstream connections alive (Ext D), so if traffic is flowing while `C-apply.sh` runs, the next request on that old
  connection to A can stall for `proxy_read_timeout` (5 s) before nginx retries it on B. Apply isolation while the
  loop is idle (Node closes idle keep-alive connections after 5 s), or expect one slow request.
- **No `log` keyword.** `pflog0` doesn't exist on our Macs and creating it needs `sudo ifconfig` (not allowed), so the
  evidence is the backend-side capture + the rule counters instead.
- **Cloud equivalent:** a security group on the backends that allows the app port only from the load balancer's security group.
