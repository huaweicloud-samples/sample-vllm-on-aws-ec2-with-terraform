#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OpenAI 兼容接口冒烟测试的公共部分。

依赖：Python 3.8 以上，以及 requests（`python3 -m pip install requests`）。
本模块只访问本机端口（默认 http://127.0.0.1:8000），不访问任何云端接口，
也不会下载模型权重；请求到达的是推理实例里已经跑起来的服务。

调用前提：先用 SSH 端口转发把实例的推理端口映射到运维本机同名端口
（完整命令见 terraform 输出里的 access_guide）。

取值优先级：命令行参数 > 同名环境变量 > 下面的默认值。
环境变量与 infra/variables.tf 的输入变量同名对应：
  MODEL_NAME           对应 var.model_name
  VLLM_PORT            对应 var.vllm_port（体现在 VLLM_BASE_URL 里）
  VLLM_BASE_URL        接口地址，默认 http://127.0.0.1:<VLLM_PORT>/v1
  VLLM_API_KEY         服务访问密钥；本实践的服务未启用密钥，留空即不带 Authorization 头。
                       若后续给服务加了访问密钥，把实际密钥填到这里，
                       文档与示例里一律写成占位符 <服务访问密钥>。
  REQUEST_TIMEOUT      单次请求超时秒数，默认 60
  MAX_TOKENS           单次请求生成的最大 token 数，默认 64

退出码约定（三个冒烟脚本一致，便于脚本化判断）：
  0 成功
  2 连不上服务：端口转发未建立，或服务还在加载权重
  3 请求超时
  4 认证失败（401/403）：密钥不对或服务要求密钥
  5 模型名不存在（404）：请求体里的 model 与服务实际加载的模型名不一致
  6 服务端返回 5xx
  7 响应结构不符合 OpenAI 接口约定
  8 缺少 requests 依赖
"""

import argparse
import json
import os
import socket
import sys
import time
import urllib.parse

try:
    import requests
except ImportError:  # pragma: no cover - 依赖缺失时给出可定位的提示
    sys.stderr.write(
        "错误：缺少 requests 依赖。\n"
        "   定位：python3 -c \"import requests\" 会报 ModuleNotFoundError。\n"
        "   处理：python3 -m pip install requests\n"
    )
    sys.exit(8)

DEFAULT_BASE_URL = "http://127.0.0.1:8000/v1"
DEFAULT_MODEL = "Qwen/Qwen2.5-0.5B-Instruct"
DEFAULT_TIMEOUT = 60.0
DEFAULT_MAX_TOKENS = 64
API_KEY_PLACEHOLDER = "<服务访问密钥>"

EXIT_OK = 0
EXIT_CONNECT = 2
EXIT_TIMEOUT = 3
EXIT_AUTH = 4
EXIT_MODEL = 5
EXIT_SERVER = 6
EXIT_PROTOCOL = 7
EXIT_DEPENDENCY = 8


class SmokeError(Exception):
    """带退出码与定位提示的失败。"""

    def __init__(self, message, code, hint=""):
        super().__init__(message)
        self.message = message
        self.code = code
        self.hint = hint

    def report(self):
        sys.stderr.write("错误：%s\n" % self.message)
        if self.hint:
            sys.stderr.write("   定位：%s\n" % self.hint)


# -----------------------------------------------------------------------------
# 参数与环境变量
# -----------------------------------------------------------------------------
def base_url_with_port(port):
    """按端口生成默认接口地址，端口对应 var.vllm_port。"""
    return "http://127.0.0.1:%d/v1" % port


def build_parser(description):
    parser = argparse.ArgumentParser(
        description=description,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("VLLM_BASE_URL") or DEFAULT_BASE_URL,
        help="OpenAI 兼容接口地址，可用环境变量 VLLM_BASE_URL 指定",
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
    parser.add_argument(
        "--no-stream",
        action="store_true",
        help="不使用流式返回（此时只统计整体耗时，不统计首个 token 延迟）",
    )
    return parser


def auth_headers(api_key):
    headers = {"Content-Type": "application/json"}
    if api_key and api_key != API_KEY_PLACEHOLDER:
        headers["Authorization"] = "Bearer %s" % api_key
    return headers


def split_base_url(base_url):
    """把 http://127.0.0.1:8000/v1 拆成 (服务根地址, 接口前缀)。"""
    parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
    if parsed.scheme not in ("http", "https"):
        raise SmokeError(
            "接口地址协议不合法：%s" % base_url,
            EXIT_PROTOCOL,
            "--base-url 需以 http:// 或 https:// 开头",
        )
    root = "%s://%s" % (parsed.scheme, parsed.netloc)
    prefix = parsed.path or "/v1"
    return root, prefix


