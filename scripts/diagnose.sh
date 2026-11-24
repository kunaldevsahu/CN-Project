#!/bin/bash
# Extension F: layer-by-layer diagnosis from a CLIENT Mac (Kunal or Vaibhav). Read-only, safe to run anytime.
#   bash diagnose.sh                      # checks app.team1.test
#   bash diagnose.sh api.team1.test
#   EXPECT=10.7.30.229 bash diagnose.sh   # also flag a DNS answer that isn't the expected edge
#
# Order: resolver config -> DNS -> IP reachability -> TCP port -> TLS -> HTTP -> load balancing.
# It stops pointing at the FIRST layer that fails; everything above that layer is not trustworthy yet.
NAME="${1:-app.team1.test}"
PORT=443
EXPECT="${EXPECT:-}"
PATH_="/api/status"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
ok()   { echo "  ${G}OK${N}   $*"; }
bad()  { echo "  ${R}FAIL${N} $*"; }
warn() { echo "  ${Y}WARN${N} $*"; }
hdr()  { echo; echo "${B}[$1] $2${N}"; }
stop() { echo; echo "${R}${B}First failing layer: $1${N}"; echo "  Next: $2"; exit 1; }

echo "${B}Diagnosing https://$NAME$PATH_  from $(hostname -s) ($(ipconfig getifaddr en0 2>/dev/null))  $(date '+%H:%M:%S')${N}"

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
  a=$(dig @"$s" "$NAME" A +short +time=2 +tries=1 2>&1 | grep -E '^[0-9.]+$' | head -1)
  full=$(dig @"$s" "$NAME" A +time=2 +tries=1 2>&1)
  status=$(echo "$full" | awk -F'status: ' '/status:/{split($2,x,",");print x[1]}')
  ttl=$(echo "$full" | awk -v n="$NAME." '$1==n && $4=="A"{print $2; exit}')
  if [ -n "$a" ]; then ok "@$s -> $a  (TTL ${ttl}s)"; ANY_DNS="$a"
  elif echo "$full" | grep -q "timed out\|no servers could be reached"; then bad "@$s -> no reply (server down, asleep, or port 53 blocked)"
  else bad "@$s -> ${status:-no answer} (server is up but has no record for $NAME)"; fi
done
SYS=$(dscacheutil -q host -a name "$NAME" 2>/dev/null | awk '/ip_address/{print $2; exit}')
if [ -n "$SYS" ]; then ok "OS resolver (what curl/browser use) -> $SYS"; else bad "OS resolver -> nothing"; fi
[ -n "$ANY_DNS" ] && [ -n "$SYS" ] && [ "$ANY_DNS" != "$SYS" ] && \
  warn "OS answer ($SYS) differs from server answer ($ANY_DNS): stale client cache or /etc/hosts. Flush: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
[ -n "$EXPECT" ] && [ -n "$SYS" ] && [ "$SYS" != "$EXPECT" ] && warn "expected $EXPECT, got $SYS: wrong record?"
[ -z "$SYS" ] && stop "DNS" "is dnsmasq running on the DNS Macs? (sudo brew services list; tail /opt/homebrew/var/log/dnsmasq.log) Is the client pointed at them? (networksetup -getdnsservers Wi-Fi)"
IP="$SYS"

# ---------------------------------------------------------------- 2. IP
hdr 2 "IP reachability (ICMP) to $IP"
if ping -c 2 -t 3 "$IP" >/dev/null 2>&1; then ok "ping $IP replies"
else warn "ping $IP no reply (host off/asleep, other subnet, or ICMP blocked). Continuing with TCP."; fi

# ---------------------------------------------------------------- 3. TCP
hdr 3 "TCP connect to $IP:$PORT (the 3-way handshake)"
out=$(nc -vz -G 3 "$IP" "$PORT" 2>&1)
if echo "$out" | grep -q succeeded; then ok "port $PORT open"
elif echo "$out" | grep -qi refused; then bad "connection REFUSED: host is up, nothing listening on $PORT (RST)"
  stop "TCP / transport" "on the edge: sudo brew services list | grep nginx; sudo nginx -t; sudo lsof -nP -iTCP:$PORT -sTCP:LISTEN"
else bad "connection TIMED OUT: no SYN-ACK (host down, firewall dropping, or wrong IP)"
  stop "TCP / network" "is $IP really the edge? Is the edge Mac awake? Any pf rule on it? (sudo pfctl -sr)"
