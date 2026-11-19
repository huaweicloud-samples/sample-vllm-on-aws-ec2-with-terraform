# 部署指导

本文给出从零到「推理服务调用成功」的完整分步命令，每一步附预期输出。命令一律使用相对路径，请在仓库根目录开始。

需要修改的全部参数取值见 [README.md](../README.md) 的参数表，本文只讲执行次序与判读方法。

---

## 第 0 步：准备本地环境

### 0.1 工具版本

```bash
terraform version
python3 --version
bash --version | head -1
```

预期输出（版本号需满足约束）：

```text
Terraform v1.5.0 或更高
Python 3.8 或更高
GNU bash, version 4 或更高
```

`infra/versions.tf` 声明的约束是 Terraform `>= 1.5.0`、huaweicloud provider `~> 1.96.1`。版本低于约束时 `terraform init` 会直接拒绝。

### 0.2 获取访问凭据

在华为云「我的凭证」页面获取 Access Key ID 与 Secret Access Key，按 `infra/providers.tf` 顶部说明在部署所用的终端里给出：

```bash
export HW_ACCESS_KEY="<访问密钥 ID>"
export HW_SECRET_KEY="<访问密钥>"
export HW_REGION_NAME="cn-north-4"
# 使用临时安全凭证时再补充：
# export HW_SECURITY_TOKEN="<临时安全凭证的 token>"
```

不要把凭据写入代码，也不要提交到仓库。`terraform.tfvars` 已在 `.gitignore` 中排除。

### 0.3 准备 SSH 密钥对

```bash
ssh-keygen -t ed25519 -f ./vllm_ops_key -N ""
cat ./vllm_ops_key.pub
```

预期输出：一行以 `ssh-ed25519 AAAA` 开头、以注释（如 `user@host`）结尾的公钥。整行内容即 `var.ssh_public_key` 的取值。私钥 `./vllm_ops_key` 保留在本地，不上传、不入仓库。

### 0.4 账号权限

执行身份需具备弹性云服务器、弹性伸缩、虚拟私有云、NAT 网关、弹性公网 IP、云硬盘、密钥对、镜像、安全组的创建与删除权限。权限不足时 `apply` 会在对应资源上报 `Unauthorized` 类错误。

---

## 第 1 步：确认 GPU 规格与可用区（必做，不可跳过）

GPU 规格仅在部分可用区上架。**`var.gpu_flavor` 必须由使用者按目标可用区的实际上架情况显式给出**，仓库里的默认值 `g5.2xlarge.8` 只用于让模板通过校验，不构成任何可用性保证。

在控制台「弹性云服务器 - 规格与镜像」区域，或调用规格查询接口，确认：

1. 目标可用区（`cn-north-4` 需选 `cn-north-4b` 或 `cn-north-4c`）当前可售的 GPU 规格名；
2. 该规格的 GPU 卡数与单卡显存。

预期产出（示例）：

```text
规格名：<你在控制台确认到的规格，例如 g5.2xlarge.8>
可用区：<该规格实际在售的可用区，例如 cn-north-4b>
GPU 卡数：<例如 1>
单卡显存：<例如 16 GB>
```

这三项决定后续四个参数的取值：

| 待填参数 | 由什么决定 |
|-|-|
| `var.gpu_flavor` | 该可用区在售的规格名 |
| `var.availability_zone` | 该规格在售的可用区 |
| `var.tensor_parallel_size` | 规格的 GPU 卡数（必须一致，否则服务启动失败） |
| `var.max_model_len` / `var.gpu_memory_utilization` | 单卡显存与所用模型体积 |

---

## 第 2 步：确认实例镜像（必做，不可跳过）

在控制台「弹性云服务器 - 公共镜像」按当前区域确认**预装 GPU 驱动**的镜像，记下镜像名或镜像 ID。二选一填写：

- 已知镜像 ID：填 `var.image_id`，此时 `var.image_name_regex` 被忽略；
- 只知道镜像名：把 `var.image_name_regex` 写成该名称的锚定正则，形如 `^<完整镜像名>$`。`compute.tf` 的 `precondition` 会拒绝未同时含 `^` 与 `$` 的取值。

