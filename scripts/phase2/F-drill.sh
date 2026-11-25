#!/bin/bash
# Extension F practice: one injected fault per layer, diagnosed from the client with scripts/diagnose.sh, confirmed with
# the manual commands, restored, and re-checked (diagnose.sh must PASS again). Run on Mac 4.
#   bash scripts/phase2/F-drill.sh healthy      # diagnose.sh on the healthy system
#   bash scripts/phase2/F-drill.sh dns|tcp|tls|http
#   dns  = wrong record on both DNS servers (app/api -> 10.7.3.175)       -> diagnose.sh exit 1
#   tcp  = nginx stopped on the edge (brew services stop nginx)           -> exit 2 (refused)
#   tls  = edge serves a self-signed cert for the wrong name (wrong.test) -> exit 3 (curl 60)
#   http = both backends stopped                                         -> exit 4 (502)
# (In a real drill a teammate injects the fault in secret; here the script injects it so the run is repeatable.)
# Evidence: evidence/phase2/F/00-diagnose-healthy.txt, 01-drill-dns.txt ... 04-drill-http.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
DRILL="${1:?usage: F-drill.sh healthy|dns|tcp|tls|http}"
CONF=/opt/homebrew/etc/nginx/servers/team1.conf; CERTS=/opt/homebrew/etc/nginx/certs; ERRLOG=/opt/homebrew/var/log/nginx/error.log
flush1() { on mac1 'sudo -n /usr/bin/dscacheutil -flushcache && sudo -n /usr/bin/killall -HUP mDNSResponder && echo "(mac1 cache flushed)"'; }
step() { echo; echo "## $*"; }
diag() {  # run diagnose.sh on mac1; prints its output and the exit code
  echo "[mac1]\$ bash scripts/diagnose.sh      (sent over ssh: ssh mac1 bash -s < scripts/diagnose.sh)"
  "${SSH[@]}" mac1 bash -s < "$REPO/scripts/diagnose.sh"; local rc=$?; echo "(diagnose.sh exit code: $rc)"; return $rc
}
T_INJ=0; T_DIAG=0
mark_inject() { T_INJ=$(epoch); echo "$(now_ms)  fault injected"; }
mark_diag() { T_DIAG=$(epoch); echo "$(now_ms)  diagnosed (diagnose.sh run + read): $(awk -v a="$T_INJ" -v b="$T_DIAG" 'BEGIN{printf "%.1f", b-a}') s after the injection"; }
mark_fixed() { local t; t=$(epoch); echo "$(now_ms)  restored and verified: $(awk -v a="$T_INJ" -v b="$t" 'BEGIN{printf "%.1f", b-a}') s after the injection"; }

healthy() { diag; }

dns() {
  step "INJECT (both DNS servers): app/api -> $STANDBY_IP"
  bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$STANDBY_IP" 2>&1 | grep -E '^[0-9:]+  (app\.|@)'; flush1; mark_inject
  step "DIAGNOSE from mac1"; diag; mark_diag
  step "CONFIRM by hand: the record itself, on each DNS server"
  for h in mac1 mac3; do echo "[$h]\$ bash dns/phase2/set-record.sh --show"; "${SSH[@]}" "$h" bash -s -- --show < "$REPO/dns/phase2/set-record.sh"; done
  crun "dig +nocmd $NAME +short; nc -vz -G 3 $STANDBY_IP 443 2>&1 | tail -1"
  step "FIX: correct record on both DNS servers"
  bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$EDGE_IP" 2>&1 | grep -E '^[0-9:]+  (app\.|@)'; flush1
}

tcp() {
  step "INJECT (edge, Mac 4): stop nginx"; echo "\$ brew services stop nginx"
  /opt/homebrew/bin/brew services stop nginx 2>&1 | tail -1; sleep 1; mark_inject
  step "DIAGNOSE from mac1"; diag; mark_diag
  step "CONFIRM by hand"
  crun "nc -vz -G 3 $EDGE_IP 443 2>&1 | tail -1; ping -c 1 -q $EDGE_IP | tail -1"
  run "/opt/homebrew/bin/brew services list | grep -E 'Name|nginx'; lsof -nP -iTCP:443 -sTCP:LISTEN || echo 'nothing listens on :443'"
  step "FIX: start nginx (config test first)"
  run "/opt/homebrew/bin/nginx -t 2>&1 | tail -1 && /opt/homebrew/bin/brew services start nginx 2>&1 | tail -1"
  for i in $(seq 1 30); do nc -z -G 1 127.0.0.1 443 2>/dev/null && break; sleep 0.3; done
}

