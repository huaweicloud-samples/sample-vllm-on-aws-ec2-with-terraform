# =============================================================================
# 网络：VPC、子网、公网出网通道
# =============================================================================
# 推理实例放在独立子网内，对外只开放 SSH；下载模型权重与安装依赖经公网 NAT 出网。
# 华为云在创建公网 NAT 网关时由平台自动向 VPC 默认路由表注入 0.0.0.0/0 的下一跳，
# 因此这里不新建路由表、也不显式声明默认路由。

resource "huaweicloud_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  name        = local.resource_name.vpc
  description = "承载 vLLM 推理实例的专有网络"
  cidr        = var.vpc_cidr
  tags        = local.common_tags
}

# 承载公网 NAT 网关的子网
resource "huaweicloud_vpc_subnet" "public" {
  count = local.create_public ? 1 : 0

  name              = local.resource_name.public_subnet
  vpc_id            = local.vpc_id
  cidr              = var.public_subnet_cidr
  gateway_ip        = var.public_subnet_gateway_ip
  availability_zone = var.availability_zone
  tags              = local.common_tags
}

# 承载推理实例的子网
resource "huaweicloud_vpc_subnet" "private" {
  count = local.create_private ? 1 : 0

  name              = local.resource_name.instance_subnet
  vpc_id            = local.vpc_id
  cidr              = var.private_subnet_cidr
  gateway_ip        = var.private_subnet_gateway_ip
  availability_zone = var.availability_zone
  tags              = local.common_tags
}

# 出网用的公网地址
resource "huaweicloud_vpc_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name = local.resource_name.nat_eip
  tags = local.common_tags
  publicip {
    type = var.nat_eip_type
  }

  bandwidth {
    name        = local.resource_name.nat_eip
    share_type  = "PER"
    charge_mode = var.nat_eip_charge_mode
    size        = var.nat_eip_bandwidth_size
  }
}

resource "huaweicloud_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name          = local.resource_name.nat
  description   = "为推理子网提供访问公网的出网通道"
  vpc_id        = local.vpc_id
  subnet_id     = local.public_subnet_id
  spec          = var.nat_spec
  charging_mode = var.nat_charging_mode
  tags          = local.common_tags

  # 复用已有 VPC 时不需要新建子网，但仍要保证 NAT 挂载的子网已就绪
  depends_on = [huaweicloud_vpc_subnet.public]
}

# 推理子网整段网段的源地址转换规则
resource "huaweicloud_nat_snat_rule" "instance" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id = huaweicloud_nat_gateway.main[0].id
  subnet_id      = local.instance_subnet_id
  floating_ip_id = huaweicloud_vpc_eip.nat[0].id
  source_type    = 0
  description    = "推理实例下载模型权重与安装依赖的出网地址转换"
}
