# A · LAN evidence (Task A) — captured 2026-10-02

## IP inventory
| Role | Member | IPv4 | Subnet mask | Prefix | Gateway | Interface | MAC |
|---|---|---|---|---|---|---|---|
| Mac 1: DNS + client | Vaibhav | 10.7.16.0 | 255.255.224.0 | /19 | 10.7.0.1 | en0 | 80:47:15:df:87:98 |
| Mac 2: Edge (nginx) | Kevish | 10.7.21.121 | 255.255.224.0 | /19 | 10.7.0.1 | en0 | ba:53:b8:ee:a3:2f |
| Mac 3: Backend A | Himanshu | 10.7.18.211 | 255.255.224.0 | /19 | 10.7.0.1 | en0 | 36:f5:7a:81:ae:5e |
| Mac 4: Backend B + client | Kunal | 10.7.16.48 | 255.255.224.0 | /19 | 10.7.0.1 | en0 | f2:e2:90:9b:fe:dd |

Commands used on each Mac:
```
ipconfig getifaddr en0
ipconfig getoption en0 subnet_mask
route -n get default | grep gateway
ifconfig en0 | grep ether
```

## Raw outputs (subnet mask / gateway / MAC)
```
Kevish:   255.255.224.0 | gateway: 10.7.0.1 | ether ba:53:b8:ee:a3:2f
Vaibhav:  255.255.224.0 | gateway: 10.7.0.1 | ether 80:47:15:df:87:98
Himanshu: 255.255.224.0 | gateway: 10.7.0.1 | ether 36:f5:7a:81:ae:5e
Kunal:    255.255.224.0 | gateway: 10.7.0.1 | ether f2:e2:90:9b:fe:dd
```

## Ping from Kevish's Mac (10.7.21.121) to the other three
```
PING 10.7.16.0 (10.7.16.0): 56 data bytes
64 bytes from 10.7.16.0: icmp_seq=0 ttl=64 time=48.887 ms
64 bytes from 10.7.16.0: icmp_seq=1 ttl=64 time=66.513 ms
64 bytes from 10.7.16.0: icmp_seq=2 ttl=64 time=86.465 ms
--- 10.7.16.0 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 48.887/67.288/86.465/15.351 ms

PING 10.7.18.211 (10.7.18.211): 56 data bytes
64 bytes from 10.7.18.211: icmp_seq=0 ttl=64 time=90.076 ms
64 bytes from 10.7.18.211: icmp_seq=1 ttl=64 time=109.684 ms
64 bytes from 10.7.18.211: icmp_seq=2 ttl=64 time=33.498 ms
--- 10.7.18.211 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 33.498/77.753/109.684/32.300 ms

PING 10.7.16.48 (10.7.16.48): 56 data bytes
64 bytes from 10.7.16.48: icmp_seq=0 ttl=64 time=6.679 ms
64 bytes from 10.7.16.48: icmp_seq=1 ttl=64 time=8.732 ms
64 bytes from 10.7.16.48: icmp_seq=2 ttl=64 time=8.278 ms
--- 10.7.16.48 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 6.679/7.896/8.732/0.881 ms
```
All other pairs (Vaibhav, Himanshu, Kunal → the other three) also replied with 0% loss.
TTL 64 on every reply = no router hop between the Macs (same L2 segment).