预期产出：一个镜像 ID，或一条锚定正则。

> `image_id` 与 `image_name_regex` 的默认值都是空串：两者都留空时，`compute.tf` 的 `precondition` 会在规划阶段中止，不会创建出实例。若填写的是不含 GPU 驱动的通用镜像，实例内的初始化脚本会中止并写明原因（见第 6 步的判读）。

---

## 第 3 步：部署前的离线自检（不需要任何云资源）

在仓库根目录执行客户端单元测试：

```bash
python -m unittest discover -s src/client -t src/client
```

预期输出：

```text
................
----------------------------------------------------------------------
Ran 16 tests in 0.0Xs

OK
```

这 16 个用例覆盖请求体构造、地址解析优先级、`Authorization` 头开关与错误码归类，属部署前可完整执行的静态校验。若报 `ModuleNotFoundError`，先 `python3 -m pip install requests`。

同时在 `infra/` 目录内做一次配置校验（`init` 之后）：

```bash
cd infra
terraform init
terraform validate
```

预期输出：

```text
Success! The configuration is valid, but there were some validation warnings as shown above.
```

---

## 第 4 步：填写变量

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

必须改动的五项（其余按实际情况调整）：

```hcl
availability_zone = "<第 1 步确认的可用区>"
gpu_flavor        = "<第 1 步确认的规格名>"
image_id          = "<第 2 步确认的镜像 ID>"   # 或改 image_name_regex 为锚定正则
ssh_public_key    = "ssh-ed25519 AAAA... operator@laptop"
ops_cidr          = "<运维固定公网 IP>/32"
```

`ssh_public_key` 与 `ops_cidr` 在 `variables.tf` 中没有默认值，缺失时 Terraform 会提示要求输入。

### 校验规则与预期报错

`variables.tf` 的 `validation` 块会拦截下列情况：

| 触发条件 | 预期报错（原文） |
|-|-|
| `gpu_flavor` 为空白 | `gpu_flavor 不能为空，请填写目标可用区实际可售的 GPU 规格名称。` |
| `instance_count` 不在 1-10 | `instance_count 取值范围为 1 到 10。` |
| `image_architecture` 非 x86/arm | `image_architecture 只能是 x86 或 arm。` |
| `system_disk_type` / `data_disk_type` 不在允许清单 | `system_disk_type 需为 SSD / SAS / SATA / GPSSD / ESSD / GPSSD2 / ESSD2 之一。` |
| `system_disk_size` 不在 40-1024 | `system_disk_size 取值范围为 40 到 1024 GB。` |
| `data_disk_size` 不在 10-32768 | `data_disk_size 取值范围为 10 到 32768 GB。` |
| `nat_spec` 非 1/2/3/4 | `nat_spec 只能是 1 / 2 / 3 / 4。` |
| `nat_charging_mode` 取值不合法 | `nat_charging_mode 只能是 postPaid 或 prePaid。` |
| `nat_eip_charge_mode` / `instance_eip_charge_mode` 取值不合法 | `nat_eip_charge_mode 只能是 traffic 或 bandwidth。` |
| `instance_eip_share_type` 非 PER/WHOLE | `instance_eip_share_type 只能是 PER 或 WHOLE。` |
| `ssh_public_key` 为空白 | `ssh_public_key 不能为空：实例的运维通道依赖 SSH 密钥对。` |
| `ops_cidr` 非法或为 `0.0.0.0/0` | `ops_cidr 需为合法 CIDR 且不得为 0.0.0.0/0，请把来源收敛到运维出口地址。` |
| `image_name_regex` 未锚定 | `image_name_regex 必须用 ^ 与 $ 锚定首尾，否则会命中名称相近的其它镜像。`（`compute.tf` 的 precondition） |
| `image_id` 为空且 `image_name_regex` 为空 | `未指定 image_id 时，image_name_regex 不能为空。`（`compute.tf` 的 precondition） |

---

## 第 5 步：预览变更

```bash
cd infra
terraform plan -var-file=terraform.tfvars
```

预期输出：

