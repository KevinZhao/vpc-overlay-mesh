# vpc-overlay-mesh 实验环境
# 拓扑：VPC-OLD（旧容器网络：pod IP 在 VPC CIDR 之外，靠 VPC 路由表「pod 段 → node ENI」投递）
#       ↔ VPC peering ↔ VPC-NEW（新架构：pod IP 在 VPC CIDR 之内）
# 两侧各 3 台 EC2 路由器，全互联 VXLAN（跑在 peering 上），见 docs/design.md。
# 没有 IGW，也没有公网 IP：管理走 SSM interface endpoint，软件包走 S3 gateway endpoint，路由器调 EC2 API 走 EC2 interface endpoint。

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project }
  }
}

variable "project" { default = "overlay-mesh-poc" }
variable "region" { default = "eu-central-1" }
variable "az_id" {
  description = "所有子网所在的 AZ ID（路由器与 workload 同 AZ）"
  default     = "euc1-az1"
}
variable "instance_type" { default = "c8gn.large" }
variable "router_instance_type" { default = "c8gn.large" }

locals {
  old_cidr    = "10.110.0.0/16"
  new_cidr    = "10.120.0.0/16"
  pod_cidr    = "100.64.10.0/24" # 不在任何 VPC CIDR 内：模拟旧容器网络的 pod 段
  pod_ip      = "100.64.10.10"
  pod_pool    = "100.64.0.0/14" # pod 地址池：路由器内核路由按池写，具体 pod 段只在 VPC 路由表 / prefix list 里
  old_node_ip = "10.110.1.10"
  new_host_ip = "10.120.1.10"
  old_wl_cidr = "10.110.1.0/24"
  new_wl_cidr = "10.120.1.0/24"
  dummy_rts   = 20 # 空路由表：用来测「一次切换要改多张表」的耗时与 API 限流

  # 路由器：A = 老侧，B = 新侧；数据 ENI 的 tag 决定路由器身份（守护进程启动时据此认出自己）
  routers = {
    A1 = { side = "a", idx = 1, ip = "10.110.10.10" }
    A2 = { side = "a", idx = 2, ip = "10.110.10.12" }
    A3 = { side = "a", idx = 3, ip = "10.110.10.13" }
    B1 = { side = "b", idx = 1, ip = "10.120.10.10" }
    B2 = { side = "b", idx = 2, ip = "10.120.10.12" }
    B3 = { side = "b", idx = 3, ip = "10.120.10.13" }
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------- VPC / 子网 ----------------
resource "aws_vpc" "old" {
  cidr_block           = local.old_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-old" }
}
resource "aws_vpc" "new" {
  cidr_block           = local.new_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-new" }
}

resource "aws_subnet" "old_node" {
  vpc_id               = aws_vpc.old.id
  cidr_block           = local.old_wl_cidr
  availability_zone_id = var.az_id
  tags                 = { Name = "old-node" }
}
resource "aws_subnet" "old_transit" {
  vpc_id               = aws_vpc.old.id
  cidr_block           = "10.110.10.0/24"
  availability_zone_id = var.az_id
  tags                 = { Name = "old-transit" }
}
resource "aws_subnet" "old_mgmt" {
  vpc_id               = aws_vpc.old.id
  cidr_block           = "10.110.20.0/24"
  availability_zone_id = var.az_id
  tags                 = { Name = "old-mgmt" }
}
resource "aws_subnet" "new_wl" {
  vpc_id               = aws_vpc.new.id
  cidr_block           = local.new_wl_cidr
  availability_zone_id = var.az_id
  tags                 = { Name = "new-workload" }
}
resource "aws_subnet" "new_transit" {
  vpc_id               = aws_vpc.new.id
  cidr_block           = "10.120.10.0/24"
  availability_zone_id = var.az_id
  tags                 = { Name = "new-transit" }
}
resource "aws_subnet" "new_mgmt" {
  vpc_id               = aws_vpc.new.id
  cidr_block           = "10.120.20.0/24"
  availability_zone_id = var.az_id
  tags                 = { Name = "new-mgmt" }
}

resource "aws_vpc_peering_connection" "pcx" {
  vpc_id      = aws_vpc.old.id
  peer_vpc_id = aws_vpc.new.id
  auto_accept = true
  tags        = { Name = "${var.project}-old-new" }
}

# ---------------- 安全组 ----------------
# 路由器数据 ENI：入、出都是 0.0.0.0/0 全放行 → 连接不被 SG 跟踪（没有 conntrack 上限，切换后连接状态不丢）
# 实验环境是私有子网、没有公网路由；生产要用 NACL 收口（docs/operations-runbook.md §1）
resource "aws_security_group" "router_old" {
  name   = "${var.project}-router-old"
  vpc_id = aws_vpc.old.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "router_new" {
  name   = "${var.project}-router-new"
  vpc_id = aws_vpc.new.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "host_old" {
  name   = "${var.project}-host-old"
  vpc_id = aws_vpc.old.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8", "100.64.0.0/10"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "host_new" {
  name   = "${var.project}-host-new"
  vpc_id = aws_vpc.new.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8", "100.64.0.0/10"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "ep_old" {
  name   = "${var.project}-endpoints-old"
  vpc_id = aws_vpc.old.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.old_cidr, local.pod_cidr]
  }
}
resource "aws_security_group" "ep_new" {
  name   = "${var.project}-endpoints-new"
  vpc_id = aws_vpc.new.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.new_cidr]
  }
}

