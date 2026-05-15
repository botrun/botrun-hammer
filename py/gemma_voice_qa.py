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
# v1.9.3: 預設改用 lmstudio-community 4bit MLX（5GB, TPS 77 vs bf16 22 = 3.5x 快）
# 警告：mlx-community/gemma-4-e4b-it-4bit 與 unsloth/...UD-MLX-4bit 有 PLE 量化 bug 會輸出亂碼/截斷，不要用
# mlx-community/gemma-4-e4b-it-OptiQ-4bit 與 mlx-vlm 0.5 不相容（missing 963 params）
QUANT_MODELS = {
    "4bit": "lmstudio-community/gemma-4-E4B-it-MLX-4bit",
    "bf16": "google/gemma-4-e4b-it",
}
DEFAULT_QUANT = "4bit"
DEFAULT_MODEL = QUANT_MODELS[DEFAULT_QUANT]
# v1.9.2: 改 agent-style — 移除舊版「對話一樣自然回答」用語（會讓小模型走 chat 路線只點頭不做事）
DEFAULT_PROMPT = (
    "你是直接執行指令的助理。聆聽下方語音裡的指令，立刻動手完成它。\n"
    "規則：\n"
    "1. 用繁體中文輸出。\n"
    "2. 如果要求產出文件（HTML、Markdown、程式碼、文章、清單），\n"
    "   直接輸出**完整內容**，不要先說「好的」「當然可以」「我來幫你」之類確認語。\n"
    "3. 如果是問題，直接給答案，不要重述問題。\n"
    "4. 不要做語音轉錄，不要重複語音內容。\n"
    "5. 動手做，越具體越完整越好；不要停在「我可以幫你...」。"
)
# 候選 prompts（--prompt-bench 用）
PROMPT_CANDIDATES = {
    "v0_minimal": "請以繁體中文回應這段語音。",
    "v1_chat_old": (
        "請聆聽這段語音中的問題或內容，以繁體中文直接回答或回應。"
        "不要重述語音內容、不要做轉錄；像對話一樣自然回答。"
    ),
    "v2_agent_strict": DEFAULT_PROMPT,
    "v3_agent_role": (
        "[ROLE] 執行者，不是聊天機器人。\n"
        "[TASK] 完成下方語音中的指令。\n"
        "[OUTPUT] 繁體中文，直接給最終產物，沒有開場白沒有確認句。"
    ),
}
SAMPLE_RATE = 16000
CHANNELS = 1
GEMMA_MAX_SEC = 30.0

# 不服從訊號（小寫敏感 / 中文不分大小寫）
SYCOPHANT_PREFIXES = (
    "好的", "好的，", "好的!", "當然", "當然可以", "沒問題", "我可以幫", "我會幫",
    "請問", "你想要", "有什麼", "我來幫",
)


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


def looks_sycophant(text: str) -> bool:
    """前 30 字含敷衍前綴 → 疑似不服從."""
    head = text.strip()[:30]
    return any(head.startswith(p) for p in SYCOPHANT_PREFIXES)