```text
Terraform will perform the following actions:
  # huaweicloud_as_configuration.vllm will be created
  # huaweicloud_as_group.vllm will be created
  # huaweicloud_kps_keypair.ops will be created
  # huaweicloud_nat_gateway.main[0] will be created
  # huaweicloud_nat_snat_rule.instance[0] will be created
  # huaweicloud_networking_secgroup.instance will be created
  # huaweicloud_networking_secgroup_rule.ssh_from_ops will be created
  # huaweicloud_vpc.main[0] will be created
  # huaweicloud_vpc_eip.nat[0] will be created
  # huaweicloud_vpc_subnet.private[0] will be created
  # huaweicloud_vpc_subnet.public[0] will be created
Plan: 11 to add, 0 to change, 0 to destroy.
```

判读要点：

- 复用已有 VPC 或子网时，对应的 `[0]` 条目消失，`Plan` 数字随之减少，这是预期行为（`local.create_vpc / create_public / create_private` 生效）。
- `enable_nat_gateway = false` 时 `huaweicloud_nat_gateway.main[0]`、`huaweicloud_nat_snat_rule.instance[0]`、`huaweicloud_vpc_eip.nat[0]` 三条都不会出现。
- 检查 `huaweicloud_as_configuration.vllm` 段落里的 `flavor` 是否等于你填入的 `gpu_flavor`、`image` 是否等于第 2 步确认的镜像 ID。
- 伸缩组的 `availability_zones` 必须等于 `var.availability_zone`。

---

## 第 6 步：执行部署

```bash
cd infra
terraform apply -var-file=terraform.tfvars
```

预期输出结尾：

```text
Apply complete! Resources: 11 added, 0 changed, 0 destroyed.

Outputs:

access_guide = "..."
availability_zone = "cn-north-4b"
gpu_flavor = "g5.2xlarge.8"
image_id = "<32 位十六进制串>"
inference_port = 8000
instance_subnet_id = "<子网 ID>"
model_name = "Qwen/Qwen2.5-0.5B-Instruct"
region = "cn-north-4"
scaling_configuration_id = "<伸缩配置 ID>"
scaling_group_id = "<伸缩组 ID>"
security_group_id = "<安全组 ID>"
service_name = "vllm"
ssh_keypair_name = "vllm-gpu-keypair"
vpc_id = "<VPC ID>"
```

14 项输出的用途：

| 输出 | 用途 |
|-|-|
| `access_guide` | 完整的访问步骤（隧道命令、健康探测、示例对话请求与排查命令），照抄即可 |
| `availability_zone` / `gpu_flavor` / `image_id` | 复核第 1、2 步的确认结果是否真的下发 |
| `region` | 确认控制台切到了正确区域 |
| `vpc_id` / `instance_subnet_id` / `security_group_id` | 后续网络与安全组核对 |
| `ssh_keypair_name` | 登录实例时确认用的是这对密钥 |
| `scaling_group_id` / `scaling_configuration_id` | 在控制台定位伸缩组与实例模板 |
| `service_name` | 实例内 systemd 单元名，固定 `vllm` |
| `inference_port` | 端口转发两侧与客户端 `--port` 要用的端口 |
| `model_name` | 请求体 `model` 字段的取值；与 `service_name`、`inference_port` 三项共同构成 `src/serve/`、`src/client/` 默认值的漂移基线 |

> `apply` 成功只代表资源形态声明完成。伸缩组里的实例由平台异步创建，服务就绪还需 8 到 15 分钟的权重下载与加载。

---

## 第 7 步：取实例地址

伸缩组内实例的公网与私网地址不在 Terraform 输出中，按 `access_guide` 的说明二选一获取：

```bash
cd infra
terraform state show huaweicloud_as_group.vllm
```

或在控制台「弹性云服务器」列表中找到标签为 `Name = <name_prefix>-inference-server`（默认 `vllm-gpu-inference-server`）的实例。

预期产出：

```text
实例公网地址：<EIP_ADDRESS>
实例私网地址：<例如 10.0.10.x>
```

私网地址用于端口转发目标，公网地址用于 SSH 登录入口。

---

## 第 8 步：判读实例初始化日志

```bash
ssh -i <本地私钥文件> root@<实例公网IP>
cat /var/log/vllm-setup.log
systemctl status vllm
journalctl -u vllm --no-pager -n 50
```

