#!/bin/bash
# 审查补测的特殊场景（定稿代码 v4，生产参数）。用法：bash mesh/special.sh <场景>
#   sdc       数据 ENI 的 source/dest check 被重新打开（A3）
#   untag-all 对侧（B）全部 ENI 的 overlay-mesh tag 被删 → 期望忽略，不拆隧道
#   untag-one 只删 B3 的 tag → 30 s 后被移出成员，B3 自己隔离下线，B1/B2 接管
#   crash     A2 真实内核崩溃（sysrq c），之后 API reboot
#   forcestop B2 被强制停机，60 s 后启动
#   n2        摘掉 B3 的数据 ENI（每侧只剩 2 台）→ B1 硬故障 → 只剩 B2；再恢复
#   mismatch  只给 A2 推一份 home 不同的配置 → 期望 CONFIG-MISMATCH、不互抢
#   clock     A1 时钟跳 +120 s → 期望没有误判
#   foreign   入口路由被人工改到 TGW 但没打 freeze → 期望守护进程不碰
#   deleted   入口路由被删 → 期望不重试风暴
#   logrotate 强制轮转日志 → 期望守护进程照常写
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;d=json.load(open('$J'));v=d['$1'];print(v if not isinstance(v,dict) else json.dumps(v))"; }
R=eu-central-1; S=scripts/ssm.sh; OLD=$(g old_node); now(){ python3 -c 'import time;print(round(time.time(),2))'; }
probe_start(){ PDUR=$1; PT0=$(now); PCID=$(aws ssm send-command --region $R --instance-ids $OLD --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["1200"]}))' "ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.01 --duration $1 > /tmp/sp.json")" --query Command.CommandId --output text); sleep 5; }
probe_result(){ # $1 = 参考时刻
  for i in $(seq 1 150); do st=$(aws ssm get-command-invocation --region $R --command-id $PCID --instance-id $OLD --query Status --output text 2>/dev/null); [ "$st" = Success ] && break; sleep 5; done
  $S $OLD "cat /tmp/sp.json" 120 | python3 -c "
import sys,json; t=sys.stdin.read(); j=json.loads(t[t.index('{'):t.rindex('}')+1]); ref=float('$1')
ev=sorted(set((round(s-ref,2),d) for f in j['flows'] for s,d in f['outages']))
print(f\"  32 条流：受影响 {sum(1 for f in j['flows'] if f['outages'])}，丢包 {sum(f['lost'] for f in j['flows'])}，中断（相对事件 s, 时长）: {ev[:8]}\")"; }
logs(){ # $1 = 起始 epoch，其余 = 路由器
  t=$1; shift; for r in "$@"; do echo "  [$r]"; $S $(g router_$r) "awk -v t=$t '\$1>=t && /SELF|SIDE|TUN|TAKE|ERR|MEMBERS|ISOLATED|QUORUM|MISMATCH|FREEZE|GONE|WARN|STALE/ {printf \"    %+.1f %s\\n\", \$1-$t, substr(\$0, index(\$0,\$2), 140)}' /var/log/overlay-mesh.log | head -${LOGN:-12}" | sed 's/^Success\t//' | grep -v '^\s*$'; done; }
case $1 in
sdc)
  ENI=$(g eni_a3); probe_start 70; T=$(now); echo "### sdc：打开 A3 数据 ENI 的 source/dest check @ $T"
  aws ec2 modify-network-interface-attribute --region $R --network-interface-id $ENI --source-dest-check; sleep 35
  T2=$(now); aws ec2 modify-network-interface-attribute --region $R --network-interface-id $ENI --no-source-dest-check; echo "  关闭 @ +$(python3 -c "print(round($T2-$T,1))") s"
  probe_result $T; logs ${T%.*} a3 a1 a2;;
untag-all)
  probe_start 60; T=$(now); echo "### untag-all：删除 B1/B2/B3 数据 ENI 的 overlay-mesh tag @ $T"
  aws ec2 delete-tags --region $R --resources $(g eni_b) $(g eni_b2) $(g eni_b3) --tags Key=overlay-mesh; sleep 40
  aws ec2 create-tags --region $R --resources $(g eni_b) $(g eni_b2) $(g eni_b3) --tags Key=overlay-mesh,Value=poc; echo "  已恢复 tag"
  probe_result $T; logs ${T%.*} a1 b1;;
untag-one)
  probe_start 90; T=$(now); echo "### untag-one：只删 B3 的 tag @ $T"
  aws ec2 delete-tags --region $R --resources $(g eni_b3) --tags Key=overlay-mesh; sleep 50
  aws ec2 create-tags --region $R --resources $(g eni_b3) --tags Key=overlay-mesh,Value=poc; echo "  已恢复 tag @ +50 s"
  probe_result $T; LOGN=16 logs ${T%.*} a1 b3 b1 b2;;
crash)
  V=$(g router_a2); probe_start 200; T=$(now); echo "### crash：A2 内核崩溃（sysrq c）@ $T"
  aws ssm send-command --region $R --instance-ids $V --document-name AWS-RunShellScript --parameters '{"commands":["sysctl -w kernel.sysrq=1; sync; echo c > /proc/sysrq-trigger"]}' >/dev/null
  sleep 40; echo "  40 s 后状态：$(aws ec2 describe-instance-status --region $R --instance-ids $V --include-all-instances --query 'InstanceStatuses[0].[InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' --output text)"
  T2=$(now); aws ec2 reboot-instances --region $R --instance-ids $V; echo "  API reboot @ +$(python3 -c "print(round($T2-$T,1))") s"
  probe_result $T; LOGN=14 logs ${T%.*} a2 a1 a3;;
