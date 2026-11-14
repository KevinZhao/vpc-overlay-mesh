# 迁移期自建转发（EC2 路由器全 active mesh）生产运维手册

> **适用范围**：旧容器网络 VPC（pod IP 在 VPC 外）与新架构 VPC（pod IP 在 VPC 内）之间，老 pod ↔ 新 VPC 的跨边界流量。老 VPC 迁空后下线。
> **状态**：v0.2（对应守护进程 v4.2）。所有步骤和数字都来自实验环境（[test-report.md](test-report.md)）。**生产上线前，必须先完成 §9 的待办，并在生产环境做一次演练**。
> **相关**：
> - 设计：[design.md](design.md)
> - 实验环境手册：[lab-runbook.md](lab-runbook.md)
> - 代码：`lab/mesh/`
>
> **生产安全**：本手册里所有改动路由表、ENI、实例的操作，都只在**已批准的变更窗口**内执行，并提前通知相关网络团队；业务高峰和封网期间不执行。

---

## 1. 组件清单

| 组件 | 老侧 | 新侧 | 说明 |
|---|---|---|---|
| transit 子网 | 每个 AZ 一个，例如 /27 | 同左 | 只放路由器的数据 ENI。**老侧 transit 子网的路由表必须包含全部 `pod 段 → node ENI`**（由 pod 路由同步维护） |
| 路由器 | A1…An（c8gn.16xlarge） | B1…Bn | 全部同时转发，N+1 冗余；台数 = ⌈峰值 ÷ 140 Gbps 或 4.2 Mpps⌉ + 1（[design.md](design.md) §6） |
| 数据 ENI | 每台 1 块，source/dest check 关闭 | 同左 | tag：`overlay-mesh=<名称>`、`overlay-side=a/b`、`overlay-name=A1`、`overlay-index=1..9`。**ENI 和实例分开管理**，替换实例时 IP 不变 |
| 安全组 | 数据 ENI：入、出都是 0.0.0.0/0 全放行（连接不被跟踪）；访问控制交给 NACL | 同左 | NACL 只放行：对端 transit 子网的 UDP 4789 / 3784 / 3785，以及本侧业务网段 |
| EC2 interface endpoint | 管理子网 | 同左 | 路由器在 VPC 内调 ReplaceRoute，延迟约 45 ms；本机调用要 0.8 s |
| IAM 角色 | DescribeRouteTables、DescribeNetworkInterfaces；**只能对打了 `overlay-managed=true` 的路由表执行 ReplaceRoute** | 同左 | 每侧只能改本账号的路由表 |
| 入口路由 | 老 node 子网路由表：新 VPC 网段拆成若干段（/20～/22），每段 home 一台 A | 新 workload 子网路由表：**pod 段按路由器分组放进 PL**（每台 B 一个 PL），每个 PL 一条路由 | 每侧路由条目 ≤ 50（`ReplaceRoute` 桶容量）；PL 按 max entries 计入路由表配额 |
| 守护进程 | `overlay-mesh.py`（systemd `overlay-mesh`） | 同左 | 配置 `/etc/overlay-mesh.json`；日志 `/var/log/overlay-mesh.log` |
| pod 路由同步 | `podroute_sync.py`：用 EventBridge 定时触发 Lambda 时最短 1 min 一次；要做到 30 s 以内，就在一台小实例上以 systemd 常驻循环运行 | — | 以老 node 子网路由表为准：补齐 transit 路由表，新 pod 段加入 PL |
| 降级路径 | TGW 侧的 attachment 和路由**在迁移期内一律不删** | 同左 | L3 降级 = 入口路由改指 TGW（§6.2） |

**参数**：`interval 0.3 s`、`detect 0.9 s`、`hold 10 s`、`discover 10 s`。

**实测基线**（v4.2，c8gn.large，每侧 3 台，实验环境，详见[design.md](design.md) §5）：