# -----------------------------------------------------------------------------
# HTTP 调用与错误归类
# -----------------------------------------------------------------------------
def raise_for_response(response, url):
    """把 HTTP 状态码翻译成可定位的失败原因。"""
    code = response.status_code
    if 200 <= code < 300:
        return
    body = (response.text or "").strip().replace("\n", " ")[:300]
    if code in (401, 403):
        raise SmokeError(
            "服务拒绝该请求（HTTP %d）" % code,
            EXIT_AUTH,
            "接口要求访问密钥：用 --api-key %s 传入实际密钥，或设置环境变量 VLLM_API_KEY"
            % API_KEY_PLACEHOLDER,
        )
    if code == 404:
        raise SmokeError(
            "请求的资源不存在（HTTP 404）",
            EXIT_MODEL,
            "多为请求体里的 model 取值与服务实际加载的模型名不一致；"
            "先执行 health_check.py 看 /v1/models 列出的名称，或服务尚未加载完成：%s 返回 %s"
            % (url, body),
        )
    if code == 422:
        raise SmokeError(
            "请求体不符合接口约定（HTTP 422）",
            EXIT_PROTOCOL,
            "%s 返回 %s" % (url, body),
        )
    if 500 <= code < 600:
        raise SmokeError(
            "服务端返回 HTTP %d" % code,
            EXIT_SERVER,
            "登录实例查看服务日志：src/serve/vllm-logs.sh -n 100；返回内容：%s" % body,
        )
    raise SmokeError(
        "接口返回非预期状态码 HTTP %d" % code,
        EXIT_PROTOCOL,
        "%s 返回 %s" % (url, body),
    )


def http_get(url, api_key, timeout):
    try:
        response = requests.get(url, headers=auth_headers(api_key), timeout=timeout)
    except requests.exceptions.ConnectTimeout as exc:
        raise SmokeError(
            "连接 %s 超时" % url, EXIT_TIMEOUT, describe_connection_failure(url, exc)
        ) from exc
    except requests.exceptions.ReadTimeout as exc:
        raise SmokeError(
            "读取 %s 超时（已连接，服务端未在 %.0fs 内返回）" % (url, timeout),
            EXIT_TIMEOUT,
            "加载权重期间属正常现象，可加大 --timeout 后重试",
        ) from exc
    except requests.exceptions.ConnectionError as exc:
        raise SmokeError(
            "无法连接 %s" % url, EXIT_CONNECT, describe_connection_failure(url, exc)
        ) from exc
    raise_for_response(response, url)
    return response


def describe_connection_failure(url, exc):
    """连接类失败给出具体的排查次序。"""
    host = urllib.parse.urlsplit(url).hostname or ""
    port = urllib.parse.urlsplit(url).port or ""
    return (
        "端口 %s 上无响应。按次序确认："
        "1) 运维本机是否已建立端口转发（ssh -N -L %s:<实例私网IP>:%s root@<实例公网IP>）；"
        "2) 实例内服务是否已就绪（实例上执行 src/serve/vllm-status.sh --port %s）；"
        "3) 原始异常：%s"
        % (host, port, port, port, exc)
    )


# -----------------------------------------------------------------------------
# 健康检查与模型列表（三个冒烟脚本共用）
# -----------------------------------------------------------------------------
def check_health(base_url, api_key, timeout):
    root, _ = split_base_url(base_url)
    url = "%s/health" % root
    response = http_get(url, api_key, timeout)
    return url, response.status_code


def list_models(base_url, api_key, timeout):
    root, prefix = split_base_url(base_url)
    url = "%s%s/models" % (root, prefix)
    response = http_get(url, api_key, timeout)
    try:
        payload = response.json()
    except ValueError as exc:
        raise SmokeError(
            "%s 返回的不是合法 JSON" % url,
            EXIT_PROTOCOL,
            "响应前 200 字符：%s" % (response.text or "")[:200],
        ) from exc
    models = [item.get("id", "") for item in payload.get("data", []) if isinstance(item, dict)]
    return url, models


def verify_model_available(base_url, api_key, timeout, model, quiet=False):
    """确认服务已就绪且模型名可被调用，返回服务列出的模型名列表。"""
    _, models = list_models(base_url, api_key, timeout)
    if models and model not in models:
        raise SmokeError(
            "服务已加载的模型里没有 %s" % model,
            EXIT_MODEL,
            "服务列出：%s；请求体里的 model 需与之完全一致（对应 var.model_name）"
            % ", ".join(models),
        )
    if not quiet:
        print("服务已加载模型：%s" % (", ".join(models) if models else "（列表为空）"))
    return models


