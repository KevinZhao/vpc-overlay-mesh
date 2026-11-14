# 实验环境操作手册

> 用途：在一个测试账号里搭建两侧各 3 台路由器的实验环境，复现 [test-report.md](test-report.md) 里的每一项测试，最后清理。
> 环境：默认 `eu-central-1` / `euc1-az1`，可以通过变量 `region`、`az_id` 修改，要求该 AZ 有 c8gn 实例。没有 IGW，也没有公网 IP，全部通过 SSM 操作。
> **只能在测试账号里使用**：脚本会做故障注入，包括触发真实内核崩溃、强制停机、修改路由表和 ENI。

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 凭证 | 测试账号的 AWS 凭证；`aws sts get-caller-identity` 确认账号正确 |
| 工具 | terraform ≥ 1.5、aws CLI v2、python3、jq（可选） |
| Python 依赖 | 控制类脚本需要 boto3：`python3 -m venv /tmp/ovr/venv && /tmp/ovr/venv/bin/pip install boto3` |
| Shell | **一律用 bash 执行脚本**。zsh 不会按空格拆分 `$VAR`；macOS 自带的 bash 3.2 不支持 `declare -A`，脚本已经避开了这些写法 |
| 配额 | 日常需要约 16 vCPU；吞吐测试需要约 256 vCPU（4 台 c8gn.16xlarge） |
| 费用 | 日常约 $1.4/h（8 台 c8gn.large + 8 个 interface endpoint + TGW 两个 attachment）；吞吐测试额外约 $17/h |

## 1. 拓扑

```
VPC-OLD 10.110.0.0/16（旧容器网络）                    VPC-NEW 10.120.0.0/16（新架构）
  old-node    10.110.1.0/24  old-node 10.110.1.10        new-workload 10.120.1.0/24  new-host 10.120.1.10 / .70 / .140 / .200
              pod netns 100.64.10.10 / .70 / .140 / .200
  old-transit 10.110.10.0/24 A1 .10  A2 .12  A3 .13       new-transit  10.120.10.0/24 B1 .10  B2 .12  B3 .13
  old-mgmt    10.110.20.0/24 路由器主网卡、endpoints       new-mgmt     10.120.20.0/24
                    └──────────────── VPC peering（VXLAN 外层）────────────────┘
TGW（tgw.tf，降级路径）：两个 VPC 都挂在 transit 子网上；100.64.0.0/14 → 老 VPC 的 attachment
```

| 资源 | 说明 |
|---|---|
| 路由器 | `aws_instance.router["A1".."B3"]`，c8gn.large，AL2023 arm64 |
| 数据 ENI | `aws_network_interface.data["A1".."B3"]`，source/dest check 关闭；tag：`overlay-mesh=poc`、`overlay-side`、`overlay-name`、`overlay-index` |
| 入口路由 | 老侧 `rt-old-node`：4 个 /26 + 10.120.0.0/16。新侧 `rt-new-workload`：3 个 prefix list + 100.64.10.0/24 + 10.110.1.0/24。这两张表都打了 `overlay-managed=true` 标签 |
| 守护进程 | `lab/mesh/overlay-mesh.py`；配置来自 `terraform output mesh_config`，在路由器上是 `/etc/overlay-mesh.json`；日志在 `/var/log/overlay-mesh.log` |

## 2. 搭建

```bash
cd lab
terraform init && terraform apply                       # 约 5 min；路由器由 user_data 自动安装守护进程
mkdir -p /tmp/ovr
terraform output -json ids > /tmp/ovr/poc_ids.json      # 所有脚本都从这里读资源 ID
terraform output -raw mesh_config > /tmp/ovr/mesh_config.json
```

**第一次搭建后还要补两个手工步骤**，这两步没有放进 Terraform：

```bash
J=/tmp/ovr/poc_ids.json; g(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
# 1) new-host 的附加地址（VPC 层）。OS 层的地址：在 new-host 上建一个开机脚本，用 ip addr replace 加上 .70/.140/.200
NEWENI=$(aws ec2 describe-instances --instance-ids $(g new_host) \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
aws ec2 assign-private-ip-addresses --network-interface-id $NEWENI --private-ip-addresses 10.120.1.70 10.120.1.140 10.120.1.200
# 2) 测试服务：
#    new-host 上：flowprobe.py server 5300（绑定 4 个地址）、nginx（T12 用）
#    old-node 上：在 /usr/local/sbin/pod-up.sh 里追加 .70/.140/.200 三个 pod 地址；pod-http.service（T12-R 用）
#    把 lab/mesh/flowprobe.py、httpprobe.py 复制到 /usr/local/bin/（用 scripts/ssm.sh + base64 传输）
```

**检查状态**：

