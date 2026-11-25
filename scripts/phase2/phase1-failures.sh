#!/bin/bash
# Phase 1 failure demos, repeated on the Phase 2 system (edge on Mac 4). Run on Mac 4; the client is mac1.
# Every demo: inject the fault -> look at it from the client layer by layer -> RESTORE -> prove it is restored.
#   bash scripts/phase2/phase1-failures.sh            # all five, in order
#   bash scripts/phase2/phase1-failures.sh 4          # only demo 4 (1..5)
#  1 wrong DNS server on the client   2 wrong IP in the DNS record   3 wrong destination port
#  4 one backend down (B)             5 both backends down (502 from nginx, TLS still fine)
# Evidence: evidence/phase2/phase1-failures/0N-<name>.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
ERRLOG=/opt/homebrew/var/log/nginx/error.log
flush1() { on mac1 'sudo -n /usr/bin/dscacheutil -flushcache && sudo -n /usr/bin/killall -HUP mDNSResponder && echo "(mac1 cache flushed)"'; }
step() { echo; echo "## $*"; }
http6() { crun 'for i in 1 2 3 4 5 6; do h=$(curl -sS -D - -o /dev/null --max-time 8 https://$NAME/api/status 2>&1); printf "%s  #%s http=%s  x-backend=%s  x-upstream=%s  x-upstream-status=%s\n" "$(tsm)" $i "$(echo "$h" | awk "NR==1{print \$2}")" "$(echo "$h" | hv x-backend)" "$(echo "$h" | hv x-upstream)" "$(echo "$h" | hv x-upstream-status)"; sleep 0.4; done'; }
ok_check() { step "RESTORED? (from mac1)"; crun "dig +nocmd $NAME +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"; http6; }
errlog_since() { echo; echo "## nginx error.log on the edge (Mac 4), new lines"; tail -n +$(($1+1)) "$ERRLOG" | sed -E 's/, server: .*upstream: /, upstream: /' | cut -c1-190; }

demo1() {  # wrong DNS server
  step "INJECT (mac1): DNS server = 8.8.8.8 only"
  before=$(on mac1 'networksetup -getdnsservers Wi-Fi | tr "\n" " "'); echo "before: $before"
  crun "sudo -n /usr/sbin/networksetup -setdnsservers Wi-Fi 8.8.8.8 && networksetup -getdnsservers Wi-Fi"; flush1
  step "1 DNS: plain dig (which server, which status?)"
  crun "dig $NAME | grep -E 'status:|IN[[:space:]]+SOA|SERVER:|Query time'"
  step "app: curl by name"; crun "curl -sS -o /dev/null https://$NAME/api/status; echo \"curl exit=\$?\""
  step "2 IP: the edge itself is fine"; crun "ping -c 2 -q $EDGE_IP | tail -1"
  step "same request with the name pinned to the right IP (bypasses DNS): works"
  crun "curl -sS -o /dev/null -w 'http=%{http_code} ssl_verify=%{ssl_verify_result}\n' --resolve $NAME:443:$EDGE_IP https://$NAME/api/status"
  step "RESTORE (mac1): both team DNS servers"
  crun "sudo -n /usr/sbin/networksetup -setdnsservers Wi-Fi $DNS1 $DNS2 && networksetup -getdnsservers Wi-Fi | tr '\n' ' '; echo"; flush1
  ok_check
  echo; echo "Layer: DNS (client configuration). The name could not be turned into an address, so nothing after DNS even started."
}

demo2() {  # wrong IP in the record
  step "precondition: mac3 has no web server on 443 (standby edge stopped)"; echo "\$ nc -vz -G 2 $STANDBY_IP 443"; nc -vz -G 2 "$STANDBY_IP" 443 2>&1 | tail -1
  step "INJECT (mac1 + mac3, both DNS servers): app/api -> $STANDBY_IP (wrong Mac)"
  bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$STANDBY_IP" 2>&1 | grep -E '^[0-9:]+  (app\.|@)'; flush1
  step "1 DNS: resolves, but to the wrong address"; crun "dig +nocmd $NAME +short; dscacheutil -q host -a name $NAME | grep ip_address"
  step "2 IP: that host is up"; crun "ping -c 2 -q $STANDBY_IP | tail -1"
  step "3 TCP: nothing listens on 443 there -> RST, refused at once"; crun "nc -vz -G 3 $STANDBY_IP 443 2>&1 | tail -1"
  step "app: curl"; crun "curl -sS -o /dev/null -w 'http=%{http_code}\n' https://$NAME/api/status; echo \"curl exit=\$?\""
  step "RESTORE: record back to $EDGE_IP on both DNS servers"
  bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$EDGE_IP" 2>&1 | grep -E '^[0-9:]+  (app\.|@)'; flush1
  ok_check
  echo; echo "Layer: DNS data (record). dig answers, but with the wrong IP; TCP to that IP is refused. dig is right only if it matches the plan."
}

