#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""离线单元测试：只验证请求体与请求参数的构造，不发起任何网络访问。

运行方式（任选其一，全程离线、无需本机安装 requests）：
  python3 src/client/test_smoke_client.py
  python3 -m unittest discover -s src/client -p "test_*.py"

实现要点：用桩模块替换 HTTP 层（requests）。桩只记录调用参数并回放预置响应，
不会建立任何连接；同时清理同名环境变量，保证断言与本机环境无关。
"""

import contextlib
import io
import os
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

AMBIENT_KEYS = (
    "VLLM_BASE_URL",
    "VLLM_EIP",
    "VLLM_PORT",
    "VLLM_API_KEY",
    "MODEL_NAME",
    "REQUEST_TIMEOUT",
    "MAX_TOKENS",
    "SMOKE_PROMPT",
    "SMOKE_SYSTEM_PROMPT",
    "SMOKE_TEMPERATURE",
)


# -----------------------------------------------------------------------------
# HTTP 层桩：在导入被测模块之前注册，避免依赖真实 requests
# -----------------------------------------------------------------------------
class RequestException(Exception):
    pass


class StubRequests(types.ModuleType):
    """记录调用参数并按 handler 回放响应。"""

    def __init__(self):
        super().__init__("requests")
        self.calls = []
        self.handler = None
        exceptions = types.ModuleType("requests.exceptions")
        for name in (
            "RequestException",
            "ConnectionError",
            "Timeout",
            "ConnectTimeout",
            "ReadTimeout",
        ):
            setattr(exceptions, name, type(name, (RequestException,), {}))
        self.exceptions = exceptions

    def reset(self, handler):
        self.calls = []
        self.handler = handler

    def _record(self, method, url, **kwargs):
        record = {"method": method, "url": url}
        record.update(kwargs)
        self.calls.append(record)
        response = self.handler(record)
        if response is None:
            raise AssertionError("桩未给 %s %s 准备响应" % (method, url))
        return response

    def get(self, url, headers=None, timeout=None):
        return self._record("GET", url, headers=headers, timeout=timeout)

    def post(self, url, headers=None, json=None, timeout=None, stream=False):
        return self._record("POST", url, headers=headers, json=json, timeout=timeout, stream=stream)


class StubResponse(object):
    def __init__(self, status_code=200, payload=None, text="", lines=None):
        self.status_code = status_code
        self._payload = payload
        self.text = text
        self._lines = lines or []

    def json(self):
        if self._payload is None:
            raise ValueError("no json body")
        return self._payload

    def iter_lines(self, decode_unicode=True):
        return iter(self._lines)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


REQUESTS = StubRequests()
sys.modules["requests"] = REQUESTS
sys.modules["requests.exceptions"] = REQUESTS.exceptions

import chat_completion  # noqa: E402  （必须在桩注册之后导入）
import client_common  # noqa: E402
import health_check  # noqa: E402
import smoke_common  # noqa: E402
import stream_chat_completion  # noqa: E402

MODEL_ID = "Qwen/Qwen2.5-0.5B-Instruct"
MODELS_PAYLOAD = {"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]}
CHAT_PAYLOAD = {
    "id": "cmpl-1",
    "object": "chat.completion",
    "model": MODEL_ID,
    "choices": [
        {"index": 0, "message": {"role": "assistant", "content": "好的。"}, "finish_reason": "stop"}
    ],
    "usage": {"prompt_tokens": 9, "completion_tokens": 2, "total_tokens": 11},
}


def default_handler(record):
    url = record["url"]
    if url.endswith("/health"):
        return StubResponse(200, text="ok")
    if url.endswith("/v1/models"):
        return StubResponse(200, payload=MODELS_PAYLOAD)
    if url.endswith("/v1/chat/completions"):
        if record.get("stream"):
            return StubResponse(
                200,
                lines=[
                    'data: {"choices":[{"delta":{"content":"你"}}]}',
                    "",
                    'data: {"choices":[{"delta":{"content":"好"}}]}',
                    "data: [DONE]",
                ],
            )
        return StubResponse(200, payload=CHAT_PAYLOAD)
    raise AssertionError("未预期的地址：%s" % url)


@contextlib.contextmanager
def isolated(handler=None):
    """清空相关环境变量并复位桩，返回记录到的调用列表。"""
    kept = {key: os.environ[key] for key in AMBIENT_KEYS if key in os.environ}
    for key in kept:
        del os.environ[key]
    REQUESTS.reset(handler or default_handler)
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            yield buffer
    finally:
        os.environ.update(kept)


class PayloadConstructionTest(unittest.TestCase):
    """请求体构造：字段集合、取值与顺序。"""

    def test_non_stream_payload_is_exactly_the_documented_shape(self):
        payload = client_common.build_chat_payload(
            model=MODEL_ID, prompt="你好", max_tokens=64, stream=False, system_prompt="你是运维助手"
        )
        self.assertEqual(
            payload,
            {
                "model": MODEL_ID,
                "messages": [
                    {"role": "system", "content": "你是运维助手"},
                    {"role": "user", "content": "你好"},
                ],
                "max_tokens": 64,
                "stream": False,
            },
        )
        self.assertEqual(list(payload.keys()), ["model", "messages", "max_tokens", "stream"])
        self.assertEqual(list(payload["messages"][0].keys()), ["role", "content"])

    def test_stream_payload_only_differs_by_stream_flag(self):
        streaming = client_common.build_chat_payload("m", "p", 32, True)
        self.assertTrue(streaming["stream"])
        self.assertEqual([m["role"] for m in streaming["messages"]], ["user"])

    def test_temperature_written_only_when_given(self):
        self.assertNotIn("temperature", client_common.build_chat_payload("m", "p", 16, False))
        payload = client_common.build_chat_payload("m", "p", 16, False, temperature=0.3)
        self.assertEqual(payload["temperature"], 0.3)

    def test_empty_system_prompt_is_omitted(self):
        self.assertEqual([m["role"] for m in client_common.build_messages("p", None)], ["user"])


class EndpointResolutionTest(unittest.TestCase):
    """地址取值优先级：显式地址 > 公网地址与端口拼接 > 占位符即报错。"""

    def parse(self, argv):
        with isolated():
            return client_common.build_arg_parser("test").parse_args(argv)

    def test_placeholder_eip_without_base_url_fails_locally(self):
        args = self.parse(["--eip", client_common.DEFAULT_EIP])
        self.assertEqual(args.eip, "<EIP_ADDRESS>")
        with self.assertRaises(smoke_common.SmokeError) as caught:
            client_common.resolve_base_url(args)
        self.assertEqual(caught.exception.code, smoke_common.EXIT_PROTOCOL)

    def test_eip_and_port_compose_public_address(self):
        args = self.parse(["--eip", "203.0.113.20", "--port", "8123"])
        self.assertEqual(client_common.resolve_base_url(args), "http://203.0.113.20:8123/v1")

    def test_base_url_wins_over_eip(self):
        args = self.parse(["--base-url", "http://127.0.0.1:8000/v1", "--eip", "203.0.113.20"])
        self.assertEqual(client_common.resolve_base_url(args), "http://127.0.0.1:8000/v1")

    def test_completion_and_models_url_join_prefix(self):
        base = "http://203.0.113.20:8000/v1"
        self.assertEqual(
            client_common.completion_url(base, client_common.CHAT_COMPLETIONS_PATH),
            "http://203.0.113.20:8000/v1/chat/completions",
        )
        self.assertEqual(client_common.models_url(base), "http://203.0.113.20:8000/v1/models")


class HttpRequestTest(unittest.TestCase):
    """通过桩断言真正发出去的请求：方法、地址、请求头、stream 标记与请求体。"""

    def test_non_stream_script_posts_expected_body(self):
        with isolated():
            code = chat_completion.main(
                [
                    "--base-url",
                    "http://127.0.0.1:8000/v1",
                    "--prompt",
                    "你好",
                    "--system-prompt",
                    "你是运维助手",
                    "--max-tokens",
                    "48",
                    "--temperature",
                    "0.2",
                ]
            )
            self.assertEqual(code, 0)
            posts = [c for c in REQUESTS.calls if c["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["url"], "http://127.0.0.1:8000/v1/chat/completions")
        self.assertFalse(posts[0]["stream"])
        self.assertEqual(posts[0]["headers"]["Content-Type"], "application/json")
        self.assertNotIn("Authorization", posts[0]["headers"])
        self.assertEqual(posts[0]["timeout"], smoke_common.DEFAULT_TIMEOUT)
        self.assertEqual(
            posts[0]["json"],
            {
                "model": MODEL_ID,
                "messages": [
                    {"role": "system", "content": "你是运维助手"},
                    {"role": "user", "content": "你好"},
                ],
                "max_tokens": 48,
                "stream": False,
                "temperature": 0.2,
            },
        )

    def test_stream_script_posts_stream_true_and_reads_chunks(self):
        with isolated() as out:
            code = stream_chat_completion.main(
                ["--base-url", "http://127.0.0.1:8000/v1", "--prompt", "你好"]
            )
            self.assertEqual(code, 0)
            posts = [c for c in REQUESTS.calls if c["method"] == "POST"]
            text = out.getvalue()
        self.assertEqual(len(posts), 1)
        self.assertTrue(posts[0]["stream"])
        self.assertTrue(posts[0]["json"]["stream"])
        self.assertEqual(list(posts[0]["json"].keys()), ["model", "messages", "max_tokens", "stream"])
        self.assertIn("你好", text)

    def test_model_check_lists_models_before_completion(self):
        with isolated():
            code = chat_completion.main(["--base-url", "http://127.0.0.1:8000/v1"])
            self.assertEqual(code, 0)
            urls = [c["url"] for c in REQUESTS.calls]
        self.assertEqual(urls[0], "http://127.0.0.1:8000/v1/models")
        self.assertEqual(urls[-1], "http://127.0.0.1:8000/v1/chat/completions")

    def test_skip_model_check_goes_straight_to_completion(self):
        with isolated():
            code = chat_completion.main(
                ["--base-url", "http://127.0.0.1:8000/v1", "--skip-model-check"]
            )
            self.assertEqual(code, 0)
            urls = [c["url"] for c in REQUESTS.calls]
        self.assertEqual(urls, ["http://127.0.0.1:8000/v1/chat/completions"])

    def test_api_key_control_authorization_header(self):
        payload = client_common.build_chat_payload("m", "p", 8, False)
        with isolated():
            smoke_common.post_completion(
                "http://127.0.0.1:8000/v1",
                client_common_placeholder(),
                5,
                client_common.CHAT_COMPLETIONS_PATH,
                payload,
            )
            self.assertNotIn("Authorization", REQUESTS.calls[-1]["headers"])
            smoke_common.post_completion(
                "http://127.0.0.1:8000/v1",
                "sk-placeholder-token",
                5,
                client_common.CHAT_COMPLETIONS_PATH,
                payload,
            )
            self.assertEqual(
                REQUESTS.calls[-1]["headers"]["Authorization"], "Bearer sk-placeholder-token"
            )

    def test_health_check_hits_health_then_models(self):
        with isolated() as out:
            code = health_check.main(["--base-url", "http://127.0.0.1:8000/v1"])
            self.assertEqual(code, 0)
            text = out.getvalue()
            urls = [c["url"] for c in REQUESTS.calls if c["method"] == "GET"]
        self.assertEqual(urls, ["http://127.0.0.1:8000/health", "http://127.0.0.1:8000/v1/models"])
        self.assertIn(MODEL_ID, text)

    def test_unknown_model_fails_with_model_exit_code_when_required(self):
        with self.assertRaises(SystemExit) as caught:
            with isolated():
                health_check.main(
                    [
                        "--base-url",
                        "http://127.0.0.1:8000/v1",
                        "--model",
                        "not-loaded-model",
                        "--require-model",
                    ]
                )
        self.assertEqual(caught.exception.code, smoke_common.EXIT_MODEL)

    def test_server_side_failure_maps_to_documented_exit_code(self):
        with isolated(lambda record: StubResponse(503, text="loading weights")):
            with self.assertRaises(smoke_common.SmokeError) as caught:
                smoke_common.list_models("http://127.0.0.1:8000/v1", "", 5)
        self.assertEqual(caught.exception.code, smoke_common.EXIT_SERVER)


def client_common_placeholder():
    """服务未启用访问密钥时的占位写法，不应产生 Authorization 头。"""
    return smoke_common.API_KEY_PLACEHOLDER


if __name__ == "__main__":
    unittest.main(verbosity=2)