# ---------------- Endpoints（SSM、EC2、S3） ----------------
locals { if_services = ["ssm", "ssmmessages", "ec2messages", "ec2"] } # ec2：路由器在 VPC 内调 ReplaceRoute / Describe*
resource "aws_vpc_endpoint" "ssm_old" {
  for_each            = toset(local.if_services)
  vpc_id              = aws_vpc.old.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.old_mgmt.id]
  security_group_ids  = [aws_security_group.ep_old.id]
  private_dns_enabled = true
}
resource "aws_vpc_endpoint" "ssm_new" {
  for_each            = toset(local.if_services)
  vpc_id              = aws_vpc.new.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.new_mgmt.id]
  security_group_ids  = [aws_security_group.ep_new.id]
  private_dns_enabled = true
}
resource "aws_vpc_endpoint" "s3_old" {
  vpc_id            = aws_vpc.old.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.old_node.id, aws_route_table.old_transit.id, aws_route_table.old_mgmt.id]
}
resource "aws_vpc_endpoint" "s3_new" {
  vpc_id            = aws_vpc.new.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.new_wl.id, aws_route_table.new_transit.id, aws_route_table.new_mgmt.id]
}

# ---------------- IAM ----------------
# 实验环境里路由器和测试主机共用一个角色；生产要拆开，路由器角色只保留下面 router_failover 的权限 + SSM
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# 路由器自治切换：只允许改打了 overlay-managed=true 的路由表；Describe 无法按资源限定
resource "aws_iam_role_policy" "router_failover" {
  name = "overlay-router-failover"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:DescribeRouteTables", "ec2:DescribeNetworkInterfaces"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:ReplaceRoute"], Resource = "arn:aws:ec2:${var.region}:*:route-table/*",
      Condition = { StringEquals = { "aws:ResourceTag/overlay-managed" = "true" } } },
    ]
  })
}
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

