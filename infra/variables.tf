# =============================================================================
# 输入变量
# =============================================================================
# 与资源规格、磁盘类型与容量、带宽与网络模式相关的参数全部显式给出，
# 不依赖 provider 默认值。

# -----------------------------------------------------------------------------
# 区域与命名
# -----------------------------------------------------------------------------

variable "region" {
  description = "华为云区域"
  type        = string
  default     = "cn-north-4"
}

variable "availability_zone" {
  description = "实例所在可用区。GPU 规格仅在部分可用区上架，cn-north-4 需选 cn-north-4b 或 cn-north-4c。"
  type        = string
  default     = "cn-north-4b"
}

variable "name_prefix" {
  description = "所有资源名称的统一前缀"
  type        = string
  default     = "vllm-gpu"
}

# -----------------------------------------------------------------------------
# 网络：留空即新建，填写即复用
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "复用的 VPC ID。留空则新建 VPC。"
  type        = string
  default     = ""
}

variable "public_subnet_id" {
  description = "复用承载公网 NAT 网关的子网 ID。留空则新建。"
  type        = string
  default     = ""
}

variable "private_subnet_id" {
  description = "复用承载推理实例的子网 ID。留空则新建。"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "新建 VPC 的网段"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "新建承载公网 NAT 网关的子网网段"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_gateway_ip" {
  description = "新建公网子网的网关地址，须落在 public_subnet_cidr 内"
  type        = string
  default     = "10.0.1.1"
}

variable "private_subnet_cidr" {
  description = "新建承载推理实例的子网网段"
  type        = string
  default     = "10.0.10.0/24"
}

variable "private_subnet_gateway_ip" {
  description = "新建推理子网的网关地址，须落在 private_subnet_cidr 内"
  type        = string
  default     = "10.0.10.1"
}

# -----------------------------------------------------------------------------
# 实例规格：GPU 规格与磁盘、带宽等直接决定资源形态，逐项显式给出
# -----------------------------------------------------------------------------

variable "gpu_flavor" {
  description = <<-EOT
    GPU 实例规格名称，必须由使用者按目标可用区实际上架情况显式给出，本实践不做自动挑选。
    可选范围参考：g5 / g6 / pi2 / p2v 等 GPU 规格族，均只在部分可用区提供。
    默认值仅用于让模板可校验，正式部署前请在 terraform.tfvars 中覆盖为实际使用的规格。
  EOT
  type        = string
  default     = "g5.2xlarge.8"

  validation {
    condition     = length(trim(var.gpu_flavor, " ")) > 0
    error_message = "gpu_flavor 不能为空，请填写目标可用区实际可售的 GPU 规格名称。"
  }
}

variable "instance_count" {
  description = "伸缩组实例数，同时作为伸缩组的最小、期望与最大实例数（单实例常驻推理服务形态）"
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 10
    error_message = "instance_count 取值范围为 1 到 10。"
  }
}

variable "image_id" {
  description = "实例镜像 ID。填写后忽略 image_name_regex，直接用该镜像创建实例。"
  type        = string
  default     = ""
}

variable "image_name_regex" {
  description = <<-EOT
    镜像名称正则，用于在公共镜像中挑选实例镜像。默认为空：未填写 image_id 时必须在部署前给出取值，
    否则规划阶段就中止，避免用一台不含 GPU 驱动的实例跑完创建流程。
    首尾必须用 ^ $ 锚定，否则会误命中名称相近的其它镜像。
    预装 GPU 驱动的镜像在各区域的镜像名与驱动版本号都不同，先在控制台「弹性云服务器 - 公共镜像」列表按区域确认，
    再把确认到的镜像名写成锚定正则，或直接把 image_id 指定为确认后的镜像 ID。
    注意：通用镜像不含 GPU 驱动，使用通用镜像启动时初始化脚本会中止并写明原因。
  EOT
  type        = string
  default     = ""
}

