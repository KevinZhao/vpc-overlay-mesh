#!/bin/bash
# T17-G：pod 路由同步工具的护栏。① 权威 RT 为空 → 中止；② 一次要删 > max-delete 条 → 中止；③ PL 满 → 中止。全部只用实验资源，结束后清理。
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; PY=/tmp/ovr/venv/bin/python
TRT=$(aws ec2 describe-route-tables --region $R --filters "Name=tag:Name,Values=rt-old-transit*" --query 'RouteTables[0].RouteTableId' --output text)
DUMMY=$(python3 -c "import json;print(json.load(open('$J'))['rt_old_dummy'][1])")
PLS=$(python3 -c "import json;print(' '.join(json.load(open('$J'))['pl_pods'].values()))")
ONENI=$(aws ec2 describe-instances --region $R --instance-ids $(g old_node) --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId' --output text)
echo "### ① 权威 RT 指向一张空表（模拟读错表 / 容器网络控制器正在重写）"
$PY mesh/podroute_sync.py --src-rt $DUMMY --transit-rt $TRT --pl $PLS --pool 100.64.0.0/14 --keep 100.64.10.0/24 --apply 2>&1 | tail -1
echo "### ② transit RT 里多出 6 条 src 里没有的 pod 路由 → 一次要删 6 条 > max-delete 5"
for i in 1 2 3 4 5 6; do aws ec2 create-route --region $R --route-table-id $TRT --destination-cidr-block 100.64.$((20+i)).0/24 --network-interface-id $ONENI >/dev/null; done
$PY mesh/podroute_sync.py --src-rt $(g rt_old_node) --transit-rt $TRT --pl $PLS --pool 100.64.0.0/14 --keep 100.64.10.0/24 --apply 2>&1 | tail -1
echo "  确认 6 条仍在：$(aws ec2 describe-route-tables --region $R --route-table-ids $TRT --query 'length(RouteTables[0].Routes[?starts_with(DestinationCidrBlock,`100.64.2`)])')"
$PY mesh/podroute_sync.py --src-rt $(g rt_old_node) --transit-rt $TRT --pl $PLS --pool 100.64.0.0/14 --keep 100.64.10.0/24 --apply --max-delete 6 2>&1 | tail -1
echo "### ③ PL 满：建一个 max 2 的 PL，src 新增 3 个 pod 段"
SPL=$(aws ec2 create-managed-prefix-list --region $R --prefix-list-name poc-small --address-family IPv4 --max-entries 2 --query PrefixList.PrefixListId --output text); sleep 5
for i in 1 2 3; do aws ec2 create-route --region $R --route-table-id $(g rt_old_node) --destination-cidr-block 100.64.$((30+i)).0/24 --network-interface-id $ONENI >/dev/null; done
$PY mesh/podroute_sync.py --src-rt $(g rt_old_node) --transit-rt $TRT --pl $SPL --pool 100.64.0.0/14 --keep 100.64.10.0/24 2>&1 | tail -1
echo "### 清理"
for i in 1 2 3; do aws ec2 delete-route --region $R --route-table-id $(g rt_old_node) --destination-cidr-block 100.64.$((30+i)).0/24; done
aws ec2 delete-managed-prefix-list --region $R --prefix-list-id $SPL >/dev/null && echo "  已删除测试 PL $SPL"
$PY mesh/podroute_sync.py --src-rt $(g rt_old_node) --transit-rt $TRT --pl $PLS --pool 100.64.0.0/14 --keep 100.64.10.0/24 2>&1 | tail -1
