#!/bin/bash
# Extension D: HA failover in nginx. Run on Mac 4 (the edge).
#   A 60 s request loop runs on mac1 through https://app.team1.test (one request every 0.5 s).
#   At ~15 s Backend A (mac3 :3001) is stopped (SIGINT = Ctrl+C), at ~40 s it is started again (nohup).
#   tcpdump on this Mac: en0 = edge <-> Backend A (10.7.3.175:3001), lo0 = edge <-> Backend B (127.0.0.1:3002).
#
#   bash scripts/phase2/D-failover.sh
#   DURATION=60 STOP_AT=15 START_AT=40 GAP=0.5 bash scripts/phase2/D-failover.sh
#
# Expected: every request 200; while A is down only B answers (a request that hits dead A is retried on B:
# x-upstream-status "502, 200"); A is back in the rotation <= ~5 s after restart (fail_timeout=5s).
# All timing analysis uses ONE clock (this Mac): the pcap + nginx's per-request log (t=$msec).
# Evidence: evidence/phase2/D/00-events.txt ... 08-summary.txt + the two pcaps.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
DURATION=${DURATION:-60}; STOP_AT=${STOP_AT:-15}; START_AT=${START_AT:-40}; GAP=${GAP:-0.5}
D="$EVID/D"; mkdir -p "$D"; TMP=$(mktemp -d)
ME=$(whoami)
NODE_A=/usr/local/bin/node        # mac3's node binary (not on PATH in ssh sessions)
ERRLOG=/opt/homebrew/var/log/nginx/error.log
ACCLOG=/opt/homebrew/var/log/nginx/team1-access.log
CONF=/opt/homebrew/etc/nginx/servers/team1.conf
EV="$D/00-events.txt"; LOOPF="$D/03-client-loop.txt"
P1="$D/01-en0-edge-A-3001.pcap"; P2="$D/02-lo0-edge-B-3002.pcap"
A_IP="${A_HP%:*}"

ev() { printf '%s  %s\n' "$(now_ms)" "$*" | tee -a "$EV"; }
sh3() { "${SSH[@]}" mac3 bash -s; }   # run a bash snippet (stdin) on mac3
MS3='perl -MTime::HiRes=time -MPOSIX=strftime -e '"'"'$t=time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t-int($t))*1000'"'"

stop_A() { sh3 <<EOF
pid=\$(lsof -t -nP -iTCP:3001 -sTCP:LISTEN)
[ -z "\$pid" ] && { echo "Backend A was not running"; exit 0; }
echo "[mac3]\\\$ kill -INT \$pid     # \$(ps -o command= -p \$pid), same as Ctrl+C"
kill -INT \$pid
for i in \$(seq 1 30); do lsof -t -nP -iTCP:3001 -sTCP:LISTEN >/dev/null || break; sleep 0.1; done
lsof -nP -iTCP:3001 -sTCP:LISTEN >/dev/null && echo "still listening!" || echo "port 3001 closed at \$($MS3) (mac3 clock)"
EOF
}

start_A() { sh3 <<EOF
mkdir -p ~/team1-logs; cd ~/cn-backend || exit 1
echo "[mac3]\\\$ cd ~/cn-backend && BACKEND=A PORT=3001 nohup $NODE_A server.js >> ~/team1-logs/backendA.log 2>&1 &"
BACKEND=A PORT=3001 nohup $NODE_A server.js >> ~/team1-logs/backendA.log 2>&1 < /dev/null &
echo \$! > ~/team1-logs/backendA.pid
for i in \$(seq 1 50); do lsof -nP -iTCP:3001 -sTCP:LISTEN >/dev/null && break; sleep 0.1; done
echo "listening again at \$($MS3) (mac3 clock): \$(lsof -nP -iTCP:3001 -sTCP:LISTEN | awk 'NR==2{print \$1, "pid", \$2, \$9}')  (pid in ~/team1-logs/backendA.pid)"
EOF
}

# ------------------------------------------------------------------ 0. preflight
: > "$EV"
{ header "Ext D · 00 events: what was done when (this Mac's clock, ms)" \
    "Plan: ${DURATION}s loop on $CLIENT, stop Backend A at ~${STOP_AT}s, start it at ~${START_AT}s, request every ${GAP}s"; } | tee -a "$EV"
