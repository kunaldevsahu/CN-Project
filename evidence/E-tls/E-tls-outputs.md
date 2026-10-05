# E · HTTPS / TLS evidence (Task E) — captured 2026-10-02

## Certificate verification (Kevish)
```
$OPENSSL verify -CAfile rootCA.pem team1.crt
team1.crt: OK

$OPENSSL x509 -in team1.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:app.team1.test, DNS:api.team1.test
```

## HTTPS through nginx with explicit CA trust (Kevish, local)
```
curl -i --resolve app.team1.test:443:127.0.0.1 \
  --cacert ~/cn-certs/rootCA.pem https://app.team1.test/api/status
HTTP/2 200
server: nginx/1.31.6
date: Fri, 02 Oct 2026 11:00:25 GMT
content-type: application/json; charset=utf-8
content-length: 63
x-powered-by: Express
x-backend: A
cache-control: no-store
etag: W/"3f-09Krt2dUuIHYebsKpoKBMWbsY7c"

{"backend":"A","status":"ok","time":"2026-10-02T11:00:25.037Z"}
```
HTTP/2 negotiated; TLS terminates at nginx, the leg to the backend is plain HTTP.

## Client trust
rootCA.pem added to the System keychain on Vaibhav, Himanshu and Kunal:
```
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/rootCA.pem
```
Then `curl -i https://app.team1.test/api/status` returned HTTP/2 200 with no -k and no --cacert,
and Safari opened https://app.team1.test without a warning (confirmed by the team).

## TLS handshake on the wire
See G-wireshark: packets 353 (Client Hello, SNI app.team1.test), 356 (Server Hello, Certificate,
Server Key Exchange, Server Hello Done), 358 (Client Key Exchange, Change Cipher Spec, Finished),
360 (server Change Cipher Spec, Finished).

## Client HTTPS with no -k and no --cacert (Kunal, 10.7.16.48)
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % curl -i https://app.team1.test/api/status
HTTP/2 200
server: nginx/1.31.6
date: Fri, 02 Oct 2026 13:21:57 GMT
content-type: application/json; charset=utf-8
content-length: 63
x-powered-by: Express
x-backend: B
cache-control: no-store
etag: W/"3f-EACuqHYSavkcSwlA238p4B4xx0Q"

{"backend":"B","status":"ok","time":"2026-10-02T13:21:57.184Z"}
```
Name resolved through team DNS, certificate validated against the trusted Team1 CA, HTTP/2 negotiated.

## Screenshots
- E-browser-certificate.png: Chrome loaded https://app.team1.test with no warning; certificate issued to app.team1.test by Team1 Local Root CA, valid Oct 2 2026 to Nov 3 2027 (397 days)
- E-keychain-ca-trust.png: Team1 Local Root CA in the System keychain, "trusted for all users", Always Trust; CA:TRUE, Key Cert Sign + CRL Sign, RSA 2048, valid to 4 Jan 2029 (825 days)

## HTTP/1.1 and HTTP/2 on the same service (Kunal)
```
kunaldevsahu@Kunals-MacBook-Pro-3 ~ % curl -sI --http1.1 https://app.team1.test/api/status | head -1
curl -sI --http2 https://app.team1.test/api/status | head -1
HTTP/1.1 200 OK
HTTP/2 200
```
The version is agreed inside the TLS handshake via ALPN: the client offers protocols in its Client Hello and nginx picks one.
