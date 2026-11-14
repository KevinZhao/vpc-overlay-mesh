#!/bin/bash
# T4：单对路由器（A1 ↔ B1，c8gn.16xlarge）的转发能力。用法：t4_perf.sh <名称> '<iperf3 参数>'
# 发生器 old-node（10.110.1.10）→ new-host（10.120.1.10），都是 c8gn.16xlarge；经 A1 → VXLAN → B1 转发
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
R=eu-central-1; NAME=$1; ARGS=$2; DUR=${DUR:-20}
A1=$(g router_a1); B1=$(g router_b1); OLD=$(g old_node)
bg(){ aws ssm send-command --region $R --instance-ids "$1" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["300"]}))' "$2")" --query Command.CommandId --output text; }
out(){ for i in $(seq 1 120); do st=$(aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query Status --output text 2>/dev/null); case $st in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 2; done; aws ssm get-command-invocation --region $R --command-id "$1" --instance-id "$2" --query StandardOutputContent --output text; }
waitto(){ echo "python3 -c 'import time;time.sleep(max(0,$1-time.time()))'"; }
P64=$(base64 < scripts/perfsnap.py | tr -d '\n')
T=$(python3 -c 'import time;print(int(time.time())+15)'); S1=$((T+6)); S2=$((T+DUR-4))
SNAP="echo $P64 | base64 -d > /tmp/perfsnap.py; $(waitto $S1); python3 /tmp/perfsnap.py; $(waitto $S2); python3 /tmp/perfsnap.py"
CA=$(bg $A1 "$SNAP"); CB=$(bg $B1 "$SNAP")
CG=$(bg $OLD "$(waitto $T); iperf3 -c 10.120.1.10 $ARGS -t $DUR -J > /tmp/t4.json 2>&1; python3 -c \"
import json;j=json.load(open('/tmp/t4.json'));e=j['end']
if 'error' in j: print('ERR',j['error'])
s=e.get('sum_received') or e.get('sum'); print('recv_Gbps=%.1f'%(s['bits_per_second']/1e9), 'lost%%=%s'%s.get('lost_percent','-'))
if 'sum_received_bidir_reverse' in e: print('reverse_Gbps=%.1f'%(e['sum_received_bidir_reverse']['bits_per_second']/1e9))
print('sender_cpu=%.0f%% receiver_cpu=%.0f%%'%(e['cpu_utilization_percent']['host_total'],e['cpu_utilization_percent']['remote_total']))\"")
RG=$(out $CG $OLD); RA=$(out $CA $A1); RB=$(out $CB $B1)
python3 - "$NAME" "$RG" "$RA" "$RB" <<'PY'
import sys,json
name,rg,ra,rb=sys.argv[1:5]
def ana(txt,who):
    l=[json.loads(x) for x in txt.strip().splitlines() if x.startswith('{')]
    if len(l)<2: return f"{who}: 快照缺失"
    a,b=l; dt=b['t']-a['t']; r=[]
    for d in sorted(b['dev']):
        x={k:(b['dev'][d][k]-a['dev'][d][k])/dt for k in b['dev'][d]}
        if x['rx_bytes']+x['tx_bytes']<1e6: continue
        r.append(f"{d} rx {x['rx_bytes']*8/1e9:.1f}G/{x['rx_packets']/1e6:.2f}Mpps tx {x['tx_bytes']*8/1e9:.1f}G/{x['tx_packets']/1e6:.2f}Mpps")
    ena=[f"{d}:{k}+{b['ena'][d][k]-a['ena'][d][k]}" for d in b['ena'] for k in b['ena'][d] if b['ena'][d][k]-a['ena'][d][k]>0]
    si=[]; busy=[]
    for c in b['cpu']:
        tt=b['cpu'][c]['total']-a['cpu'][c]['total'] or 1
        si.append((b['cpu'][c]['softirq']-a['cpu'][c]['softirq'])/tt); busy.append(1-(b['cpu'][c]['idle']-a['cpu'][c]['idle'])/tt)
    hot=sum(1 for x in si if x>0.5)
    return (f"{who}: " + "; ".join(r) + f" | softirq 合计 {sum(si):.1f} 核，>50% 的核 {hot} 个，最忙 {max(busy)*100:.0f}%"
            + (f" | ENA 超限 {', '.join(ena)}" if ena else " | ENA 超限 0"))
print(f"=== {name}\n  发生器: {' '.join(rg.split())}\n  {ana(ra,'A1')}\n  {ana(rb,'B1')}")
PY
