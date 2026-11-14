#!/bin/bash
# T12：真实应用（HTTP keep-alive，客户端超时 1 s）在路由器硬故障时的表现。用法：mesh/t12_http.sh <a1|b1|...>
# 32 条长连接（4 个 pod 源 × 4 个目的 × 2），每条每 20 ms 一个 GET；T+10 硬故障，T+25 恢复（之后自动收回）
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; OLD=$(g old_node); V=$(g router_$1)
bg(){ aws ssm send-command --region $R --instance-ids "$1" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["600"]}))' "$2")" --query Command.CommandId --output text; }
out(){ for i in $(seq 1 200); do st=$(aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query Status --output text 2>/dev/null); case $st in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 2; done; aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query StandardOutputContent --output text; }
waitto(){ echo "python3 -c 'import time;time.sleep(max(0,$1-time.time()))'"; }
T=$(python3 -c 'import time;print(int(time.time())+20)'); TF=$((T+10)); TR=$((T+25))
echo "### T12 HTTP keep-alive，$1 硬故障：开始 $T，故障 $TF，恢复 $TR"
CP=$(bg $OLD "$(waitto $T); ip netns exec pod python3 /usr/local/bin/httpprobe.py --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.02 --timeout 1 --duration 55")
CV=$(bg $V "$(waitto $TF); systemctl stop overlay-mesh; iptables -I INPUT -p udp --dport 4789 -j DROP; iptables -I FORWARD -j DROP; $(waitto $TR); iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; systemctl start overlay-mesh; echo ok")
out $CV $V >/dev/null; out $CP $OLD > /tmp/ovr/t12.json
python3 - /tmp/ovr/t12.json $TF $TR <<'PY'
import sys,json,collections
t=open(sys.argv[1]).read(); j=json.loads(t[t.index('['):t.rindex(']')+1]); tf=float(sys.argv[2]); tr=float(sys.argv[3])
reqs=sum(r['reqs'] for r in j); errs=[(e[0]-tf,e[1],r['src'],r['dst']) for r in j for e in r['errors']]
conns_hit=sum(1 for r in j if r['errors'])
print(f"  连接 {len(j)} 条，请求 {reqs}，失败 {len(errs)}（{len(errs)/reqs*100:.3f}%），受影响连接 {conns_hit}/{len(j)}，重建连接 {sum(r['reconnects'] for r in j)} 次")
print("  失败类型:", dict(collections.Counter(e[1] for e in errs)))
if errs: print(f"  失败时间窗（相对故障）：{min(e[0] for e in errs):+.2f} ～ {max(e[0] for e in errs):+.2f} s；恢复后（> +{tr-tf:.0f}s）失败 {sum(1 for e in errs if e[0] > tr-tf)} 次")
g=collections.defaultdict(int)
for e in errs: g[(e[2],e[3])]+=1
print("  按 源→目的 的失败数:", dict(sorted(g.items())))
print(f"  延迟：p50 中位数 {sorted(r['p50_ms'] for r in j)[len(j)//2]} ms；p99 最大 {max(r['p99_ms'] for r in j)} ms；单次最大 {max(r['max_ms'] for r in j)} ms")
PY
