# Ext D · run 1 (15:09, first version of the script)

Same test as the files one level up. 52/52 requests 200, 4 retried on B (`502, 200`), A back 3.8 s after restart.
Known flaw: `08-summary.txt` here counts 1 A response as "while down" because it compared whole-second times from
two clocks (that request reached A just before the kill). Fixed in run 2 by classifying on the edge clock only.
The pcap summary here counts SYNs, which undercounts requests because nginx reuses upstream connections.
