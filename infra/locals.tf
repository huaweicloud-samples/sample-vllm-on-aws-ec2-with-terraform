# =============================================================================
# 派生值：网络选址、命名、标签与启动脚本渲染
# =============================================================================

locals {
  create_vpc     = var.vpc_id == ""
  create_public  = var.public_subnet_id == ""
  create_private = var.private_subnet_id == ""

  vpc_id = local.create_vpc ? huaweicloud_vpc.main[0].id : var.vpc_id

  public_subnet_id = local.create_public ? huaweicloud_vpc_subnet.public[0].id : var.public_subnet_id
  instance_subnet_id = (
    local.create_private ? huaweicloud_vpc_subnet.private[0].id : var.private_subnet_id
  )

  # 镜像：显式给出 image_id 时直接用；否则按锚定正则在本区域公共镜像中挑选
  resolved_image_id = (
    var.image_id != "" ? var.image_id : data.huaweicloud_images_image.selected[0].id
  )

  resource_name = {
    vpc             = "${var.name_prefix}-vpc"
    public_subnet   = "${var.name_prefix}-subnet-public"
    instance_subnet = "${var.name_prefix}-subnet-instance"
    nat             = "${var.name_prefix}-nat"
    nat_eip         = "${var.name_prefix}-eip-nat"
    snat            = "${var.name_prefix}-snat-instance"
    security_group  = "${var.name_prefix}-sg"
    ssh_rule        = "${var.name_prefix}-sg-ssh"
    keypair         = "${var.name_prefix}-keypair"
    configuration   = "${var.name_prefix}-config"
    scaling_group   = "${var.name_prefix}-group"
    instance_tag    = "${var.name_prefix}-inference-server"
  }

  common_tags = {
    managed_by  = "terraform"
    name_prefix = var.name_prefix
    service     = "vllm"
  }

  # 实例首次启动时装载推理框架、下载权重并把服务交给 systemd 托管
  bootstrap_script = templatefile("${path.module}/templates/vllm_bootstrap.sh.tpl", {
    model_name             = var.model_name
    max_model_len          = var.max_model_len
    gpu_memory_utilization = var.gpu_memory_utilization
    tensor_parallel_size   = var.tensor_parallel_size
    vllm_version           = var.vllm_version
    vllm_port              = var.vllm_port
    model_source_base_url  = var.model_source_base_url
    python_package_index   = var.python_package_index_url
    model_cache_dir        = var.model_cache_dir
    bootstrap_log_path     = var.bootstrap_log_path
    data_disk_mount_point  = local.data_disk_mount_point
    use_data_disk          = var.enable_data_disk
  })

  data_disk_mount_point = "/mnt/models"
}
