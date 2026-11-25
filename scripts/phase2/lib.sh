#!/bin/bash
# Shared helpers for scripts/phase2/*.sh. Source it, don't run it.
# All scripts run on Mac 4 (the edge, 10.7.30.71); client-side commands run on $CLIENT (default mac1) over ssh,
# and the output (with a header and timestamps) is tee'd into evidence/phase2/<EXT>/.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVID="$REPO/evidence/phase2"

NAME="${NAME:-app.team1.test}"
EDGE_IP="10.7.30.71"        # Mac 4, Kunal: primary edge + Backend B :3002
STANDBY_IP="10.7.3.175"     # Mac 3, Himanshu: backup DNS + Backend A :3001 + standby edge
DNS1="10.7.17.233"          # Mac 1, Vaibhav: primary DNS + main test client
DNS2="10.7.3.175"           # Mac 3: backup DNS
A_HP="10.7.3.175:3001"
B_HP="10.7.30.71:3002"
CLIENT="${CLIENT:-mac1}"    # ssh alias of the test client
CA="$REPO/certs/rootCA.pem" # public CA cert ("Team1 Local Root CA 2026-11")

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=6)

# Evidence header: title, date/time, which Mac ran it, the exact invocation.
header() {  # header "<title>" "<extra line>"...
  echo "# $1"
  echo "# Date:      $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# Run on:    $(scutil --get LocalHostName) $(ipconfig getifaddr en0)  (script: ${0#"$REPO"/} ${SCRIPT_ARGS:-})"
  echo "# Client:    $CLIENT = $("${SSH[@]}" "$CLIENT" 'echo "$(scutil --get LocalHostName) $(ipconfig getifaddr en0)"' 2>/dev/null)"
  shift; for l in "$@"; do echo "# $l"; done
  echo "# Every command is printed before its output: '\$ ' = this Mac, '[$CLIENT]\$ ' = the client."
  echo
}

# Prefix every line with the time (date +%T)
ts() { while IFS= read -r l; do printf '%s  %s\n' "$(date +%T)" "$l"; done; }

# Time with milliseconds (macOS date has no %N): now_ms -> 15:09:31.482 ; epoch -> 1795599571.482 ; hms <epoch> -> 15:09:31.482
now_ms() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t-int($t))*1000'; }
epoch()  { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
hms()    { perl -MPOSIX=strftime -e '$t=shift; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t-int($t))*1000' "$1"; }

# Run a command on this Mac, printing it first
run() { echo "\$ $*"; bash -c "$*" 2>&1; echo; }

# Prelude sent ahead of every client command (client runs it with bash, whatever its login shell is).
#   tcurl = curl WITHOUT -k. Only while the client does not trust our CA yet (curl exit 60) it adds
#           --cacert <our rootCA.pem> (full chain + name verification still happens). Nothing is written on the client.
#   hv    = value of one response header from a `curl -D -` dump
client_prelude() {
  cat <<EOF
NAME='$NAME'; EDGE_IP='$EDGE_IP'; STANDBY_IP='$STANDBY_IP'
CA_PEM='$(cat "$CA")'
curl -s -o /dev/null --max-time 4 --resolve "\$NAME:443:\$EDGE_IP" "https://\$NAME/" ; [ \$? -eq 60 ] && NEED_CA=1
[ "\${NEED_CA:-}" = 1 ] && echo "  (note: CA not yet trusted in this client's keychain -> curl gets --cacert rootCA.pem; still verified, NOT -k)"
tcurl() { if [ "\${NEED_CA:-}" = 1 ]; then curl --cacert <(printf '%s\n' "\$CA_PEM") "\$@"; else curl "\$@"; fi; }
hv() { awk -F': ' -v k="\$1" 'tolower(\$1)==k{gsub("\r","",\$2);print \$2}'; }
tsm() { perl -MTime::HiRes=time -MPOSIX=strftime -e '\$t=time; printf "%s.%03d", strftime("%H:%M:%S", localtime \$t), (\$t-int(\$t))*1000'; }
EOF
}

# Run a command (or a multi-line bash snippet) on the client, printing it first ("tcurl" shown as "curl")
crun() {
  echo "[$CLIENT]\$ ${*//tcurl/curl}"
  { client_prelude; printf '%s\n' "$*"; } | "${SSH[@]}" "$CLIENT" bash -s 2>&1
  echo
}

evidence_path() { mkdir -p "$EVID/$1"; echo "$EVID/$1/$2"; }

# Run a bash snippet on "local" (this Mac) or on an ssh host (mac1 / mac3), whatever its login shell is
# (local: bash -c, NOT bash -s <<<: with a seekable here-string, a background job started by the snippet shares the
#  read offset and bash loses its place in the script -> "unexpected EOF". Over ssh, stdin is a pipe, so -s is fine.)
on() { local t="$1"; shift; if [ "$t" = local ]; then bash -c "$*"; else "${SSH[@]}" "$t" bash -s <<<"$*"; fi; }

# Stop / start a backend:  backend stop|start A|B   (A = mac3 :3001, B = this Mac :3002)
# stop = SIGINT (Ctrl+C) to whatever listens on the port; start = nohup node server.js, log + pid in ~/team1-logs/
backend() {
  local act="$1" b="$2" host port node
  if [ "$b" = A ]; then host=mac3; port=3001; node=/usr/local/bin/node; else host=local; port=3002; node=/opt/homebrew/bin/node; fi
  if [ "$act" = stop ]; then on "$host" "pid=\$(lsof -t -nP -iTCP:$port -sTCP:LISTEN)
    if [ -n \"\$pid\" ]; then echo \"kill -INT \$pid   (\$(ps -o command= -p \$pid), = Ctrl+C)\"; kill -INT \$pid
      for i in \$(seq 1 30); do lsof -t -nP -iTCP:$port -sTCP:LISTEN >/dev/null || break; sleep 0.1; done; fi
    lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null && echo 'still listening!' || echo 'Backend $b stopped: nothing listens on :$port'"
  else on "$host" "mkdir -p ~/team1-logs; cd ~/cn-backend || exit 1
    if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null; then echo 'Backend $b already running'; exit 0; fi
    echo 'BACKEND=$b PORT=$port nohup $node server.js >> ~/team1-logs/backend$b.log 2>&1 &'
    BACKEND=$b PORT=$port nohup $node server.js >> ~/team1-logs/backend$b.log 2>&1 < /dev/null &
    echo \$! > ~/team1-logs/backend$b.pid
    for i in \$(seq 1 50); do lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null && break; sleep 0.1; done
    echo \"Backend $b listening again: \$(lsof -nP -iTCP:$port -sTCP:LISTEN | awk 'NR==2{print \$1, \"pid\", \$2, \$9}')\""
  fi
}

# Header value from a curl -D - dump (this Mac)
hval() { awk -F': ' -v k="$(echo "$1" | tr 'A-Z' 'a-z')" 'tolower($1)==k{gsub("\r","",$2);print $2}'; }
