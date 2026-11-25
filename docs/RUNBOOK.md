# Runbook: start of every session / an IP changed

College DHCP can hand out new addresses. Run this before any work or demo.

## 1. Check IPs (all 4 Macs)
```bash
ipconfig getifaddr en0
```
Expected: Vaibhav 10.7.17.233 · Pranav 10.7.30.229 (Phase 1 only) · Himanshu 10.7.3.175 · Kunal 10.7.30.71 (Phase 2 edge)

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

# Phase 2 additions (as built 2026-11-25: edge on Mac 4, Mac 2 not available)

## Who depends on whose IP now

| Whose IP changed | Fix |
|---|---|
| Kunal (Mac 4: primary edge + Backend B) | Records on BOTH DNS servers at once: `bash scripts/phase2/set-record-both.sh app.team1.test <new>` (app and api share one line). Himanshu: `edges` in `firewall/team1-backendA.pf` (else the edge is dropped by pf when isolation is on). mac3's standby config: Backend B upstream line. Update `EDGE_IP` / `B_HP` in `scripts/phase2/lib.sh`, `dns/phase2/team1.hosts`. |
| Himanshu (Mac 3: Backend A, backup DNS, standby edge) | Mac 4: Backend A upstream in `servers/team1.conf` (and `nginx/phase2/team1.conf`); mac3's standby config. Clients: `sudo -n /usr/sbin/networksetup -setdnsservers Wi-Fi 10.7.17.233 <new>`. `firewall/team1-backendB.pf` (standby allowed to :3002). `STANDBY_IP`, `DNS2`, `A_HP` in `scripts/phase2/lib.sh`. |
| Vaibhav (Mac 1: primary DNS, main client) | Each client: `sudo -n /usr/sbin/networksetup -setdnsservers Wi-Fi <new> 10.7.3.175`; `DNS1` in `scripts/phase2/lib.sh`; `~/.ssh/config` host `mac1` on Mac 4. |

## Start of a Phase 2 session
```bash
caffeinate -dims                                  # every Mac: a sleeping Mac looks like "host down"
bash scripts/phase2/health.sh                     # Mac 4: one screen with IPs, records, services, pf, standby, A/B
ssh mac1 bash -s < scripts/diagnose.sh            # Mac 4 (or Vaibhav: bash scripts/diagnose.sh): every layer PASS
```
Services and how they are managed: dnsmasq on Mac 1 + Mac 3 = launchd daemons (`sudo -n /opt/homebrew/bin/brew services
start|stop dnsmasq`; KeepAlive, so never just pkill). nginx on Mac 4 = user LaunchAgent (`brew services start nginx`).
Standby nginx on Mac 3 = root, only for Ext E (`scripts/phase2/E-standby.sh up|down`). Backends = nohup node processes,
logs and pids in `~/team1-logs/` (`source scripts/phase2/lib.sh; backend start|stop A|B` from Mac 4).

## If something is wrong
Client: `bash scripts/diagnose.sh` names the first failing layer (exit code 1 DNS, 2 TCP, 3 TLS, 4 HTTP). Edge:
`bash scripts/diagnose-edge.sh`. Full method and fault table: `docs/FAULTS.md`; faults we really hit:
`evidence/phase2/F/practice-log.md`. Quick fixes for the demo: `docs/PHASE2-DEMO.md`.
