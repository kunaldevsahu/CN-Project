#!/bin/bash
# Stage 1 (edge moved to Mac 4): prove the new edge works, before and after the DNS change.
# Run on Mac 4. Client-side checks run on mac1 over ssh.
#   bash scripts/phase2/edge-move-check.sh pre    # before DNS: curl --resolve app.team1.test:443:10.7.30.71
#   bash scripts/phase2/edge-move-check.sh post   # after DNS:  dig both DNS servers + curl by name
# Evidence: evidence/phase2/edge-move/02-pre-dns-check.txt / 03-post-dns-check.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MODE="${1:?usage: edge-move-check.sh pre|post}"; SCRIPT_ARGS="$*"

# Client snippet: 10 requests, one timestamped line each. $1 = extra curl args (e.g. --resolve ...)
loop10() {
  cat <<EOF
for i in \$(seq 1 10); do
  h=\$(tcurl -s -D - -o /dev/null ${1:-} https://\$NAME/api/status)
  printf '%s  #%-2s http=%s  x-edge=%s  x-backend=%s  x-upstream=%s\n' "\$(date +%T)" \$i \\
    "\$(echo "\$h" | awk 'NR==1{print \$2}')" "\$(echo "\$h" | hv x-edge)" "\$(echo "\$h" | hv x-backend)" "\$(echo "\$h" | hv x-upstream)"
  sleep 0.3
done
EOF
}

pre() {
  header "Edge move 02 · New edge on Mac 4 works BEFORE any DNS change (curl --resolve)" \
         "Edge: $EDGE_IP (nginx), upstream A=$A_HP B=127.0.0.1:3002"
  echo "## 1. nginx on this Mac: config test, listeners, deployed config"
  run "/opt/homebrew/bin/nginx -t"
  run "lsof -nP -a -p \$(pgrep -d, -f 'nginx: master') -iTCP -sTCP:LISTEN"
  run "cmp $REPO/nginx/phase2/team1.conf /opt/homebrew/etc/nginx/servers/team1.conf && echo 'deployed servers/team1.conf == repo nginx/phase2/team1.conf'"
  run "grep -nE '^[[:space:]]*(zone|server [0-9]|proxy_next_upstream |proxy_connect_timeout|add_header X-Edge|ssl_certificate )' /opt/homebrew/etc/nginx/servers/team1.conf"
  echo "## 2. Certificate this edge serves (chain checked against our CA)"
  run "echo | openssl s_client -connect $EDGE_IP:443 -servername $NAME -CAfile $CA -verify_return_error 2>&1 | grep -E '^depth=|Verify return code|^ *Protocol *:' | sort -u"
  echo "## 3. From the client, DNS untouched: force $NAME -> $EDGE_IP with --resolve"
  crun "tcurl -sv --resolve $NAME:443:$EDGE_IP https://$NAME/api/status -o /dev/null 2>&1 | grep -iE '^\\* (Connected|SSL|Server certificate|ALPN: server)|^\\*  +(subject|issuer|start date|expire date)|^< (HTTP|x-)'"
  echo "## 4. 10 requests through the new edge"
  crun "$(loop10 "--resolve $NAME:443:$EDGE_IP")"
}

post() {
  header "Edge move 03 · After the DNS change: both servers answer $EDGE_IP, client reaches the new edge by name"
  echo "## 1. Records on each DNS server, asked directly from the client"
  for s in "$DNS1" "$DNS2"; do for n in app.team1.test api.team1.test; do
    crun "dig @$s $n +noall +answer +comments | grep -E 'status:|IN[[:space:]]+A'"
  done; done
  echo "## 2. The client's own resolver (servers it uses, then a plain dig)"
  crun "networksetup -getdnsservers Wi-Fi"
  crun "dig $NAME +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
  crun "dscacheutil -q host -a name $NAME"
  echo "## 3. HTTPS by name, system trust only (no -k, no --cacert)"
  crun "curl -sv https://$NAME/api/status -o /dev/null 2>&1 | grep -iE '^\\* (Connected|SSL|Server certificate)|^\\*  +(subject|issuer|start date|expire date)|^< (HTTP|x-)'"
  echo "## 4. 10 requests by name"
  crun "$(loop10)"
}

OUT_FILE=$([ "$MODE" = pre ] && echo 02-pre-dns-check.txt || echo 03-post-dns-check.txt)
OUT="$(evidence_path edge-move "$OUT_FILE")"
case "$MODE" in pre) pre ;; post) post ;; *) echo "usage: $0 pre|post"; exit 1 ;; esac 2>&1 | tee "$OUT"
echo "(saved: ${OUT#"$REPO"/})"
