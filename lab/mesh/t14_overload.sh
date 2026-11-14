#!/bin/bash
# T14：过载下的误判。用法：mesh/t14_overload.sh <interval> <detect> [hold]
# 临时下发探测参数 → pod 向 10.120.1.10（入口 A1）打 40 s UDP 64 B 压满 A1 → 统计 A1/A2/A3 的 TUN / SIDE / TAKE / FAILSTATIC 事件 → 恢复默认参数
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); IV=$1; DT=$2; HD=${3:-10}
terraform output -raw mesh_config | python3 -c "import sys,json;c=json.load(sys.stdin);c.update(interval=$IV,detect=$DT,hold=$HD);print(json.dumps(c))" > /tmp/ovr/mesh_t14.json
C64=$(base64 < /tmp/ovr/mesh_t14.json | tr -d '\n')
for r in router_a1 router_a2 router_a3 router_b1 router_b2 router_b3; do scripts/ssm.sh $(g $r) "echo $C64 | base64 -d > /etc/overlay-mesh.json; systemctl restart overlay-mesh; echo ok" >/dev/null & done; wait; sleep 20
T0=$(python3 -c 'import time;print(int(time.time()))')
echo "### 参数 interval=$IV detect=$DT hold=$HD；$T0 开始压 A1"
scripts/ssm.sh $OLD "ip netns exec pod iperf3 -c 10.120.1.10 -u -b 0 -l 64 -P 2 -t 40 -J > /tmp/t14.json 2>&1; python3 -c \"import json;e=json.load(open('/tmp/t14.json'))['end']['sum'];print('发生器：%.2f Mpps 送达（%.0f%% 丢包）'%(e['packets']*(1-e['lost_percent']/100)/40/1e6, e['lost_percent']))\"" 120 | sed 's/^Success\t//'
scripts/ssm.sh $(g router_a1) "python3 /tmp/perfsnap.py >/dev/null 2>&1; cat /proc/loadavg" >/dev/null
for r in a1 a2 a3 b1; do
  scripts/ssm.sh $(g router_$r) "awk -v t=$T0 '\$1>=t' /var/log/overlay-mesh.log | awk '{print \$2}' | sort | uniq -c | tr '\n' ' '; echo; awk -v t=$T0 '\$1>=t && /TAKE/' /var/log/overlay-mesh.log | head -4" | sed "s/^Success\t/  $(echo $r | tr a-z A-Z) 事件计数：/"
done
