#!/bin/bash
# 模拟跨账号：A 侧 ENI 的 overlay-mesh tag 改为 poc-a、B 侧改为 poc-b，各侧配置 mesh=自己那一侧的值
# → 每侧只能发现本侧成员；对侧成员来自配置 static_peers。验证 mesh 建立 + 一次硬故障切换，最后恢复为同一 mesh。
# 用法：bash mesh/xacct_sim.sh setup|test|restore
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; S=scripts/ssm.sh
case $1 in
setup)
  terraform output -raw mesh_config > /tmp/ovr/mesh_config.json
  python3 - <<'PY'
import json
c = json.load(open('/tmp/ovr/mesh_config.json'))
A = [dict(name='A1', ip='10.110.10.10', idx=1), dict(name='A2', ip='10.110.10.12', idx=2), dict(name='A3', ip='10.110.10.13', idx=3)]
B = [dict(name='B1', ip='10.120.10.10', idx=1), dict(name='B2', ip='10.120.10.12', idx=2), dict(name='B3', ip='10.120.10.13', idx=3)]
for side, mesh, peers in (('a', 'poc-a', {'b': B}), ('b', 'poc-b', {'a': A})):
    x = dict(c, mesh=mesh, static_peers=peers); json.dump(x, open(f'/tmp/ovr/mesh_x{side}.json', 'w'))
PY
  aws ec2 create-tags --region $R --resources $(g eni_a) $(g eni_a2) $(g eni_a3) --tags Key=overlay-mesh,Value=poc-a
  aws ec2 create-tags --region $R --resources $(g eni_b) $(g eni_b2) $(g eni_b3) --tags Key=overlay-mesh,Value=poc-b
  for side in a b; do C64=$(base64 < /tmp/ovr/mesh_x$side.json | tr -d '\n')
    for i in 1 2 3; do $S $(g router_${side}$i) "echo $C64 | base64 -d > /etc/overlay-mesh.json; : > /var/log/overlay-mesh.log; systemctl restart overlay-mesh; echo ok" >/dev/null & done; done; wait
  sleep 30
  for r in a1 a3 b1 b3; do $S $(g router_$r) "grep -E 'MEMBERS|SELF|ERR|WARN' /var/log/overlay-mesh.log | tail -3 | cut -c1-130; ip route show proto 199 | grep -c nexthop" | sed "s/^Success\t/[$r] /"; done;;
test)
  LOGN=20 bash mesh/scenario.sh a2 hard; LOGN=20 bash mesh/scenario.sh b1 hard;;
restore)
  aws ec2 create-tags --region $R --resources $(g eni_a) $(g eni_a2) $(g eni_a3) $(g eni_b) $(g eni_b2) $(g eni_b3) --tags Key=overlay-mesh,Value=poc
  bash mesh/push.sh >/dev/null; sleep 25
  for r in a1 b1; do $S $(g router_$r) "grep -E 'MEMBERS|SELF' /var/log/overlay-mesh.log | tail -2 | cut -c1-130" | sed "s/^Success\t/[$r] /"; done;;
esac
