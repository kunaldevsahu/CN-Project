#!/bin/bash
# Extension C: test backend isolation while it is ON (after C-apply.sh). Run on Mac 4.
#   bash scripts/phase2/C-test.sh
# Expected: client (mac1) -> 10.7.3.175:3001 and 10.7.30.71:3002 TIME OUT (pf drops the SYN, no RST);
#           an unfiltered closed port (3009) is REFUSED at once (contrast); the edge (this Mac) -> A = 200;
#           the standby edge (mac3) -> B = 200; HTTPS through the edge still alternates A/B.
# Captures: mac1 en0 (client side: SYN retransmits, no reply), mac3 en0 + Mac 4 en0 (SYN arrives, nothing sent back).
# Evidence: evidence/phase2/C/02-tests.txt, 03/04/05 pcaps, 06-pcap-summary.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
C="$EVID/C"; mkdir -p "$C"
P1="$C/03-mac1-client-nc-blocked.pcap"; P3="$C/04-mac3-en0-syn-dropped.pcap"; P4="$C/05-mac4-en0-syn-dropped.pcap"
F1='tcp and (port 3001 or port 3002 or port 3009)'; F3="tcp port 3001 and host $DNS1"; F4="tcp port 3002 and host $DNS1"

cap_start() {  # cap_start <local|mac1|mac3> <file on that Mac> <filter>
  on "$1" "mkdir -p ~/team1-logs; rm -f \"$2\"; nohup sudo -n /usr/sbin/tcpdump -i en0 -U -Z \$(whoami) -w \"$2\" '$3' >/dev/null 2>~/team1-logs/tcpdump-C.err </dev/null &
           echo \"\$(scutil --get LocalHostName): \\\$ sudo -n /usr/sbin/tcpdump -i en0 -U -Z \$(whoami) -w $2 '$3'\""
}
cap_stop() { on "$1" "sudo -n /usr/bin/pkill -INT -f '^/usr/sbin/tcpdump -i en0 -U -Z [a-z]+ -w $2'; sleep 0.5; tail -1 ~/team1-logs/tcpdump-C.err 2>/dev/null; grep 'packets captured' ~/team1-logs/tcpdump-C.err"; }

NC='for t in "10.7.3.175 3001  (Backend A, pf)" "10.7.30.71 3002  (Backend B, pf)" "10.7.3.175 3009  (closed port, NO pf rule: contrast)"; do
  set -- $t; a=$(perl -MTime::HiRes=time -e "printf q(%.3f), time")
  r=$(nc -vz -G 3 $1 $2 2>&1 | tail -1); b=$(perl -MTime::HiRes=time -e "printf q(%.3f), time")
  printf "%s  nc -vz -G 3 %-10s %-4s -> %-58s %.2f s   %s\n" "$(tsm)" $1 $2 "$r" $(awk -v a=$a -v b=$b "BEGIN{print b-a}") "${*:3}"
done'