ev "preflight: edge -> A direct: $(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$A_HP/api/status")  edge -> B direct: $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/api/status)  nginx: $(pgrep -q -f 'nginx: master' && echo running || echo DOWN)"
ERR0=$(wc -l < "$ERRLOG"); ACC0=$(wc -l < "$ACCLOG")

# ------------------------------------------------------------------ 1. captures
rm -f "$P1" "$P2"
sudo -n /usr/sbin/tcpdump -i en0 -U -Z "$ME" -w "$P1" "tcp port 3001 and host $A_IP" 2>"$TMP/en0.err" &
sudo -n /usr/sbin/tcpdump -i lo0 -U -Z "$ME" -w "$P2" "tcp port 3002" 2>"$TMP/lo0.err" &
sleep 1.5
ev "tcpdump started: \$ sudo -n /usr/sbin/tcpdump -i en0 -U -Z $ME -w ${P1#"$REPO"/} 'tcp port 3001 and host $A_IP'"
ev "tcpdump started: \$ sudo -n /usr/sbin/tcpdump -i lo0 -U -Z $ME -w ${P2#"$REPO"/} 'tcp port 3002'"

# ------------------------------------------------------------------ 2. client loop (background, live on screen)
LOOP="t0=\$(date +%s); end=\$((SECONDS+$DURATION)); i=0
while [ \$SECONDS -lt \$end ]; do i=\$((i+1))
  h=\$(curl -s -D - -o /dev/null --max-time 8 -w 'DNS=%{time_namelookup} TOTAL=%{time_total}' https://\$NAME/api/status)
  printf '%s  t+%-3s #%-3s http=%-4s backend=%-2s x-upstream=%-32s x-upstream-status=%-8s dns=%-6s total=%ss\n' \"\$(tsm)\" \$((\$(date +%s)-t0)) \$i \
    \"\$(echo \"\$h\" | awk 'NR==1{print \$2}')\" \"\$(echo \"\$h\" | hv x-backend)\" \"\$(echo \"\$h\" | hv x-upstream | sed 's/, /,/g')\" \
    \"\$(echo \"\$h\" | hv x-upstream-status | sed 's/, /,/g')\" \"\$(echo \"\$h\" | sed -n 's/.*DNS=\\([0-9.]*\\).*/\\1/p' | cut -c1-6)\" \"\$(echo \"\$h\" | sed -n 's/.*TOTAL=//p' | cut -c1-6)\"
  sleep $GAP
done"
( { header "Ext D · 03 client loop on $CLIENT through the edge (Backend A stopped/started during it)" \
      "Columns: client time (ms), seconds since loop start, request #, status, backend that answered, backends tried," \
      "status per try, DNS lookup time, total time. A retried request: x-upstream=10.7.3.175:3001,127.0.0.1:3002 x-upstream-status=502,200"
    crun "$LOOP"; } 2>&1 | tee "$LOOPF" ) &
LOOP_PID=$!
T0=$(date +%s); ev "client loop started on $CLIENT"
wait_until() { while [ $(( $(date +%s) - T0 )) -lt "$1" ]; do sleep 0.2; done; }

# ------------------------------------------------------------------ 3. fail / recover Backend A
wait_until "$STOP_AT";  E_STOP=$(epoch);  ev "STOP Backend A on mac3"
stop_A 2>&1 | sed 's/^/                ↳ /' | tee -a "$EV"
wait_until "$START_AT"; E_START=$(epoch); ev "START Backend A on mac3"
start_A 2>&1 | sed 's/^/                ↳ /' | tee -a "$EV"
wait "$LOOP_PID"; ev "client loop finished"

# ------------------------------------------------------------------ 4. stop captures
sleep 1
sudo -n /usr/bin/pkill -INT -f "^/usr/sbin/tcpdump -i en0 -U -Z $ME -w $P1"
sudo -n /usr/bin/pkill -INT -f "^/usr/sbin/tcpdump -i lo0 -U -Z $ME -w $P2"
sleep 1
ev "tcpdump stopped: en0 $(grep -h 'packets captured' "$TMP/en0.err")   lo0 $(grep -h 'packets captured' "$TMP/lo0.err")"

# ------------------------------------------------------------------ 5. nginx logs + config
{ header "Ext D · 04 nginx error.log lines written during the test" "\$ tail -n +$((ERR0+1)) $ERRLOG"
  tail -n +$((ERR0+1)) "$ERRLOG"; } > "$D/04-nginx-error-excerpt.txt"
{ header "Ext D · 05 nginx per-request log (team1-access.log) during the test" "\$ tail -n +$((ACC0+1)) $ACCLOG" \
    "t= is the edge's clock (epoch, ms). Two upstreams on one line = nginx retried the request on the other backend."
  tail -n +$((ACC0+1)) "$ACCLOG"; } > "$D/05-nginx-access-excerpt.txt"
{ header "Ext D · 06 upstream + failover settings in force (deployed config)" "\$ nginx -t; sed -n '/^upstream/,/^}/p' $CONF; grep proxy_ $CONF"
  /opt/homebrew/bin/nginx -t 2>&1; echo
  sed -n '/^upstream/,/^}/p' "$CONF"; echo; grep -nE '^[[:space:]]*proxy_(connect|send|read|next)_' "$CONF"; echo
  echo "## Phase 1 vs Phase 2 edge config (diff nginx/team1.conf nginx/phase2/team1.conf, comments stripped)"
  diff <(grep -vE '^[[:space:]]*(#|$)' "$REPO/nginx/team1.conf") <(grep -vE '^[[:space:]]*(#|$)' "$REPO/nginx/phase2/team1.conf"); } > "$D/06-upstream-config.txt"

# ------------------------------------------------------------------ 6. one clock: pcap (tcpdump -tt) + access log (t=$msec)
r1() { tcpdump -tt -nn -r "$P1" "$@" 2>/dev/null; }
r2() { tcpdump -tt -nn -r "$P2" "$@" 2>/dev/null; }
# A unreachable from the edge: first FIN/RST sent by A after the STOP command ... first SYN-ACK from A after START
E_DOWN=$(r1 "src port 3001 and tcp[tcpflags] & (tcp-fin|tcp-rst) != 0" | awk -v s="$E_STOP" '$1 >= s {print $1; exit}')
E_UP=$(r1 "src port 3001 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack != 0" | awk -v s="$E_START" '$1 >= s {print $1; exit}')
: "${E_DOWN:=$E_STOP}" "${E_UP:=$E_START}"

{ header "Ext D · 07 what the packets show (tcpdump -tt -nn -r <pcap>, this Mac's clock)" \
    "STOP command $(hms "$E_STOP")  ->  A's socket closed (first FIN/RST from A) $(hms "$E_DOWN")" \
    "START command $(hms "$E_START")  ->  A accepts again (first SYN-ACK from A) $(hms "$E_UP")"
  echo "## en0: edge 10.7.30.71 <-> Backend A 10.7.3.175:3001"
  r1 "dst port 3001 and greater 100" | awk -v d="$E_DOWN" -v u="$E_UP" \
    '{ if ($1 < d) a++; else if ($1 < u) b++; else c++ } END { printf "  HTTP requests the edge sent to A:  before %d   while down %d   after restart %d\n", a, b, c }'
  printf '  TCP connections opened to A (SYN): %s   accepted (SYN-ACK): %s   refused (RST from A): %s RST packets on %s connection attempts\n' \
    "$(r1 'dst port 3001 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0' | awk '{print $3}' | sort -u | wc -l | tr -d ' ')" \
    "$(r1 'src port 3001 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack != 0' | wc -l | tr -d ' ')" \
    "$(r1 'src port 3001 and tcp[tcpflags] & tcp-rst != 0' | wc -l | tr -d ' ')" \
    "$(r1 'src port 3001 and tcp[tcpflags] & tcp-rst != 0' | awk '{print $5}' | sort -u | wc -l | tr -d ' ')"
  echo "  (nginx keeps upstream connections open: few SYNs, many requests. Each refused attempt = SYN with ECN [SEW] -> RST,"
  echo "   then macOS retries without ECN [S] -> RST again; Wi-Fi RTT 40-250 ms each, hence 0.4-0.9 s per failed try.)"
  echo "  A closes its connection when the process exits:"
  r1 "src port 3001 and tcp[tcpflags] & (tcp-fin|tcp-rst) != 0" | awk -v s="$E_STOP" '$1 >= s' | head -1 | sed 's/^/    /'
  echo "  First refused attempt (SYN -> RST):"
  F=$(r1 'src port 3001 and tcp[tcpflags] & tcp-rst != 0' | awk -v d="$E_DOWN" '$1 >= d {print $5; exit}' | sed 's/:$//; s/.*\.//')
  [ -n "$F" ] && r1 "port $F" | sed 's/^/    /'
  echo "  First accepted connection after the restart:"
  r1 "src port 3001 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack != 0" | awk -v s="$E_START" '$1 >= s {print "    " $0; exit}'
  echo
  echo "## lo0: edge <-> Backend B 127.0.0.1:3002"
  r2 "dst port 3002 and greater 100" | awk -v d="$E_DOWN" -v u="$E_UP" \
    '{ if ($1 < d) a++; else if ($1 < u) b++; else c++ } END { printf "  HTTP requests the edge sent to B:  before %d   while A down %d   after restart %d\n", a, b, c }'
  printf '  TCP connections opened to B: %s (kept alive and reused)\n' \
    "$(r2 'dst port 3002 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0' | wc -l | tr -d ' ')"
} | perl -MPOSIX=strftime -pe 's/^(\s*)(\d{10})\.(\d{3})\d*/$1.strftime("%H:%M:%S",localtime $2).".$3"/e' > "$D/07-pcap-summary.txt"

# ------------------------------------------------------------------ 7. summary
{ header "Ext D · 08 summary (edge clock: pcap + nginx t=\$msec; client view from 03-client-loop.txt)" \
    "A down (edge view) from $(hms "$E_DOWN") to $(hms "$E_UP"): $(awk -v a="$E_DOWN" -v b="$E_UP" 'BEGIN{printf "%.1f", b-a}') s"
  echo "## Client view ($CLIENT)"
  awk '/^[0-9:.]+  t\+/ { n++; for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
         code[v["http"]]++; if (v["x-upstream"] ~ /,/) { r++; rl = rl "    " $0 "\n" }
         tt = v["total"]; sub(/s$/, "", tt); if (tt + 0 > mx) { mx = tt + 0; ml = $0 } }
       END { printf "  requests: %d   ", n; for (c in code) printf "http %s: %d   ", c, code[c]; print ""
             printf "  retried on the other backend, client still got 200: %d\n%s", r, rl
             printf "  slowest: %.3f s\n    %s\n", mx, ml }' "$LOOPF"
  echo "## Edge view (nginx per-request log, classified by the pcap window)"
  tail -n +$((ACC0+1)) "$ACCLOG" | grep "client=$DNS1 " | awk -v d="$E_DOWN" -v u="$E_UP" -v st="$E_START" '
    { match($0, /t=[0-9.]+/); t = substr($0, RSTART + 2, RLENGTH - 2) + 0
      match($0, /upstream=[^=]* ustatus=/); up = substr($0, RSTART + 9, RLENGTH - 18)
      n = split(up, ups, ", "); last = ups[n]; be = (last ~ /:3001$/) ? "A" : "B"
      ph = (t < d) ? 1 : (t < u) ? 2 : 3; c[ph, be]++; if (n > 1) rt[ph]++
      if (ph == 3 && be == "A" && !fa) { fa = t } }
    END { printf "  before:        A=%d B=%d\n", c[1,"A"], c[1,"B"]
          printf "  A down:        A=%d B=%d   retried=%d   <- A must be 0\n", c[2,"A"], c[2,"B"], rt[2]
          printf "  after restart: A=%d B=%d\n", c[3,"A"], c[3,"B"]
          if (fa) printf "  first request served by A again: %.1f s after the START command\n  (passive health check: nginx only finds out A is back when it next TRIES it, after fail_timeout; that first try is the SYN-ACK at the end of the down window, %.1f s before this request was logged)\n", fa - st, fa - u
          else    print  "  A did NOT come back during the loop" }'
  echo "## nginx error.log"
  echo "  $(grep -c 'connect() failed' "$D/04-nginx-error-excerpt.txt") x connect() failed, $(grep -c 'no live upstreams' "$D/04-nginx-error-excerpt.txt") x no live upstreams"
  grep -m1 'connect() failed' "$D/04-nginx-error-excerpt.txt" | sed 's/^/    first: /'
} | tee "$D/08-summary.txt"
rm -rf "$TMP"
echo; echo "(evidence in ${D#"$REPO"/}/)"
