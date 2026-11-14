# T15：降级路径（L3）——迁移期的 TGW。两个 VPC 都挂在 transit 子网；pod 地址池静态指向老 VPC attachment
variable "enable_tgw" { default = true }
resource "aws_ec2_transit_gateway" "tgw" {
  count       = var.enable_tgw ? 1 : 0
  description = "poc fallback TGW"
  tags        = { Name = "poc-fallback-tgw" }
}
resource "aws_ec2_transit_gateway_vpc_attachment" "old" {
  count              = var.enable_tgw ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.tgw[0].id
  vpc_id             = aws_vpc.old.id
  subnet_ids         = [aws_subnet.old_transit.id]
  tags               = { Name = "tgw-att-old" }
}
resource "aws_ec2_transit_gateway_vpc_attachment" "new" {
  count              = var.enable_tgw ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.tgw[0].id
  vpc_id             = aws_vpc.new.id
  subnet_ids         = [aws_subnet.new_transit.id]
  tags               = { Name = "tgw-att-new" }
}
# 与生产一致：旧容器网络的 pod 段在 TGW 路由表里静态指向老 VPC attachment，attachment 子网 RT 再按 pod 段 → node ENI 投递
resource "aws_ec2_transit_gateway_route" "pods" {
  count                          = var.enable_tgw ? 1 : 0
  destination_cidr_block         = local.pod_pool
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.old[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.tgw[0].association_default_route_table_id
}
output "tgw_id" { value = var.enable_tgw ? aws_ec2_transit_gateway.tgw[0].id : null }
