#!/bin/bash
# T16：EC2 API 不可用时的故障切换。A2、A3 封掉到 EC2 endpoint 的 443（不封 SSM），T+12 A1 硬故障，T+22 恢复 API，T+32 恢复 A1
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); EP="$(cat /tmp/ovr/ec2_ep_old.txt)"
bg(){ aws ssm send-command --region $R --instance-ids "$1" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["600"]}))' "$2")" --query Command.CommandId --output text; }
out(){ for i in $(seq 1 200); do st=$(aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query Status --output text 2>/dev/null); case $st in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 2; done; aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query StandardOutputContent --output text; }
waitto(){ echo "python3 -c 'import time;time.sleep(max(0,$1-time.time()))'"; }
T=$(python3 -c 'import time;print(int(time.time())+20)'); TB=$((T+10)); TF=$((T+12)); TU=$((T+22)); TR=$((T+32))
BLK=""; UNB=""; for ip in $EP; do BLK="$BLK iptables -I OUTPUT -d $ip -p tcp --dport 443 -j DROP;"; UNB="$UNB iptables -D OUTPUT -d $ip -p tcp --dport 443 -j DROP;"; done
echo "### T16：封 API $TB，A1 故障 $TF，恢复 API $TU，恢复 A1 $TR"
CP=$(bg $OLD "$(waitto $T); ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.01 --duration 60")
C2=$(bg $(g router_a2) "$(waitto $TB); $BLK $(waitto $TU); $UNB echo ok"); C3=$(bg $(g router_a3) "$(waitto $TB); $BLK $(waitto $TU); $UNB echo ok")
C1=$(bg $(g router_a1) "$(waitto $TF); systemctl stop overlay-mesh; iptables -I INPUT -p udp --dport 4789 -j DROP; iptables -I FORWARD -j DROP; $(waitto $TR); iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; systemctl start overlay-mesh; echo ok")
for c in "$C2:$(g router_a2)" "$C3:$(g router_a3)" "$C1:$(g router_a1)"; do out ${c%%:*} ${c##*:} >/dev/null; done
out $CP $OLD > /tmp/ovr/t16.json
python3 - /tmp/ovr/t16.json $TF <<'PY'
import sys,json,collections
t=open(sys.argv[1]).read(); j=json.loads(t[t.index('{'):t.rindex('}')+1]); tf=float(sys.argv[2])
g=collections.defaultdict(list)
for f in j['flows']: g[(f['src'],f['dst'])]+= [(round(s-tf,2),d) for s,d in f['outages']]
for k,v in sorted(g.items()):
    if v: print(f"  {k[0]:>13} → {k[1]:<12} {sorted(set(v))[:3]}")
PY
echo "--- A2 / A3 日志（相对 A1 故障时刻）"
for r in a2 a3; do echo "  [$r]"; scripts/ssm.sh $(g router_$r) "awk -v t=$((TB-1)) '\$1>=t && /SIDE|TAKE|ERR/ {printf \"    %+.2f %s\\n\", \$1-$TF, substr(\$0, index(\$0,\$2), 150)}' /var/log/overlay-mesh.log | head -10" | sed 's/^Success\t//' | grep -v '^\s*$'; done
