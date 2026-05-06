#!/usr/bin/env python3
"""
波特槌 — lightning-whisper-mlx HTTP daemon

設計原則：
  KISS  : Python stdlib http.server，無額外 web framework 依賴
  SOLID : 模型生命週期 (ModelCache) 與 HTTP handler 分離
  DRY   : 認證 / 路由共用 helper
  DDD   : 領域只有「轉錄」與「模型切換」兩件事

安全：
  - 綁 127.0.0.1（絕不對外）
  - Bearer token 防本機其他程序誤打
  - port 自動避撞（18120..18130）

使用：
  python3 lwm_daemon.py            # 前景啟動（lwm_daemon_ctl.sh 用 nohup 包進背景）
  python3 lwm_daemon.py --port 0   # 由 OS 配 port
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

CONFIG_DIR = Path(os.environ.get("BOTRUN_HAMMER_HOME", str(Path.home() / ".botrun-hammer")))
TOKEN_FILE = CONFIG_DIR / "lwm.token"
PORT_FILE = CONFIG_DIR / "lwm.port"
PID_FILE = CONFIG_DIR / "lwm.pid"
LOG_FILE = CONFIG_DIR / "lwm.log"

DEFAULT_PORT_RANGE = range(18120, 18131)

# v1.7.9: 改用 Apple 官方 mlx-whisper（支援 large-v3-turbo，多語）
# 模型名稱 → HuggingFace MLX repo 映射
HF_REPO_MAP = {
    "tiny":            "mlx-community/whisper-tiny-mlx",
    "small":           "mlx-community/whisper-small-mlx",
    "medium":          "mlx-community/whisper-medium-mlx",
    "large":           "mlx-community/whisper-large-mlx",
    "large-v2":        "mlx-community/whisper-large-v2-mlx",
    "large-v3":        "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo":  "mlx-community/whisper-large-v3-turbo",
    # 英文專用（保留可用但不推薦繁中）
    "distil-medium.en":  "mlx-community/distil-whisper-medium.en",
    "distil-large-v3":   "mlx-community/distil-whisper-large-v3",
}
SUPPORTED_MODELS = list(HF_REPO_MAP.keys())
SUPPORTED_QUANTS = [None, "4bit", "8bit"]  # 保留參數但目前 mlx-whisper 走 repo 內建量化
DEFAULT_MODEL = os.environ.get("LWM_DEFAULT_MODEL", "large-v3-turbo")
DEFAULT_QUANT = os.environ.get("LWM_DEFAULT_QUANT") or None
MAX_AUDIO_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB hard cap


def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with LOG_FILE.open("a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


class ModelCache:
    """v1.7.9: 改用 mlx-whisper，預載 model object 避免每次 transcribe 重 mmap。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._model = None
        self._key: str | None = None
        self._loaded_at: float | None = None

    def _resolve_repo(self, model_name: str) -> str:
        # 直接吃 hf repo 字串（含 / 視為 repo path）
        if "/" in model_name:
            return model_name
        if model_name not in HF_REPO_MAP:
            raise ValueError(f"unsupported model: {model_name} (not in HF_REPO_MAP)")
        return HF_REPO_MAP[model_name]

    def get_repo(self, model_name: str) -> str:
        repo = self._resolve_repo(model_name)
        with self._lock:
            if self._key != model_name or self._model is None:
                from mlx_whisper.load_models import load_model
                log(f"model load: {model_name} -> {repo}")
                self._model = None  # 釋放舊
                t0 = time.time()
                self._model = load_model(repo)
                self._loaded_at = time.time()
                self._key = model_name
                log(f"model loaded in {self._loaded_at - t0:.2f}s")
            return repo

    def info(self) -> dict:
        with self._lock:
            if self._key is None:
                return {"model_loaded": False, "model_name": None, "quant": None}
            return {
                "model_loaded": True,
                "model_name": self._key,
                "quant": None,
                "loaded_at": self._loaded_at,
                "repo": self._resolve_repo(self._key),
            }


class AuthError(Exception):
    pass


def ensure_token() -> str:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    token = secrets.token_hex(32)
    TOKEN_FILE.write_text(token)
    TOKEN_FILE.chmod(0o600)
    return token


def pick_port() -> int:
    for port in DEFAULT_PORT_RANGE:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError(f"no free port in {DEFAULT_PORT_RANGE}")


