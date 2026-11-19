#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""非流式对话补全冒烟：一次请求拿到完整回答，并统计整体耗时。

用法示例（先按 client_common.py 的说明确定访问通道）：
  python3 chat_completion.py --base-url http://127.0.0.1:8000/v1
  python3 chat_completion.py --eip <EIP_ADDRESS> --prompt "你好，做个自我介绍"
  python3 chat_completion.py --model <模型名> --max-tokens 128 --temperature 0.7

取值优先级与全部可用环境变量见 client_common.py；退出码见 smoke_common.py。
依赖：Python 3.8 以上 + requests。
"""

import sys

from client_common import (
    DEFAULT_PROMPT,
    DEFAULT_SYSTEM_PROMPT,
    CHAT_COMPLETIONS_PATH,
    build_chat_payload,
    completion_url,
    prepare,
    build_arg_parser,
)
from smoke_common import SmokeError, post_completion, report_result, run_or_report

import os


def build_parser():
    parser = build_arg_parser("对推理服务发起一次非流式对话补全请求")
    parser.add_argument(
        "--prompt",
        default=os.environ.get("SMOKE_PROMPT") or DEFAULT_PROMPT,
        help="用户消息内容，可用环境变量 SMOKE_PROMPT 指定",
    )
    parser.add_argument(
        "--system-prompt",
        default=os.environ.get("SMOKE_SYSTEM_PROMPT") or DEFAULT_SYSTEM_PROMPT,
        help="系统消息内容；传空字符串则不发送系统消息",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=float(os.environ["SMOKE_TEMPERATURE"]) if os.environ.get("SMOKE_TEMPERATURE") else None,
        help="采样温度；不传则不写入请求体，由服务侧默认取值决定",
    )
    parser.add_argument(
        "--skip-model-check",
        action="store_true",
        help="跳过调用前的模型列表确认，直接发起补全请求",
    )
    return parser


def run(args):
    """构造请求体并发起一次非流式请求，返回退出码。"""
    base_url = prepare(args, verify_model=not args.skip_model_check)
    payload = build_chat_payload(
        model=args.model,
        prompt=args.prompt,
        max_tokens=args.max_tokens,
        stream=False,
        system_prompt=args.system_prompt or None,
        temperature=args.temperature,
    )
    url = completion_url(base_url, CHAT_COMPLETIONS_PATH)
    total, first_token, text, usage, chunks = post_completion(
        base_url, args.api_key, args.timeout, CHAT_COMPLETIONS_PATH, payload
    )
    report_result("非流式对话补全", args.model, total, first_token, text, usage, chunks, url)
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