初始化脚本全程输出都写入 `var.bootstrap_log_path`。成功路径上依次应看到：

```text
=== 推理服务初始化开始 ===
+-----------------------------------------------------------------+   （nvidia-smi 的完整输出）
首次使用数据盘 /dev/vdb，创建 ext4 文件系统...
数据盘 /dev/vdb 已挂载到 /mnt/models
安装 vllm==0.8.5 ...
等待推理服务在端口 8000 就绪（首次启动需下载模型权重，耗时较长）...
推理服务已就绪，健康检查通过。
=== 推理服务初始化完成 ===
```

异常路径与对应处置：

| 日志片段 | 含义 | 处置 |
|-|-|-|
| `未检测到 GPU 驱动，无法启动推理服务。` | 用了不含驱动的通用镜像 | 回第 2 步，把 `image_id` 指向预装 GPU 驱动的镜像后重新 `apply` |
| `dpkg 锁被占用，等待 10 秒...` 反复出现 | 镜像自身首启初始化未完成 | 属正常等待，脚本会自动继续 |
| `未找到可挂载的数据盘，模型权重将写入系统盘。` | 未启用数据盘或盘未挂上 | 检查 `enable_data_disk`、`data_disk_size`；确认系统盘余量 |
| `推理服务在等待窗口内尚未就绪，可执行 systemctl status vllm ...` | 权重下载与加载超出有界探测窗口（最长 120 次 × 10 秒） | 不代表部署失败；`systemctl status vllm` 与 `journalctl -u vllm` 继续观察，进程由 systemd 持续拉起 |

---

## 第 9 步：建立访问通道

推理服务只监听实例本机与 VPC 内，安全组里只有来自 `var.ops_cidr` 的 SSH 入方向规则，**推理端口未开放**。在运维本机建立端口转发并保持该终端运行：

```bash
ssh -i <本地私钥文件> -N -L 8000:<实例私网IP>:8000 root@<实例公网IP>
```

命令形态与 `terraform output access_guide`、`src/serve/vllm-env.sh` 末尾的访问提示完全一致；两侧端口都取 `var.vllm_port`（默认 `8000`）。

预期表现：该终端不打印任何内容、也不退出。窗口关闭即通道断开，客户端会得到退出码 `2`。

---

## 第 10 步：验证

### 10.1 健康探活（curl）

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/health
```

预期输出：

```text
200
```

返回 `000` 表示端口无响应：隧道没建立，或服务仍在加载权重。

### 10.2 健康探活与模型名确认（脚本）

```bash
cd src/client
python3 health_check.py --base-url http://127.0.0.1:8000/v1
```

预期输出：

```text
GET http://127.0.0.1:8000/health -> HTTP 200
GET http://127.0.0.1:8000/v1/models -> 已返回模型列表
服务已加载模型（1 个）：
  Qwen/Qwen2.5-0.5B-Instruct  <= 本次 --model
请求体 model  : Qwen/Qwen2.5-0.5B-Instruct（列表中已存在）
结果          : 通过
```

要严格执行「模型名必须在列表内」时用：

```bash
python3 health_check.py --base-url http://127.0.0.1:8000/v1 --require-model
```

不匹配时脚本按退出码 `5` 失败。

### 10.3 一次非流式对话

```bash
python3 chat_completion.py --base-url http://127.0.0.1:8000/v1
```

预期输出：

```text
--- 非流式对话补全 ---
接口地址      : http://127.0.0.1:8000/v1/chat/completions
模型          : Qwen/Qwen2.5-0.5B-Instruct
首 token 延迟 : -
整体耗时      : 1234 ms
返回分片数    : 1
token 统计    : prompt=25 completion=64 total=89
返回内容      : <模型返回文本，最多显示 200 字符>
结果          : 通过
```

非流式不统计首 token 延迟，该行固定 `-`。自定义提问与长度：

```bash
python3 chat_completion.py --base-url http://127.0.0.1:8000/v1 \
  --prompt "你好，做个自我介绍" --max-tokens 128 --temperature 0.7