def has_html_artifact(text: str) -> bool:
    """task=html 時偵測是否真產出 HTML."""
    lower = text.lower()
    return ("<html" in lower or "<!doctype" in lower or
            ("<head" in lower and "<body" in lower) or
            ("<div" in lower and lower.count("<") >= 5))


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
                audio=[audio_path], max_tokens=2048, temperature=0.0,
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
def render_bench_report(bench: list[dict], audio_path: str, audio_sec: float) -> str:
    """--prompt-bench markdown 報告"""
    lines = [
        f"# Prompt 服從度對照（{Path(audio_path).name}, {audio_sec:.2f}s）",
        f"**生成**: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}\n",
        "| prompt | 含 HTML | 疑似敷衍 | 字數 | tokens | TTFT | TPS | 推理總 |",
        "|--------|---------|----------|------|--------|------|-----|--------|",
    ]
    for b in bench:
        html_mark = "✅" if b["has_html"] else "❌"
        syco_mark = "⚠️ 是" if b["sycophant"] else "—"
        ttft = fmt_ms(b["r"]["ttft_s"]) if b["r"]["ttft_s"] else "N/A"
        lines.append(
            f"| `{b['name']}` | {html_mark} | {syco_mark} | "
            f"{b['r']['chars']} | {b['r']['tokens']} | {ttft} | "
            f"{b['r']['tps']:.1f} | {fmt_ms(b['r']['infer_total_s'])} |"
        )
    lines.append("\n## 各 prompt 完整輸出\n")
    for b in bench:
        lines.append(f"\n### `{b['name']}`")
        lines.append("```")
        lines.append(b["r"]["text_zh_tw"][:2000])
        lines.append("```")
        if len(b["r"]["text_zh_tw"]) > 2000:
            lines.append(f"\n_(截斷顯示前 2000 字，總長 {b['r']['chars']})_")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Gemma 4 E4B 語音問答速度 benchmark")
    ap.add_argument("--model", default=None,
                    help=f"完整 HF model id；省略則由 --quant 決定（預設 {QUANT_MODELS[DEFAULT_QUANT]}）")
    ap.add_argument("--quant", default=DEFAULT_QUANT, choices=list(QUANT_MODELS.keys()),
                    help=f"量化精度別名 (預設 {DEFAULT_QUANT}); --model 會覆蓋此值")
    ap.add_argument("--prompt", default=DEFAULT_PROMPT,
                    help="送給 Gemma 的指令；預設 agent-style 直接執行")
    ap.add_argument("--file", help="跳過錄音、直接用既有 wav 檔測（重現性最高）")
    ap.add_argument("--runs", type=int, default=1,
                    help="用 --file 時連跑 N 次取平均（單輪不算載入時間）")
    ap.add_argument("--prompt-bench", action="store_true",
                    help="同一音檔跑全部候選 prompt（v0/v1/v2/v3）對照服從度")
    ap.add_argument("--bench-out", default=None,
                    help="--prompt-bench 報告輸出路徑（預設 docs/<TW-ts>_prompt-bench.md）")
    args = ap.parse_args()

    model_id = args.model or QUANT_MODELS[args.quant]
    engine = Engine(model_id)
    runs: list[dict] = []

    try:
        if args.prompt_bench:
            if not args.file:
                sys.exit("--prompt-bench 需要搭配 --file 指定音檔")
            if not Path(args.file).exists():
                sys.exit(f"找不到檔案：{args.file}")
            print(f"\n\033[1m🧪 Prompt 服從度對照 — 同一音檔跑 {len(PROMPT_CANDIDATES)} 個候選 prompt\033[0m")
            bench: list[dict] = []
            for name, p in PROMPT_CANDIDATES.items():
                print(f"\n\033[36m═══ Prompt: {name} ═══\033[0m")
                print(f"指令：{p[:80]}{'...' if len(p) > 80 else ''}")
                r = engine.run(args.file, p, run_idx=len(bench) + 1)
                bench.append({
                    "name": name, "prompt": p, "r": r,
                    "has_html": has_html_artifact(r["text_zh_tw"]),
                    "sycophant": looks_sycophant(r["text_zh_tw"]),
                })
                render_stats_single(r)
                if bench[-1]["sycophant"]:
                    print(f"   \033[33m⚠️ 疑似敷衍前綴\033[0m")
                if bench[-1]["has_html"]:
                    print(f"   \033[32m✅ 含 HTML 標籤\033[0m")
            audio_sec = probe_duration(args.file)
            md = render_bench_report(bench, args.file, audio_sec)
            out_path = Path(args.bench_out) if args.bench_out else (
                Path(__file__).resolve().parent.parent / "docs" /
                f"{time.strftime('%Y-%m-%d_%H%M%S')}_prompt-bench.md"
            )
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(md, encoding="utf-8")
            print(f"\n\033[1m📄 報告：{out_path}\033[0m")
            # 列出贏家
            html_winners = [b["name"] for b in bench if b["has_html"]]
            print(f"\033[1m🏆 真實產出 HTML 的 prompt：{html_winners or '（無）'}\033[0m")
            return 0
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
