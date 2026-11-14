# vpc-overlay-mesh

**用 EC2 路由器 mesh + VXLAN over VPC peering，在迁移期打通「pod IP 在 VPC CIDR 之外」的旧容器网络与新 VPC。**

> ⚠️ **示例代码，按现状提供（AS IS）。** 这不是 AWS 托管服务，也不受 AWS Support 支持。使用者要自行完成代码评审、安全评审、测试和运维，并承担由此产生的风险。所有数据都来自实验环境，生产环境的规格、规模和账号结构不同，**上线前必须重新验证**（[测试报告 §6](docs/test-report.md#6-上线前必须在生产环境验证的事项)）。

## 要解决的问题

有些自建容器网络把 pod 地址放在 VPC CIDR **之外**，在 VPC 路由表里写「pod 段 → node ENI」，再由 node（关闭 source/dest check）把流量转进容器。迁移到新 VPC（pod IP 在 VPC 之内）的这段时间，老 pod 和新 VPC 之间必须互通：

| 路径 | 能否承载 VPC CIDR 外的 pod 地址 | 代价 |
|---|---|---|
| Transit Gateway | ✅ TGW 路由表 → VPC attachment → 子网路由表「pod 段 → node ENI」 | 每 GB 收数据处理费；迁移期跨边界流量大时，费用很高 |
| VPC peering | ❌ **目的地址不在对端 VPC CIDR 内的包会被丢弃**（实验实测）；包进入对端 VPC 之后不再查子网路由表 | 同 AZ 免费 |
| VGW / Private VIF | ❌ 只承载 VPC CIDR | — |
| 把 pod 段加为 secondary CIDR | ❌ 新 CIDR 不能大于等于现有路由的目的网段；加了之后 local 路由会覆盖「pod 段 → ENI」 | 有停服风险 |

## 方案

在两侧各放 N 台 EC2 路由器，**老 pod 的地址只出现在内层包里**，外层是路由器 ENI 的 VPC IP，所以可以跑在已有的 VPC peering 上：

```
老 VPC（pod IP 在 VPC 外）                                  新 VPC（pod IP 在 VPC 内）
 node 子网路由表：新 VPC 网段（拆段）→ A1 / A2 / A3            workload 子网路由表：pod 段（按组放进 prefix list）→ B1 / B2 / B3
        │                                                              │
   ┌────┴─────┐      VXLAN 全互联（A×B，每对一条隧道，VNI 唯一）     ┌───┴──────┐
   │ A1 A2 A3 │ ════════════════ VPC peering ═══════════════════ │ B1 B2 B3 │
   └────┬─────┘      Linux 多路径：按内层五元组哈希                 └───┬──────┘
        │ 解封装后经 transit 子网路由表（pod 段 → node ENI）投递             │ 解封装后在新 VPC 内直接投递
     old node → pod                                                  新 VPC 主机 / pod
```

- **全部 active**：所有路由器同时转发，按 N+1 冗余规划容量。
- **隧道段**：按流在所有对端之间做多路径，用类 BFD 的 UDP 探测；故障时**约 0.7–1.1 s 自动摘除，不调用任何 AWS API**。
- **入口段**：VPC 路由表的一条路由只能有一个下一跳，所以按网段（老侧）、按 prefix list 分组（新侧）分给不同的路由器。某台故障时，由同侧存活的路由器在 VPC 内调 `ReplaceRoute` 接管它负责的那几条路由，**约 1–2 s**。
- **自治**：没有外部控制器。故障判定要有多数派证据，探测回包里带健康标志，隔离判定要和同侧对比，收回网段前要满足 HOLD。这些规则都是为了防止误切、互抢和级联故障，见 [设计 §5](docs/design.md#5-高可用与自治切换规则)。
- **计划内维护零丢包**：drain → 同伴接管 → 维护或替换 → 健康满 HOLD 后自动收回。
- **随时降级**：入口路由改回 TGW（1–2 s，零丢包），TGW 路径在迁移期内全程保留。

## 实验结论（c8gn.large，每侧 3 台，生产参数 interval 0.3 s / detect 0.9 s / hold 10 s）

| 场景 | 结果 |
|---|---|
| 单台硬故障、软故障、内核崩溃、网卡故障 | 最长中断 0.95–1.95 s |
| 两台同时故障 | 1.38 s |
| drain、自动收回、滚动替换、进程挂起、单向不可达 | **0 丢包** |
| 同侧探测链路断开、时钟跳变、配置不一致、路由被人工改指或删除、成员发现结果异常 | 不误切，0 影响 |
| HTTP keep-alive / 短连接（客户端超时 1 s） | 失败 0.017% / 0.05%，都集中在故障后约 1 s 内 |
| 整体降级到 TGW 再恢复 | 0 丢包；TGW 路径 MTU 8500，PMTUD 正常 |
| 单台 c8gn.16xlarge 转发 | **200 Gbps**（两个方向之和），≥ 6 Mpps 无丢包 |
| EC2 API 不可用 | 隧道段约 1 s 恢复；入口段要等 API 恢复 |

完整数据见 [docs/test-report.md](docs/test-report.md)。

## 目录

| 路径 | 内容 |
|---|---|
| [docs/design.md](docs/design.md) | 设计：约束推导、方案对比、架构、高可用规则、容量与费用 |
| [docs/test-report.md](docs/test-report.md) | 测试报告：覆盖矩阵、结果、发现并修复的问题、生产验证清单 |
| [docs/operations-runbook.md](docs/operations-runbook.md) | 生产运维手册：部署、日常巡检、变更、监控告警、故障处置 |
| [docs/lab-runbook.md](docs/lab-runbook.md) | 实验环境手册：搭建、复现每个测试、清理 |
| `lab/mesh/overlay-mesh.py` | 路由器守护进程（Python 3，依赖 boto3、iproute2、iptables） |
| `lab/mesh/router-userdata.sh.tftpl` | 所有路由器共用的 user_data，身份由数据 ENI 的 tag 决定 |
| `lab/mesh/podroute_sync.py` | pod 路由同步：补齐 transit 路由表，维护 prefix list 成员（带护栏） |
| `lab/mesh/fallback_tgw.py` | 整体降级到 TGW / 恢复 |
| `lab/*.tf` | 实验环境 Terraform（两个 VPC、6 台路由器、测试主机、TGW 降级路径） |
| `lab/mesh/*.sh`、`lab/scripts/` | 测试脚本：故障场景、回归、长稳、吞吐 / PPS、限流、跨账号模拟 |

## 快速开始（实验环境）

```bash
cd lab
terraform init && terraform apply        # 约 5 分钟；费用约 $1.4/h（8 台 c8gn.large + interface endpoint + TGW）
mkdir -p /tmp/ovr && terraform output -json ids > /tmp/ovr/poc_ids.json
bash mesh/regression.sh R-a2-hard R-b2-drain   # 跑两个回归场景
terraform destroy
```

详细步骤见 [docs/lab-runbook.md](docs/lab-runbook.md)。

## 适用范围与限制

- 这是**迁移期的临时组件**：老 VPC 迁空后就应该下线。
- 入口段的故障切换依赖 EC2 API；API 不可用时，入口在故障路由器上的那部分流量要等 API 恢复。
- 入口按网段分配，不是按流。要在 VPC 路由表这一层按流做负载均衡，只能用 Gateway Load Balancer（每 GB 收费，MTU 8500）。
- 路由器和 workload 部署在同一个 AZ，不做 AZ 级冗余。
- 每侧最多 9 台路由器（受 VNI 编号方案限制）。
