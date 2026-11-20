#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模型列表探活：确认服务已就绪，并列出服务实际加载的模型名。

用法示例（先按 client_common.py 的说明确定访问通道）：
  python3 health_check.py --base-url http://127.0.0.1:8000/v1
  python3 health_check.py --eip <EIP_ADDRESS>
  python3 health_check.py --model <模型名> --require-model

做三件事：
  1. GET <服务根地址>/health     判断进程是否已就绪（首次启动需加载权重）
  2. GET <接口前缀>/models       列出服务已加载的模型名
  3. 比对 --model 是否在列表中   请求体里的 model 必须与这里列出的名称完全一致

退出码：0 探活成功且模型匹配；非 0 见 smoke_common.py 的约定
（端口无响应 2、超时 3、地址不合法 7 等）；
模型不在列表中额外返回 5，用于让调用方区分「服务活着」与「模型名写错」。
依赖：Python 3.8 以上 + requests。
"""

import sys

from client_common import build_arg_parser, models_url, resolve_base_url
from smoke_common import (
    EXIT_MODEL,
    SmokeError,
    check_health,
    list_models,
    run_or_report,
)


def build_parser():
    parser = build_arg_parser("探测推理服务健康状态并列出已加载的模型")
    parser.add_argument(
        "--require-model",
        action="store_true",
        help="模型不在服务返回列表里时按失败退出（退出码 5）",
    )
    parser.add_argument(
        "--skip-health",
        action="store_true",
        help="跳过 /health 探测，只读取模型列表",
    )
    return parser


def run(args):
    """执行探活并打印结果，返回退出码。"""
    base_url = resolve_base_url(args)
    code = None
    if not args.skip_health:
        health_url, code = check_health(base_url, args.api_key, args.timeout)
        print("GET %s -> HTTP %d" % (health_url, code))

    url, models = list_models(base_url, args.api_key, args.timeout)
    print("GET %s -> 已返回模型列表" % url)
    if models:
        print("服务已加载模型（%d 个）：" % len(models))
        for name in models:
            mark = "  <= 本次 --model" if name == args.model else ""
            print("  %s%s" % (name, mark))
    else:
        print("服务返回的模型列表为空。")

    matched = args.model in models
    print("请求体 model  : %s（列表中%s）" % (args.model, "已存在" if matched else "不存在"))
    if args.require_model and not matched:
        raise SmokeError(
            "服务已加载的模型里没有 %s" % args.model,
            EXIT_MODEL,
            "服务列出：%s；请与 infra/variables.tf 的 var.model_name 或实例上服务的 --model 取值对齐。"
            % ", ".join(models),
        )
    print("结果          : 通过" if matched else "结果          : 服务可用，但模型名需确认")
    return 0


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:  # pragma: no cover - 交互中断
        sys.stderr.write("已中断。\n")
        return 130
    except SmokeError as exc:
        run_or_report(exc)


if __name__ == "__main__":
    sys.exit(main())
