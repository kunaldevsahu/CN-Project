#!/bin/bash
# Extension F: checks run ON AN EDGE (Mac 2 primary, or Mac 3 standby). Read-only.
#   bash diagnose-edge.sh
# Use it after diagnose.sh on a client points at the edge or the edge->backend hop.
BACKENDS="10.7.18.211:3001 10.7.16.48:3002"
CONF="$(brew --prefix)/etc/nginx/servers/team1.conf"
LOGDIR="$(brew --prefix)/var/log/nginx"
B=$'\e[1m'; N=$'\e[0m'
hdr() { echo; echo "${B}== $* ==${N}"; }

hdr "This edge: $(hostname -s)  $(ipconfig getifaddr en0)"

hdr "nginx config test"
sudo nginx -t 2>&1

hdr "Is nginx running and listening on 80/443?"
sudo brew services list | grep -E 'nginx|Name'
sudo lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR==1 || /nginx/'

hdr "Files in servers/ (every one of them is loaded; old copies here cause duplicate-upstream errors)"
ls -l "$(brew --prefix)/etc/nginx/servers/"

hdr "Upstream + TLS lines currently configured"
grep -nE 'server [0-9]|listen|ssl_certificate|ssl_protocols|proxy_pass|server_name' "$CONF"

hdr "Certificate nginx is serving"
CRT=$(awk '/ssl_certificate /{gsub(";","",$2);print $2}' "$CONF")
openssl x509 -in "$CRT" -noout -subject -issuer -dates 2>&1
openssl x509 -in "$CRT" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1

hdr "Edge -> each backend directly (this is the hop the client cannot see)"
for hp in $BACKENDS; do
  h=${hp%:*}; p=${hp#*:}
  t=$(nc -vz -G 3 "$h" "$p" 2>&1 | tail -1)
  r=$(curl -s -m 4 -o /dev/null -w '%{http_code} in %{time_total}s' "http://$hp/api/status")
  echo "  $hp  tcp: $t"
  echo "  $hp  http: $r"
done
echo "  (refused = host up, backend process not running / bound to 127.0.0.1;"
echo "   timed out = host asleep, wrong IP, or a pf rule dropping this edge's IP)"

hdr "Last 8 lines of the nginx error log"
tail -n 8 "$LOGDIR/error.log" 2>/dev/null

hdr "Last 8 requests (upstream tried / status per attempt)"
tail -n 8 "$LOGDIR/team1-access.log" 2>/dev/null