| 指标 | 数值 |
|---|---|
| 单台硬故障 / 软故障 / 内核崩溃 / 网卡故障 | 最长中断 0.95–1.95 s |
| 两台同时故障 | 1.38 s |
| 只断隧道（同侧互探正常） | 3.5 s |
| 计划内 drain / 收回 / 滚动替换 / 进程挂起 | 0 丢包 |
| HTTP keep-alive（1 s 超时） | 失败 0.017%，只影响入口在故障路由器上的连接；短连接失败 0.05%，都在故障后约 1 s 内 |
| 降级到 TGW / 恢复 | 0 丢包 |
| 单台 c8gn.16xlarge | 200 Gbps（两个方向之和），≥ 6 Mpps 无丢包 |
| 注意 | **内核崩溃 40 s 后 EC2 状态检查仍然是 ok**，路由器故障只能靠守护进程自己的探测发现 |

---

## 2. 首次部署

**前置检查**（每一项都要留记录）：

1. 使用方已经提供 老侧的路由表清单，确认老 node 子网路由表的数量（决定每次切换要改多少张）和现有条目数（配额）。
2. 跨边界流量的峰值和平均包长已经算出来（来源：CloudWatch 的 EC2 指标：每台实例的 `NetworkIn`/`NetworkOut`（字节）除以 `NetworkPacketsIn`/`NetworkPacketsOut`（包数）就是平均包长，按 workload 汇总取峰值），据此算出每侧台数（[design.md](design.md) §6）。
3. 双方确认 NACL / SG 方案。数据 ENI 的 SG 全放行，是为了不被连接跟踪（`conntrack_allowance` 不会耗尽，切换后连接状态也不丢）。
4. **§9 第 1 项（跨账号发现）已经解决。**

**步骤**：

| # | 操作 | 验证 |
|---|---|---|
| 1 | 两侧建 transit 子网、NACL、SG、EC2 endpoint、IAM（Terraform：参考 `lab/main.tf`，按生产网段改写） | `terraform plan` 只有新增 |
| 2 | 建数据 ENI 并打 tag；建路由器实例，使用通用 user_data（`lab/mesh/router-userdata.sh.tftpl`）；挂载数据 ENI | 每台日志出现 `MEMBERS me=…`、`SELF healthy`；`TUN up=` 包含对侧全部路由器；`SIDE alive=` 包含同侧全部；`iptables -t mangle -S FORWARD` 能看到 TCPMSS 规则 |
| 3 | 建 PL（每台 B 一个，`max_entries` 留出 node 扩容余量），Terraform 加 `ignore_changes = [entry]`；先用 dry-run 跑一次 pod 路由同步，确认没有误操作后再 `--apply` | transit 路由表包含全部 pod 段；PL 条目总数 = pod 段数 |
| 4 | **空载观察 48 h**：入口路由先不指向路由器 | 守护进程没有重启，没有出现 `ISOLATED` / `FAILSTATIC` |
| 5 | 选一个低风险的老 node 子网和一个新侧 PL：两侧用 replace-route 把这部分入口切到路由器（老侧 1 段、新侧 1 个 PL） | 用 canary 双向探测（参考 `lab/mesh/flowprobe.py`）；TGW 的 bytes 相应下降；观察 72 h |
| 6 | 每扩大一批之前，先做一次切换演练：任选一台 drain 再收回（应该 0 丢包），再做一次 L3 降级和恢复 | 演练记录 |
| 7 | 逐批扩大；单台负载接近 70% 时扩容（§4.4） | CloudWatch ENA 指标（§7） |

**回退**（任何阶段都适用）：执行 §6.2 的 L3 降级，入口路由全部改回 TGW。

---

## 3. 日常巡检

```bash
# 每台路由器
systemctl is-active overlay-mesh
grep -E 'SELF|ISOLATED|FAILSTATIC|ERR|STALE' /var/log/overlay-mesh.log | tail     # 不应该有新的 ERR / ISOLATED
ip route show proto 199            # 守护进程管理的路由；ip route | grep -v 'proto 199' 中不应出现 pod / 隧道网段
ethtool -S <数据网卡> | grep allowance_exceeded   # 持续增长 = 接近实例规格上限
# 入口路由归属：每条入口路由应该指向它 home 的 ENI（除非 home 正在 drain 或故障）
aws ec2 describe-route-tables --route-table-ids <rt...> --query 'RouteTables[].Routes[?NetworkInterfaceId]'
# pod 路由同步：dry-run 应该没有动作
python3 podroute_sync.py ... （不加 --apply）
```