def make_handler(token: str, cache: ModelCache, started_at: float):
    class Handler(BaseHTTPRequestHandler):
        # 靜默 stdout（log 自己處理）
        def log_message(self, fmt: str, *args) -> None:  # noqa: N802
            return

        def _check_auth(self) -> None:
            hdr = self.headers.get("Authorization", "")
            if not hdr.startswith("Bearer "):
                raise AuthError("missing bearer")
            if not secrets.compare_digest(hdr[7:].strip(), token):
                raise AuthError("invalid token")

        def _json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _qs(self) -> dict[str, str]:
            qs = parse_qs(urlparse(self.path).query)
            return {k: v[0] for k, v in qs.items()}

        def _route(self) -> str:
            return urlparse(self.path).path

        def do_GET(self) -> None:  # noqa: N802
            log(f"GET {self.path} from {self.client_address[0]}")
            try:
                self._check_auth()
            except AuthError as exc:
                log(f"GET {self.path} auth failed: {exc}")
                return self._json(401, {"error": str(exc)})

            route = self._route()
            if route == "/health":
                info = cache.info()
                info.update({"ok": True, "uptime_s": time.time() - started_at, "version": "1.7.0"})
                return self._json(200, info)
            if route == "/models":
                return self._json(200, {"models": SUPPORTED_MODELS, "quants": SUPPORTED_QUANTS})
            return self._json(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            log(f"POST {self.path} content_len={self.headers.get('Content-Length', '?')} from {self.client_address[0]}")
            try:
                self._check_auth()
            except AuthError as exc:
                log(f"POST {self.path} auth failed: {exc}")
                return self._json(401, {"error": str(exc)})

            route = self._route()
            qs = self._qs()
            model = qs.get("model", DEFAULT_MODEL)
            quant_raw = qs.get("quant")
            quant = None if quant_raw in (None, "", "none", "None") else quant_raw

            if route == "/switch_model":
                t0 = time.time()
                try:
                    cache.get_repo(model)
                except Exception as exc:
                    return self._json(500, {"error": str(exc)})
                return self._json(200, {"ok": True, "loaded_in_s": time.time() - t0, "model": model})

            if route == "/transcribe":
                length = int(self.headers.get("Content-Length", "0"))
                log(f"transcribe: bytes={length} model={model} quant={quant} lang={qs.get('lang')}")
                if length <= 0:
                    return self._json(400, {"error": "empty body"})
                if length > MAX_AUDIO_BYTES:
                    return self._json(413, {"error": "audio too large"})
                suffix = qs.get("ext", ".m4a")
                if not suffix.startswith("."):
                    suffix = "." + suffix
                read_t0 = time.time()
                with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                    remaining = length
                    while remaining > 0:
                        chunk = self.rfile.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        tmp.write(chunk)
                        remaining -= len(chunk)
                    tmp_path = tmp.name
                log(f"transcribe: body received in {time.time() - read_t0:.2f}s, tmp={tmp_path}")
                try:
                    repo = cache.get_repo(model)
                    import mlx_whisper
                    t0 = time.time()
                    lang = qs.get("lang") or None
                    kwargs = {"path_or_hf_repo": repo}
                    if lang:
                        kwargs["language"] = lang
                    result = mlx_whisper.transcribe(tmp_path, **kwargs)
                    text = (result.get("text") if isinstance(result, dict) else str(result)) or ""
                    latency = time.time() - t0
                    log(f"transcribe ok bytes={length} model={model} quant={quant} latency={latency:.2f}s text_len={len(text)}")
                    return self._json(200, {
                        "text": text.strip(),
                        "latency_ms": int(latency * 1000),
                        "model": model,
                        "quant": quant,
                        "audio_bytes": length,
                    })
                except Exception as exc:
                    log(f"transcribe error: {exc!r}")
                    return self._json(500, {"error": repr(exc)})
                finally:
                    try:
                        os.unlink(tmp_path)
                    except OSError:
                        pass

            if route == "/shutdown":
                threading.Thread(target=lambda: (time.sleep(0.2), os._exit(0)), daemon=True).start()
                return self._json(200, {"ok": True})

            return self._json(404, {"error": "not found"})

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=None, help="0=auto, default=18120 range")
    parser.add_argument("--preload", action="store_true", help="預載 default 模型")
    args = parser.parse_args()

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    token = ensure_token()
    port = args.port if args.port is not None else pick_port()

    cache = ModelCache()
    started_at = time.time()

    if args.preload:
        try:
            cache.get_repo(DEFAULT_MODEL)
        except Exception as exc:
            log(f"preload failed: {exc!r}")

    handler_cls = make_handler(token, cache, started_at)
    server = ThreadingHTTPServer(("127.0.0.1", port), handler_cls)
    actual_port = server.server_address[1]
    PORT_FILE.write_text(str(actual_port))
    port = actual_port
    PID_FILE.write_text(str(os.getpid()))
    log(f"daemon listen 127.0.0.1:{port} pid={os.getpid()} token_file={TOKEN_FILE}")

    def shutdown(*_):
        log("shutdown signal received")
        server.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    finally:
        for f in (PORT_FILE, PID_FILE):
            try:
                f.unlink()
            except OSError:
                pass
        log("daemon exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
