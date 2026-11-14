#!/bin/bash
# 审查补测 + v4.1 重跑 的总控：每项之前检查 6 台健康（不健康就等最多 90 s，仍不健康则记录并跳过）
set -uo pipefail
cd "$(dirname "$0")/.."
J=${IDS:-/tmp/ovr/poc_ids.json}; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
TS=$(date +%m%d%H%M); OUT=results/rest_$TS; mkdir -p $OUT
healthy_all(){ for i in $(seq 1 9); do bad=""; for r in a1 a2 a3 b1 b2 b3; do
    st=$(scripts/ssm.sh $(g router_$r) "grep -E 'SELF' /var/log/overlay-mesh.log | tail -1" 2>/dev/null | grep -c 'SELF healthy'); [ "$st" = 1 ] || bad="$bad $r"; done
    [ -z "$bad" ] && return 0; echo "  [等待健康]$bad"; sleep 10; done; echo "  [仍不健康]$bad"; return 1; }
run(){ name=$1; shift; echo "=== $name  $(date +%T)"; healthy_all || echo "  ！前置不健康，结果需人工判断"; "$@" > $OUT/$name.log 2>&1; grep -E "^###|32 条流|受影响|连接 |失败|中断|abort|applied|首个|switch_s|terraform 用时|ERR replace|25 s 后|状态|已停机|启动|已删除|确认" $OUT/$name.log | head -12; }
for s in ${ONLY_SP:-sdc untag-all untag-one crash forcestop n2 mismatch clock foreign deleted logrotate}; do run sp-$s bash mesh/special.sh $s; done
run t12-a1 bash mesh/t12_http.sh a1
run t12r-a1 bash mesh/t12_reverse.sh a1
run t12r-b2 bash mesh/t12_reverse.sh b2
run t15 bash mesh/t15_tgw.sh
run t16 bash mesh/t16_noapi.sh
run t17 bash mesh/t17_podsync.sh
run t17g bash mesh/t17_guards.sh
run t18-a3 bash mesh/t18_replace.sh a3
run xacct-setup bash mesh/xacct_sim.sh setup
run xacct-test bash mesh/xacct_sim.sh test
run xacct-restore bash mesh/xacct_sim.sh restore
echo "=== 完成 $(date +%T)"; healthy_all && echo "  全部健康"