```

### 10.4 一次流式对话

```bash
python3 stream_chat_completion.py --base-url http://127.0.0.1:8000/v1
```

预期输出：

```text
请求体 stream=True，逐分片读取 SSE。
--- 流式对话补全 ---
接口地址      : http://127.0.0.1:8000/v1/chat/completions
模型          : Qwen/Qwen2.5-0.5B-Instruct
首 token 延迟 : 412 ms
整体耗时      : 1500 ms
返回分片数    : 62
返回内容      : <模型返回文本，最多显示 200 字符>
结果          : 通过
```

逐分片查看内容：`python3 stream_chat_completion.py --base-url http://127.0.0.1:8000/v1 --show-chunks`。

### 10.5 实例内状态自检

登录实例后执行（只读，不改任何配置）。前提是先完成第 11 步的「手工前置动作」把脚本上传到实例：

```bash
ssh -i <本地私钥文件> root@<实例公网IP> 'bash /opt/src/serve/vllm-status.sh'
```

预期输出（片段）：

```text
== 推理服务状态（端口 8000，模型 Qwen/Qwen2.5-0.5B-Instruct）==
systemd 服务               vllm.service：active（开机自启 enabled）
服务配置                   /etc/systemd/system/vllm.service 已存在
推理框架版本               已装 0.8.5，部署声明 var.vllm_version=0.8.5
端口监听                   8000 正在监听
显存占用                   <nvidia-smi 查询结果>
权重缓存目录               /mnt/models/huggingface 存在
GET /health                200
服务结论                   就绪
GET /v1/models             Qwen/Qwen2.5-0.5B-Instruct
```

退出码：`/health` 返回 200 时为 `0`，其他情况为 `1` 并逐行写明原因。本机没有 `systemctl` / `nvidia-smi` 时相应字段自动跳过。

### 10.6 交付检查清单

- [ ] `terraform apply` 输出 14 项 `Outputs`，`gpu_flavor` 与 `availability_zone` 为人工确认值
- [ ] `/var/log/vllm-setup.log` 末尾出现 `=== 推理服务初始化完成 ===`
- [ ] `systemctl status vllm` 为 `active`
- [ ] `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/health` 返回 `200`
- [ ] `health_check.py` 列出的模型名与 `var.model_name` 完全一致
- [ ] `chat_completion.py` 末行 `结果          : 通过`
- [ ] `stream_chat_completion.py` 的首 token 延迟不是 `-`

**部署完成后请按本节步骤在真实环境自行验证，全部通过后方可视为交付完成。**

---

## 第 11 步：运行期变更

`src/serve/` 的四个动作脚本在实例内以 root 执行，`vllm-env.sh` 是它们共用的函数库，不单独执行。取值优先级：**命令行参数 > 同名环境变量 > 实例上已生效的服务配置 > 脚本内默认值**，因此不带参数直接执行时读到的就是部署时下发的值。

**手工前置动作（必做）**：这五个脚本不在伸缩配置的 `user_data` 里，不会自动出现在实例上，需要运维人员自行上传一次。在仓库根目录执行：

```bash
scp -i <本地私钥文件> src/serve/*.sh root@<实例公网IP>:/opt/src/serve/
ssh -i <本地私钥文件> root@<实例公网IP> 'chmod +x /opt/src/serve/*.sh'
```

预期输出：`scp` 逐个回显传输进度，末行为 `100%`；`chmod` 无输出。此后下文一律写成 `ssh -i <本地私钥文件> root@<实例公网IP> 'bash /opt/src/serve/vllm-status.sh'` 的形式，或在已登录的实例会话里直接执行 `/opt/src/serve/vllm-status.sh`。

> 实例被伸缩组替换后需重新上传一次，或把该目录放到数据盘上并自行保留。

以下命令均在已登录的实例会话中以 root 执行：

