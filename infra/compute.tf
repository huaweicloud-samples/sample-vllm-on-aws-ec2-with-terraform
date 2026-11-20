# =============================================================================
# 计算：登录密钥、镜像、伸缩配置与伸缩组
# =============================================================================
# 一台 GPU 实例常驻承载推理服务，由伸缩组负责健康检查与自动替换。

# -----------------------------------------------------------------------------
# SSH 密钥对：公钥由运维人员提供，私钥不进入仓库与状态文件
# -----------------------------------------------------------------------------

resource "huaweicloud_kps_keypair" "ops" {
  name        = local.resource_name.keypair
  description = "运维人员登录推理实例使用的密钥对"
  public_key  = var.ssh_public_key
}

# -----------------------------------------------------------------------------
# 镜像：按锚定正则在本区域公共镜像中定位
# -----------------------------------------------------------------------------

data "huaweicloud_images_image" "selected" {
  count = var.image_id == "" ? 1 : 0

  name_regex   = var.image_name_regex
  architecture = var.image_architecture
  visibility   = "public"
  most_recent  = true

  lifecycle {
    precondition {
      condition     = length(var.image_name_regex) > 0
      error_message = "未指定 image_id 时，image_name_regex 不能为空。"
    }

    precondition {
      condition     = can(regex("\\^", var.image_name_regex)) && can(regex("\\$$", var.image_name_regex))
      error_message = "image_name_regex 必须用 ^ 与 $ 锚定首尾，否则会命中名称相近的其它镜像。"
    }
  }
}

# -----------------------------------------------------------------------------
# 伸缩配置：等同一份可复用的实例模板
# -----------------------------------------------------------------------------

resource "huaweicloud_as_configuration" "vllm" {
  scaling_configuration_name = local.resource_name.configuration

  instance_config {
    flavor   = var.gpu_flavor
    image    = local.resolved_image_id
    key_name = huaweicloud_kps_keypair.ops.name

    # 华为云要求这里传入 base64 编码后的脚本内容
    user_data = base64encode(local.bootstrap_script)

    security_group_ids = [huaweicloud_networking_secgroup.instance.id]

    disk {
      volume_type = var.system_disk_type
      disk_type   = "SYS"
      size        = var.system_disk_size
    }

    dynamic "disk" {
      for_each = var.enable_data_disk ? [1] : []
      content {
        volume_type = var.data_disk_type
        disk_type   = "DATA"
        size        = var.data_disk_size
      }
    }

    # 每台伸缩出的实例自动分配一个公网地址，作为 SSH 运维入口
    public_ip {
      eip {
        ip_type = var.instance_eip_type

        bandwidth {
          share_type    = var.instance_eip_share_type
          charging_mode = var.instance_eip_charge_mode
          size          = var.instance_eip_bandwidth_size
        }
      }
    }

    charging_mode = "postPaid"
  }
}

# -----------------------------------------------------------------------------
# 伸缩组：实例数固定在 1，健康检查方式采用实例状态探测
# -----------------------------------------------------------------------------

resource "huaweicloud_as_group" "vllm" {
  scaling_group_name       = local.resource_name.scaling_group
  scaling_configuration_id = huaweicloud_as_configuration.vllm.id
  vpc_id                   = local.vpc_id

  desire_instance_number = var.instance_count
  min_instance_number    = var.instance_count
  max_instance_number    = var.instance_count

  availability_zones           = [var.availability_zone]
  multi_az_scaling_policy      = "PICK_FIRST"
  cool_down_time               = 900
  health_periodic_audit_method = "NOVA_AUDIT"
  health_periodic_audit_time   = 5
  instance_terminate_policy    = "OLD_INSTANCE"

  # 实例被移出伸缩组时一并释放其公网地址与磁盘，避免留下无人认领的残留资源
  delete_publicip  = true
  delete_volume    = true
  delete_instances = "yes"

  networks {
    id = local.instance_subnet_id
  }

  tags = merge(local.common_tags, {
    Name = local.resource_name.instance_tag
  })

  lifecycle {
    # 期望实例数由伸缩组在运行期自行调整，不以此处的声明值回写
    ignore_changes = [
      desire_instance_number,
    ]
  }
}