---

## 4. 变更操作

### 4.1 计划内维护（打补丁、重启单台）：零丢包

1. `touch /etc/overlay-mesh.drain`：自检不通过，路由器停止应答探测，但**照常转发**。
2. 等约 2 s：同侧存活的路由器接管它负责的入口路由（日志 `TAKE takeover-from-<它>`），对侧把它从多路径中摘除（`TUN … down=<它>`）。
3. 确认它的数据网卡上已经没有业务流量（`sar -n DEV 1` 或 perfsnap）。
4. 执行维护操作。
5. `mv /etc/overlay-mesh.drain /tmp/`：健康满 `hold`（10 s）后，它自己收回入口路由（日志 `TAKE failback`）。

实测：drain 和收回全程 0 丢包。

### 4.2 滚动替换（换 AMI、换机型）：零丢包，每台约 5 min

1. 按 §4.1 drain。
2. `terraform apply -replace='aws_instance.router_a["A2"]'`：先拆数据 ENI（约 3.5 min），再销毁并新建实例，然后挂回同一块 ENI，IP 不变。
3. 新实例通过 user_data 自动安装守护进程，从 ENI tag 认出自己，健康满 10 s 后收回路由。
4. 确认 `MEMBERS`、`SELF healthy`、`TAKE failback` 这几条日志都出现了，再替换下一台。**不要同一侧同时替换两台。**

实测：360 s 全程 32 条流 0 丢包。

### 4.3 升级守护进程 / 修改配置

1. 先在实验环境里验证新版本。
2. 一台一台来：drain → 推送新版本（user_data 或 SSM）→ 重启服务 → 确认健康 → 解除 drain。
3. **新旧版本会共存一段时间**：探测回包的格式必须向后兼容（v4.1 修过：v4 解析不了 v3 的回包）。每个新版本都要在实验环境里，用「一半旧、一半新」的组合跑一遍回归（`lab/mesh/regression.sh`）。
4. **从没有 proto 标记的旧版本升级时**，先手工删除旧版装的 pod / 隧道网段路由，再启动新版。
   - 原因：守护进程只清理带 `proto 199` 的残留路由。实验中出现过旧版留下的 `/24` blackhole 在 ENI 拆下时吞掉了全部 pod 流量。
5. 修改隧道网段、eth 网段等配置时，同样要确认 `ip route | grep -v 'proto 199'` 里没有残留。
6. 配置要**同时推到所有路由器**。推送期间，配置哈希不一致的路由器会报 `CONFIG-MISMATCH`，只接管、不收回，等全部推完就会恢复。

### 4.4 扩容（加路由器）

1. 新建数据 ENI，tag 中的 `overlay-index` 用一个没有用过的序号（1–9）；建实例并挂载。
2. 其他路由器会在 `discover` 周期（10 s）内自动发现它，建隧道、更新多路径。**不需要改其他路由器的配置。**
3. 给它分配入口：在配置的 `entries` 里加上以它为 home 的段 / PL，然后逐台推送配置；或者在 PL 之间重新分配 pod 段。
4. 验证它的 `TAKE failback`，以及负载分布。

### 4.5 缩容

1. 先把以它为 home 的入口改到其他路由器（改配置并推送）。
2. drain，确认已经没有流量。
3. 卸下数据 ENI 或终止实例：其他路由器连续 3 次（约 30 s）发现不到它，才会把它移出成员列表并删除隧道。这是防抖，避免一次查询结果为空就拆光隧道。
4. **不要用删 tag 的方式下线路由器**：被删 tag 的路由器在防抖期结束前仍然是 home，防抖期结束后它的入口会中断约 3.6 s，直到同伴接管（实测 untag-one）。

### 4.6 pod 段增减（旧容器网络 node 上下线）