```bash
for r in router_a1 router_a2 router_a3 router_b1 router_b2 router_b3; do
  scripts/ssm.sh $(g $r) "grep -E 'MEMBERS|SELF|SIDE|TUN' /var/log/overlay-mesh.log | tail -3"
done
# 32 条流冒烟测试：全部 lost 0 才算正常
scripts/ssm.sh $(g old_node) "ip netns exec pod python3 /usr/local/bin/flowprobe.py client --src 100.64.10.10,100.64.10.70,100.64.10.140,100.64.10.200 --dst 10.120.1.10,10.120.1.70,10.120.1.140,10.120.1.200 --per 2 --interval 0.02 --duration 4" 60
```

正常状态应该是：每台都有 `SELF healthy`，`SIDE alive` 包含同侧 3 台，`TUN up` 包含对侧 3 台。

**升级守护进程或修改配置**：存量实例的 user_data 被 `ignore_changes`，只能推送；推送前会自动把旧文件备份成 `.prev`。

```bash
terraform apply && bash mesh/push.sh                   # 推送到 6 台；ROUTERS="router_a2" bash mesh/push.sh 只推一台
```

## 3. 测试用例

| 用例 | 命令 | 说明 |
|---|---|---|
| 回归（13 个场景） | `bash mesh/regression.sh [场景 ...]` | hard / soft / drain / sidelink / 两台同时故障 / netdrop / flap / oneway / tunnelcut / fwdrop / sigstop / linkdown；每个场景输出一行汇总 |
| 单个故障场景 | `bash mesh/scenario.sh <a1[,a2]> <hard\|soft\|drain\|sidelink\|netdrop\|flap\|oneway\|tunnelcut\|fwdrop\|sigstop\|linkdown> [秒]` | 32 条流；输出受影响的流、最长中断，以及各路由器的决策日志 |
| 特殊场景 | `bash mesh/special.sh <sdc\|untag-all\|untag-one\|crash\|forcestop\|n2\|mismatch\|clock\|foreign\|deleted\|logrotate>` | 会修改 ENI 属性和 tag、触发真实内核崩溃、强制停机、摘下再挂回 ENI，结束时自动恢复 |
| HTTP，老侧发起 | `bash mesh/t12_http.sh <路由器>` | 需要 new-host 上的 nginx |
| HTTP，新侧发起 | `bash mesh/t12_reverse.sh <路由器>` | 需要 old-node 上的 pod-http.service |
| 过载误判 | `bash mesh/t14_overload.sh <interval> <detect>` | 会临时下发探测参数；**测完执行 `bash mesh/push.sh` 恢复** |
| 降级到 TGW | `bash mesh/t15_tgw.sh` | 依赖 `tgw.tf`；内部调用 `mesh/fallback_tgw.py down/restore` |
| EC2 API 不可用 | `bash mesh/t16_noapi.sh` | 先把老 VPC 里 EC2 endpoint 的 IP 写进 `/tmp/ovr/ec2_ep_old.txt`（获取方法见 §5） |
| pod 路由同步 | `bash mesh/t17_podsync.sh` | 临时建 pod2 netns 和 100.64.11.0/24，结束时清理 |
| 同步工具护栏 | `bash mesh/t17_guards.sh` | 空表 / 删除超限 / PL 满三种情况 |
| 滚动替换 | `bash mesh/t18_replace.sh <路由器>` | 执行 `terraform apply -replace`，约 6 min；自动更新 ID 文件 |
| 长稳 | `bash mesh/t19_soak.sh [秒]` | 每 600 s 对一台路由器注入一次 15 s 硬故障 |
| 跨账号模拟 | `bash mesh/xacct_sim.sh setup\|test\|restore` | 两侧 tag 改成 poc-a / poc-b，对侧成员走 `static_peers`；**测完必须执行 restore** |
| 路由规模 | `/tmp/ovr/venv/bin/python scripts/t11_route_scale.py <空路由表> <eni-x> <eni-y> 150` | 测完会自动删除这 150 条路由 |
| 吞吐 / PPS | `bash scripts/t4_perf.sh "<名称>" "<iperf3 参数>"` | 先按 §4 升配，并把 A2/A3/B2/B3 设为 drain |
| 总控 | `ONLY_SP="..." caffeinate -i bash mesh/run_rest.sh` | 每一项之前检查 6 台是否健康；`caffeinate` 防止电脑睡眠（macOS） |

所有故障注入都是**可逆**的：
- hard = 停守护进程 + iptables 丢弃 4789 和 FORWARD；
- soft = 关 `ip_forward`；
- drain = 建 `/etc/overlay-mesh.drain` 文件；
- 其余场景见脚本里的注释。

