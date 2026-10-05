# Setup and launch instructions (configuration bundle)

How every machine was configured on 2026-10-02. Domain: `team1.test`. Network: college Wi-Fi, 10.7.0.0/19, gateway 10.7.0.1.

| Machine | Member | IP | Role |
|---|---|---|---|
| Mac 1 | Vaibhav | 10.7.16.0 | dnsmasq (DNS) + client |
| Mac 2 | Kevish | 10.7.21.121 | nginx edge, TLS, load balancer |
| Mac 3 | Himanshu | 10.7.18.211 | Backend A :3001 |
| Mac 4 | Kunal | 10.7.16.48 | Backend B :3002 + capture client |

## 0. All Macs
- Built-in tools checked: `which curl dig nslookup ping openssl`
- Private Wi-Fi Address for the college network set to **Fixed** (System Settings → Wi-Fi → Details).
- Network details recorded with:
  ```bash
  ipconfig getifaddr en0
  ipconfig getoption en0 subnet_mask
  route -n get default | grep gateway
  ifconfig en0 | grep ether
  ```

## 1. Mac 1: DNS (dnsmasq 2.93)
```bash
brew install dnsmasq
cp $(brew --prefix)/etc/dnsmasq.conf $(brew --prefix)/etc/dnsmasq.conf.original
# copy dns/dnsmasq.conf from this repo to $(brew --prefix)/etc/dnsmasq.conf
$(brew --prefix)/sbin/dnsmasq --test --conf-file=$(brew --prefix)/etc/dnsmasq.conf   # syntax check OK.
sudo brew services start dnsmasq        # sudo: port 53 is privileged
dig @127.0.0.1 app.team1.test +short    # 10.7.21.121
```
Note: dnsmasq lives in `/opt/homebrew/sbin`, which is not on PATH by default.

## 2. Client Macs (Kunal, Himanshu): use the team DNS
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.16.0
dig app.team1.test +short     # 10.7.21.121
dig google.com +short         # still resolves (forwarded upstream)
# undo: sudo networksetup -setdnsservers Wi-Fi empty
```

## 3. Mac 3 and Mac 4: backends (Node.js + Express)
```bash
mkdir -p ~/cn-backend && cd ~/cn-backend
npm init -y && npm install express
# copy backend/server.js from this repo
BACKEND=A PORT=3001 node server.js   # Mac 3 (Himanshu)
BACKEND=B PORT=3002 node server.js   # Mac 4 (Kunal)
```
Check from the edge: `curl -i http://10.7.18.211:3001/api/status` and `curl -i http://10.7.16.48:3002/api/status`.

Tip: share code by copying from the repo or a .txt file, not WhatsApp. Chat apps replace backticks and quotes.

## 4. Mac 2: edge (nginx 1.31.6)
```bash
brew install nginx
mkdir -p $(brew --prefix)/etc/nginx/servers
# copy nginx/team1.conf from this repo to $(brew --prefix)/etc/nginx/servers/team1.conf
sudo nginx -t
sudo brew services start nginx    # later changes: sudo brew services restart nginx
```

## 5. Mac 2: TLS certificates
```bash
cd certs && bash make-certs.sh
sudo brew services restart nginx
curl -i --resolve app.team1.test:443:127.0.0.1 --cacert rootCA.pem https://app.team1.test/api/status   # HTTP/2 200
```
Then AirDrop **only `rootCA.pem`** to each client and trust it:
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/rootCA.pem
curl -i https://app.team1.test/api/status    # no -k, no warnings
```

## 6. Verification commands (demo)
```bash
for i in 1 2 3 4; do curl -si https://app.team1.test/api/status | grep -i x-backend; done   # A B A B
curl -I https://app.team1.test/api/cached                                                   # cache-control + etag
ETAG=$(curl -sI https://app.team1.test/api/cached | grep -i '^etag' | cut -d' ' -f2 | tr -d '\r')
curl -I -H "If-None-Match: $ETAG" https://app.team1.test/api/cached                         # HTTP/2 304
curl -sI --http1.1 https://app.team1.test/api/status | head -1                              # HTTP/1.1 200 OK
curl -sI --http2   https://app.team1.test/api/status | head -1                              # HTTP/2 200
```

## 7. Packet capture (Mac 4)
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
# Wireshark: capture filter "host 10.7.16.0 or host 10.7.21.121", start on Wi-Fi: en0
curl -v --tls-max 1.2 https://app.team1.test/api/status 2>&1 | tee ~/curl-verbose.txt
# stop, save phase1-full-flow.pcapng
# display filter: dns.qry.name == "app.team1.test" or tcp.port == <client port>
```
`--tls-max 1.2` keeps the Certificate message visible (TLS 1.3 encrypts it).