variable "image_architecture" {
  description = "镜像指令集架构，需与 gpu_flavor 所属架构一致"
  type        = string
  default     = "x86"

  validation {
    condition     = contains(["x86", "arm"], var.image_architecture)
    error_message = "image_architecture 只能是 x86 或 arm。"
  }
}

variable "system_disk_type" {
  description = "系统盘类型"
  type        = string
  default     = "GPSSD"

  validation {
    condition     = contains(["SSD", "SAS", "SATA", "GPSSD", "ESSD", "GPSSD2", "ESSD2"], var.system_disk_type)
    error_message = "system_disk_type 需为 SSD / SAS / SATA / GPSSD / ESSD / GPSSD2 / ESSD2 之一。"
  }
}

variable "system_disk_size" {
  description = "系统盘容量（GB），需容纳运行环境与模型权重缓存"
  type        = number
  default     = 100

  validation {
    condition     = var.system_disk_size >= 40 && var.system_disk_size <= 1024
    error_message = "system_disk_size 取值范围为 40 到 1024 GB。"
  }
}

variable "enable_data_disk" {
  description = "是否挂载独立数据盘，用于持久化模型权重缓存"
  type        = bool
  default     = true
}

variable "data_disk_type" {
  description = "数据盘类型"
  type        = string
  default     = "GPSSD"

  validation {
    condition     = contains(["SSD", "SAS", "SATA", "GPSSD", "ESSD", "GPSSD2", "ESSD2"], var.data_disk_type)
    error_message = "data_disk_type 需为 SSD / SAS / SATA / GPSSD / ESSD / GPSSD2 / ESSD2 之一。"
  }
}

variable "data_disk_size" {
  description = "数据盘容量（GB），按所用模型权重体积放大"
  type        = number
  default     = 200

  validation {
    condition     = var.data_disk_size >= 10 && var.data_disk_size <= 32768
    error_message = "data_disk_size 取值范围为 10 到 32768 GB。"
  }
}

# -----------------------------------------------------------------------------
# 出网与入口
# -----------------------------------------------------------------------------

variable "enable_nat_gateway" {
  description = "是否创建公网 NAT 网关为子网提供出网能力。实例自带公网地址时可关闭。"
  type        = bool
  default     = true
}

variable "nat_spec" {
  description = "公网 NAT 网关规格：1（小型）、2（中型）、3（大型）、4（超大型）"
  type        = string
  default     = "1"

  validation {
    condition     = contains(["1", "2", "3", "4"], var.nat_spec)
    error_message = "nat_spec 只能是 1 / 2 / 3 / 4。"
  }
}

variable "nat_charging_mode" {
  description = "公网 NAT 网关的模式取值：postPaid 或 prePaid"
  type        = string
  default     = "postPaid"

  validation {
    condition     = contains(["postPaid", "prePaid"], var.nat_charging_mode)
    error_message = "nat_charging_mode 只能是 postPaid 或 prePaid。"
  }
}

variable "nat_eip_type" {
  description = "出网公网地址类型，5_bgp 为动态 BGP"
  type        = string
  default     = "5_bgp"
}

variable "nat_eip_charge_mode" {
  description = "出网公网地址的带宽类型取值：traffic 或 bandwidth"
  type        = string
  default     = "traffic"

  validation {
    condition     = contains(["traffic", "bandwidth"], var.nat_eip_charge_mode)
    error_message = "nat_eip_charge_mode 只能是 traffic 或 bandwidth。"
  }
}

variable "nat_eip_bandwidth_size" {
  description = "出网公网地址带宽上限（Mbit/s）：nat_eip_charge_mode 为 traffic 时取值 1-300，为 bandwidth 时取值 1-2000"
  type        = number
  default     = 50
}

variable "instance_eip_type" {
  description = "实例公网地址类型，5_bgp 为动态 BGP"
  type        = string
  default     = "5_bgp"
}

