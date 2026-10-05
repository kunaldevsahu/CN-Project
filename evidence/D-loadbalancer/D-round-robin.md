# D · Reverse proxy and load balancing evidence (Task D) — captured 2026-10-02

## nginx config test (Kevish)
```
sudo nginx -t
nginx: the configuration file /opt/homebrew/etc/nginx/nginx.conf syntax is ok
nginx: configuration file /opt/homebrew/etc/nginx/nginx.conf test is successful
```

## Round-robin through the domain name (Kunal, HTTP stage before TLS)
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % for i in 1 2 3 4; do curl -si http://app.team1.test/api/status | grep X-Backend; done
X-Backend: A
X-Backend: B
X-Backend: A
X-Backend: B
```
The client only used the name app.team1.test; it never contacted 10.7.18.211 or 10.7.16.48.