# -----------------------------------------------------------------------------
# 请求发送与首 token 延迟统计
# -----------------------------------------------------------------------------
def post_completion(base_url, api_key, timeout, path, payload):
    """发送一次生成请求，返回 (整体耗时, 首 token 延迟, 文本, usage, 分片数)。

    流式返回时逐行读取 SSE，首个非空内容分片即视为首 token；
    非流式时首 token 延迟为 None，只有整体耗时。
    """
    root, prefix = split_base_url(base_url)
    url = "%s%s/%s" % (root, prefix, path)
    stream = payload.get("stream", False)

    try:
        started = time.monotonic()
        response = requests.post(
            url,
            headers=auth_headers(api_key),
            json=payload,
            timeout=timeout,
            stream=stream,
        )
    except requests.exceptions.ConnectionError as exc:
        raise SmokeError("无法连接 %s" % url, EXIT_CONNECT, describe_connection_failure(url, exc)) from exc
    except requests.exceptions.Timeout as exc:
        raise SmokeError(
            "请求 %s 超时（%.0fs）" % (url, timeout),
            EXIT_TIMEOUT,
            "首次调用需加载模型权重，可加大 --timeout 后重试",
        ) from exc

    with response:
        raise_for_response(response, url)
        if not stream:
            try:
                body = response.json()
            except ValueError as exc:
                raise SmokeError(
                    "%s 返回的不是合法 JSON" % url,
                    EXIT_PROTOCOL,
                    "响应前 200 字符：%s" % (response.text or "")[:200],
                ) from exc
            total = time.monotonic() - started
            return total, None, extract_text(body), body.get("usage"), 1

        chunks = []
        first_token = None
        for raw in response.iter_lines(decode_unicode=True):
            if not raw:
                continue
            if not raw.startswith("data:"):
                continue
            data = raw[len("data:"):].strip()
            if data == "[DONE]":
                break
            try:
                piece = json.loads(data)
            except ValueError as exc:
                raise SmokeError(
                    "流式分片不是合法 JSON",
                    EXIT_PROTOCOL,
                    "分片内容：%s（%s）" % (data[:120], exc),
                ) from exc
            text = extract_text(piece)
            if text:
                if first_token is None:
                    first_token = time.monotonic() - started
                chunks.append(text)
        total = time.monotonic() - started
        usage = piece.get("usage") if chunks and "piece" in dir() else None
        return total, first_token, "".join(chunks), usage, len(chunks)


def extract_text(body):
    """从 chat 与 completions 两类响应里取出文本内容。"""
    choices = body.get("choices") or []
    if not choices:
        return ""
    first = choices[0] or {}
    message = first.get("message") or {}
    if message.get("content"):
        return message["content"]
    if first.get("text"):
        return first["text"]
    delta = first.get("delta") or {}
    return delta.get("content") or ""


def format_ms(seconds):
    return "-" if seconds is None else "%.0f ms" % (seconds * 1000.0)


def report_result(title, model, total, first_token, text, usage, chunks, url):
    print("--- %s ---" % title)
    print("接口地址      : %s" % url)
    print("模型          : %s" % model)
    print("首 token 延迟 : %s" % format_ms(first_token))
    print("整体耗时      : %s" % format_ms(total))
    print("返回分片数    : %d" % chunks)
    if usage:
        print(
            "token 统计    : prompt=%s completion=%s total=%s"
            % (
                usage.get("prompt_tokens", "-"),
                usage.get("completion_tokens", "-"),
                usage.get("total_tokens", "-"),
            )
        )
    preview = (text or "").strip().replace("\n", " ")
    print("返回内容      : %s" % (preview[:200] if preview else "（空）"))
    if not preview:
        print("提示          : 服务返回了空内容，请检查 max_tokens 是否过小或服务日志。")
    print("结果          : 通过")


def run_or_report(error):
    """统一输出失败信息并按约定退出码结束进程。"""
    if isinstance(error, SmokeError):
        error.report()
        sys.exit(error.code)
    if isinstance(error, requests.exceptions.RequestException):
        SmokeError("请求失败：%s" % error, EXIT_PROTOCOL, "接口地址与端口转发是否可用").report()
        sys.exit(EXIT_PROTOCOL)
    raise error


def port_of(base_url):
    try:
        return int(urllib.parse.urlsplit(base_url).port or 0)
    except ValueError:
        return 0


def tcp_probe(host, port, timeout=2.0):
    """在报错前先判断端口是否有进程监听，便于区分「隧道没建」与「服务没起」。"""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False