- 由 pod 路由同步工具自动处理：transit 路由表补路由或删路由，PL 加段或减段。实测从同步开始到连通 4.5–9.2 s。
- 护栏：单次删除超过 `--max-delete`（默认 5 条）、权威路由表为空、PL 已满，这三种情况都会中止，需要人工确认。
- 跨账号：transit 路由表在老侧账号，PL 在新侧账号，PL 那一侧用 `--pl-role-arn` assume 到新侧账号的角色。
- 工具**只修改 description = `pod (sync)` 的 PL 条目**，其他条目不动；每个 PL 一次调用，等 `modify-complete` 后再处理下一个。
- **PL 快满时**（条目数接近 max entries）要提前扩容：修改 max entries 会影响路由表配额，或者新增一个 PL 和一台路由器。

### 4.7 版本 / 配置回滚

- **保留上一个版本**：每台路由器上留一份 `/usr/local/sbin/overlay-mesh.py.prev` 和 `/etc/overlay-mesh.json.prev`。升级脚本覆盖文件之前，先把当前文件复制成 `.prev`。
- **回滚**：逐台执行「drain → 把 `.prev` 复制回原文件 → `systemctl restart overlay-mesh` → 确认 `SELF healthy` 和 `TUN up` 包含全部对端 → 解除 drain」。
- **配置回滚要一次推完所有路由器**。推送期间出现 `CONFIG-MISMATCH` 是正常的，推完之后应该消失。
- 如果回滚之后仍然异常，执行 §6.2，整体降级到 TGW。

### 4.8 替换路由器时容量不足（ICE）

- 替换实例之前，先确认目标 AZ 有同规格的容量：可以先 `run-instances --dry-run`；重要窗口可以预留 ODCR。
- 新实例起不来：
  - 旧实例保持 drain 状态，**先不要终止**，入口已经由同伴承担；
  - 换一个同系列的规格（例如 c8gn.12xlarge / 24xlarge），数据 ENI 的 tag 不变；
  - 按 [design.md](design.md) §6 核对剩余台数够不够承载峰值，不够就先降级一部分入口到 TGW（只改这些段的下一跳，并给路由表打冻结标签）。

---

## 5. 自动处置（不需要人工介入）

| 事件 | 守护进程的行为 | 预期影响 |
|---|---|---|
| 单台路由器宕机或硬故障 | 对侧在约 0.9 s 内把它从多路径中摘除；同侧多数派确认后，按 rendezvous hash 分配接管者，只改下一跳是它的入口路由 | 隧道段 0.7–1.1 s，入口段 1.4–1.8 s |
| 路由器软故障（`ip_forward` 被关、FORWARD 链有 DROP、source/dest check 被打开、数据网卡 down、依赖或 MSS 规则丢失、数据面线程卡住） | 自检失败，**回包里带上 ok=false**（照常应答），对侧把它移出 ECMP，同侧接管它的入口 | 0.55–2 s；source/dest check 要等成员发现，最长 10 s |
| 同侧之间的探测链路断开 | 隧道对端仍然报告它存活，**不切换** | 无 |
| 单向不可达（只有它的回包被丢） | 被接管一次；恢复后等满 HOLD 才收回，**不会互抢** | 入口段约 1.2 s |
| 本机被单独隔离（看不到一半以上对端，而同伴看得到） | `ISOLATED` → 持续超过 1.8 s 判自己不健康，让同伴接管；不再隔离 3 s 之后才恢复健康 | 约 1.5–3.5 s |
| **全体**都看不到对端（pcx 断开、对侧大面积故障） | 谁都不下线，`FAILSTATIC` 保留最后一组下一跳；隧道网段有 blackhole 兜底，**不会漏到默认路由**；需要人工按 §6.2 降级 | 直到人工降级 |
| 路由器反复抖动 | 恢复后要健康满 HOLD、并且被对端持续看到满 HOLD 才收回；每条路由 10 s 内最多切换一次，60 s 内切换 3 次后退避到 60 s | 不会来回切 |
| 入口路由被人工改到 TGW 或其他目标、或者被删掉 | **不碰**，视为人工操作 | 无 |
| 推送配置期间各台配置不一致 | `CONFIG-MISMATCH`：只接管、不收回 | 无 |
| EC2 API 慢或不可用 | 调 API 的线程卡住只告警（`WARN thread-…`），不判不健康 | 见 §6.3 |
| 故障路由器恢复 | 健康满 10 s，并且被多数对端看到满 10 s，才收回入口路由 | 0 丢包 |

