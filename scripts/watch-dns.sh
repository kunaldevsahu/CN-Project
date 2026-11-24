#!/bin/bash
# Extensions B and E: run on a CLIENT during a record change / cutover. One line every 2 s.
#   bash watch-dns.sh                      # app.team1.test
#   bash watch-dns.sh app.team1.test | tee ~/P2-B-ttl-watch.txt
#
# Columns:
#   server   = what the DNS server says NOW  (dig asks the server directly, bypassing the client cache)
#   os-cache = what this Mac's resolver (mDNSResponder) answers: this is what curl/browsers use
#   edge     = which nginx actually served the request (X-Edge header)
# During the TTL window, server shows the NEW IP while os-cache and edge still show the OLD one.
NAME="${1:-app.team1.test}"
printf "%-8s  %-15s %-15s %-6s %s\n" time server os-cache http edge
while true; do
  srv=$(dig "$NAME" A +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  sys=$(dscacheutil -q host -a name "$NAME" 2>/dev/null | awk '/ip_address/{print $2; exit}')
  hdrs=$(curl -s -D - -o /dev/null --max-time 3 "https://$NAME/api/status" 2>/dev/null)
  code=$(echo "$hdrs" | awk 'NR==1{print $2}')
  edge=$(echo "$hdrs" | awk -F': ' 'tolower($1)=="x-edge"{gsub("\r","",$2);print $2}')
  flag=""; [ -n "$srv" ] && [ -n "$sys" ] && [ "$srv" != "$sys" ] && flag="  <- client cache still old"
  printf "%-8s  %-15s %-15s %-6s %s%s\n" "$(date +%H:%M:%S)" "${srv:--}" "${sys:--}" "${code:--}" "${edge:--}" "$flag"
  sleep 2
done