```bash
# 只看将要生效的参数与服务配置内容，不做任何变更
/opt/src/serve/vllm-start.sh --dry-run

# 换一个模型重启服务（首次加载该模型仍需下载权重）
/opt/src/serve/vllm-start.sh --model <模型名> --max-model-len 4096

# 只拉起服务、不等待就绪
/opt/src/serve/vllm-start.sh --no-wait

# 加大就绪等待窗口到 1200 秒
/opt/src/serve/vllm-start.sh --wait-seconds 1200

# 停止实例内的服务进程（不影响伸缩组）
/opt/src/serve/vllm-stop.sh

# 看最近 100 行服务日志
/opt/src/serve/vllm-logs.sh -n 100

# 只看初始化日志
/opt/src/serve/vllm-logs.sh --source bootstrap -n 200

# 持续跟踪
/opt/src/serve/vllm-logs.sh -f
```

`vllm-start.sh --dry-run` 预期输出（片段）：

```text
推理服务运行参数（生效取值 / 来源）：
  SERVICE_NAME             = vllm                               (默认值)
  MODEL_NAME               = Qwen/Qwen2.5-0.5B-Instruct         (实例上的服务配置)
  VLLM_PORT                = 8000                               (实例上的服务配置)
  ...
以下为本脚本会写入的服务配置内容（--dry-run，未做任何变更）：
```

来源标注取值为 `命令行参数` / `环境变量` / `实例上的服务配置` / `默认值` 四种，据此可判断某项参数是否被本地临时值覆盖。

`vllm-start.sh` 退出码约定：`1` 参数不合法、`2` 缺少 systemd 或权限不足、`3` 服务未就绪、`4` 运行环境缺失（此时脚本会提示先 `cat /var/log/vllm-setup.log` 确认初始化进度）。

> 运行期用 `vllm-start.sh` 改出来的参数不会回写到 Terraform 声明。要让改动成为长期形态，请改 `terraform.tfvars` 后重新 `apply`；否则实例被替换后回到声明值。

> 客户端脚本与初始化脚本的提示文案里出现的是仓库相对路径（如 `src/serve/vllm-status.sh --port 8000`、`src/serve/vllm-logs.sh -n 100`）。在实例上按本步上传后，对应路径是 `/opt/src/serve/vllm-status.sh`、`/opt/src/serve/vllm-logs.sh`；若你把仓库整体检出到实例，则提示里的路径可直接照用。

---

## 第 12 步：释放资源

```bash
cd infra
terraform destroy -var-file=terraform.tfvars
```

预期输出：

```text
Plan: 0 to add, 0 to change, 11 to destroy.
Destroy complete! Resources: 11 destroyed.
```

要点：

- 伸缩组声明了 `delete_publicip = true`、`delete_volume = true`、`delete_instances = "yes"`，实例被移出时一并释放公网地址与磁盘，不留无人认领的资源。
- 复用的 VPC / 子网不由本实践创建，`destroy` 不会删除它们。
- 权重缓存随数据盘一并释放；需要保留权重供下次部署复用时，请在 `destroy` 前把 `/mnt/models` 的内容导出。
- 实践结束后请及时释放资源，避免残留。

---

## 附录：命令速查

| 目的 | 命令 |
|-|-|
| 配置校验 | `cd infra && terraform init && terraform validate` |
| 部署前离线自检 | `python -m unittest discover -s src/client -t src/client` |
| 预览 / 部署 / 释放 | `terraform plan` / `terraform apply` / `terraform destroy`（均在 `infra/` 内，带 `-var-file=terraform.tfvars`） |
| 取访问步骤 | `cd infra && terraform output access_guide` |
| 查伸缩组状态 | `cd infra && terraform state show huaweicloud_as_group.vllm` |
| 建访问通道 | `ssh -i <本地私钥文件> -N -L 8000:<实例私网IP>:8000 root@<实例公网IP>` |
| 健康探活 | `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/health` |
| 模型列表 | `python3 src/client/health_check.py --base-url http://127.0.0.1:8000/v1` |
| 非流式对话 | `python3 src/client/chat_completion.py --base-url http://127.0.0.1:8000/v1` |
| 流式对话 | `python3 src/client/stream_chat_completion.py --base-url http://127.0.0.1:8000/v1` |
| 实例内状态 / 日志 / 启停 | `/opt/src/serve/vllm-status.sh` / `vllm-logs.sh -n 50` / `vllm-start.sh` / `vllm-stop.sh`（需先上传，见第 11 步） |
