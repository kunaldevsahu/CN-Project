#!/bin/bash
# Extension F: layer-by-layer diagnosis from a CLIENT Mac. Read-only, safe to run any time.
#   bash diagnose.sh                       # checks app.team1.test, expects the primary edge 10.7.30.71
#   bash diagnose.sh api.team1.test
#   EXPECT=10.7.3.175 bash diagnose.sh     # during an intentional cutover to the standby edge
#   EXPECT= bash diagnose.sh               # don't check which IP the name resolves to
# From Mac 4 against the main client:  ssh mac1 bash -s < scripts/diagnose.sh
#
# Order: resolver config -> DNS -> IP -> TCP -> TLS -> HTTP (-> load balancing, info only).
# It stops at the FIRST layer that fails (everything above it can't be trusted yet) and ends with a PASS/FAIL summary
# for DNS, TCP, TLS and HTTP. Exit code: 0 = all pass, 1 DNS, 2 TCP, 3 TLS, 4 HTTP.
NAME="${1:-app.team1.test}"
PORT=443
EXPECT="${EXPECT-10.7.30.71}"
PATH_="/api/status"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi
ok()   { echo "  ${G}OK${N}   $*"; }
bad()  { echo "  ${R}FAIL${N} $*"; }
warn() { echo "  ${Y}WARN${N} $*"; }
hdr()  { echo; echo "${B}[$1] $2${N}"; }
S_DNS=SKIP; S_TCP=SKIP; S_TLS=SKIP; S_HTTP=SKIP
summary() {
  echo; echo "${B}SUMMARY${N}  DNS $S_DNS  |  TCP $S_TCP  |  TLS $S_TLS  |  HTTP $S_HTTP"
}
stop() {  # stop <layer var> <layer label> <exit code> <next step hint>
  eval "$1=FAIL"; summary
  echo "${R}${B}First failing layer: $2${N}"; echo "  Next: $4"; exit "$3"
}

echo "${B}Diagnosing https://$NAME$PATH_  from $(scutil --get LocalHostName 2>/dev/null || hostname -s) ($(ipconfig getifaddr en0 2>/dev/null))  $(date '+%H:%M:%S')${N}"
[ -n "$EXPECT" ] && echo "Expected edge: $EXPECT"

# ---------------------------------------------------------------- 0. resolver config
hdr 0 "Resolver configuration (which DNS servers this Mac asks)"
SERVERS=$(scutil --dns 2>/dev/null | awk '/^resolver #1/{f=1} f&&/nameserver\[/{print $3} f&&/^$/{exit}')
[ -z "$SERVERS" ] && SERVERS=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null)
if [ -z "$SERVERS" ]; then bad "no DNS servers configured"; else ok "servers: $(echo $SERVERS)"; fi
if grep -qiE "^[^#]*[[:space:]]$NAME([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  warn "/etc/hosts has an entry for $NAME, it OVERRIDES DNS for curl/browser (dig ignores it):"
  grep -iE "[[:space:]]$NAME([[:space:]]|$)" /etc/hosts | sed 's/^/         /'
fi

# ---------------------------------------------------------------- 1. DNS
hdr 1 "DNS (UDP 53): ask each server directly, then the OS resolver"
ANY_DNS=""
for s in $SERVERS; do
  full=$(dig @"$s" "$NAME" A +time=2 +tries=1 2>&1)
  a=$(echo "$full" | awk -v n="$NAME." '$1==n && $4=="A"{print $5; exit}')
  ttl=$(echo "$full" | awk -v n="$NAME." '$1==n && $4=="A"{print $2; exit}')
  status=$(echo "$full" | awk -F'status: ' '/status:/{split($2,x,",");print x[1]}')
  if [ -n "$a" ]; then ok "@$s -> $a  (TTL ${ttl}s)"; ANY_DNS="$a"
  elif echo "$full" | grep -q "timed out\|no servers could be reached"; then bad "@$s -> no reply (server down, asleep, or port 53 blocked)"
  else bad "@$s -> ${status:-no answer} (server is up but has no record for $NAME)"; fi
done
SYS=$(dscacheutil -q host -a name "$NAME" 2>/dev/null | awk '/ip_address/{print $2; exit}')
if [ -n "$SYS" ]; then ok "OS resolver (what curl/browser use) -> $SYS"; else bad "OS resolver -> nothing"; fi
[ -n "$ANY_DNS" ] && [ -n "$SYS" ] && [ "$ANY_DNS" != "$SYS" ] && \
  warn "OS answer ($SYS) differs from server answer ($ANY_DNS): stale client cache or /etc/hosts. Flush: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
[ -z "$SYS" ] && stop S_DNS "DNS (name does not resolve)" 1 \
  "is dnsmasq running on the DNS Macs? (sudo brew services list; dig @10.7.17.233 / @10.7.3.175) Is the client pointed at them? (networksetup -getdnsservers Wi-Fi)"
if [ -n "$EXPECT" ] && [ "$SYS" != "$EXPECT" ]; then
  bad "resolves to $SYS but the edge is $EXPECT: wrong record (or a cutover in progress: run with EXPECT=$SYS)"
  stop S_DNS "DNS data (wrong IP for $NAME)" 1 "check the record on BOTH DNS servers: bash dns/phase2/set-record.sh --show (mac1 and mac3)"
fi
S_DNS=PASS
IP="$SYS"

