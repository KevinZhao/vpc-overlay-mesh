#!/bin/bash
# 通用故障场景（路线二 v3，每侧 3 台）。用法：mesh/scenario.sh <路由器列表，逗号分隔，如 a2 或 a1,a2> <hard|soft|drain|sidelink|noapi> [注入时长 s，默认 15]
# 32 条 UDP 流（4 个 pod 源 × 4 个目的 × 2 端口，10 ms 间隔）；T+10 注入；T+10+D 恢复；home 健康 HOLD 秒后自动收回
#  hard  停进程 + 丢弃 VXLAN 与全部转发     soft  只关 ip_forward     drain  计划内维护
#  sidelink 只丢弃同侧之间的探测（期望不切换）  noapi  在该路由器上封掉 EC2 API（443 到 endpoint），同时注入 hard 到同侧另一台见 T16
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); M=$2; D=${3:-15}; DUR=$((D+40))
IFS=',' read -ra VICS <<< "$1"
DEVQ="D=\$(ip -o -4 addr show | awk '/ 10.1[12]0.10.1[0-3]\//{print \$2}')"
inj(){ case $M in
  netdrop)  echo "$DEVQ; iptables -t raw -I PREROUTING -i \$D -j DROP; iptables -t raw -I OUTPUT -o \$D -j DROP";;
  oneway)   echo "$DEVQ; iptables -t raw -I OUTPUT -o \$D -p udp --sport 3784 -j DROP; iptables -t raw -I OUTPUT -o vx-+ -p udp --sport 3784 -j DROP";;
  tunnelcut) echo "$DEVQ; iptables -t raw -I PREROUTING -i \$D -p udp --dport 4789 -j DROP; iptables -t raw -I OUTPUT -o \$D -p udp --dport 4789 -j DROP";;
  fwdrop)   echo "iptables -I FORWARD -j DROP";;
  sigstop)  echo "kill -STOP \$(systemctl show -p MainPID --value overlay-mesh)";;
  linkdown) echo "$DEVQ; echo \$D > /tmp/linkdown.dev; ip link set \$D down";;
  flap)     echo "$DEVQ; for i in 1 2 3 4 5 6; do iptables -t raw -I PREROUTING -i \$D -j DROP; iptables -t raw -I OUTPUT -o \$D -j DROP; sleep 2; iptables -t raw -D PREROUTING -i \$D -j DROP; iptables -t raw -D OUTPUT -o \$D -j DROP; sleep 8; done";;
  hard)  echo "systemctl stop overlay-mesh; iptables -I INPUT -p udp --dport 4789 -j DROP; iptables -I FORWARD -j DROP";;
  soft)  echo "sysctl -qw net.ipv4.ip_forward=0";;
  drain) echo "touch /etc/overlay-mesh.drain";;
  sidelink) echo "for s in 10.110.10.10 10.110.10.12 10.110.10.13 10.120.10.10 10.120.10.12 10.120.10.13; do iptables -I INPUT -s \$s -p udp --dport 3784 -j DROP; iptables -I INPUT -s \$s -p udp --sport 3784 -j DROP; done";;
esac; }
rec(){ case $M in
  netdrop)  echo "$DEVQ; iptables -t raw -D PREROUTING -i \$D -j DROP; iptables -t raw -D OUTPUT -o \$D -j DROP";;
  oneway)   echo "$DEVQ; iptables -t raw -D OUTPUT -o \$D -p udp --sport 3784 -j DROP; iptables -t raw -D OUTPUT -o vx-+ -p udp --sport 3784 -j DROP";;
  tunnelcut) echo "$DEVQ; iptables -t raw -D PREROUTING -i \$D -p udp --dport 4789 -j DROP; iptables -t raw -D OUTPUT -o \$D -p udp --dport 4789 -j DROP";;
  fwdrop)   echo "iptables -D FORWARD -j DROP";;
  sigstop)  echo "kill -CONT \$(systemctl show -p MainPID --value overlay-mesh)";;
  linkdown) echo "ip link set \$(cat /tmp/linkdown.dev) up";;   # 网卡 down 后 networkd 会撤掉 IP，不能再按 IP 找网卡
  flap)     echo "true";;
  hard)  echo "iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; systemctl start overlay-mesh";;
  soft)  echo "sysctl -qw net.ipv4.ip_forward=1";;
  drain) echo "mv -f /etc/overlay-mesh.drain /tmp/overlay-mesh.drain.done";;
  sidelink) echo "for s in 10.110.10.10 10.110.10.12 10.110.10.13 10.120.10.10 10.120.10.12 10.120.10.13; do iptables -D INPUT -s \$s -p udp --dport 3784 -j DROP; iptables -D INPUT -s \$s -p udp --sport 3784 -j DROP; done";;
esac; }
bg(){ aws ssm send-command --region $R --instance-ids "$1" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["600"]}))' "$2")" --query Command.CommandId --output text; }
out(){ for i in $(seq 1 200); do st=$(aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query Status --output text 2>/dev/null); case $st in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 2; done; aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query StandardOutputContent --output text; }
waitto(){ echo "python3 -c 'import time;time.sleep(max(0,$1-time.time()))'"; }
T=$(python3 -c 'import time;print(int(time.time())+20)'); TF=$((T+10)); TR=$((TF+D))
echo "### ${1} / $M：流开始 $T，注入 $TF，恢复 $TR"
CP=$(bg $OLD "$(waitto $T); ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.01 --duration $DUR")
CVS=()
for v in "${VICS[@]}"; do CVS+=("$(bg $(g router_$v) "$(waitto $TF); $(inj); $(waitto $TR); $(rec); echo ok"):$(g router_$v)"); done
for c in "${CVS[@]}"; do out ${c%%:*} ${c##*:} >/dev/null; done
out $CP $OLD > /tmp/ovr/scn.json
python3 - /tmp/ovr/scn.json $TF $TR <<'PY'
import sys,json,collections
t=open(sys.argv[1]).read(); j=json.loads(t[t.index('{'):t.rindex('}')+1]); tf=float(sys.argv[2]); tr=float(sys.argv[3])
g=collections.defaultdict(list)
for f in j['flows']: g[(f['src'],f['dst'])].append(f)
tot=0; allo=[]
for k,v in sorted(g.items()):
    ev=sorted(set((round(s-tf,2),d) for f in v for s,d in f['outages'])); tot+=sum(f['lost'] for f in v); allo+=[d for _,d in ev]
    if ev: print(f"  {k[0]:>13} → {k[1]:<12} {sum(1 for f in v if f['outages'])}/{len(v)} 条受影响：{ev[:4]}")
print(f"  合计：{sum(1 for f in j['flows'] if f['outages'])}/{len(j['flows'])} 条流受影响，最长中断 {max(allo,default=0):.2f}s，丢包 {tot}（每流 {j['packets_per_flow']}）")
PY
echo "--- 决策日志（相对注入时刻）"
for r in a1 a2 a3 b1 b2 b3; do
  L=$(scripts/ssm.sh $(g router_$r) "awk -v t=$((TF-1)) '\$1>=t && /SELF|SIDE|TUN|TAKE|ERR|MEMBERS|FAILSTATIC|REMOVE|ISOLATED|QUORUM|MISMATCH|FREEZE|STALE|GONE/ {printf \"    %+.2f %s\\n\", \$1-$TF, substr(\$0, index(\$0,\$2))}' /var/log/overlay-mesh.log | head -${LOGN:-14}" | sed 's/^Success\t//' | grep -v '^\s*$')
  [ -n "$L" ] && echo "  [$(echo $r | tr a-z A-Z)]" && echo "$L"
done
