# G · Packet capture evidence (Task G) — Kunal's Mac, en0, 2026-10-02

Request captured: `curl -v --tls-max 1.2 https://app.team1.test/api/status`
Files in this folder: `phase1-full-flow.pcapng` (whole capture, 686 packets), `phase1-app-flow.pcapng` (only the app.team1.test DNS + TCP 50353 conversation, renumbered from 1), `curl-verbose.txt`

Screenshots in this folder:
- G0 — Wi-Fi: en0 ready to capture
- G1 — display filter `dns`
- G2 — display filter `tcp.flags.syn == 1`
- G3 — display filter `tls.handshake`
- G4 — `dns.qry.name == "app.team1.test" or tcp.port == 50353` (handshake through teardown, including retransmission)

## What to point at

| Packets | Layer | Shows |
|---|---|---|
| 346 → 347 | DNS / UDP | 10.7.16.48:58942 → 10.7.16.0:53, `A app.team1.test`; response `A 10.7.21.121` |
| 349, 351 (+ ACK) | TCP | SYN 50353 → 443, SYN-ACK 443 → 50353; client ephemeral port 50353, server port 443 |
| 353 | TLS 1.2 | Client Hello, SNI = app.team1.test |
| 356 | TLS 1.2 | Server Hello, Certificate, Server Key Exchange, Server Hello Done |
| 358 | TLS 1.2 | Client Key Exchange, Change Cipher Spec, Encrypted Handshake Message |
| 360 | TLS 1.2 | Change Cipher Spec, Encrypted Handshake Message (server Finished) |
| 362–373 | TLS Application Data | HTTP request/response, encrypted (headers only visible in curl -v) |
| 375, 377, 389, 390 | TCP reliability | Encrypted Alert (Seq 501) lost; Dup ACK Ack=501 with SACK 524–525; retransmission from Seq 501 |
| 376, 392, 393 | Teardown | FIN from client; RST from server for the leftover connection |

Also in the capture: QUIC (UDP 443) from other apps = HTTP/3 (explanation-only).

## Detail screenshots
- G5 — clean flow from the top: DNS 346/347, handshake 349/351/352, TLS 353–360, data, teardown
- G6 — packet 346: UDP Src Port 58942 → Dst Port 53; Ethernet dst = 80:47:15:df:87:98 (Vaibhav's MAC)
- G7 — packet 349: TCP Src Port 50353 → Dst Port 443, Seq 0, Flags SYN, Window 65535, options MSS / window scale / SACK permitted; Ethernet dst = ba:53:b8:ee:a3:2f (Kevish's MAC)
- G8 — packet 362: TLSv1.2 record, Content Type Application Data (23), Encrypted Application Data (unreadable), Application Data Protocol = HTTP/2 (chosen by ALPN)

Viva point: the destination MAC is the target Mac's own MAC, not the gateway's, so frames go host-to-host on the same L2 segment.

## curl -v output (curl-verbose.txt)
The same request seen from the application side: DNS gave 10.7.21.121; ALPN offered h2,http/1.1 and the server accepted h2;
the TLS 1.2 handshake messages match packets 353-360; the certificate (CN=app.team1.test, issuer Team1 Local Root CA) verified OK;
and the HTTP/2 request and response headers, including x-backend: A, which are encrypted on the wire (packet 362).
