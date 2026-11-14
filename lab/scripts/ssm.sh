#!/bin/bash
# 用法：ssm.sh <instance-id> '<shell command>' [timeout_s]
# 通过 SSM RunShellScript 执行命令，打印 stdout/stderr
set -euo pipefail
IID="$1"; CMD="$2"; TO="${3:-120}"; REGION="${POC_REGION:-eu-central-1}"
PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":[sys.argv[2]]}))' "$CMD" "$TO")
CID=$(aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
      --parameters "$PARAMS" --timeout-seconds 60 --query Command.CommandId --output text)
for _ in $(seq 1 $((TO+30))); do
  ST=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)
  case "$ST" in Success|Failed|TimedOut|Cancelled) break;; esac
  sleep 1
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
