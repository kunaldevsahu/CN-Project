#!/bin/bash
# Extension E: start / stop / check the STANDBY edge (nginx on mac3, 10.7.3.175). Run on Mac 4.
#   bash scripts/phase2/E-standby.sh up      # nginx -t + start on mac3, then check it from mac1 WITHOUT touching DNS
#   bash scripts/phase2/E-standby.sh check   # only the check from mac1
#   bash scripts/phase2/E-standby.sh down    # stop nginx on mac3 (do this only when no DNS record points at it)
# nginx on mac3 runs as ROOT via `sudo -n /opt/homebrew/bin/nginx` (workers as nobody). A user-level nginx started
# over ssh is blocked by macOS Local Network privacy: connect() to other LAN hosts fails at once with
# "(65: No route to host)" and no SYN is sent (see evidence/phase2/F/practice-log.md). Config: nginx/phase2/team1-standby.conf
# Evidence: evidence/phase2/E/02-standby-up.txt · E/13-standby-down.txt (or the file given as 2nd argument)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
ACT="${1:?usage: E-standby.sh up|down|check [evidence file name]}"

check() {
  echo "## Standby checked from $CLIENT with --resolve (DNS untouched), system trust only (no -k)"
  crun "curl -sv --resolve $NAME:443:$STANDBY_IP https://$NAME/api/status -o /dev/null 2>&1 | grep -iE '^\\* (Connected|SSL connection)|^\\*  +(subject|issuer|SSL certificate verify)|^< (HTTP|x-edge|x-backend)'"
  echo "## Both edges present different certificates (serial) from the same CA"
  crun "for ip in $EDGE_IP $STANDBY_IP; do echo \"\$ip: \$(echo | openssl s_client -connect \$ip:443 -servername $NAME 2>/dev/null | openssl x509 -noout -serial -issuer | tr '\\n' ' ')\"; done"
  echo "## 6 requests to the standby: it load-balances over the SAME two backends"
  crun 'for i in 1 2 3 4 5 6; do h=$(curl -s -D - -o /dev/null -w "IP=%{remote_ip}" --resolve $NAME:443:$STANDBY_IP https://$NAME/api/status); printf "%s  #%s http=%s remote=%s x-edge=%s x-backend=%s x-upstream=%s\n" "$(tsm)" $i "$(echo "$h" | awk "NR==1{print \$2}")" "$(echo "$h" | sed -n "s/.*IP=//p")" "$(echo "$h" | hv x-edge)" "$(echo "$h" | hv x-backend)" "$(echo "$h" | hv x-upstream)"; sleep 0.3; done'
}

up() {
  echo "## Start nginx on mac3"
  on mac3 'echo "[mac3]\$ sudo -n /opt/homebrew/bin/nginx -t"; sudo -n /opt/homebrew/bin/nginx -t 2>&1 || exit 1
    if pgrep -q -f "nginx: master"; then echo "[mac3]\$ sudo -n /opt/homebrew/bin/nginx -s reload   (already running)"; sudo -n /opt/homebrew/bin/nginx -s reload
    else echo "[mac3]\$ sudo -n /opt/homebrew/bin/nginx </dev/null >/dev/null 2>&1    # root: see header; detach from ssh"; sudo -n /opt/homebrew/bin/nginx </dev/null >/dev/null 2>&1; fi
    sleep 1; ps -o user=,pid=,command= -p $(pgrep -d, -f "nginx: "); sudo -n /usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN | awk "NR<=2"'
  echo; check
}

down() {
  echo "## Stop nginx on mac3"
  on mac3 'if pgrep -q -f "nginx: master"; then echo "[mac3]\$ sudo -n /opt/homebrew/bin/nginx -s quit"; sudo -n /opt/homebrew/bin/nginx -s quit; sleep 1.5; fi
    pgrep -lf "nginx: master" || echo "no nginx master process on mac3"'
  echo "\$ nc -vz -G 2 $STANDBY_IP 443   (from this Mac)"; nc -vz -G 2 "$STANDBY_IP" 443 2>&1 | tail -1
  echo "## DNS must not point at it (both servers):"
  for s in "$DNS1" "$DNS2"; do echo "  @$s: $(dig +nocmd @"$s" "$NAME" +short +time=2 +tries=1)"; done
}

case "$ACT" in
  up)    F="${2:-02-standby-up.txt}";   T="Ext E · standby edge UP on mac3 and checked from $CLIENT before any DNS change" ;;
  down)  F="${2:-13-standby-down.txt}"; T="Ext E · standby edge DOWN on mac3" ;;
  check) F="${2:-02-standby-check.txt}"; T="Ext E · standby edge check from $CLIENT" ;;
  *) echo "usage: $0 up|down|check"; exit 1 ;;
esac
OUT="$(evidence_path E "$F")"
{ header "$T"; "$ACT"; } 2>&1 | tee "$OUT"
echo "(saved: ${OUT#"$REPO"/})"