tls() {
  local BK; BK=~/backups/nginx-servers-team1.conf.$(date +%Y%m%d-%H%M%S)
  step "INJECT (edge, Mac 4): serve a self-signed certificate for the WRONG name"
  run "cp -p $CONF $BK && echo 'backup: $BK'"
  run "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=wrong.test -keyout $CERTS/drill-wrong.key -out $CERTS/drill-wrong.crt 2>/dev/null && chmod 600 $CERTS/drill-wrong.key && echo 'made drill-wrong.crt (CN=wrong.test, self-signed)'"
  run "sed -i '' 's|/certs/team1.crt;|/certs/drill-wrong.crt;|; s|/certs/team1.key;|/certs/drill-wrong.key;|' $CONF && grep -n 'ssl_certificate' $CONF"
  run "/opt/homebrew/bin/nginx -t 2>&1 | tail -1 && /opt/homebrew/bin/nginx -s reload && echo reloaded"
  sleep 1; mark_inject
  step "DIAGNOSE from mac1"; diag; mark_diag
  step "CONFIRM by hand: which certificate does the edge present?"
  crun "echo | openssl s_client -connect $EDGE_IP:443 -servername $NAME 2>/dev/null | openssl x509 -noout -subject -issuer"
  crun "curl -sS -o /dev/null https://$NAME/api/status 2>&1 | head -1"
  step "FIX: restore the config from the backup, test, reload, remove the drill cert"
  run "cp -p $BK $CONF && cmp $CONF $REPO/nginx/phase2/team1.conf && echo 'config restored (== repo copy)'"
  run "/opt/homebrew/bin/nginx -t 2>&1 | tail -1 && /opt/homebrew/bin/nginx -s reload && rm -f $CERTS/drill-wrong.crt $CERTS/drill-wrong.key && echo 'reloaded, drill cert removed'"
  sleep 1
}

http() {
  local E0; E0=$(wc -l < "$ERRLOG")
  step "INJECT: stop both backends"; backend stop A; backend stop B; mark_inject
  step "DIAGNOSE from mac1"; diag; mark_diag
  step "CONFIRM on the edge: diagnose-edge.sh (edge -> each backend) and the error log"
  bash "$REPO/scripts/diagnose-edge.sh" 2>&1 | sed $'s/\e\\[[0-9;]*m//g' | sed -n '/Edge -> each backend/,/timed out = host/p'
  echo; echo "new error.log lines:"; tail -n +$((E0+1)) "$ERRLOG" | sed -E 's/, server: .*upstream: /, upstream: /' | cut -c1-170 | tail -4
  step "FIX: start both backends"; backend start A; backend start B; sleep 6; echo "(waited 6 s: fail_timeout=5s)"
}

case "$DRILL" in
  healthy) F=00-diagnose-healthy.txt; T="diagnose.sh on the healthy system (all layers PASS)" ;;
  dns)  F=01-drill-dns.txt;  T="Drill DNS: wrong record on both DNS servers" ;;
  tcp)  F=02-drill-tcp.txt;  T="Drill TCP: nginx stopped on the edge" ;;
  tls)  F=03-drill-tls.txt;  T="Drill TLS: edge serves a certificate for the wrong name" ;;
  http) F=04-drill-http.txt; T="Drill HTTP: both backends down" ;;
  *) echo "usage: $0 healthy|dns|tcp|tls|http"; exit 1 ;;
esac
OUT="$(evidence_path F "$F")"
{ header "Ext F · $T" "Method: inject -> diagnose.sh on mac1 (first failing layer) -> confirm by hand -> fix -> diagnose.sh again"
  "$DRILL"
  if [ "$DRILL" != healthy ]; then step "VERIFY: diagnose.sh again"; diag; mark_fixed; fi
} 2>&1 | tee "$OUT"
echo "(saved: ${OUT#"$REPO"/})"
