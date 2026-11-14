#!/bin/bash
# T18：滚动替换一台路由器（换 AMI / 机型的标准流程）。用法：mesh/t18_replace.sh <a2|b2|...>
# 32 条流跑 360 s；T+10 drain → T+20 terraform apply -replace（销毁并重建实例，数据 ENI 和 IP 不变）→ 新实例自动加入 → 健康 10 s 后收回
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); V=$1; VID=$(g router_$V); KEY=$(echo $V | tr a-z A-Z); SIDE=${V:0:1}
waitto(){ echo "python3 -c 'import time;time.sleep(max(0,$1-time.time()))'"; }
T=$(python3 -c 'import time;print(int(time.time())+20)'); TD=$((T+10)); TX=$((T+20))
echo "### T18：替换 $KEY（$VID）；流开始 $T，drain $TD，替换 $TX"
CP=$(aws ssm send-command --region $R --instance-ids $OLD --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["900"]}))' "$(waitto $T); ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.01 --duration 360 > /tmp/t18.json")" --query Command.CommandId --output text)
python3 -c "import time;time.sleep(max(0,$TD-time.time()))"; scripts/ssm.sh $VID "touch /etc/overlay-mesh.drain; echo drained" | head -1
python3 -c "import time;time.sleep(max(0,$TX-time.time()))"
RES="aws_instance.router[\"$KEY\"]"
T1=$(python3 -c 'import time;print(time.time())'); terraform apply -auto-approve -no-color -replace="$RES" 2>&1 | grep -E "Destruction complete|Creation complete|Apply complete" | sed 's/^/  /'
T2=$(python3 -c 'import time;print(time.time())'); terraform output -json ids > $J; NID=$(g router_$V)
echo "  terraform 用时 $(python3 -c "print(round($T2-$T1,1))") s，新实例 $NID"
for i in $(seq 1 60); do L=$(scripts/ssm.sh $NID "grep -E 'MEMBERS|SELF healthy|TAKE' /var/log/overlay-mesh.log 2>/dev/null | head -8" 2>/dev/null | sed 's/^Success\t//'); echo "$L" | grep -q failback && break; sleep 10; done
echo "--- 新实例日志"; echo "$L" | awk -v t=$T1 '{printf "    +%.1f s（相对 terraform 开始）%s\n", $1-t, substr($0, index($0,$2))}'
echo "--- 等流结束"; for i in $(seq 1 60); do st=$(aws ssm get-command-invocation --region $R --command-id $CP --instance-id $OLD --query Status --output text); [ "$st" = Success ] && break; sleep 10; done
scripts/ssm.sh $OLD "cat /tmp/t18.json" 120 | python3 -c "
import sys,json; t=sys.stdin.read(); j=json.loads(t[t.index('{'):t.rindex('}')+1])
hit=[f for f in j['flows'] if f['outages']]
print(f'  32 条流全程 360 s：受影响 {len(hit)} 条，丢包 {sum(f[\"lost\"] for f in j[\"flows\"])}', [(f['src'],f['dst'],[(round(s-$TD,1),d) for s,d in f['outages']]) for f in hit][:6])"
