# =============================================================================
# 安全组
# =============================================================================
# 入方向只放行来自运维网段的 SSH；推理服务端口不开放入方向，通过 SSH 端口转发访问。
# 出方向不建规则：创建安全组时平台已自动带一条放通全部出方向的默认规则，
# 重复声明会与默认规则冲突。

resource "huaweicloud_networking_secgroup" "instance" {
  name        = local.resource_name.security_group
  description = "vLLM 推理实例安全组：仅运维网段可 SSH"

  tags = local.common_tags
}

resource "huaweicloud_networking_secgroup_rule" "ssh_from_ops" {
  security_group_id = huaweicloud_networking_secgroup.instance.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.ssh_port
  port_range_max    = var.ssh_port
  remote_ip_prefix  = var.ops_cidr
  description       = "限定运维来源网段的 SSH 入口"
}