fi

# ---------------------------------------------------------------- 4. TLS
hdr 4 "TLS handshake + certificate validation (no -k)"
CERT=$(echo | openssl s_client -connect "$IP:$PORT" -servername "$NAME" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -text 2>/dev/null)
if [ -n "$CERT" ]; then
  echo "$CERT" | grep -E '^(subject|issuer|notAfter)=' | sed 's/^/         /'
  echo "$CERT" | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ */         SAN: /'
fi
curl -sS -o /dev/null --max-time 5 "https://$NAME$PATH_" 2>/tmp/diag_tls.txt; rc=$?
case $rc in
  0|22) ok "TLS handshake done, certificate trusted for $NAME" ;;
  35)   bad "handshake failed (curl 35): protocol/cipher mismatch or not TLS on this port"; cat /tmp/diag_tls.txt
        stop "TLS" "on the edge check ssl_protocols / ssl_certificate lines; sudo nginx -t" ;;
  51|60) bad "certificate NOT trusted (curl $rc)"; cat /tmp/diag_tls.txt
        stop "TLS (certificate)" "name not in SAN? expired? Team1 CA missing from this Mac's System keychain? (security find-certificate -c 'Team1 Local Root CA' /Library/Keychains/System.keychain)" ;;
  28)   bad "timed out during TLS/HTTP (curl 28)"; stop "TLS/HTTP" "edge accepted TCP but did not answer; check nginx error.log" ;;
  *)    bad "curl exit $rc"; cat /tmp/diag_tls.txt; stop "TLS" "see the curl error above" ;;
esac

# ---------------------------------------------------------------- 5. HTTP
hdr 5 "HTTP (application) through the edge"
H=$(curl -sS -D - -o /tmp/diag_body.txt --max-time 8 -w 'time_total=%{time_total}s' "https://$NAME$PATH_" 2>&1)
code=$(echo "$H" | awk 'NR==1{print $2}')
get() { echo "$H" | awk -F': ' -v k="$1" 'tolower($1)==k{gsub("\r","",$2);print $2}'; }
echo "         status=$code  x-backend=$(get x-backend)  x-edge=$(get x-edge)  x-upstream=$(get x-upstream)  x-upstream-status=$(get x-upstream-status)  $(echo "$H" | grep -o 'time_total=.*')"
echo "         body: $(head -c 200 /tmp/diag_body.txt)"
case "$code" in
  200) ok "application answered" ;;
  502) bad "502 Bad Gateway: edge OK, it could not get a valid answer from ANY backend (refused/reset)"
       stop "Edge -> backend (application side)" "on the edge: tail /opt/homebrew/var/log/nginx/error.log; curl from the edge to each backend; backends running? bound to 0.0.0.0? pf rule allows the edge's IP?" ;;
  504) bad "504 Gateway Timeout: backends did not accept/answer in time (asleep, dropped by firewall, wrong IP)"
       stop "Edge -> backend (network/firewall)" "on the edge: nc -vz -G 3 <backend-ip> <port>; check pf rules on the backend (sudo pfctl -a com.apple/team1 -sr)" ;;
  404) bad "404: request reached a server that has no such path (wrong upstream? wrong server block?)"
       stop "Application / routing" "check proxy_pass and the upstream ports in team1.conf" ;;
  *)   bad "HTTP $code"; stop "Application" "check the edge error.log and the backend terminal" ;;
esac
[ -n "$(get x-upstream | grep ',')" ] && warn "this request needed a RETRY on another backend (failover happened)"

# ---------------------------------------------------------------- 6. LB
hdr 6 "Load balancing (6 requests)"
seq_=""; for _ in 1 2 3 4 5 6; do
  b=$(curl -s -D - -o /dev/null --max-time 8 "https://$NAME$PATH_" | awk -F': ' 'tolower($1)=="x-backend"{gsub("\r","",$2);print $2}')
  seq_="$seq_ ${b:--}"; done
echo "         backends:$seq_"
if echo "$seq_" | grep -q A && echo "$seq_" | grep -q B; then ok "both backends in rotation"
else warn "only one backend is serving: the other is down or marked failed (fail_timeout 10 s)"; fi

echo; echo "${G}${B}All layers OK${N}"
