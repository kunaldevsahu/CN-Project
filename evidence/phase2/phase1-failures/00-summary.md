# Phase 1 failure demos, repeated on the Phase 2 system (2026-11-25, 15:53–15:56)

Script: `scripts/phase2/phase1-failures.sh [1-5]` (run on Mac 4, client = mac1). Every demo: inject → look at it layer by
layer from the client → restore → prove it is restored (6 requests, A/B alternating). Phase 1 results: `evidence/H-failures/`.

| # | Fault (injected on) | First layer that fails | What mac1 sees | Phase 1 (2026-10-02) | Restored |
|---|---|---|---|---|---|
| 1 | Client DNS = 8.8.8.8 (mac1) | DNS (client config) | `NXDOMAIN`, `SERVER: 8.8.8.8`, root SOA → curl `(6)`; ping edge OK; `--resolve` → 200 | same: NXDOMAIN, curl `(6)` | ✅ 6/6 × 200 |
| 2 | Record → 10.7.3.175 (mac1 + mac3) | DNS data → TCP | resolves to the wrong Mac; ping OK; `nc 443` **refused**; curl `(7)` after ~1.1 s | same: curl `(7)` after 1070 ms | ✅ |
| 3 | Client uses :8443 | transport (port) | `nc 443` succeeds, `8443` refused; curl `(7)` | same | ✅ (nothing to undo) |
| 4 | Backend B stopped (Mac 4) | edge → backend | **6/6 × 200**, all from A; tries on B show `502, 200` (retried on A); error.log `connect() failed (61)` | B only, 200 | ✅ |
| 5 | Backends A + B stopped | application | DNS OK, TCP OK, **TLS verify OK**, then **HTTP/2 502** from nginx, no X-Backend; error.log `connect() failed` → `no live upstreams` | same: 502 with TLS OK | ✅ |

What changed since Phase 1: the edge is Mac 4 (`x-edge: mac4-primary`), and failover is faster (`max_fails=2
fail_timeout=5s`, Backend B back in the rotation within ~6 s of the restart). The X-Upstream headers show the retry,
which Phase 1 could only see in nginx's error log.

**DNS failure vs application failure** (the viva question): in demo 1 the name never becomes an address, so no TCP/TLS
happens at all (curl 6). In demo 5 everything up to HTTP works and the edge itself answers 502. The first command that
tells them apart is `dig` (or `dscacheutil -q host`): no answer = DNS; an answer = look further up the stack.

Script fixes found while running (logged so nobody repeats them): bash 3.2 brace-expands `{print $1, $2}` inside
`"$(…)"` (use no comma in braces), and `bash -s <<<` on the local Mac breaks when the snippet starts a background job
(`lib.sh` now uses `bash -c` locally).
