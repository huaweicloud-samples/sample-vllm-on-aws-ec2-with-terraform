#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对话补全与探活脚本共用的取值与请求体构造。

依赖：Python 3.8 以上，以及 requests（`python3 -m pip install requests`）。
本模块与同目录脚本只访问推理服务，不访问云端管理接口，也不下载模型权重。

取值优先级：命令行参数 > 同名环境变量 > 下面的默认值。默认值一律是占位符，
仓库内不含任何真实地址与访问密钥。
  --eip / VLLM_EIP           推理实例的公网地址，默认占位符 <EIP_ADDRESS>
  --port / VLLM_PORT         服务监听端口，对应 var.vllm_port，默认 8000
  --base-url / VLLM_BASE_URL 接口地址。显式给出时优先，直接使用给定地址
  --api-key / VLLM_API_KEY   服务访问密钥，默认空（本实践的服务未启用访问密钥，
                             留空即不带 Authorization 头；若已启用则填入实际密钥）
  --model / MODEL_NAME       模型名称，对应 var.model_name
  --timeout / REQUEST_TIMEOUT 单次请求超时秒数，默认 60
  --max-tokens / MAX_TOKENS  生成上限，默认 64

访问通道两种，二选一：
  1. SSH 端口转发（默认部署形态即支持）：运维本机执行
       ssh -i <本地私钥文件> -N -L 8000:<实例私网IP>:8000 root@<实例公网IP>
     随后设 VLLM_BASE_URL=http://127.0.0.1:8000/v1，或 --base-url 传同值。
  2. 直接用公网地址访问：需先在安全组放通该端口（默认只放通运维网段的 SSH 入口），
     随后传 --eip <实例公网地址>，接口地址由 --eip 与 --port 组合得到。

退出码沿用 smoke_common.py 的约定，便于脚本化判断。
"""

import argparse
import os

from smoke_common import (
    DEFAULT_MAX_TOKENS,
    DEFAULT_MODEL,
    DEFAULT_TIMEOUT,
    EXIT_MODEL,
    EXIT_PROTOCOL,
    SmokeError,
    split_base_url,
    verify_model_available,
)

DEFAULT_EIP = "<EIP_ADDRESS>"

DEFAULT_PROMPT = "用一句话说明 GPU 加速实例适合承载什么样的推理服务。"
DEFAULT_SYSTEM_PROMPT = "你是运维助手，回答尽量简短。"

CHAT_COMPLETIONS_PATH = "chat/completions"
MODELS_PATH = "models"


# -----------------------------------------------------------------------------
# 参数面板
# -----------------------------------------------------------------------------
def build_arg_parser(description):
    """构造与 smoke_common.py 同名同义的参数面板，额外提供 --eip 与 --port。"""
    parser = argparse.ArgumentParser(
        description=description,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("VLLM_BASE_URL", ""),
        help="接口地址，可用环境变量 VLLM_BASE_URL 指定；留空时由 --eip 与 --port 组合",
    )
    parser.add_argument(
        "--eip",
        default=os.environ.get("VLLM_EIP") or DEFAULT_EIP,
        help="推理实例的公网地址，可用环境变量 VLLM_EIP 指定",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("VLLM_PORT") or 8000),
        help="服务监听端口（对应 var.vllm_port），仅在未显式给出 --base-url 时参与拼接",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL_NAME") or DEFAULT_MODEL,
        help="模型名称，需与服务实际加载的 model 完全一致（对应 var.model_name）",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("VLLM_API_KEY", ""),
        help="服务访问密钥，可用环境变量 VLLM_API_KEY 指定；留空表示服务未启用密钥",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("REQUEST_TIMEOUT") or DEFAULT_TIMEOUT),
        help="单次请求超时秒数，可用环境变量 REQUEST_TIMEOUT 指定",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=int(os.environ.get("MAX_TOKENS") or DEFAULT_MAX_TOKENS),
        help="生成上限，可用环境变量 MAX_TOKENS 指定",
    )
    return parser


def resolve_base_url(args):
    """按优先级得到接口地址：显式给出的地址优先，其次由公网地址与端口拼接。

    两者都拿不到可用值时给出可定位的失败，避免请求打到占位符地址上。
    """
    base_url = (getattr(args, "base_url", "") or "").strip()
    if base_url:
        return base_url

    eip = (getattr(args, "eip", "") or "").strip()
    if not eip or DEFAULT_EIP in eip:
        raise SmokeError(
            "接口地址未确定：--eip 仍是占位符 %s，且未给出 --base-url" % DEFAULT_EIP,
            EXIT_PROTOCOL,
            "二选一：1) 已建立端口转发时传 --base-url http://127.0.0.1:<端口>/v1"
            "（或设环境变量 VLLM_BASE_URL）；2) 直连公网地址时传 --eip <实例公网地址>"
            "（需先在安全组放通该端口）。",
        )
    return "http://%s:%d/v1" % (eip, args.port)


def completion_url(base_url, path):
    root, prefix = split_base_url(base_url)
    return "%s%s/%s" % (root, prefix, path.strip("/"))


def models_url(base_url):
    return completion_url(base_url, MODELS_PATH)


# -----------------------------------------------------------------------------
# 请求体构造
# -----------------------------------------------------------------------------
def build_messages(prompt, system_prompt=None):
    """按对话接口的约定组装 messages 列表：系统消息在首位，可省略。"""
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})
    return messages


def build_chat_payload(model, prompt, max_tokens, stream, system_prompt=None, temperature=None):
    """构造对话补全请求体。

    stream=True 时服务端以 SSE 分片返回；temperature 仅在显式给出时写入，
    避免覆盖服务侧的默认取值。
    """
    payload = {
        "model": model,
        "messages": build_messages(prompt, system_prompt),
        "max_tokens": max_tokens,
        "stream": stream,
    }
    if temperature is not None:
        payload["temperature"] = temperature
    return payload


# -----------------------------------------------------------------------------
# 通用执行骨架
# -----------------------------------------------------------------------------
def prepare(args, verify_model=True):
    """确认服务已就绪且模型名可调用，返回最终接口地址。"""
    base_url = resolve_base_url(args)
    if verify_model:
        try:
            verify_model_available(base_url, args.api_key, args.timeout, args.model, quiet=True)
        except SmokeError as exc:
            if exc.code != EXIT_MODEL:
                raise
            print("提示：%s" % exc.message)
            print("   仍按请求体 model=%s 发起调用，便于确认服务侧的实际取值。" % args.model)
    return base_url
