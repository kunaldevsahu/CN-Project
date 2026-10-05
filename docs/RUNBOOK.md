# Runbook: start of every session / an IP changed

College DHCP can hand out new addresses. Run this before any work or demo.

## 1. Check IPs (all 4 Macs)
```bash
ipconfig getifaddr en0
```
Expected: Vaibhav 10.7.16.0 · Kevish 10.7.21.121 · Himanshu 10.7.18.211 · Kunal 10.7.16.48

## 2. If something changed

| Whose IP changed | Fix |
|---|---|
| Kevish (edge) | Vaibhav: edit both `host-record` lines in `$(brew --prefix)/etc/dnsmasq.conf` → `sudo brew services restart dnsmasq`. Clients: flush cache. |
| Himanshu or Kunal (backend) | Kevish: edit the `upstream` block in `$(brew --prefix)/etc/nginx/servers/team1.conf` → `sudo nginx -t && sudo brew services restart nginx` |
| Vaibhav (DNS) | Each client: `sudo networksetup -setdnsservers Wi-Fi <new IP>` |

Flush a client's DNS cache:
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

## 3. Start what doesn't survive sleep
```bash
caffeinate -dims                                      # Vaibhav and Kevish, leave the tab open
cd ~/cn-backend && BACKEND=A PORT=3001 node server.js # Himanshu
cd ~/cn-backend && BACKEND=B PORT=3002 node server.js # Kunal
```
dnsmasq, nginx, client DNS settings and the trusted CA survive restarts.

## 4. One test checks everything (Kunal)
```bash
for i in 1 2 3 4; do curl -si https://app.team1.test/api/status | grep -i x-backend; done
```
A and B alternating = DNS, TCP, TLS, nginx and both backends are up.

## If it fails, go layer by layer
1. `dig app.team1.test +short` → empty / "could not resolve": DNS (is Vaibhav's Mac awake?)
2. `ping -c 2 10.7.21.121` → no reply: network
3. `nc -vz 10.7.21.121 443` → refused: nginx not running
4. `curl -v https://app.team1.test` → certificate error: TLS / CA trust
5. `502 Bad Gateway`: backends down
