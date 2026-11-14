#!/bin/bash
# 定稿代码（v4）+ 生产参数的回归：原有场景重跑 + 审查新增场景。每个场景一份日志，最后汇总一行一个。
# 用法：bash mesh/regression.sh [场景名 ...]   不带参数 = 全部
set -uo pipefail
cd "$(dirname "$0")/.."
TS=$(date +%m%d%H%M)
ALL="R-a2-hard R-b3-hard R-a1-soft R-b2-drain R-b1-sidelink R-a1a2-hard N-a1-netdrop N-a1-flap N-a2-oneway N-b1-tunnelcut N-a3-fwdrop N-b2-sigstop N-a1-linkdown"
LIST=${*:-$ALL}
summ(){ f=$1; echo "$(head -1 $f | sed 's/^### //') ｜ $(grep -E '合计' $f | sed 's/^ *合计：//') ｜ TAKE $(grep -c 'TAKE' $f) 次（failback $(grep -c 'failback' $f)） ｜ $(grep -oE 'UNHEALTHY reason=[a-z_-]+' $f | sort -u | tr '\n' ' ')$(grep -q ISOLATED $f && echo ' ISOLATED')"; }
for sc in $LIST; do
  IFS=- read -r kind who mode <<< "$sc"
  who=$(echo $who | sed 's/a1a2/a1,a2/')
  f=results/reg_${sc}_$TS.log
  dur=15; [ "$mode" = flap ] && dur=62
  LOGN=40 bash mesh/scenario.sh $who $mode $dur > $f 2>&1
  summ $f
done