脚本会在约定的时刻自动恢复。如果脚本中途被打断，按 §6 手工恢复。

## 4. 升配 / 降配（吞吐测试）

```bash
bash -c 'IDS="$(g router_a1) $(g router_b1) $(g old_node) $(g new_host)"
aws ec2 stop-instances --instance-ids $IDS && aws ec2 wait instance-stopped --instance-ids $IDS
for i in $IDS; do aws ec2 modify-instance-attribute --instance-id $i --instance-type Value=c8gn.16xlarge; done
aws ec2 start-instances --instance-ids $IDS && aws ec2 wait instance-running --instance-ids $IDS'
```

测完一定要改回 c8gn.large。改规格后网卡名会变，守护进程按 IP 识别网卡，不受影响。RPS 等调优参数不会持久化。

## 5. 常用命令

```bash
# 路由器日志（从某个时刻开始）
scripts/ssm.sh <iid> "awk -v t=<epoch> '\$1>=t' /var/log/overlay-mesh.log | head -50"
# 冻结 / 解冻入口路由表
aws ec2 create-tags --resources <rtb> --tags Key=overlay-freeze,Value=true
aws ec2 delete-tags --resources <rtb> --tags Key=overlay-freeze
# drain / 解除 drain
scripts/ssm.sh <iid> "touch /etc/overlay-mesh.drain"
scripts/ssm.sh <iid> "mv -f /etc/overlay-mesh.drain /tmp/"
# pod 路由同步（默认 dry-run）
/tmp/ovr/venv/bin/python mesh/podroute_sync.py --src-rt <rt-old-node> --transit-rt <rt-old-transit> \
  --pl <pl-g1> <pl-g2> <pl-g3> --pool 100.64.0.0/14 --keep 100.64.10.0/24 [--apply]
# 老 VPC 里 EC2 endpoint 的 IP（T16 用）
aws ec2 describe-vpc-endpoints --filters Name=service-name,Values=com.amazonaws.<region>.ec2 \
  --query 'VpcEndpoints[].NetworkInterfaceIds' --output text
```

## 6. 中断后的恢复与排查

1. **故障注入被打断**：在被注入的路由器上执行
   `iptables -D FORWARD -j DROP; iptables -D INPUT -p udp --dport 4789 -j DROP; iptables -t raw -F; sysctl -w net.ipv4.ip_forward=1; mv -f /etc/overlay-mesh.drain /tmp/; systemctl start overlay-mesh`
   可以多执行几次，规则不存在时只是报错，没有影响。
2. **special.sh / xacct_sim.sh 被打断**：
   - 数据 ENI 是否都在 in-use：n2 会摘下 B3 的 ENI，用 `aws ec2 attach-network-interface --device-index 1` 挂回；
   - tag 是否都是 `overlay-mesh=poc`；
   - 实例是否都在 running；
   - 入口路由是否都在、是否指向 home：foreign 会把一条路由改到 TGW，deleted 会删掉一条路由；
   - 最后执行 `bash mesh/push.sh`，把统一配置推回所有路由器。
3. **pod 流量全部不通，但 node IP 能通**：在路由器上执行 `ip route | grep -v 'proto 199'`，查有没有残留的 pod 段路由，特别是 blackhole；再执行 `ip route get <pod IP> from <源> iif <数据网卡>`，看实际选中的是哪条路由。
4. **新实例没有加入 mesh**：
   - 看 `/var/log/poc-dnf.log`：开机时 rpm 锁冲突会导致 dnf 失败，user_data 有 30 次重试，用 `rpm -q iptables-nft python3-boto3` 校验；
   - 看守护进程日志里有没有 `WAIT` 和 `SELF healthy`。
5. **本机重启后 `/tmp/ovr` 被清空**：按 §2 重新生成 ID 文件和 mesh 配置，并重建 venv。
6. **SSM 报 InvalidInstanceId**：检查 `AWS_REGION` 环境变量；`scripts/ssm.sh` 默认使用 `POC_REGION=eu-central-1`。
7. **Terraform state 漂移**：
   - 用 CLI 挂载过的 ENI，`terraform destroy` 之前先 `detach-network-interface --force`；
   - 入口路由和 prefix list 的条目都设了 `ignore_changes`，不会被 Terraform 回滚。

## 7. 清理

```bash
cd lab
# 如果用 CLI 挂载过 ENI（例如 n2 中断后手工挂回），先卸下，否则 destroy 会因为 ENI 正在使用而失败
terraform destroy
aws ec2 describe-instances --filters Name=tag:Project,Values=overlay-mesh-poc Name=instance-state-name,Values=running,stopped \
  --query 'length(Reservations[].Instances[])'      # 应该为 0
```

本地临时文件在 `/tmp/ovr/`，可以随时删除。
