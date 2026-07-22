#!/usr/bin/env python3
"""
波特槌 — mlx-whisper HTTP daemon

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
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# v1.9.0 地雷：MLX 的 default stream 是 thread-local。
# ThreadingHTTPServer 每個 request 起新 thread，會出現
# "There is no Stream(gpu, N) in current thread." 因為模型權重 allocated 在
# load thread 的 stream，但 generate 跑在不同 thread。
# 修法：把所有 MLX 操作（load/transcribe）丟進固定單一 worker thread 執行。
MLX_WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")

CONFIG_DIR = Path(os.environ.get("BOTRUN_HAMMER_HOME", str(Path.home() / ".botrun-hammer")))
TOKEN_FILE = CONFIG_DIR / "lwm.token"
PORT_FILE = CONFIG_DIR / "lwm.port"
PID_FILE = CONFIG_DIR / "lwm.pid"
LOG_FILE = CONFIG_DIR / "lwm.log"

DEFAULT_PORT_RANGE = range(18120, 18131)
DAEMON_VERSION = "1.11.0"  # v1.11.0: 加 Breeze-ASR 全精度 backend（whisper + gemma-4 + breeze）

# v1.7.9: 改用 Apple 官方 mlx-whisper（支援 large-v3-turbo，多語）
HF_REPO_MAP = {
    "tiny":            "mlx-community/whisper-tiny-mlx",
    "small":           "mlx-community/whisper-small-mlx",
    "medium":          "mlx-community/whisper-medium-mlx",
    "large":           "mlx-community/whisper-large-mlx",
    "large-v2":        "mlx-community/whisper-large-v2-mlx",
    "large-v3":        "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo":  "mlx-community/whisper-large-v3-turbo",
    "distil-medium.en":  "mlx-community/distil-whisper-medium.en",
    "distil-large-v3":   "mlx-community/distil-whisper-large-v3",
}

# v1.9.0: Gemma 4 audio backend (via mlx-vlm)
# 注意：Gemma 4 audio 硬限 30 秒（25 tokens/sec * 30s = 750 audio tokens）
GEMMA_REPO_MAP = {
    "gemma-4-e2b":  "google/gemma-4-e2b-it",
    "gemma-4-e4b":  "google/gemma-4-e4b-it",
}
GEMMA_MAX_AUDIO_SEC = 30.0

# v1.11.0: Breeze-ASR（聯發創新基地）全精度本機 backend（transformers + torch，非 MLX 量化）。
#   - breeze-asr-26：Whisper-large-v2 微調，台語（Taigi）→ 華語漢字轉錄
#   - breeze-asr-25：Whisper-large-v2 微調，台灣華語 + 華英混用（code-switching）
# 全精度＝直接載 F32 safetensors，跑在 Apple Silicon MPS（無官方 MLX 權重，故走 PyTorch）。
BREEZE_REPO_MAP = {
    "breeze-asr-26": "MediaTek-Research/Breeze-ASR-26",
    "breeze-asr-25": "MediaTek-Research/Breeze-ASR-25",
}

SUPPORTED_MODELS = (
    list(HF_REPO_MAP.keys()) + list(GEMMA_REPO_MAP.keys()) + list(BREEZE_REPO_MAP.keys())
)
SUPPORTED_QUANTS = [None, "4bit", "8bit"]
DEFAULT_MODEL = os.environ.get("LWM_DEFAULT_MODEL", "large-v3")
DEFAULT_QUANT = os.environ.get("LWM_DEFAULT_QUANT") or None
MAX_AUDIO_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB hard cap


def is_gemma_model(name: str) -> bool:
    """Dispatcher key — KISS: 前綴判別即可，新引擎加 elseif 一行."""
    return name.startswith("gemma-") or name in GEMMA_REPO_MAP


def is_breeze_model(name: str) -> bool:
    """v1.11.0: Breeze-ASR 全精度 backend 的 dispatcher key."""
    return name.startswith("breeze-") or name in BREEZE_REPO_MAP


def probe_audio_duration(path: str) -> float | None:
    """用 ffprobe 拿音檔長度（秒）。失敗回 None（不阻擋轉錄）。"""
    import subprocess
    for ffp in ("/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "ffprobe"):
        try:
            out = subprocess.check_output(
                [ffp, "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", path],
                stderr=subprocess.DEVNULL, timeout=10,
            )
            return float(out.decode().strip())
        except (FileNotFoundError, subprocess.SubprocessError, ValueError):
            continue
    return None


def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with LOG_FILE.open("a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


class TranscribeError(Exception):
    """Domain error — 由 backend 拋出，dispatcher 對映 HTTP status."""
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status = status
        self.msg = msg


class Backend:
    """DDD: 「給音檔出文字」的領域介面。子類各自決定怎麼載模型、怎麼 transcribe."""
    name: str = "base"

    def load(self, model_name: str) -> str:  # returns repo path used
        raise NotImplementedError

    def transcribe(self, audio_path: str, model_name: str, lang: str | None) -> str:
        raise NotImplementedError


class WhisperBackend(Backend):
    """v1.7.9 既有 mlx-whisper 路徑."""
    name = "whisper"

    def __init__(self) -> None:
        self._model = None
        self._key: str | None = None

    def _resolve_repo(self, model_name: str) -> str:
        if "/" in model_name:
            return model_name
        if model_name not in HF_REPO_MAP:
            raise TranscribeError(400, f"unsupported whisper model: {model_name}")
        return HF_REPO_MAP[model_name]

    def load(self, model_name: str) -> str:
        repo = self._resolve_repo(model_name)
        if self._key != model_name or self._model is None:
            from mlx_whisper.load_models import load_model
            log(f"[whisper] load {model_name} -> {repo}")
            self._model = None
            t0 = time.time()
            self._model = load_model(repo)
            log(f"[whisper] loaded in {time.time() - t0:.2f}s")
            self._key = model_name
        return repo

    def transcribe(self, audio_path: str, model_name: str, lang: str | None) -> str:
        repo = self.load(model_name)
        import mlx_whisper
        kwargs = {"path_or_hf_repo": repo}
        if lang:
            kwargs["language"] = lang
        result = mlx_whisper.transcribe(audio_path, **kwargs)
        return (result.get("text") if isinstance(result, dict) else str(result)) or ""


class GemmaAudioBackend(Backend):
    """v1.9.0: Gemma 4 audio (mlx-vlm). 硬限 30s.

    懶載入策略：第一次用到才 import mlx_vlm（避免雲端使用者吃 ~2GB 依賴）。
    """
    name = "gemma-audio"

    def __init__(self) -> None:
        self._model = None
        self._processor = None
        self._key: str | None = None

    def _resolve_repo(self, model_name: str) -> str:
        if "/" in model_name:
            return model_name
        if model_name not in GEMMA_REPO_MAP:
            raise TranscribeError(400, f"unsupported gemma model: {model_name}")
        return GEMMA_REPO_MAP[model_name]

    def load(self, model_name: str) -> str:
        repo = self._resolve_repo(model_name)
        if self._key != model_name or self._model is None:
            try:
                from mlx_vlm import load as vlm_load
            except ImportError as exc:
                raise TranscribeError(
                    501,
                    f"mlx-vlm 未安裝。請跑：pip install mlx-vlm torchvision  詳：{exc}",
                )
            log(f"[gemma-audio] load {model_name} -> {repo}")
            self._model = None
            self._processor = None
            t0 = time.time()
            self._model, self._processor = vlm_load(repo)
            log(f"[gemma-audio] loaded in {time.time() - t0:.2f}s")
            self._key = model_name
        return repo

    def transcribe(self, audio_path: str, model_name: str, lang: str | None) -> str:
        # 30s 上限檢查
        duration = probe_audio_duration(audio_path)
        if duration is not None and duration > GEMMA_MAX_AUDIO_SEC:
            raise TranscribeError(
                422,
                f"Gemma 4 audio max {GEMMA_MAX_AUDIO_SEC}s, got {duration:.1f}s. "
                f"請改用 whisper 模型（large-v3 或 large-v3-turbo）做長音轉錄。",
            )
        self.load(model_name)
        from mlx_vlm import generate as vlm_generate
        from mlx_vlm.prompt_utils import apply_chat_template

        # 中文 prompt 引導，避免 echo prompt
        lang_hint = "繁體中文" if (lang or "").startswith("zh") else (lang or "the same language as the audio")
        instruction = f"請逐字轉錄這段音訊，使用{lang_hint}輸出。只輸出轉錄文字，不要任何前後說明。"
        prompt = apply_chat_template(
            self._processor, self._model.config, instruction, num_audios=1,
        )
        result = vlm_generate(
            model=self._model, processor=self._processor, prompt=prompt,
            audio=[audio_path], max_tokens=500,
            temperature=0.0,  # 轉錄任務 deterministic
        )
        # mlx-vlm v0.1+ 回 GenerationResult dataclass 或 str
        text = getattr(result, "text", None) or str(result)
        # strip prompt echo / 角色標記
        for prefix in ("model\n", "assistant\n", "Transcription:", "轉錄："):
            if text.startswith(prefix):
                text = text[len(prefix):]
        return text.strip()


class BreezeBackend(Backend):
    """v1.11.0: Breeze-ASR 全精度（transformers + torch）.

    為何不走 mlx-whisper：Breeze-ASR-26/25 官方只出 F32 safetensors（PyTorch），
    無官方 MLX 權重；「全精度」即直接載 F32 跑 HF pipeline，不做任何量化。
    Apple Silicon 上優先用 MPS，否則退回 CPU。長音檔用 chunk_length_s 切塊處理。

    懶載入：第一次用到才 import torch / transformers（避免雲端使用者吃 ~3GB 依賴）。
    """
    name = "breeze"

    def __init__(self) -> None:
        self._pipe = None
        self._key: str | None = None

    def _resolve_repo(self, model_name: str) -> str:
        if "/" in model_name:
            return model_name
        if model_name not in BREEZE_REPO_MAP:
            raise TranscribeError(400, f"unsupported breeze model: {model_name}")
        return BREEZE_REPO_MAP[model_name]

    def load(self, model_name: str) -> str:
        repo = self._resolve_repo(model_name)
        if self._key != model_name or self._pipe is None:
            try:
                import torch
                from transformers import pipeline
            except ImportError as exc:
                raise TranscribeError(
                    501,
                    "transformers/torch 未安裝。請跑："
                    "~/.botrun-hammer/venv/bin/pip install transformers torch accelerate "
                    f"詳：{exc}",
                )
            # 全精度：F32。MPS 對 fp16 的部分算子支援不穩，故本機一律 fp32。
            if torch.backends.mps.is_available():
                device, dtype = "mps", torch.float32
            elif torch.cuda.is_available():
                device, dtype = "cuda", torch.float16
            else:
                device, dtype = "cpu", torch.float32
            log(f"[breeze] load {model_name} -> {repo} device={device} dtype={dtype}")
            self._pipe = None
            t0 = time.time()
            self._pipe = pipeline(
                "automatic-speech-recognition",
                model=repo,
                torch_dtype=dtype,
                device=device,
                chunk_length_s=28,   # <30s Whisper 窗口，長音檔自動切塊
            )
            log(f"[breeze] loaded in {time.time() - t0:.2f}s")
            self._key = model_name
        return repo

    def transcribe(self, audio_path: str, model_name: str, lang: str | None) -> str:
        self.load(model_name)
        # Breeze-26 台語→華語漢字；Breeze 系皆 Whisper-large-v2 微調，
        # 預設讓模型自行判語言（強制 language 反而可能干擾微調行為）。
        # 若呼叫端明確指定 lang 才轉成 whisper generate 參數。
        generate_kwargs = {"task": "transcribe"}
        if lang:
            generate_kwargs["language"] = lang
        result = self._pipe(
            audio_path,
            return_timestamps=True,   # 長音檔（>30s）切塊必須開，否則 transformers 報錯
            generate_kwargs=generate_kwargs,
        )
        if isinstance(result, dict):
            return (result.get("text") or "").strip()
        return str(result).strip()


class BackendCache:
    """v1.9.0: 依 model name 路由 backend；同時只保留一個 backend 載入的權重."""

    # v1.11.0: backend 種類 -> 工廠，方便切換時「釋放非當前 backend」而不寫死每個分支
    _FACTORIES = {
        "gemma": GemmaAudioBackend,
        "breeze": BreezeBackend,
        "whisper": WhisperBackend,
    }

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._backends: dict[str, Backend] = {k: f() for k, f in self._FACTORIES.items()}
        self._current: Backend | None = None
        self._current_model: str | None = None
        self._loaded_at: float | None = None

    def _kind(self, model_name: str) -> str:
        if is_gemma_model(model_name):
            return "gemma"
        if is_breeze_model(model_name):
            return "breeze"
        return "whisper"

    def _pick(self, model_name: str) -> Backend:
        return self._backends[self._kind(model_name)]

    def _load_impl(self, model_name: str) -> str:
        backend = self._pick(model_name)
        if self._current is not None and self._current is not backend:
            log(f"backend switch: {self._current.name} -> {backend.name}; free others")
            # 釋放除目標外的所有 backend 權重（重建工廠即丟棄舊模型，讓 GC/MLX 回收）
            for kind, fac in self._FACTORIES.items():
                if self._backends[kind] is not backend:
                    self._backends[kind] = fac()
            backend = self._pick(model_name)
        repo = backend.load(model_name)
        self._current = backend
        self._current_model = model_name
        self._loaded_at = time.time()
        return repo

    def load(self, model_name: str) -> str:
        # 路由到 MLX worker thread（避免 stream-thread mismatch）
        with self._lock:
            return MLX_WORKER.submit(self._load_impl, model_name).result()

    def _transcribe_impl(self, audio_path: str, model_name: str, lang: str | None) -> str:
        backend = self._pick(model_name)
        if self._current is not backend or self._current_model != model_name:
            self._load_impl(model_name)
            backend = self._pick(model_name)
        return backend.transcribe(audio_path, model_name, lang)

    def transcribe(self, audio_path: str, model_name: str, lang: str | None) -> str:
        with self._lock:
            return MLX_WORKER.submit(self._transcribe_impl, audio_path, model_name, lang).result()

    def info(self) -> dict:
        with self._lock:
            if self._current_model is None:
                return {"model_loaded": False, "model_name": None, "quant": None}
            backend = self._pick(self._current_model)
            return {
                "model_loaded": True,
                "model_name": self._current_model,
                "backend": backend.name,
                "quant": None,
                "loaded_at": self._loaded_at,
                "repo": backend._resolve_repo(self._current_model),
            }


# 向後相容別名：原 ModelCache 名稱沿用，避免外部腳本破壞
ModelCache = BackendCache


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
                info.update({"ok": True, "uptime_s": time.time() - started_at, "version": DAEMON_VERSION})
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
                    cache.load(model)
                except TranscribeError as exc:
                    return self._json(exc.status, {"error": exc.msg})
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
                    t0 = time.time()
                    lang = qs.get("lang") or None
                    text = cache.transcribe(tmp_path, model, lang)
                    latency = time.time() - t0
                    log(f"transcribe ok bytes={length} model={model} latency={latency:.2f}s text_len={len(text)}")
                    return self._json(200, {
                        "text": text.strip(),
                        "latency_ms": int(latency * 1000),
                        "model": model,
                        "quant": quant,
                        "audio_bytes": length,
                    })
                except TranscribeError as exc:
                    log(f"transcribe domain error [{exc.status}]: {exc.msg}")
                    return self._json(exc.status, {"error": exc.msg, "model": model})
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
            cache.load(DEFAULT_MODEL)
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
