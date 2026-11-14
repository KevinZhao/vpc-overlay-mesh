#!/bin/bash
# 把守护进程 + 统一配置（terraform output mesh_config）推送到已在运行的路由器
# （存量实例的 user_data 被 ignore_changes，只能用 SSM 推；新建 / 替换的实例由 user_data 自动安装）
# 用法：mesh/push.sh            推送全部 6 台
#       ROUTERS="router_a2" mesh/push.sh   只推指定的
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p /tmp/ovr; J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
terraform output -raw mesh_config > /tmp/ovr/mesh_config.json
D64=$(gzip -9c mesh/overlay-mesh.py | base64 | tr -d '\n'); C64=$(base64 < /tmp/ovr/mesh_config.json | tr -d '\n')
for r in ${ROUTERS:-router_a1 router_a2 router_a3 router_b1 router_b2 router_b3}; do
  scripts/ssm.sh $(g $r) "dnf install -y -q python3-boto3 >/dev/null 2>&1; for f in /usr/local/sbin/overlay-mesh.py /etc/overlay-mesh.json; do [ -f \$f ] && cp -p \$f \$f.prev; done; echo $D64 | base64 -d | gunzip > /usr/local/sbin/overlay-mesh.py; echo $C64 | base64 -d > /etc/overlay-mesh.json; mkdir -p /etc/systemd/system/overlay-mesh.service.d; printf '[Unit]\\nStartLimitIntervalSec=0\\n' > /etc/systemd/system/overlay-mesh.service.d/10-nolimit.conf; printf '/var/log/overlay-mesh.log {\\n size 50M\\n rotate 10\\n compress\\n copytruncate\\n missingok\\n}\\n' > /etc/logrotate.d/overlay-mesh; systemctl daemon-reload; : > /var/log/overlay-mesh.log; systemctl restart overlay-mesh; echo $r ok" | head -1 &
done
wait
