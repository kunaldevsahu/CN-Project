# H · Failure demonstrations — captured 2026-10-02 on Kunal's Mac unless noted

## 1. Wrong DNS server on the client
```
sudo networksetup -setdnsservers Wi-Fi 8.8.8.8
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

kunaldevsahu@Kunals-MacBook-Pro-3 ~ % dig app.team1.test
curl https://app.team1.test/api/status

; <<>> DiG 9.10.6 <<>> app.team1.test
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 31898
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 512
;; QUESTION SECTION:
;app.team1.test.			IN	A

;; AUTHORITY SECTION:
.			86218	IN	SOA	a.root-servers.net. nstld.verisign-grs.com. 2026100200 1800 900 604800 86400

;; Query time: 43 msec
;; SERVER: 8.8.8.8#53(8.8.8.8)
;; WHEN: Fri Oct 02 17:04:36 IST 2026
;; MSG SIZE  rcvd: 118

curl: (6) Could not resolve host: app.team1.test
```
Then `ping -c 2 10.7.21.121` replied and
`curl --resolve app.team1.test:443:10.7.21.121 https://app.team1.test/api/status` succeeded (confirmed by the team).
DNS failed; IP connectivity did not. Restored with `sudo networksetup -setdnsservers Wi-Fi 10.7.16.0`.

## 2. DNS record points to the wrong IP
Vaibhav changed `host-record=app.team1.test` to 10.7.18.211 (Himanshu, no nginx) and restarted dnsmasq.
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
dig app.team1.test +short
curl https://app.team1.test/api/status
curl https://api.team1.test/api/status
10.7.18.211
curl: (7) Failed to connect to app.team1.test port 443 after 1070 ms: Couldn't connect to server
{"backend":"B","status":"ok","time":"2026-10-02T11:39:21.289Z"}
```
Resolution succeeded but pointed at the wrong host; TCP to 443 failed. api.team1.test (correct record) still worked.
Restored, then:
```
dig app.team1.test +short
10.7.21.121
```

## 3. One backend stopped (Backend A, Ctrl+C on Himanshu's Mac)
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % for i in 1 2 3 4 5 6; do curl -si https://app.team1.test/api/status | grep -i x-backend; done
x-backend: B
x-backend: B
x-backend: B
x-backend: B
x-backend: B
x-backend: B
```
nginx error log on Kevish's Mac:
```
tail -n 5 $(brew --prefix)/var/log/nginx/error.log
2026/10/02 16:36:58 [error] 6528#0: *11 upstream timed out (60: Operation timed out) while connecting to upstream, client: 10.7.16.48, server: app.team1.test, request: "HEAD /api/cached HTTP/2.0", upstream: "http://10.7.18.211:3001/api/cached", host: "app.team1.test"
2026/10/02 17:11:16 [error] 6528#0: *44 kevent() reported that connect() failed (61: Connection refused) while connecting to upstream, client: 10.7.16.48, server: app.team1.test, request: "GET /api/status HTTP/2.0", upstream: "http://10.7.18.211:3001/api/status", host: "app.team1.test"
```
After restarting Backend A (fail_timeout 10s):
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % for i in 1 2 3 4 5 6; do curl -si https://app.team1.test/api/status | grep -i x-backend; done
x-backend: B
x-backend: B
x-backend: A
x-backend: B
x-backend: A
x-backend: B
```

## 4. Both backends stopped
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % dig app.team1.test +short
curl -vi https://app.team1.test/api/status 2>&1 | grep -iE "SSL connection|HTTP/2|x-backend|server:"
10.7.21.121
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256 / [blank] / UNDEF
* using HTTP/2
* [HTTP/2] [1] OPENED stream for https://app.team1.test/api/status
* [HTTP/2] [1] [:method: GET]
* [HTTP/2] [1] [:scheme: https]
* [HTTP/2] [1] [:authority: app.team1.test]
* [HTTP/2] [1] [:path: /api/status]
* [HTTP/2] [1] [user-agent: curl/8.7.1]
* [HTTP/2] [1] [accept: */*]
> GET /api/status HTTP/2
< HTTP/2 502
< server: nginx/1.31.6
HTTP/2 502
server: nginx/1.31.6
```
DNS, TLS and HTTP/2 all work at the edge; 502 comes from nginx with no x-backend header.
(Progress-meter lines removed; bullets restored to curl's "*" after a chat app altered them.)

## 5. Wrong destination port
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % nc -vz 10.7.21.121 443
nc -vz 10.7.21.121 8443
Connection to 10.7.21.121 port 443 [tcp/https] succeeded!
nc: connectx to 10.7.21.121 port 8443 (tcp) failed: Connection refused
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % curl https://app.team1.test:8443/api/status
curl: (7) Failed to connect to app.team1.test port 8443 after 1039 ms: Couldn't connect to server
```
Same host, different port: the address picks the machine, the port picks the service.

## Unplanned: DNS server offline
When Vaibhav's Mac shut down, every client failed name resolution:
```
curl: (6) Could not resolve host: app.team1.test
exit=6
```
