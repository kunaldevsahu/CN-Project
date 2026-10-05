# F · HTTP caching evidence (Task F) — captured 2026-10-02 on Kunal's Mac

## Cache headers
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % curl -I https://app.team1.test/api/cached
HTTP/2 200
server: nginx/1.31.6
date: Fri, 02 Oct 2026 11:03:59 GMT
content-type: application/json; charset=utf-8
content-length: 49
x-powered-by: Express
x-backend: B
cache-control: public, max-age=60
etag: W/"31-BhpixH3upRuqs+uGPrcnwzO1ql0"
```

## Conditional request -> 304 Not Modified
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % ETAG=$(curl -sI https://app.team1.test/api/cached | grep -i '^etag' | cut -d' ' -f2 | tr -d '\r')
echo $ETAG
curl -I -H "If-None-Match: $ETAG" https://app.team1.test/api/cached
W/"31-BhpixH3upRuqs+uGPrcnwzO1ql0"
HTTP/2 304
server: nginx/1.31.6
date: Fri, 02 Oct 2026 11:14:15 GMT
x-powered-by: Express
x-backend: A
cache-control: public, max-age=60
etag: W/"31-BhpixH3upRuqs+uGPrcnwzO1ql0"
```
The ETag was first served by Backend B; the 304 came from Backend A.
Identical content on both backends gives an identical ETag, so revalidation works behind the load balancer.

## The three cases
- Fresh hit: within max-age=60 the client reuses its copy; no request is sent.
- Conditional request: after expiry, If-None-Match is sent; server replies 304 with no body.
- Full request: no cached copy; server replies 200 with the full body.
