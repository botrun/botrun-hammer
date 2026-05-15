#!/usr/bin/env python3
"""
Gemma 4 E4B 語音問答 CLI（速度 benchmark 用）
─────────────────────────────────────────────
你用麥克風問問題 → Gemma 4 E4B 多模態直接以**繁體中文**回答。
沿途量測 TTFT / TPS / 模型載入 / 端到端延遲。

UX：Toggle 模式（Enter 開始錄、Enter 結束送），loop 不斷可連問；--file 模式取既有音檔測。

範例：
    # 預設互動 loop（按 Enter 開始/結束，Ctrl+C 離開）
    ~/.botrun-hammer/venv/bin/python py/gemma_voice_qa.py

    # 用既有檔測 5 次取平均（最重現性）
    ~/.botrun-hammer/venv/bin/python py/gemma_voice_qa.py \
        --file scripts/asr_benchmark/reference_zh_25s.wav --runs 5

    # 改 prompt（預設「請以繁體中文回答這段語音問題」）
    ~/.botrun-hammer/venv/bin/python py/gemma_voice_qa.py \
        --prompt "請用一句繁體中文總結這段音訊"
"""
from __future__ import annotations

import argparse
import os
import statistics
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

# ──────────────────────────────────────────
# 預設參數
# ──────────────────────────────────────────
DEFAULT_MODEL = "google/gemma-4-e4b-it"
DEFAULT_PROMPT = (
    "請聆聽這段語音中的問題或內容，以**繁體中文**直接回答或回應。"
    "不要重述語音內容、不要做轉錄；像對話一樣自然回答。"
)
SAMPLE_RATE = 16000
CHANNELS = 1
GEMMA_MAX_SEC = 30.0


# ──────────────────────────────────────────
# 工具
# ──────────────────────────────────────────
def now() -> float:
    return time.perf_counter()


def fmt_ms(seconds: float) -> str:
    return f"{seconds * 1000:.0f}ms" if seconds < 1 else f"{seconds:.2f}s"


def to_traditional(text: str) -> str:
    try:
        import zhconv
        return zhconv.convert(text, "zh-tw")
    except ImportError:
        return text