# ---------------------------------------------------------------- 2. IP (information only)
hdr 2 "IP reachability (ICMP) to $IP"
if ping -c 2 -t 3 "$IP" >/dev/null 2>&1; then ok "ping $IP replies"
else warn "ping $IP no reply (host off/asleep, other subnet, or ICMP blocked). Continuing with TCP."; fi

# ---------------------------------------------------------------- 3. TCP
hdr 3 "TCP connect to $IP:$PORT (the 3-way handshake)"
out=$(nc -vz -G 3 "$IP" "$PORT" 2>&1)
if echo "$out" | grep -q succeeded; then ok "port $PORT open"; S_TCP=PASS
elif echo "$out" | grep -qi refused; then bad "connection REFUSED: host is up, nothing listening on $PORT (RST)"
  stop S_TCP "TCP (port $PORT refused)" 2 "on the edge: brew services list | grep nginx; nginx -t; lsof -nP -iTCP:$PORT -sTCP:LISTEN"
else bad "connection TIMED OUT: no SYN-ACK (host down, firewall dropping, or wrong IP)"
  stop S_TCP "TCP / network (timeout)" 2 "is $IP really the edge? Is the edge Mac awake? Any pf rule on it? (sudo pfctl -sr)"
fi

# ---------------------------------------------------------------- 4. TLS
hdr 4 "TLS handshake + certificate validation (no -k)"
CERT=$(echo | openssl s_client -connect "$IP:$PORT" -servername "$NAME" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -text 2>/dev/null)
if [ -n "$CERT" ]; then
  echo "$CERT" | grep -E '^(subject|issuer|notAfter)=' | sed 's/^/         /'
  echo "$CERT" | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ */         SAN: /'
fi
curl -sS -o /dev/null --max-time 5 "https://$NAME$PATH_" 2>"$TMP/tls"; rc=$?
case $rc in
  0|22) ok "TLS handshake done, certificate trusted for $NAME"; S_TLS=PASS ;;
  35)   bad "handshake failed (curl 35): protocol/cipher mismatch or not TLS on this port"; cat "$TMP/tls"
        stop S_TLS "TLS (handshake)" 3 "on the edge check ssl_protocols / ssl_certificate lines; nginx -t" ;;
  51|60) bad "certificate NOT trusted (curl $rc)"; cat "$TMP/tls"
        stop S_TLS "TLS (certificate)" 3 "name not in SAN? expired? CA missing from this Mac's System keychain? (security find-certificate -c 'Team1 Local Root CA' /Library/Keychains/System.keychain)" ;;
  28)   bad "timed out during TLS/HTTP (curl 28)"; stop S_TLS "TLS/HTTP (timeout)" 3 "edge accepted TCP but did not answer; check nginx error.log" ;;
  *)    bad "curl exit $rc"; cat "$TMP/tls"; stop S_TLS "TLS" 3 "see the curl error above" ;;
esac

# ---------------------------------------------------------------- 5. HTTP
hdr 5 "HTTP (application) through the edge"
H=$(curl -sS -D - -o "$TMP/body" --max-time 8 -w 'time_total=%{time_total}s' "https://$NAME$PATH_" 2>&1)
code=$(echo "$H" | awk 'NR==1{print $2}')
get() { echo "$H" | awk -F': ' -v k="$1" 'tolower($1)==k{gsub("\r","",$2);print $2}'; }
echo "         status=$code  x-backend=$(get x-backend)  x-edge=$(get x-edge)  x-upstream=$(get x-upstream)  x-upstream-status=$(get x-upstream-status)  $(echo "$H" | grep -o 'time_total=.*')"
echo "         body: $(head -c 200 "$TMP/body")"
case "$code" in
  200) ok "application answered"; S_HTTP=PASS ;;
  502) bad "502 Bad Gateway: edge OK, it could not get a valid answer from ANY backend (refused/reset)"
       stop S_HTTP "HTTP: edge -> backend (502)" 4 "on the edge: tail error.log; curl each backend from the edge; backends running? bound to 0.0.0.0? pf rule allows the edge's IP?" ;;
  504) bad "504 Gateway Timeout: backends did not accept/answer in time (asleep, dropped by firewall, wrong IP)"
       stop S_HTTP "HTTP: edge -> backend (504)" 4 "on the edge: nc -vz -G 3 <backend-ip> <port>; pf rules on the backend (sudo pfctl -a com.apple/team1 -sr)" ;;
  404) bad "404: request reached a server that has no such path (wrong upstream? wrong server block?)"
       stop S_HTTP "HTTP (404, routing)" 4 "check proxy_pass and the upstream ports in team1.conf" ;;
  *)   bad "HTTP $code"; stop S_HTTP "HTTP ($code)" 4 "check the edge error.log and the backend logs" ;;
esac
[ -n "$(get x-upstream | grep ',')" ] && warn "this request needed a RETRY on another backend (failover happened)"

# ---------------------------------------------------------------- 6. load balancing (information only)
hdr 6 "Load balancing (6 requests, information only)"
seq_=""; for _ in 1 2 3 4 5 6; do
  b=$(curl -s -D - -o /dev/null --max-time 8 "https://$NAME$PATH_" | awk -F': ' 'tolower($1)=="x-backend"{gsub("\r","",$2);print $2}')
  seq_="$seq_ ${b:--}"; done
echo "         backends:$seq_"
if echo "$seq_" | grep -q A && echo "$seq_" | grep -q B; then ok "both backends in rotation"
else warn "only one backend is serving: the other is down or marked failed (fail_timeout)"; fi

summary
echo "${G}${B}All layers OK${N}"
exit 0