variable "instance_eip_charge_mode" {
  description = "实例公网地址的带宽类型取值：traffic 或 bandwidth"
  type        = string
  default     = "traffic"

  validation {
    condition     = contains(["traffic", "bandwidth"], var.instance_eip_charge_mode)
    error_message = "instance_eip_charge_mode 只能是 traffic 或 bandwidth。"
  }
}

variable "instance_eip_bandwidth_size" {
  description = "实例公网地址带宽上限（Mbit/s）：instance_eip_charge_mode 为 traffic 时取值 1-300，为 bandwidth 时取值 1-2000"
  type        = number
  default     = 50
}

variable "instance_eip_share_type" {
  description = "实例公网地址的带宽共享方式，PER 为独享带宽"
  type        = string
  default     = "PER"

  validation {
    condition     = contains(["PER", "WHOLE"], var.instance_eip_share_type)
    error_message = "instance_eip_share_type 只能是 PER 或 WHOLE。"
  }
}

# -----------------------------------------------------------------------------
# 访问通道
# -----------------------------------------------------------------------------

variable "ssh_public_key" {
  description = "登录实例使用的 SSH 公钥（OpenSSH 格式，如 ssh-ed25519 AAAA... user@host）。私钥保留在运维人员本地，不入仓库。"
  type        = string

  validation {
    condition     = length(trim(var.ssh_public_key, " ")) > 0
    error_message = "ssh_public_key 不能为空：实例的运维通道依赖 SSH 密钥对。"
  }
}

variable "ops_cidr" {
  description = "允许通过 SSH 访问实例的运维来源网段，形如 <运维固定公网 IP>/32。出于收敛攻击面的考虑，不接受 0.0.0.0/0。"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.ops_cidr)) && var.ops_cidr != "0.0.0.0/0"
    error_message = "ops_cidr 需为合法 CIDR 且不得为 0.0.0.0/0，请把来源收敛到运维出口地址。"
  }
}

variable "ssh_port" {
  description = "SSH 端口"
  type        = number
  default     = 22
}

# -----------------------------------------------------------------------------
# 推理服务参数
# -----------------------------------------------------------------------------

variable "model_name" {
  description = "对外提供服务的模型名称，需与请求体中的 model 字段完全一致"
  type        = string
  default     = "Qwen/Qwen2.5-0.5B-Instruct"
}

variable "max_model_len" {
  description = "模型支持的最大序列长度"
  type        = number
  default     = 8192
}

variable "gpu_memory_utilization" {
  description = "分配给键值缓存的显存比例，取值 0 到 1"
  type        = string
  default     = "0.85"
}

variable "tensor_parallel_size" {
  description = "张量并行的显卡数量，需与实例挂载的 GPU 卡数一致"
  type        = number
  default     = 1
}

variable "vllm_version" {
  description = "推理框架版本，按运行环境实际可用的版本固定"
  type        = string
  default     = "0.8.5"
}

variable "vllm_port" {
  description = "推理服务监听端口，服务只在实例本机与 VPC 内监听，不对公网开放"
  type        = number
  default     = 8000
}

variable "model_source_base_url" {
  description = "模型权重下载源地址。国内区域建议改用距离更近的镜像站点。"
  type        = string
  default     = "https://huggingface.co"
}

variable "python_package_index_url" {
  description = "安装推理框架所用的软件包索引地址，建议改为距离更近的镜像源"
  type        = string
  default     = "https://pypi.tuna.tsinghua.edu.cn/simple"
}

variable "model_cache_dir" {
  description = "模型权重在实例内的缓存目录；启用数据盘时建议落在数据盘挂载点，避免每次重建实例重复下载"
  type        = string
  default     = "/mnt/models/huggingface"
}

variable "bootstrap_log_path" {
  description = "实例初始化脚本的日志文件路径"
  type        = string
  default     = "/var/log/vllm-setup.log"
}