---

## 6. 人工处置

### 6.1 单台故障之后

1. 确认接管完成：存活路由器的日志里有 `TAKE takeover-from-<故障台>`，入口路由已经指向存活路由器。
2. 定位原因，例如 EC2 状态检查、`journalctl -u overlay-mesh`、`dmesg`。
3. 修复后按 §4.2 替换，或者直接恢复，它会自己收回路由。

### 6.2 整体降级回 TGW（L3）：一侧全部故障、软件 bug、性能异常、需要紧急回退时

```bash
# 降级：先冻结入口路由表（守护进程不再修改），等 3 s，再把所有入口路由并发改到 TGW
python3 fallback_tgw.py down --config /etc/overlay-mesh.json --tgw <tgw-id> --sides a,b
# 恢复：入口路由改回各自 home 的 ENI，然后解除冻结
python3 fallback_tgw.py restore --config /etc/overlay-mesh.json --tgw <tgw-id> --sides a,b
```

- 实测：降级 10 条路由用 1.16 s，恢复用 1.9 s，32 条流没有 ≥ 50 ms 的中断。
- **TGW 的 MTU 是 8500，PMTUD 正常**（会回 `Frag needed`），不需要先改 pod / node 的 MTU。
- 前提：TGW 路由表里，老 pod 段静态指向老 VPC 的 attachment；attachment 子网的路由表里有 `pod 段 → node ENI`。**迁移期这些配置一律不删。**
- 手工方式（没有脚本时）：给入口路由表打 `overlay-freeze=true` 标签，然后逐条执行 `aws ec2 replace-route ... --transit-gateway-id <tgw>`。

### 6.3 EC2 API 不可用

- 隧道段照常自愈，因为它不依赖 API。
- 入口段**只能等 API 恢复**：守护进程每 0.5–3 s 重试一次，API 恢复后 1 s 内补上。
- 期间如果又有路由器故障，入口在它上面的那部分流量会中断，直到 API 恢复。这是自建方案的固有风险，每侧台数越多，影响的比例越小（1/N）。

### 6.4 过载

- 现象：`ethtool -S` 的 `allowance_exceeded` 持续增长，日志里 `TUN` 反复抖动、出现 `FAILSTATIC` / `ISOLATED`。
- 临时处置：把这台路由器 home 的一部分入口段改到负载低的路由器上（改配置中的 home 并推送）；或者整台 drain，让其他路由器分担。
- 根本处置：按 §4.4 扩容。

### 6.5 黑洞 / 不通排查

1. pod 不通、node IP 通：查路由器上的残留路由（§4.3 第 3 条），查 transit 路由表有没有这个 pod 段（pod 路由同步），查 PL 里有没有这个段。
2. 只有部分 pod 不通：`ip route get <pod> from <源> iif <数据网卡>`，看选中的是哪个下一跳；对端的 eth 路由和 transit 路由表是否完整。
3. 大包不通、小包通：MTU。隧道内层是 8951，路由器上有 MSS clamp；走 TGW 时是 8500，靠 PMTUD。

### 6.6 pcx 整体中断 / 全体 FAILSTATIC

- **现象**：
  - 两侧所有路由器的日志里，`TUN up=` 都是空的，持续出现 `FAILSTATIC`；
  - 所有 canary 同时失败；
  - 守护进程**不会**自动降级：全体都看不到对端时，谁都不下线。这是为了避免级联，所以需要人工判断。
- **判断**：
  1. 先查 peering 状态：`aws ec2 describe-vpc-peering-connections`，看是否 active，两侧 transit 子网路由表里指向 pcx 的路由是否还在；
  2. 再查 NACL / SG 最近有没有变更（CloudTrail）；
  3. 在一台路由器上抓包：`tcpdump -ni <数据网卡> udp port 4789`，看有没有收发。
