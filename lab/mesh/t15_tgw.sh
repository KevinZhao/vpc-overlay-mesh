#!/bin/bash
# T15：整体降级回 TGW（L3）与 MTU 落差。32 条流 80 s；T+10 降级（含 3 s 冻结等待）；在 TGW 路径上测 MTU 与 TCP；T+50 恢复
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; PY=/tmp/ovr/venv/bin/python; OLD=$(g old_node); TGW=$(terraform output -raw tgw_id)
terraform output -raw mesh_config > /tmp/ovr/mesh_config.json
T=$(python3 -c 'import time;print(int(time.time())+20)')
CP=$(aws ssm send-command --region $R --instance-ids $OLD --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["600"]}))' "python3 -c 'import time;time.sleep(max(0,$T-time.time()))'; ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.01 --duration 80 > /tmp/t15.json")" --query Command.CommandId --output text)
python3 -c "import time;time.sleep(max(0,$T+10-time.time()))"
echo "### 降级到 TGW"; D=$($PY mesh/fallback_tgw.py down --config /tmp/ovr/mesh_config.json --tgw $TGW); echo "$D" | cut -c1-300
TD=$(echo "$D" | python3 -c "import sys,json;print(json.load(sys.stdin)['t_switch_start'])")
sleep 3
echo "### TGW 路径上的 MTU（pod → 新 host，DF）"
scripts/ssm.sh $OLD "for s in 8472 8473 8923; do echo \"-s \$s（IP 包 \$((s+28)) B）：\$(ip netns exec pod ping -M do -c 2 -W 1 -s \$s 10.120.1.10 2>&1 | grep -E 'received|mtu|too long' | tr '\n' ' ')\"; done; ip netns exec pod tracepath -n 10.120.1.10 2>&1 | grep -iE 'pmtu|reached' | head -3" 60 | sed 's/^Success\t//'
echo "### TGW 路径上的 TCP（pod → 新 host，iperf3 -P 8，10 s；看 MSS）"
scripts/ssm.sh $OLD "ip netns exec pod iperf3 -c 10.120.1.10 -P 8 -t 10 -J > /tmp/t15i.json; python3 -c \"import json;e=json.load(open('/tmp/t15i.json'))['end'];print('recv %.1f Gbps, retrans %d'%(e['sum_received']['bits_per_second']/1e9, e['sum_sent'].get('retransmits',0)))\"; ip netns exec pod ss -tin dst 10.120.1.10 2>/dev/null | grep -oE 'mss:[0-9]+' | sort | uniq -c | head -3" 90 | sed 's/^Success\t//'
python3 -c "import time;time.sleep(max(0,$T+50-time.time()))"
echo "### 恢复到路由器"; U=$($PY mesh/fallback_tgw.py restore --config /tmp/ovr/mesh_config.json --tgw $TGW); echo "$U" | cut -c1-300
TU=$(echo "$U" | python3 -c "import sys,json;print(json.load(sys.stdin)['t_switch_start'])")
for i in $(seq 1 30); do st=$(aws ssm get-command-invocation --region $R --command-id $CP --instance-id $OLD --query Status --output text); [ "$st" = Success ] && break; sleep 5; done
echo "### 32 条流"; scripts/ssm.sh $OLD "cat /tmp/t15.json" 60 | python3 -c "
import sys,json; t=sys.stdin.read(); j=json.loads(t[t.index('{'):t.rindex('}')+1])
ev=[(round(s-$TD,2) if s<$TU-5 else 'restore%+.2f'%(s-$TU), d) for f in j['flows'] for s,d in f['outages']]
print('  受影响', sum(1 for f in j['flows'] if f['outages']), '/ 32 条；丢包', sum(f['lost'] for f in j['flows']), '；中断（相对切换开始, 时长）:', sorted(set(ev), key=str)[:8])"
echo "### 日志里的 FREEZE"; for r in router_a1 router_b1; do scripts/ssm.sh $(g $r) "grep -E 'FREEZE|TAKE' /var/log/overlay-mesh.log | tail -3" | sed "s/^Success\t/  $r /"; done