OUT="$C/02-tests.txt"
{ header "Ext C · 02 tests with isolation ON" "Captures: mac1 '$F1' · mac3 '$F3' · Mac 4 '$F4'"
  echo "## Rules in force"
  for m in mac3 local; do on $m 'echo "$(scutil --get LocalHostName): $(sudo -n /sbin/pfctl -si 2>/dev/null | grep Status | cut -c1-16)"; sudo -n /sbin/pfctl -a com.apple/team1 -sr 2>/dev/null | sed "s/^/    /"'; done
  echo; echo "## Captures"
  cap_start mac1 '$HOME/team1-logs/C-mac1.pcap' "$F1"
  cap_start mac3 '$HOME/team1-logs/C-mac3.pcap' "$F3"
  cap_start local "$P4" "$F4"
  sleep 2
  echo; echo "## 1. Client (mac1) straight to the backends: must TIME OUT (dropped), unlike a closed port (REFUSED)"
  crun "$NC"
  echo "## 2. The edge (this Mac, 10.7.30.71) to Backend A: allowed"
  run "curl -s -m 4 -D - -o /dev/null -w 'took %{time_total}s\n' http://$A_HP/api/status | grep -iE '^HTTP|^x-backend|took'"
  echo "## 3. The edge to Backend B over loopback (how nginx reaches it): allowed (lo0)"
  run "curl -s -m 4 -D - -o /dev/null http://127.0.0.1:3002/api/status | grep -iE '^HTTP|^x-backend'"
  echo "## 4. The standby edge (mac3, 10.7.3.175) to Backend B: allowed"
  echo "[mac3]\$ curl -s -m 4 -D - -o /dev/null http://$B_HP/api/status"
  on mac3 "curl -s -m 4 -D - -o /dev/null http://$B_HP/api/status | grep -iE '^HTTP|^x-backend'"; echo
  echo "## 5. The service through the edge still works and still alternates"
  crun 'for i in $(seq 1 8); do h=$(curl -s -D - -o /dev/null https://$NAME/api/status); printf "%s  #%s http=%s x-backend=%s x-upstream=%s\n" "$(tsm)" $i "$(echo "$h" | awk "NR==1{print \$2}")" "$(echo "$h" | hv x-backend)" "$(echo "$h" | hv x-upstream)"; sleep 0.3; done'
  sleep 1
  echo "## 6. pf rule counters (pfctl -a com.apple/team1 -vsr): the block rule has counted the dropped SYNs"
  for m in mac3 local; do on $m 'echo "$(scutil --get LocalHostName):"; sudo -n /sbin/pfctl -a com.apple/team1 -vsr 2>/dev/null | sed "s/^/    /"'; done
  echo; echo "## Captures stopped"
  for m in mac1 mac3; do echo "  $m: $(cap_stop $m "/Users/[a-z]+/team1-logs/C-$m.pcap" | tr '\n' ' ')"; done
  echo "  mac4: $(cap_stop local "$P4" | tr '\n' ' ')"
} 2>&1 | tee "$OUT"

scp -q -o BatchMode=yes mac1:team1-logs/C-mac1.pcap "$P1"; scp -q -o BatchMode=yes mac3:team1-logs/C-mac3.pcap "$P3"
on mac1 'rm -f ~/team1-logs/C-mac1.pcap'; on mac3 'rm -f ~/team1-logs/C-mac3.pcap'
rd() { tcpdump -nn -r "$1" "${@:2}" 2>/dev/null; }
{ header "Ext C · 06 what the three captures show" "Files: ${P1#"$REPO"/}, ${P3#"$REPO"/}, ${P4#"$REPO"/}"
  echo "## mac1 (client side): SYNs go out, retransmitted, NOTHING comes back from 3001/3002; 3009 gets an immediate RST"
  rd "$P1" | sed 's/, options \[.*\], length/, length/; s/^/  /'
  echo
  for p in "$P3:mac3 :3001" "$P4:Mac 4 :3002"; do f=${p%%:*}; n=${p#*:}
    printf '## %s: SYNs from mac1 that ARRIVED: %s   replies sent back (SYN-ACK or RST): %s\n' "$n" \
      "$(rd "$f" "src host $DNS1 and tcp[tcpflags] & tcp-syn != 0" | wc -l | tr -d ' ')" \
      "$(rd "$f" "dst host $DNS1" | wc -l | tr -d ' ')"
    rd "$f" | sed 's/, options \[.*\], length/, length/; s/^/  /'; echo
  done
  echo "Reading: tcpdump (BPF) sees an incoming packet BEFORE pf filters it, so the SYN shows up on the backend Mac,"
  echo "but pf drops it and the kernel never answers: no SYN-ACK, no RST. The client retransmits and nc gives up after 3 s."
} 2>&1 | tee "$C/06-pcap-summary.txt"
echo "(saved: evidence/phase2/C/02-tests.txt 03-05 pcaps 06-pcap-summary.txt)"