demo3() {  # wrong destination port
  step "INJECT: nothing on the edge, the CLIENT uses the wrong port (8443)"
  step "3 TCP: same host, two ports"; crun "nc -vz -G 3 $EDGE_IP 443 2>&1 | tail -1; nc -vz -G 3 $EDGE_IP 8443 2>&1 | tail -1"
  step "app"; crun "curl -sS -o /dev/null -w 'http=%{http_code}\n' https://$NAME:8443/api/status; echo \"curl exit=\$?\""
  crun "curl -sS -o /dev/null -w 'http=%{http_code}\n' https://$NAME/api/status; echo \"curl exit=\$?   (443)\""
  step "RESTORE: nothing to undo (use 443)"; ok_check
  echo; echo "Layer: transport (port). The IP picks the machine, the port picks the service; nothing listens on 8443 -> RST -> refused."
}

demo4() {  # one backend down (B)
  E0=$(wc -l < "$ERRLOG")
  step "INJECT (Mac 4): stop Backend B (:3002)"; backend stop B
  step "app from mac1: every request still 200, served by A; a request that tried B was retried on A"; http6
  errlog_since "$E0"
  step "RESTORE (Mac 4): start Backend B again (nohup)"; backend start B
  sleep 6; echo "(waited 6 s: fail_timeout=5s, then nginx tries B again)"
  ok_check
  echo; echo "Layer: edge -> backend. One backend down is invisible to the client (nginx retries on the other one, passive health check)."
}

demo5() {  # both backends down
  E0=$(wc -l < "$ERRLOG")
  step "INJECT: stop Backend A (mac3) and Backend B (Mac 4)"; backend stop A; backend stop B
  step "1 DNS + 3 TCP + 4 TLS: all still fine"
  crun "dig +nocmd $NAME +short; nc -vz -G 3 $EDGE_IP 443 2>&1 | tail -1"
  crun "curl -sv https://$NAME/api/status -o /dev/null 2>&1 | grep -iE '^\\* (SSL connection|using HTTP)|SSL certificate verify|^< (HTTP|server|x-)'"
  step "5 HTTP: the edge answers 502 itself (no X-Backend)"; http6
  errlog_since "$E0"
  step "RESTORE: start both backends"; backend start A; backend start B
  sleep 6; echo "(waited 6 s for fail_timeout)"
  ok_check
  echo; echo "Layer: application behind the edge. DNS, TCP, TLS and HTTP/2 all work; the edge reports 502 because no backend answers."
  echo "Compare demo 1 (DNS failure): there the name did not resolve at all. That is the difference between a DNS and an application failure."
}

declare -a NAMES=("" "01-wrong-dns-server" "02-wrong-ip-in-record" "03-wrong-port" "04-one-backend-down" "05-both-backends-down")
declare -a TITLES=("" "Wrong DNS server on the client (mac1 -> 8.8.8.8)" "DNS record points to the wrong IP (10.7.3.175, no web server)" \
  "Wrong destination port (8443)" "One backend down (Backend B on Mac 4)" "Both backends down (502 from nginx, TLS still fine)")
for n in ${1:-1 2 3 4 5}; do
  OUT="$(evidence_path phase1-failures "${NAMES[$n]}.txt")"
  { header "Phase 1 failure demo $n on the Phase 2 system · ${TITLES[$n]}" "Edge $EDGE_IP (Mac 4), DNS $DNS1 + $DNS2; inject -> observe layer by layer -> restore -> verify"
    "demo$n"; } 2>&1 | tee "$OUT"
  echo "(saved: ${OUT#"$REPO"/})"; echo
done