forcestop)
  V=$(g router_b2); probe_start 220; T=$(now); echo "### forcestop：B2 强制停机 @ $T"
  aws ec2 stop-instances --region $R --instance-ids $V --force >/dev/null; aws ec2 wait instance-stopped --region $R --instance-ids $V
  echo "  已停机 @ +$(python3 -c "import time;print(round(time.time()-$T,1))") s"; sleep 30
  aws ec2 start-instances --region $R --instance-ids $V >/dev/null; T2=$(now); echo "  启动 @ +$(python3 -c "print(round($T2-$T,1))") s"
  probe_result $T; LOGN=14 logs ${T%.*} b2 b1 a1;;
n2)
  ATT=$(aws ec2 describe-network-interfaces --region $R --network-interface-ids $(g eni_b3) --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  probe_start 150; T=$(now); echo "### n2：摘掉 B3 数据 ENI @ $T（每侧只剩 2 台）"
  aws ec2 detach-network-interface --region $R --attachment-id $ATT --force; sleep 45
  T1=$(now); echo "  B1 硬故障 @ +$(python3 -c "print(round($T1-$T,1))") s"
  $S $(g router_b1) "systemctl stop overlay-mesh; iptables -I INPUT -p udp --dport 4789 -j DROP; iptables -I FORWARD -j DROP; sleep 20; iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; systemctl start overlay-mesh; echo ok" 60 >/dev/null
  echo "  B1 恢复；重新挂回 B3 ENI"; aws ec2 attach-network-interface --region $R --network-interface-id $(g eni_b3) --instance-id $(g router_b3) --device-index 1 >/dev/null
  probe_result $T; LOGN=18 logs ${T%.*} b2 b1 b3 a1;;
mismatch)
  terraform output -raw mesh_config | python3 -c "import sys,json;c=json.load(sys.stdin);[e.update(home='A2') for e in c['sides']['a']['entries'] if e.get('cidr')=='10.120.1.0/26'];print(json.dumps(c))" > /tmp/ovr/mesh_mm.json
  probe_start 60; T=$(now); echo "### mismatch：只给 A2 推 home 不同的配置 @ $T"
  $S $(g router_a2) "echo $(base64 < /tmp/ovr/mesh_mm.json | tr -d '\n') | base64 -d > /etc/overlay-mesh.json; systemctl restart overlay-mesh; echo ok" >/dev/null; sleep 40
  echo "  恢复 A2 的正确配置"; ROUTERS=router_a2 bash mesh/push.sh >/dev/null
  probe_result $T; logs ${T%.*} a2 a1;;
clock)
  probe_start 60; T=$(now); echo "### clock：A1 时钟 +120 s @ $T"
  $S $(g router_a1) "systemctl stop chronyd; date -s '+120 seconds' >/dev/null; sleep 30; systemctl start chronyd; chronyc -a makestep >/dev/null; echo ok" 90 >/dev/null
  probe_result $T; logs $(( ${T%.*} - 1 )) a1 a2;;
foreign)
  RT=$(g rt_old_node); TGW=$(terraform output -raw tgw_id); probe_start 45; T=$(now)
  echo "### foreign：10.120.1.64/26 被人工改到 TGW（没打 freeze）@ $T"
  aws ec2 replace-route --region $R --route-table-id $RT --destination-cidr-block 10.120.1.64/26 --transit-gateway-id $TGW; sleep 25
  echo "  25 s 后下一跳：$(aws ec2 describe-route-tables --region $R --route-table-ids $RT --query "RouteTables[0].Routes[?DestinationCidrBlock=='10.120.1.64/26'].[TransitGatewayId||NetworkInterfaceId]" --output text)"
  aws ec2 replace-route --region $R --route-table-id $RT --destination-cidr-block 10.120.1.64/26 --network-interface-id $(g eni_a2); echo "  人工改回 A2"
  probe_result $T; logs ${T%.*} a1 a2 a3;;
deleted)
  RT=$(g rt_old_node); T=$(now); echo "### deleted：删除 10.120.1.192/26 @ $T"
  aws ec2 delete-route --region $R --route-table-id $RT --destination-cidr-block 10.120.1.192/26; sleep 30
  for r in a1 a2 a3; do echo "  $r 30 s 内 ERR replace：$($S $(g router_$r) "awk -v t=${T%.*} '\$1>=t && /ERR replace/' /var/log/overlay-mesh.log | wc -l" | sed 's/^Success\t//' | tr -d '[:space:]') 条"; done
  aws ec2 create-route --region $R --route-table-id $RT --destination-cidr-block 10.120.1.192/26 --network-interface-id $(g eni_a2) >/dev/null; echo "  已重建（指向 home A2）";;
logrotate)
  V=$(g router_a1); $S $V "logrotate -f /etc/logrotate.d/overlay-mesh; sleep 3; ls -la /var/log/overlay-mesh.log*; P=\$(systemctl show -p MainPID --value overlay-mesh); ls -l /proc/\$P/fd | grep overlay-mesh; touch /etc/overlay-mesh.drain; sleep 2; mv -f /etc/overlay-mesh.drain /tmp/; sleep 1; tail -2 /var/log/overlay-mesh.log";;
*) echo "未知场景 $1"; exit 1;;
esac
