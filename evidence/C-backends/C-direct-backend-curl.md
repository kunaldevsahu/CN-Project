# C · Backend evidence (Task C) — captured 2026-10-02

Kevish's Mac (the edge, 10.7.21.121) reaching each backend directly across the LAN:

```
curl -i http://10.7.18.211:3001/api/status
HTTP/1.1 200 OK
X-Powered-By: Express
X-Backend: A
Cache-Control: no-store
Content-Type: application/json; charset=utf-8
Content-Length: 63
ETag: W/"3f-8GLaBe/4pURn5lo8i6swjHuz3OQ"
Date: Fri, 02 Oct 2026 10:55:20 GMT
Connection: keep-alive
Keep-Alive: timeout=5

{"backend":"A","status":"ok","time":"2026-10-02T10:55:20.505Z"}
```

```
curl -i http://10.7.16.48:3002/api/status
HTTP/1.1 200 OK
X-Powered-By: Express
X-Backend: B
Cache-Control: no-store
Content-Type: application/json; charset=utf-8
Content-Length: 63
ETag: W/"3f-JxXZnkoThcr2il2Tv20jup59+aA"
Date: Fri, 02 Oct 2026 10:55:42 GMT
Connection: keep-alive
Keep-Alive: timeout=5

{"backend":"B","status":"ok","time":"2026-10-02T10:55:42.057Z"}
```

Both backends bind 0.0.0.0 (all interfaces), so the edge can reach them.
The ETags differ because /api/status includes the backend name and time.

## Backend log: every request arrives from the edge, not the client
Kunal (client, 10.7.16.48) sent 4 requests through the domain name:
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % for i in 1 2 3 4; do curl -si https://app.team1.test/api/status | grep -i x-backend; done
x-backend: B
x-backend: A
x-backend: B
x-backend: A
```
Backend A's terminal (Himanshu) at the same time:
```
himanshupal@Himanshus-MacBook-Pro cn-backend % cd ~/cn-backend && BACKEND=A PORT=3001 node server.js
Backend A listening on 0.0.0.0:3001
2026-10-02T13:01:22.740Z  from=10.7.21.121  GET /api/status
2026-10-02T13:01:22.956Z  from=10.7.21.121  GET /api/status
2026-10-02T13:20:33.886Z  from=10.7.21.121  GET /api/status
2026-10-02T13:20:34.266Z  from=10.7.21.121  GET /api/status
```
The source is 10.7.21.121 (Kevish's nginx), never the client's 10.7.16.48: the backend only talks to the reverse proxy.