# ---------------- 路由器：数据 ENI（和实例分开管理，替换实例时 IP 不变）+ 实例 ----------------
resource "aws_network_interface" "data" {
  for_each          = local.routers
  subnet_id         = each.value.side == "a" ? aws_subnet.old_transit.id : aws_subnet.new_transit.id
  private_ips       = [each.value.ip]
  security_groups   = [each.value.side == "a" ? aws_security_group.router_old.id : aws_security_group.router_new.id]
  source_dest_check = false
  tags = {
    Name            = "eni-${each.key}-data"
    "overlay-mesh"  = "poc"
    "overlay-side"  = each.value.side
    "overlay-name"  = each.key
    "overlay-index" = tostring(each.value.idx)
  }
}
resource "aws_instance" "router" {
  for_each               = local.routers
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.router_instance_type
  subnet_id              = each.value.side == "a" ? aws_subnet.old_mgmt.id : aws_subnet.new_mgmt.id
  vpc_security_group_ids = [each.value.side == "a" ? aws_security_group.router_old.id : aws_security_group.router_new.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data              = local.mesh_ud # 所有路由器相同；身份由数据 ENI 的 tag 决定
  metadata_options { http_tokens = "required" }
  lifecycle { ignore_changes = [user_data] } # 存量实例升级用 mesh/push.sh；替换实例时才用新的 user_data
  tags = { Name = "router-${each.key}", Role = "router-${upper(each.value.side)}" }
}
resource "aws_network_interface_attachment" "data" {
  for_each             = local.routers
  instance_id          = aws_instance.router[each.key].id
  network_interface_id = aws_network_interface.data[each.key].id
  device_index         = 1
}

# ---------------- 测试主机 ----------------
resource "aws_instance" "old_node" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.old_node.id
  private_ip             = local.old_node_ip
  vpc_security_group_ids = [aws_security_group.host_old.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  source_dest_check      = false # 与旧容器网络的 node 一致：pod 流量由 node 转发
  user_data              = templatefile("${path.module}/userdata/oldnode.sh.tftpl", { pod_ip = local.pod_ip })
  metadata_options { http_tokens = "required" }
  tags = { Name = "old-node-sim" }
}
resource "aws_instance" "new_host" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.new_wl.id
  private_ip             = local.new_host_ip
  vpc_security_group_ids = [aws_security_group.host_new.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data              = file("${path.module}/userdata/newhost.sh")
  metadata_options { http_tokens = "required" }
  tags = { Name = "new-host-sim" }
}

# ---------------- 路由表：老侧 ----------------
# 每张表都带「pod 段 → old-node ENI」（模拟旧容器网络控制器写入的逐 node 路由）
resource "aws_route_table" "old_node" {
  vpc_id = aws_vpc.old.id
  tags   = { Name = "rt-old-node", "overlay-managed" = "true" }
}
resource "aws_route" "old_node_pod" {
  route_table_id         = aws_route_table.old_node.id
  destination_cidr_block = local.pod_cidr
  network_interface_id   = aws_instance.old_node.primary_network_interface_id
}
resource "aws_route" "old_node_to_new" {
  route_table_id         = aws_route_table.old_node.id
  destination_cidr_block = local.new_cidr
  network_interface_id   = aws_network_interface.data["A1"].id
  lifecycle { ignore_changes = [network_interface_id] } # 切换由路由器自己 ReplaceRoute
}
resource "aws_route_table_association" "old_node" {
  subnet_id      = aws_subnet.old_node.id
  route_table_id = aws_route_table.old_node.id
}

resource "aws_route_table" "old_dummy" {
  count  = local.dummy_rts
  vpc_id = aws_vpc.old.id
  tags   = { Name = "rt-old-dummy-${count.index}" }
}
resource "aws_route" "old_dummy_to_new" {
  count                  = local.dummy_rts
  route_table_id         = aws_route_table.old_dummy[count.index].id
  destination_cidr_block = local.new_cidr
  network_interface_id   = aws_network_interface.data["A1"].id
  lifecycle { ignore_changes = [network_interface_id] }
}

resource "aws_route_table" "old_transit" {
  vpc_id = aws_vpc.old.id
  tags   = { Name = "rt-old-transit" }
}
resource "aws_route" "old_transit_pod" { # 路由器解封装后经 transit 子网投递到 node：这里必须有全部 pod 段
  route_table_id         = aws_route_table.old_transit.id
  destination_cidr_block = local.pod_cidr
  network_interface_id   = aws_instance.old_node.primary_network_interface_id
}
resource "aws_route" "old_transit_peer" { # VXLAN 外层：对端 transit 子网走 peering
  route_table_id            = aws_route_table.old_transit.id
  destination_cidr_block    = "10.120.10.0/24"
  vpc_peering_connection_id = aws_vpc_peering_connection.pcx.id
}
resource "aws_route_table_association" "old_transit" {
  subnet_id      = aws_subnet.old_transit.id
  route_table_id = aws_route_table.old_transit.id
}

resource "aws_route_table" "old_mgmt" {
  vpc_id = aws_vpc.old.id
  tags   = { Name = "rt-old-mgmt" }
}
resource "aws_route" "old_mgmt_pod" {
  route_table_id         = aws_route_table.old_mgmt.id
  destination_cidr_block = local.pod_cidr
  network_interface_id   = aws_instance.old_node.primary_network_interface_id
}
resource "aws_route_table_association" "old_mgmt" {
  subnet_id      = aws_subnet.old_mgmt.id
  route_table_id = aws_route_table.old_mgmt.id
}

# ---------------- 路由表：新侧 ----------------
resource "aws_route_table" "new_wl" {
  vpc_id = aws_vpc.new.id
  tags   = { Name = "rt-new-workload", "overlay-managed" = "true" }
}
resource "aws_route" "new_wl_pod" {
  route_table_id         = aws_route_table.new_wl.id
  destination_cidr_block = local.pod_cidr
  network_interface_id   = aws_network_interface.data["B1"].id
  lifecycle { ignore_changes = [network_interface_id] }
}
resource "aws_route" "new_wl_oldnode" {
  route_table_id         = aws_route_table.new_wl.id
  destination_cidr_block = local.old_wl_cidr
  network_interface_id   = aws_network_interface.data["B2"].id
  lifecycle { ignore_changes = [network_interface_id] }
}
resource "aws_route" "new_wl_old_rest" { # 老 VPC 里 VPC CIDR 内的地址直接走 peering
  route_table_id            = aws_route_table.new_wl.id
  destination_cidr_block    = local.old_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.pcx.id
}
resource "aws_route_table_association" "new_wl" {
  subnet_id      = aws_subnet.new_wl.id
  route_table_id = aws_route_table.new_wl.id
}

resource "aws_route_table" "new_transit" {
  vpc_id = aws_vpc.new.id
  tags   = { Name = "rt-new-transit" }
}
resource "aws_route" "new_transit_old" {
  route_table_id            = aws_route_table.new_transit.id
  destination_cidr_block    = local.old_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.pcx.id
}
resource "aws_route_table_association" "new_transit" {
  subnet_id      = aws_subnet.new_transit.id
  route_table_id = aws_route_table.new_transit.id
}

resource "aws_route_table" "new_mgmt" {
  vpc_id = aws_vpc.new.id
  tags   = { Name = "rt-new-mgmt" }
}
resource "aws_route_table_association" "new_mgmt" {
  subnet_id      = aws_subnet.new_mgmt.id
  route_table_id = aws_route_table.new_mgmt.id
}

# ---------------- 入口路由：按路由器分配 ----------------
# 新侧：pod 段按路由器分组放进 prefix list，每组一条路由（每组再加 90 个占位 /28，模拟生产「每 node 一个 pod 段」的规模）
# 老侧：新 VPC 网段拆成 /26，分给 A1–A3
locals {
  pod_groups = {
    g1 = { home = "B1", real = ["100.64.10.0/26"] }
    g2 = { home = "B2", real = ["100.64.10.64/26"] }
    g3 = { home = "B3", real = ["100.64.10.128/26", "100.64.10.192/26"] }
  }
  pod_group_idx = { g1 = 0, g2 = 1, g3 = 2 }
  old_entries = {
    "10.120.1.0/26"   = "A1"
    "10.120.1.64/26"  = "A2"
    "10.120.1.128/26" = "A3"
    "10.120.1.192/26" = "A2"
  }
}
resource "aws_ec2_managed_prefix_list" "pods" {
  for_each       = local.pod_groups
  name           = "${var.project}-pods-${each.key}"
  address_family = "IPv4"
  max_entries    = 100
  # 初始条目由 Terraform 写入；之后 pod 段的增减由 mesh/podroute_sync.py 维护（description = "pod (sync)"），Terraform 不回滚
  lifecycle { ignore_changes = [entry] }
  dynamic "entry" {
    for_each = concat(each.value.real, [for i in range(90) : "100.65.${local.pod_group_idx[each.key] * 10 + floor(i / 16)}.${(i % 16) * 16}/28"])
    content {
      cidr        = entry.value
      description = "pod segment"
    }
  }
}
resource "aws_route" "new_wl_pods" {
  for_each                   = local.pod_groups
  route_table_id             = aws_route_table.new_wl.id
  destination_prefix_list_id = aws_ec2_managed_prefix_list.pods[each.key].id
  network_interface_id       = aws_network_interface.data[each.value.home].id
  lifecycle { ignore_changes = [network_interface_id] }
}
resource "aws_route" "old_node_entries" {
  for_each               = local.old_entries
  route_table_id         = aws_route_table.old_node.id
  destination_cidr_block = each.key
  network_interface_id   = aws_network_interface.data[each.value].id
  lifecycle { ignore_changes = [network_interface_id] }
}

# ---------------- 守护进程配置与 user_data ----------------
locals {
  mesh_config = jsonencode({
    mesh = "poc", region = var.region, interval = 0.3, detect = 0.9, hold = 10, discover = 10
    sides = {
      a = {
        tunnel_cidrs = [local.new_wl_cidr], eth_cidrs = [local.pod_pool, local.old_wl_cidr]
        entries = concat([for c, h in local.old_entries : { rt = aws_route_table.old_node.id, cidr = c, home = h }],
        [{ rt = aws_route_table.old_node.id, cidr = local.new_cidr, home = "A1" }])
      }
      b = {
        tunnel_cidrs = [local.pod_pool, local.old_wl_cidr], eth_cidrs = [local.new_wl_cidr]
        entries = concat([for g, v in local.pod_groups : { rt = aws_route_table.new_wl.id, pl = aws_ec2_managed_prefix_list.pods[g].id, home = v.home }],
          [{ rt = aws_route_table.new_wl.id, cidr = local.pod_cidr, home = "B1" },
        { rt = aws_route_table.new_wl.id, cidr = local.old_wl_cidr, home = "B2" }])
      }
    }
  })
  mesh_ud = templatefile("${path.module}/mesh/router-userdata.sh.tftpl", {
    daemon_b64gz = base64gzip(file("${path.module}/mesh/overlay-mesh.py"))
    config_b64   = base64encode(local.mesh_config)
  })
}

# ---------------- 输出（测试脚本从 ids 读资源 ID） ----------------
output "mesh_config" { value = local.mesh_config }
output "ids" {
  value = {
    router_a1    = aws_instance.router["A1"].id
    router_a2    = aws_instance.router["A2"].id
    router_a3    = aws_instance.router["A3"].id
    router_b1    = aws_instance.router["B1"].id
    router_b2    = aws_instance.router["B2"].id
    router_b3    = aws_instance.router["B3"].id
    eni_a        = aws_network_interface.data["A1"].id
    eni_a2       = aws_network_interface.data["A2"].id
    eni_a3       = aws_network_interface.data["A3"].id
    eni_b        = aws_network_interface.data["B1"].id
    eni_b2       = aws_network_interface.data["B2"].id
    eni_b3       = aws_network_interface.data["B3"].id
    old_node     = aws_instance.old_node.id
    new_host     = aws_instance.new_host.id
    rt_old_node  = aws_route_table.old_node.id
    rt_new_wl    = aws_route_table.new_wl.id
    rt_old_dummy = aws_route_table.old_dummy[*].id
    pl_pods      = { for k, v in aws_ec2_managed_prefix_list.pods : k => v.id }
    pcx          = aws_vpc_peering_connection.pcx.id
    pod_ip       = local.pod_ip
    new_host_ip  = local.new_host_ip
    old_node_ip  = local.old_node_ip
  }
}
