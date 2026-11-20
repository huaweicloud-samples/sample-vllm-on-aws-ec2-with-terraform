# =============================================================================
# Provider 配置
# =============================================================================
# Provider 所需的访问密钥在华为云「我的凭证」页面获取，部署前按下面的方式给出：
#   export HW_ACCESS_KEY="<访问密钥 ID>"
#   export HW_SECRET_KEY="<访问密钥>"
#   export HW_REGION_NAME="cn-north-4"
# 使用临时安全凭证时再补充 HW_SECURITY_TOKEN。
# 仓库与示例文件里只写尖括号占位符，不保存任何实际密钥。

provider "huaweicloud" {
  region = var.region
}