def probe_duration(path: str) -> float:
    try:
        with wave.open(path, "rb") as wf:
            return wf.getnframes() / wf.getframerate()
    except wave.Error:
        # 非 PCM wav → 退用 ffprobe
        for ffp in ("/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "ffprobe"):
            try:
                out = subprocess.check_output(
                    [ffp, "-v", "error", "-show_entries", "format=duration",
                     "-of", "default=noprint_wrappers=1:nokey=1", path],
                    stderr=subprocess.DEVNULL, timeout=5,
                )
                return float(out.decode().strip())
            except (FileNotFoundError, subprocess.SubprocessError):
                continue
        return 0.0


# ──────────────────────────────────────────
# 錄音
# ──────────────────────────────────────────
def record_until_enter() -> str:
    """Enter 開始 → 錄音中顯示時間 → 再按 Enter 結束。回傳 wav 路徑."""
    import sounddevice as sd
    import threading

    print("\n🎤 按 \033[1mEnter\033[0m 開始錄音（再按一次結束）...", end="", flush=True)
    input()

    print("\033[31m●\033[0m REC", end="", flush=True)
    frames: list[np.ndarray] = []
    stop_event = threading.Event()
    start = now()

    def callback(indata, _frames, _time_info, _status):
        frames.append(indata.copy())

    stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=CHANNELS,
                            dtype="int16", callback=callback)
    stream.start()

    def ticker():
        while not stop_event.is_set():
            elapsed = now() - start
            warn = "  ⚠️ 已超過 Gemma 30s 上限" if elapsed > GEMMA_MAX_SEC else ""
            print(f"\r\033[31m●\033[0m REC  {elapsed:5.1f}s{warn}     ", end="", flush=True)
            time.sleep(0.1)

    tick_thread = threading.Thread(target=ticker, daemon=True)
    tick_thread.start()

    try:
        input()  # 第二次 Enter 結束
    except (KeyboardInterrupt, EOFError):
        pass
    stop_event.set()
    stream.stop()
    stream.close()
    tick_thread.join(timeout=0.5)
    duration = now() - start
    print(f"\r✅ 錄音結束（{duration:.2f}s）              ")

    audio = np.concatenate(frames, axis=0) if frames else np.zeros((0, CHANNELS), dtype=np.int16)
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    with wave.open(tmp.name, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # int16
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(audio.tobytes())
    return tmp.name


# ──────────────────────────────────────────
# 推理 + 計時
# ──────────────────────────────────────────
class Engine:
    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = None
        self.processor = None
        self.load_time: float | None = None

    def ensure_loaded(self):
        if self.model is not None:
            return
        print(f"\n⏳ 載入 Gemma 模型 ({self.model_id}) ...", flush=True)
        t0 = now()
        from mlx_vlm import load as vlm_load
        self.model, self.processor = vlm_load(self.model_id)
        self.load_time = now() - t0
        print(f"   模型載入：{fmt_ms(self.load_time)}", flush=True)

    def run(self, audio_path: str, prompt: str, run_idx: int = 1) -> dict:
        self.ensure_loaded()
        from mlx_vlm import stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template

        audio_sec = probe_duration(audio_path)
        if audio_sec > GEMMA_MAX_SEC:
            print(f"\n⚠️ 音檔 {audio_sec:.1f}s 超過 Gemma 30s 上限，可能截斷")

        t_prompt_start = now()
        chat_prompt = apply_chat_template(
            self.processor, self.model.config, prompt, num_audios=1,
        )
        t_prompt_ready = now()

        print(f"\n🤖 Gemma 4 (#{run_idx}) 推理中... 音檔 {audio_sec:.2f}s\n")
        chunks: list[str] = []
        t_first_token: float | None = None
        t_start_infer = now()
        try:
            for chunk in stream_generate(
                model=self.model, processor=self.processor, prompt=chat_prompt,
                audio=[audio_path], max_tokens=600, temperature=0.0,
            ):
                if t_first_token is None:
                    t_first_token = now()
                    print(f"   ⚡ TTFT = {fmt_ms(t_first_token - t_start_infer)}")
                    print("   ─── 回答 ───")
                # mlx-vlm 0.5 串流 yield str；保險 fallback
                piece = chunk if isinstance(chunk, str) else getattr(chunk, "text", str(chunk))
                chunks.append(piece)
                sys.stdout.write(piece)
                sys.stdout.flush()
        except KeyboardInterrupt:
            print("\n(已中斷)")

        t_end = now()
        raw_text = "".join(chunks)
        tw_text = to_traditional(raw_text)

        # token 數：用 tokenizer encode 算精確 token 數
        try:
            tok = self.processor.tokenizer  # type: ignore[attr-defined]
            n_tokens = len(tok.encode(raw_text))
        except Exception:
            n_tokens = len(raw_text)  # fallback: 字數

        infer_total = t_end - t_start_infer
        ttft = (t_first_token - t_start_infer) if t_first_token else None
        decode_time = (t_end - t_first_token) if t_first_token else infer_total
        tps = n_tokens / decode_time if decode_time > 0 else 0.0

        if tw_text != raw_text:
            print(f"\n\n   ─── 繁體正規化 ───\n   {tw_text}")

        return {
            "audio_sec": audio_sec,
            "prompt_prep_s": t_prompt_ready - t_prompt_start,
            "ttft_s": ttft,
            "decode_s": decode_time,
            "infer_total_s": infer_total,
            "tokens": n_tokens,
            "tps": tps,
            "chars": len(raw_text),
            "text_zh_tw": tw_text,
        }


# ──────────────────────────────────────────
# 報告
# ──────────────────────────────────────────
def render_stats_single(r: dict) -> None:
    print(f"""
\033[1m─── 速度報告 ───\033[0m
  音檔長度       : {r['audio_sec']:.2f} s
  Prompt 準備    : {fmt_ms(r['prompt_prep_s'])}
  TTFT           : {fmt_ms(r['ttft_s']) if r['ttft_s'] else 'N/A'}
  Decode 時間    : {fmt_ms(r['decode_s'])}
  推理總時間     : {fmt_ms(r['infer_total_s'])}
  輸出 tokens    : {r['tokens']}  ({r['chars']} 字)
  TPS            : {r['tps']:.1f} tok/s
  即時率 RTF     : {r['infer_total_s'] / r['audio_sec']:.2f}× ({"快於" if r['infer_total_s'] < r['audio_sec'] else "慢於"} 即時)
""")


def render_stats_aggregate(runs: list[dict], load_time: float | None) -> None:
    def stat(name: str, getter):
        vals = [getter(r) for r in runs if getter(r) is not None]
        if not vals:
            return f"  {name:14}: N/A"
        if len(vals) == 1:
            return f"  {name:14}: {fmt_ms(vals[0]) if name != 'TPS' else f'{vals[0]:.1f} tok/s'}"
        mean = statistics.mean(vals)
        stdev = statistics.stdev(vals)
        unit = " tok/s" if name == "TPS" else ""
        formatter = (lambda v: f"{v:.1f}{unit}") if name == "TPS" else (lambda v: fmt_ms(v))
        return f"  {name:14}: 平均 {formatter(mean)}  σ={formatter(stdev)}  最小 {formatter(min(vals))}  最大 {formatter(max(vals))}"

    print(f"\n\033[1m═══ {len(runs)} 輪聚合 ═══\033[0m")
    if load_time:
        print(f"  模型載入      : {fmt_ms(load_time)} (僅首次)")
    print(stat("Prompt 準備", lambda r: r["prompt_prep_s"]))
    print(stat("TTFT", lambda r: r["ttft_s"]))
    print(stat("Decode 時間", lambda r: r["decode_s"]))
    print(stat("推理總時間", lambda r: r["infer_total_s"]))
    print(stat("TPS", lambda r: r["tps"]))
    audio = runs[0]["audio_sec"]
    rtfs = [r["infer_total_s"] / r["audio_sec"] for r in runs]
    print(f"  RTF           : 平均 {statistics.mean(rtfs):.2f}×  (音檔 {audio:.2f}s)")


# ──────────────────────────────────────────
# 主流程
# ──────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description="Gemma 4 E4B 語音問答速度 benchmark")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--prompt", default=DEFAULT_PROMPT,
                    help="送給 Gemma 的指令；預設請它聽問題直接以繁中回答")
    ap.add_argument("--file", help="跳過錄音、直接用既有 wav 檔測（重現性最高）")
    ap.add_argument("--runs", type=int, default=1,
                    help="用 --file 時連跑 N 次取平均（單輪不算載入時間）")
    args = ap.parse_args()

    engine = Engine(args.model)
    runs: list[dict] = []

    try:
        if args.file:
            if not Path(args.file).exists():
                sys.exit(f"找不到檔案：{args.file}")
            for i in range(args.runs):
                print(f"\n\033[36m═══ Run {i + 1} / {args.runs} ═══\033[0m")
                r = engine.run(args.file, args.prompt, run_idx=i + 1)
                runs.append(r)
                render_stats_single(r)
        else:
            print("🎤 \033[1mGemma 4 E4B 語音問答（speed benchmark）\033[0m")
            print("   每段 ≤30 秒；Ctrl+C 離開\n")
            i = 0
            while True:
                i += 1
                print(f"\n\033[36m═══ Run #{i} ═══\033[0m")
                wav = record_until_enter()
                try:
                    r = engine.run(wav, args.prompt, run_idx=i)
                    runs.append(r)
                    render_stats_single(r)
                finally:
                    try:
                        os.unlink(wav)
                    except OSError:
                        pass
    except KeyboardInterrupt:
        print("\n(收到 Ctrl+C)")

    if len(runs) >= 2:
        render_stats_aggregate(runs, engine.load_time)
    return 0


if __name__ == "__main__":
    sys.exit(main())
