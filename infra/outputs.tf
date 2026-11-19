# =============================================================================
# 输出
# =============================================================================

output "region" {
  description = "部署区域"
  value       = var.region
}

output "availability_zone" {
  description = "实例所在可用区"
  value       = var.availability_zone
}

output "vpc_id" {
  description = "VPC ID（新建或复用）"
  value       = local.vpc_id
}

output "instance_subnet_id" {
  description = "推理实例所在子网 ID"
  value       = local.instance_subnet_id
}

output "security_group_id" {
  description = "推理实例安全组 ID"
  value       = huaweicloud_networking_secgroup.instance.id
}

output "ssh_keypair_name" {
  description = "登录实例使用的密钥对名称"
  value       = huaweicloud_kps_keypair.ops.name
}

output "image_id" {
  description = "实例使用的镜像 ID"
  value       = local.resolved_image_id
}

output "gpu_flavor" {
  description = "实例使用的 GPU 规格名称"
  value       = var.gpu_flavor
}

output "scaling_group_id" {
  description = "伸缩组 ID"
  value       = huaweicloud_as_group.vllm.id
}

output "scaling_configuration_id" {
  description = "伸缩配置 ID"
  value       = huaweicloud_as_configuration.vllm.id
}

output "service_name" {
  description = "实例内推理服务的 systemd 单元名"
  value       = "vllm"
}

output "inference_port" {
  description = "推理服务监听端口（仅实例本机与 VPC 内可达，不对公网开放）"
  value       = var.vllm_port
}

output "model_name" {
  description = "请求体中 model 字段需要使用的模型名称"
  value       = var.model_name
}

output "access_guide" {
  description = "如何通过 SSH 端口转发调用推理接口"
  value       = <<-EOT
    伸缩组里的实例由平台创建，公网地址与私网地址请在控制台「弹性云服务器」列表或
    执行 terraform state show huaweicloud_as_group.vllm 后查询确认。

    1. 建立端口转发（本地 8000 映射到实例 8000），保持该终端运行：
       ssh -i <本地私钥文件> -N -L ${var.vllm_port}:<实例私网IP>:${var.vllm_port} root@<实例公网IP>

       实例只放通了来自 ops_cidr 的 SSH 入口，推理端口本身不开放入方向。

    2. 等待服务就绪（首次启动需要下载并加载模型权重，通常 8 到 15 分钟）：
       curl -s -o /dev/null -w "%%{http_code}\n" http://127.0.0.1:${var.vllm_port}/health
       返回 200 即表示服务可用。

    3. 发起一次对话请求：
       curl http://127.0.0.1:${var.vllm_port}/v1/chat/completions \
         -H "Content-Type: application/json" \
         -d '{"model": "${var.model_name}", "messages": [{"role": "user", "content": "你好"}], "max_tokens": 100}'

    排查进度可登录实例后查看：
       cat ${var.bootstrap_log_path}
       systemctl status vllm
       journalctl -u vllm --no-pager -n 50
  EOT
}