- **处置**：
  - 5 分钟内无法恢复，就执行 §6.2，整体降级到 TGW；
  - peering 恢复之后，确认所有 `TUN up=` 都恢复了，再执行 `restore`。

---

## 7. 监控与告警

> 下面的配置**由使用方实施**。实验环境里只验证了日志关键字和 ENA 计数，CloudWatch 的告警链路没有端到端验证过，上线前要逐条触发一次。

### 7.1 采集（CloudWatch agent，每台路由器）

```json
{
  "logs": { "logs_collected": { "files": { "collect_list": [
    { "file_path": "/var/log/overlay-mesh.log", "log_group_name": "/overlay-mesh/router", "log_stream_name": "{instance_id}" }
  ] } } },
  "metrics": { "namespace": "OverlayMesh", "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "procstat": [ { "pattern": "overlay-mesh.py", "measurement": ["pid_count", "memory_rss", "cpu_usage"] } ],
      "ethtool":  { "interface_include": ["ens*"], "metrics_include": [
        "bw_in_allowance_exceeded", "bw_out_allowance_exceeded", "pps_allowance_exceeded",
        "conntrack_allowance_exceeded", "linklocal_allowance_exceeded" ] },
      "net": { "resources": ["*"], "measurement": ["bytes_sent", "bytes_recv", "packets_sent", "packets_recv", "drop_in", "drop_out"] }
  } }
}
```

### 7.2 日志 metric filter（log group `/overlay-mesh/router`）

| 指标名 | filter pattern | 含义 |
|---|---|---|
| `Takeover` | `"TAKE takeover-from"` | 发生了接管（有路由器故障或 drain） |
| `Failback` | `"TAKE failback"` | 收回 |
| `Unhealthy` | `"SELF UNHEALTHY"` | 有路由器自检失败（看 reason） |
| `Isolated` | `"ISOLATED"` | 路由器看不到一半以上的对端 |
| `FailStatic` | `"FAILSTATIC"` | 所有隧道对端同时不可用 |
| `ConfigMismatch` | `"CONFIG-MISMATCH"` | 同侧配置不一致 |
| `MemberGone` | `"MEMBER-GONE"` | 有成员被移出 |
| `ApiError` | `"ERR replace"` 或 `"ERR describe"` | EC2 API 调用失败 |
| `ThreadStall` | `"WARN thread-"` | 调 API 的线程长时间卡住 |
| `StaleRoute` | `"STALE removed"` | 清理了残留路由（升级、改配置之后偶尔出现属于正常） |

### 7.3 告警

| 告警 | 条件 | 级别 | 处置 |
|---|---|---|---|
| 守护进程不在 | `procstat pid_count < 1`，持续 1 min | P1 | §6.1 |
| 有路由器自检失败 | `Unhealthy ≥ 1`（5 min 窗口） | P2 | 看日志里的 reason；drain 状态属于预期 |
| 接管发生 | `Takeover ≥ 1` | 通知 | 确认原因，§6.1 |
| 全体隧道不可用 | `FailStatic`：同一侧超过一半的路由器在 1 min 内都出现 | **P1** | §6.6 |
| 隔离 | `Isolated` 持续 3 min | P2 | 查本机负载和网卡（§6.4 / §6.5） |
| 配置不一致 | `ConfigMismatch` 持续 10 min | P3 | 推完配置（§4.3） |
| API 失败 | `ApiError ≥ 5`（5 min）或者 `ThreadStall ≥ 1` | P2 | §6.3；期间如果有路由器故障，入口切换会被推迟 |
| 带宽 / PPS 余量 | 网卡字节或包数超过规划值 70%，持续 15 min | P3 | §4.4 扩容 |
| ENA 超限 | `*_allowance_exceeded` 的增量 > 0，持续 5 min | P2 | §6.4 |
| 入口归属偏离 home | 定时任务比对路由表和配置，偏离超过 5 min | P3 | 正常情况下故障恢复后 10–30 s 内会收回；长时间偏离要检查 HOLD 条件 |
| pod 路由不同步 | 同步工具 dry-run 有差异，连续 2 次 | P2 | §4.6 |
| **canary 失败** | 每对「pod ↔ 新 VPC 主机」双向探测，丢包 > 1%，持续 1 min | **P1** | §6.5 / §6.6 |

