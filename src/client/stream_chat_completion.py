#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流式对话补全冒烟：请求体 stream=true，逐分片读取 SSE 并统计首 token 延迟。

用法示例（先按 client_common.py 的说明确定访问通道）：
  python3 stream_chat_completion.py --base-url http://127.0.0.1:8000/v1
  python3 stream_chat_completion.py --eip <EIP_ADDRESS> --prompt "讲一个短笑话"
  python3 stream_chat_completion.py --max-tokens 128

输出包含首 token 延迟、整体耗时与返回分片数，用于判断服务侧是否真的按流式返回。
取值优先级与全部可用环境变量见 client_common.py；退出码见 smoke_common.py。
依赖：Python 3.8 以上 + requests。
"""

import os
import sys

from client_common import (
    CHAT_COMPLETIONS_PATH,
    DEFAULT_PROMPT,
    DEFAULT_SYSTEM_PROMPT,
    build_arg_parser,
    build_chat_payload,
    completion_url,
    prepare,
)
from smoke_common import SmokeError, post_completion, report_result, run_or_report


def build_parser():
    parser = build_arg_parser("对推理服务发起一次流式对话补全请求")
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
        "--show-chunks",
        action="store_true",
        help="把每个分片的内容逐行打印出来（默认只打印汇总）",
    )
    parser.add_argument(
        "--skip-model-check",
        action="store_true",
        help="跳过调用前的模型列表确认，直接发起补全请求",
    )
    return parser


def run(args):
    """构造 stream=true 的请求体并读取分片，返回退出码。"""
    base_url = prepare(args, verify_model=not args.skip_model_check)
    payload = build_chat_payload(
        model=args.model,
        prompt=args.prompt,
        max_tokens=args.max_tokens,
        stream=True,
        system_prompt=args.system_prompt or None,
        temperature=args.temperature,
    )
    url = completion_url(base_url, CHAT_COMPLETIONS_PATH)
    print("请求体 stream=%s，逐分片读取 SSE。" % payload["stream"])
    total, first_token, text, usage, chunks = post_completion(
        base_url, args.api_key, args.timeout, CHAT_COMPLETIONS_PATH, payload
    )
    if args.show_chunks and text:
        print("--- 分片内容 ---")
        for index, piece in enumerate(text.splitlines() or [text], start=1):
            print("%02d %s" % (index, piece))
    report_result("流式对话补全", args.model, total, first_token, text, usage, chunks, url)
    if first_token is None:
        print("提示          : 未读到任何非空分片，请确认服务是否以流式返回（--show-chunks 可看细节）。")
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
