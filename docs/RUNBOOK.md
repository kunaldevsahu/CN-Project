# Runbook: start of every session / an IP changed

College DHCP can hand out new addresses. Run this before any work or demo.

## 1. Check IPs (all 4 Macs)
```bash
ipconfig getifaddr en0
```
Expected: Vaibhav 10.7.17.233 · Pranav 10.7.30.229 · Himanshu 10.7.3.175 · Kunal 10.7.30.71

## 2. If something changed

| Whose IP changed | Fix |
|---|---|
| Pranav (edge) | Vaibhav: edit both `host-record` lines in `$(brew --prefix)/etc/dnsmasq.conf` → `sudo brew services restart dnsmasq`. Clients: flush cache. |
| Himanshu or Kunal (backend) | Pranav: edit the `upstream` block in `$(brew --prefix)/etc/nginx/servers/team1.conf` → `sudo nginx -t && sudo brew services restart nginx` |
| Vaibhav (DNS) | Each client: `sudo networksetup -setdnsservers Wi-Fi <new IP>` |

Flush a client's DNS cache:
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

## 3. Start what doesn't survive sleep
```bash
caffeinate -dims                                      # Vaibhav and Pranav, leave the tab open
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
2. `ping -c 2 10.7.30.229` → no reply: network
3. `nc -vz 10.7.30.229 443` → refused: nginx not running
4. `curl -v https://app.team1.test` → certificate error: TLS / CA trust
5. `502 Bad Gateway`: backends down

---

# Phase 2 additions

## Who depends on whose IP now

| Whose IP changed | Fix |
|---|---|
| Pranav (primary edge) | **Vaibhav and Himanshu**: `bash dns/phase2/set-record.sh app.team1.test <new>` and the same for `api.team1.test`, on BOTH DNS servers. **Himanshu and Kunal**: update `edges` in `firewall/team1-backend{A,B}.pf` and re-run `fw-on.sh` if isolation is on (else the edge gets 504). Update the IP in `dns/phase2/team1.hosts` in the repo. |
| Himanshu (Backend A, backup DNS, standby edge) | Pranav **and** Himanshu: upstream line in `servers/team1.conf` on both edges. Clients: `sudo networksetup -setdnsservers Wi-Fi 10.7.17.233 <new>`. Kunal: `edges` in `team1-backendB.pf`. |
| Kunal (Backend B) | Pranav **and** Himanshu: upstream line in `servers/team1.conf` on both edges |
| Vaibhav (primary DNS) | Each client: `sudo networksetup -setdnsservers Wi-Fi <new> 10.7.3.175` |

## Start of a Phase 2 session
```bash
caffeinate -dims                                  # Vaibhav, Pranav, Himanshu (DNS + edges)
sudo brew services list | grep -E 'dnsmasq|nginx' # Mac 1: dnsmasq · Mac 2: nginx · Mac 3: dnsmasq + nginx
bash dns/phase2/set-record.sh --show              # Mac 1 and Mac 3 print the SAME records
bash scripts/diagnose.sh                          # Kunal: every layer OK, both backends in rotation
```

## If something is wrong
Client: `bash scripts/diagnose.sh` names the first failing layer. Edge: `bash scripts/diagnose-edge.sh`. Full method and fault table: `docs/FAULTS.md`.