**不要依赖 EC2 状态检查**：实测内核崩溃 40 s 后，状态检查仍然是 ok。路由器故障只能靠守护进程的探测和 canary 来发现。

### 7.4 Canary

- 两侧每个入口分组（老侧每个网段、新侧每个 prefix list）各选一对固定的「pod ↔ 新 VPC 主机」，持续跑双向探测（UDP 或 TCP，可以参考 `lab/mesh/flowprobe.py`），把丢包率作为 CloudWatch 自定义指标上报。
- canary 本身要跨越路由器，从路由器上直接发包不算。

## 8. 已知限制

1. 入口段的故障切换依赖 EC2 API（§6.3）。
2. 入口按网段分配，不是按流，负载均衡粒度受网段大小影响；要做到真正的按流均衡只能用 GWLB（约 $0.0077/GB，MTU 8500，健康检查最快约 10 s）。
3. pod 段和 PL 的规模：每个 PL 的 max entries 计入路由表配额（默认 500 / 张，可申请提高）。
4. 过载时本机自身会丢包。守护进程只能保证不误切、不漏到默认路由，扛不住过载，所以容量规划必须留 30% 余量。
5. 路由器和 workload 部署在同一个 AZ，不做 AZ 级冗余。

## 9. 生产化之前的待办

| # | 事项 | 原因 / 现状 |
|---|---|---|
| 1 | **跨账号成员发现** | **已实现方案 ①**：配置里的 `static_peers` 提供对侧成员，本侧继续自动发现。实验环境用不同的 mesh tag 模拟了「对侧不可见」，mesh 建立和切换都正常（1.3–2.2 s）。**还要在真实的跨账号环境里测一次**（IAM、assume role） |
| 2 | 跨账号 pcx 的语义 | T2 在同账号测到：源地址在 VPC 外的包能送达、目的地址在 VPC 外的会被丢弃。跨账号要复测 |
| 3 | 探测和数据隔离 | 过载时探测包会和数据一起被丢。现在靠多数派证据和 fail-static 兜底；可以考虑让探测走管理 ENI，同时保留隧道内探测，用来验证数据面 |
| 4 | pod 路由同步工具的部署形态 | EventBridge 定时规则最短间隔 1 min：可以接受 1 min 级别的 pod 上线延迟，就用 Lambda + EventBridge；要更快，就在小实例上常驻循环运行。两种方式都要配最小权限 IAM（老侧 transit 路由表 + 新侧 PL 的 assume role）；容器网络的路由控制器如果有事件，也可以改为事件触发 |
| 5 | 指标和告警接入 | §7 |
| 6 | 生产规格的复测 | c8gn.16xlarge 上的切换时延（T4 只测了吞吐）、真实包长下的 PPS 余量 |
| 7 | 24–72 h 长稳 | 实验环境只跑了 60 min，而且是旧版本；定稿 v4.2 没有跑长稳 |
| 8 | **新侧托管服务的回程** | NLB、RDS、ElastiCache、MSK、endpoint 所在子网的路由表都要挂上 pod PL 路由（[test-report.md](test-report.md) §6 C1） |
| 9 | **新侧 CNI 的 SNAT** | 确认新侧 CNI 对「目的地址在 VPC 外」的流量会不会做 SNAT（test-report §6 C2） |
| 10 | **容器网络的路由控制器** | 确认它不会清理加在 node 子网路由表里的入口路由（test-report §6 C3） |
| 11 | 只断隧道时的检测速度 | 现在 3.5 s（隔离 → 判自己不健康 → 同伴判死）。可以考虑「隔离时直接判自己不健康」，但过载时会更容易让出流量，需要权衡 |
| 12 | **过载下的行为（定稿代码）** | 定稿代码里，过载的路由器在同伴看得到对端时会主动让出流量，这个行为还没有在过载条件下测过（[test-report.md](test-report.md) §5） |
