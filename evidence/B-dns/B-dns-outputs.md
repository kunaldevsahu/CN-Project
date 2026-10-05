# B · Private DNS evidence (Task B) — captured 2026-10-02

## Upstream DNS reachable from the college network (Vaibhav)
```
vaibhavsingh@Vaibhavs-MacBook-Air-4 ~ % dig @8.8.8.8 google.com +short
192.178.134.113
192.178.134.100
192.178.134.101
192.178.134.139
192.178.134.102
192.178.134.138
```

## Config syntax check (Vaibhav)
```
$(brew --prefix)/sbin/dnsmasq --test --conf-file=$(brew --prefix)/etc/dnsmasq.conf
dnsmasq: syntax check OK.
```

## Query on the DNS server itself (Vaibhav)
```
dig @127.0.0.1 app.team1.test +short
10.7.21.121
```

## Query across the LAN, addressed to the DNS server (Kunal)
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % dig @10.7.16.0 app.team1.test +short
10.7.21.121
```

## Clients configured to use 10.7.16.0 (Kunal and Himanshu)
```
sudo networksetup -setdnsservers Wi-Fi 10.7.16.0
dig app.team1.test +short
10.7.21.121          <- both Kunal and Himanshu
```

## Forwarding still works for non-project names
Himanshu:
```
dig google.com +short
192.178.134.101
192.178.134.113
192.178.134.102
192.178.134.139
192.178.134.138
192.178.134.100
```
Kunal:
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % dig google.com +short
192.178.134.101
192.178.134.113
192.178.134.102
192.178.134.139
192.178.134.138
192.178.134.100
```

## Client resolver settings (screenshots)
- B-client-dns-kunal.png and B-client-dns-himanshu.png: System Settings → Wi-Fi (Rishihood_Learner) → Details → DNS lists only 10.7.16.0
