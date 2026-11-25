#!/bin/bash
# One-screen health check of the whole Phase 2 setup, in its demo-day baseline state. Read-only. Run on Mac 4.
#   bash scripts/phase2/health.sh
# Baseline: records -> 10.7.30.71 on both DNS servers, nginx on Mac 4, Backend A (mac3) + B (Mac 4) up, pf anchor empty,
# standby nginx on mac3 stopped, clients use both team DNS servers, CA trusted, passwordless sudo -n works.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
FP="89CC62AEC2F203F222E04A15879B73AFBC4F5D3771E784DEA6F9F930F8033B6A"   # Team1 Local Root CA 2026-11
FAILS=0
chk() { if [ "$1" = 1 ]; then printf '  OK  %s\n' "$2"; else printf '  !!  %s\n' "$2"; FAILS=$((FAILS+1)); fi; }
facts='echo "ip=$(ipconfig getifaddr en0)"
echo "sudo=$(sudo -n -l 2>/dev/null | grep -c "NOPASSWD: /opt/homebrew/sbin/dnsmasq")"
echo "ca=$(security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -c '"$FP"')"
echo "dns=$(networksetup -getdnsservers Wi-Fi 2>/dev/null | tr "\n" " " | sed "s/ $//")"
echo "dnsmasq=$(pgrep -x dnsmasq >/dev/null && echo up || echo down)"
echo "rec=$(dig +nocmd @127.0.0.1 '"$NAME"' +short +time=1 +tries=1 2>/dev/null | head -1)"
echo "a3001=$(lsof -nP -iTCP:3001 -sTCP:LISTEN 2>/dev/null | grep -c LISTEN)"
echo "b3002=$(lsof -nP -iTCP:3002 -sTCP:LISTEN 2>/dev/null | grep -c LISTEN)"
echo "nginx=$(pgrep -f "nginx: master" >/dev/null && echo up || echo down)"
echo "pf=$(sudo -n /sbin/pfctl -si 2>/dev/null | grep -oE "Status: (Enabled|Disabled)" | cut -d" " -f2)"
echo "anchor=$(sudo -n /sbin/pfctl -a com.apple/team1 -sr 2>/dev/null | grep -c .)"'
get() { echo "$2" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }

F1=$(on mac1 "$facts" 2>/dev/null); F3=$(on mac3 "$facts" 2>/dev/null); F4=$(on local "$facts" 2>/dev/null)
echo "Team 1 · Phase 2 health · $(date '+%Y-%m-%d %H:%M:%S') · from $(scutil --get LocalHostName)"
echo "== Macs"
for m in "mac1:$DNS1:$F1" "mac3:$STANDBY_IP:$F3" "mac4:$EDGE_IP:$F4"; do
  n=${m%%:*}; r=${m#*:}; want=${r%%:*}; f=${r#*:}
  chk "$([ "$(get ip "$f")" = "$want" ] && [ "$(get sudo "$f")" = 1 ] && [ "$(get ca "$f")" -ge 1 ] 2>/dev/null && echo 1)" \
      "$n  ip $(get ip "$f") (want $want) · sudo -n $([ "$(get sudo "$f")" = 1 ] && echo ok || echo NO) · CA 2026-11 $([ "$(get ca "$f")" -ge 1 ] 2>/dev/null && echo trusted || echo MISSING)"
done
echo "== DNS"
for m in "mac1:$F1" "mac3:$F3"; do n=${m%%:*}; f=${m#*:}
  chk "$([ "$(get dnsmasq "$f")" = up ] && [ "$(get rec "$f")" = "$EDGE_IP" ] && echo 1)" "$n dnsmasq $(get dnsmasq "$f"), $NAME -> $(get rec "$f") (want $EDGE_IP)"
  chk "$([ "$(get dns "$f")" = "$DNS1 $DNS2" ] && echo 1)" "$n client DNS servers: $(get dns "$f")"
done
echo "== Edge + backends"
chk "$([ "$(get nginx "$F4")" = up ] && nc -z -G 2 "$EDGE_IP" 443 2>/dev/null && echo 1)" "Mac 4 nginx $(get nginx "$F4"), :443 $(nc -z -G 2 "$EDGE_IP" 443 2>/dev/null && echo open || echo CLOSED)"
chk "$(cmp -s /opt/homebrew/etc/nginx/servers/team1.conf "$REPO/nginx/phase2/team1.conf" && /opt/homebrew/bin/nginx -t >/dev/null 2>&1 && echo 1)" "Mac 4 nginx config == repo and nginx -t ok"
chk "$([ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$A_HP/api/status")" = 200 ] && echo 1)" "Backend A ($A_HP) from the edge: $(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$A_HP/api/status")"
chk "$([ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/api/status)" = 200 ] && echo 1)" "Backend B (127.0.0.1:3002) from the edge: $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/api/status)"
chk "$([ "$(get nginx "$F3")" = down ] && echo 1)" "standby nginx on mac3: $(get nginx "$F3") (want down outside Ext E)"
echo "== pf (Ext C rolled back)"
chk "$([ "$(get anchor "$F3")" = 0 ] && [ "$(get anchor "$F4")" = 0 ] && echo 1)" "anchor com.apple/team1 rules: mac3 $(get anchor "$F3"), Mac 4 $(get anchor "$F4") (want 0); pf: mac3 $(get pf "$F3"), Mac 4 $(get pf "$F4") (as found: Disabled / Enabled)"
echo "== End to end from mac1 (scripts/diagnose.sh)"
D=$("${SSH[@]}" mac1 bash -s < "$REPO/scripts/diagnose.sh" 2>&1); rc=$?
chk "$([ $rc = 0 ] && echo 1)" "$(echo "$D" | grep -E '^SUMMARY' | sed 's/SUMMARY  //')   backends:$(echo "$D" | awk '/backends:/{sub(/.*backends:/,""); print; exit}')"
echo
[ "$FAILS" = 0 ] && echo "ALL OK: ready for the demo" || echo "$FAILS check(s) need attention (see !! lines; quick fixes: docs/PHASE2-DEMO.md)"
exit "$FAILS"
