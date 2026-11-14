#!/bin/bash
# T19：长稳 + 周期性故障注入。用法：mesh/t19_soak.sh [时长 s，默认 3600]
# 32 条流全程运行（20 ms 间隔）；每 600 s 依次对 a1 b2 a3 b1 a2 注入 15 s 硬故障；前后采集守护进程 RSS / CPU / 日志量
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); DUR=${1:-3600}; RTS="a1 a2 a3 b1 b2 b3"
stat(){ for r in $RTS; do scripts/ssm.sh $(g router_$r) "P=\$(systemctl show -p MainPID --value overlay-mesh); echo \"$r rss_kb=\$(ps -o rss= -p \$P | tr -d ' ') cpu_s=\$(ps -o cputimes= -p \$P 2>/dev/null || ps -o time= -p \$P) log_lines=\$(wc -l < /var/log/overlay-mesh.log) err=\$(grep -c ERR /var/log/overlay-mesh.log) restarts=\$(systemctl show -p NRestarts --value overlay-mesh)\"" | sed 's/^Success\t//' | head -1; done; }
echo "### 开始 $(date '+%F %T')，时长 $DUR s"; echo "--- 基线"; stat
T=$(python3 -c 'import time;print(int(time.time())+20)')
CP=$(aws ssm send-command --region $R --instance-ids $OLD --document-name AWS-RunShellScript --timeout-seconds 600 --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":[str(int(sys.argv[2])+600)]}))' "python3 -c 'import time;time.sleep(max(0,$T-time.time()))'; ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.02 --duration $DUR > /tmp/t19.json" $DUR)" --query Command.CommandId --output text)
EV=""; i=0
for v in a1 b2 a3 b1 a2; do i=$((i+1)); TF=$((T+600*i-300)); [ $((TF+30)) -gt $((T+DUR)) ] && break
  python3 -c "import time;time.sleep(max(0,$TF-time.time()))"
  scripts/ssm.sh $(g router_$v) "systemctl stop overlay-mesh; iptables -I INPUT -p udp --dport 4789 -j DROP; iptables -I FORWARD -j DROP; sleep 15; iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; systemctl start overlay-mesh; echo ok" 60 >/dev/null
  EV="$EV $TF:$v"; echo "  故障 #$i：$v @ $(date -r $TF '+%T')"
done
python3 -c "import time;time.sleep(max(0,$T+$DUR+5-time.time()))"
for k in $(seq 1 60); do st=$(aws ssm get-command-invocation --region $R --command-id $CP --instance-id $OLD --query Status --output text); [ "$st" = Success ] && break; sleep 10; done
echo "--- 结束 $(date '+%F %T')"; stat
scripts/ssm.sh $OLD "cat /tmp/t19.json" 120 | python3 -c "
import sys,json
t=sys.stdin.read(); j=json.loads(t[t.index('{'):t.rindex('}')+1])
ev=[(int(x.split(':')[0]),x.split(':')[1]) for x in '$EV'.split()]
out=[(s,d) for f in j['flows'] for s,d in f['outages']]
print(f\"32 条流 × {j['packets_per_flow']} 包：总丢包 {sum(f['lost'] for f in j['flows'])}，≥50 ms 的中断 {len(out)} 次\")
for tf,v in ev:
    w=[d for s,d in out if tf-1<=s<=tf+40]
    print(f'  故障 {v}：{len(w)} 条流中断，最长 {max(w,default=0):.2f}s')
rest=[(round(s-ev[0][0] if ev else 0,1),d) for s,d in out if not any(tf-1<=s<=tf+40 for tf,_ in ev)]
print('  故障窗口之外的中断：', rest if rest else '无')"
