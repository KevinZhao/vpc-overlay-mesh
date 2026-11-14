#!/bin/bash
# T17：旧容器网络新 node 上线（新 pod 段 100.64.11.0/24），容器网络控制器只写了 node 子网 RT。
# 同步前：新 VPC → 新 pod 不通；运行 podroute_sync.py 后：transit RT 补路由、PL 加段，测从同步到连通的时间。最后清理。
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; PY=/tmp/ovr/venv/bin/python; S=scripts/ssm.sh
OLD=$(g old_node); NEW=$(g new_host); ONENI=$(aws ec2 describe-instances --region $R --instance-ids $OLD --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId' --output text)
TRT=$(aws ec2 describe-route-tables --region $R --filters "Name=tag:Name,Values=rt-old-transit*" --query 'RouteTables[0].RouteTableId' --output text)
PLS=$(python3 -c "import json;print(' '.join(json.load(open('$J'))['pl_pods'].values()))")
SYNC="$PY mesh/podroute_sync.py --src-rt $(g rt_old_node) --transit-rt $TRT --pl $PLS --pool 100.64.0.0/14 --keep 100.64.10.0/24"
echo "### 1. 新 node 上线：pod2 netns 100.64.11.10，容器网络控制器写 node 子网 RT"
$S $OLD "ip netns add pod2 2>/dev/null; ip link add veth2-h type veth peer name veth2-p 2>/dev/null; ip link set veth2-p netns pod2 2>/dev/null; ip addr replace 100.64.11.1/24 dev veth2-h; ip link set veth2-h mtu 9001 up; sysctl -qw net.ipv4.conf.veth2-h.rp_filter=0; ip netns exec pod2 ip addr replace 100.64.11.10/24 dev veth2-p; ip netns exec pod2 ip link set veth2-p mtu 9001 up; ip netns exec pod2 ip link set lo up; ip netns exec pod2 ip route replace default via 100.64.11.1; echo ok" | head -1
aws ec2 create-route --region $R --route-table-id $(g rt_old_node) --destination-cidr-block 100.64.11.0/24 --network-interface-id $ONENI >/dev/null && echo "node 子网 RT 已写入 100.64.11.0/24 → $ONENI"
echo "### 2. 同步前：新 host → 新 pod"; $S $NEW "ping -c 3 -W 1 100.64.11.10 | tail -2" | sed 's/^Success\t//'
echo "### 3. dry-run"; $SYNC
echo "### 4. 应用同步，并从新 host 持续 ping（0.1 s）测连通时间"
CP=$(aws ssm send-command --region $R --instance-ids $NEW --document-name AWS-RunShellScript --parameters '{"commands":["ping -D -i 0.1 -c 300 -W 1 100.64.11.10 | grep -m1 -E \"bytes from\" ; date +%s.%N"]}' --query Command.CommandId --output text)
sleep 3; T0=$(python3 -c 'import time;print(time.time())'); $SYNC --apply; echo "sync_start=$T0"
sleep 12; aws ssm get-command-invocation --region $R --command-id $CP --instance-id $NEW --query StandardOutputContent --output text | head -1 | python3 -c "
import sys,re; l=sys.stdin.read(); m=re.search(r'\[(\d+\.\d+)\]',l); print('首个成功回包:', m.group(1) if m else l.strip(), '相对同步开始 %.2f s'%(float(m.group(1))-$T0) if m else '')"
echo "### 5. 同步后：pod2 → 新 host、新 host → pod2"; $S $OLD "ip netns exec pod2 ping -c 3 -W 1 10.120.1.10 | tail -1" | sed 's/^Success\t//'; $S $NEW "ping -c 3 -W 1 100.64.11.10 | tail -1" | sed 's/^Success\t//'
echo "### 6. 再跑一次 dry-run（应无动作）"; $SYNC
echo "### 7. node 下线：删除 node 子网 RT 路由 → 同步应删除 transit 路由与 PL 条目"
aws ec2 delete-route --region $R --route-table-id $(g rt_old_node) --destination-cidr-block 100.64.11.0/24 && $SYNC --apply
$S $OLD "ip netns del pod2; ip link del veth2-h 2>/dev/null; echo cleaned" | head -1
