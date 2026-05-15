#!/usr/bin/env python3
"""
波特槌多引擎 ASR 精準度對照
---------------------------
讀 reference_zh_25s.{wav,txt}，依序對 daemon /switch_model + /transcribe，
計算 CER（繁中比 WER 合理，因為中文沒有空白分詞）+ 端到端延遲，
輸出 markdown 表。

KISS：只用 stdlib + 純 Python CER（無 editdistance 依賴）
DRY ：所有引擎走同一條路徑（model name 由 CLI 傳入）

用法：
    # 先啟動 daemon：~/.botrun-hammer/scripts/lwm_daemon_ctl.sh start
    python3 run_wer_compare.py
    python3 run_wer_compare.py --models large-v3,large-v3-turbo,gemma-4-e4b
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent
WAV = HERE / "reference_zh_25s.wav"
TXT = HERE / "reference_zh_25s.txt"
HOME = Path.home()
PORT_FILE = HOME / ".botrun-hammer" / "lwm.port"
TOKEN_FILE = HOME / ".botrun-hammer" / "lwm.token"


def _normalize_zh(s: str) -> str:
    """簡→繁 + 全形標點→半形（公平比 Whisper vs Gemma）。zhconv 缺失時直接回原文."""
    try:
        import zhconv
        s = zhconv.convert(s, "zh-tw")
    except ImportError:
        pass
    # 標點正規化：常見全形→半形 + 移除句末標點差異
    repl = {"，": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";",
            "「": '"', "」": '"', "（": "(", "）": ")", "、": ","}
    for a, b in repl.items():
        s = s.replace(a, b)
    return s


def cer(reference: str, hypothesis: str, normalize: bool = True) -> float:
    """Character Error Rate via Levenshtein. 中文每字一單位、英文每字母一單位.

    normalize=True 時做簡→繁 + 標點半形化（讓 Whisper 簡中輸出能跟繁中 GT 公平比）.
    """
    if normalize:
        reference = _normalize_zh(reference)
        hypothesis = _normalize_zh(hypothesis)
    ref = "".join(reference.split())
    hyp = "".join(hypothesis.split())
    if not ref:
        return 0.0 if not hyp else 1.0
    # DP edit distance
    m, n = len(ref), len(hyp)
    prev = list(range(n + 1))
    for i in range(1, m + 1):
        curr = [i] + [0] * n
        for j in range(1, n + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        prev = curr
    return prev[n] / m


def daemon_creds() -> tuple[int, str]:
    if not PORT_FILE.exists() or not TOKEN_FILE.exists():
        sys.exit("[FAIL] daemon 未啟動。先跑 ~/.botrun-hammer/scripts/lwm_daemon_ctl.sh start")
    return int(PORT_FILE.read_text().strip()), TOKEN_FILE.read_text().strip()


def http_request(method: str, url: str, token: str, data: bytes | None = None, timeout: int = 600):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def switch_model(port: int, token: str, model: str) -> tuple[bool, float, str]:
    url = f"http://127.0.0.1:{port}/switch_model?model={urllib.parse.quote(model)}"
    t0 = time.time()
    status, body = http_request("POST", url, token, timeout=900)
    elapsed = time.time() - t0
    ok = status == 200 and '"ok": true' in body
    return ok, elapsed, body


def transcribe(port: int, token: str, model: str, wav: Path) -> tuple[bool, float, str, str]:
    """Returns (ok, latency_s, text, raw_body)"""
    url = (
        f"http://127.0.0.1:{port}/transcribe"
        f"?model={urllib.parse.quote(model)}&quant=none&ext=wav&lang=zh"
    )
    data = wav.read_bytes()
    t0 = time.time()
    status, body = http_request("POST", url, token, data=data, timeout=600)
    elapsed = time.time() - t0
    if status != 200:
        return False, elapsed, "", body
    try:
        payload = json.loads(body)
        text = payload.get("text", "")
        return True, elapsed, text, body
    except json.JSONDecodeError:
        return False, elapsed, "", body


def run_one(port: int, token: str, model: str, wav: Path, ground_truth: str) -> dict:
    print(f"\n=== {model} ===", flush=True)
    sw_ok, sw_t, sw_body = switch_model(port, token, model)
    print(f"  switch_model: ok={sw_ok} elapsed={sw_t:.1f}s")
    if not sw_ok:
        return {"model": model, "ok": False, "error": f"switch failed: {sw_body[:200]}"}

    tr_ok, tr_t, text, raw = transcribe(port, token, model, wav)
    print(f"  transcribe : ok={tr_ok} latency={tr_t:.2f}s")
    if not tr_ok:
        return {"model": model, "ok": False, "error": f"transcribe failed: {raw[:200]}",
                "switch_s": sw_t, "transcribe_s": tr_t}
    c_raw = cer(ground_truth, text, normalize=False)
    c_norm = cer(ground_truth, text, normalize=True)
    print(f"  CER raw    : {c_raw*100:.2f}%  (含繁簡/標點差異)")
    print(f"  CER norm   : {c_norm*100:.2f}%  (簡→繁 + 全形→半形)")
    print(f"  text[:120] : {text[:120]}")
    return {
        "model": model, "ok": True,
        "switch_s": sw_t, "transcribe_s": tr_t,
        "cer": c_norm, "cer_raw": c_raw, "text": text,
    }


def render_markdown(results: list[dict], ground_truth: str, audio_seconds: float) -> str:
    lines = []
    lines.append("# 多引擎 ASR 精準度報告\n")
    lines.append(f"**生成時間**: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    lines.append(f"**音檔**: `reference_zh_25s.wav` ({audio_seconds:.2f}s, 16kHz mono)")
    lines.append(f"**Ground truth 字數**: {len(ground_truth.replace(chr(10), '').replace(' ', ''))}\n")
    lines.append("## 對照表\n")
    lines.append("| 模型 | OK | CER (normalized) | CER (raw) | 載入秒 | 轉錄秒 | 即時率 |")
    lines.append("|------|----|------------------|-----------|--------|--------|--------|")
    for r in results:
        if r.get("ok"):
            rtf = r["transcribe_s"] / audio_seconds
            lines.append(
                f"| `{r['model']}` | ✅ | **{r['cer']*100:.2f}%** | "
                f"{r['cer_raw']*100:.2f}% | "
                f"{r['switch_s']:.1f}s | {r['transcribe_s']:.2f}s | {rtf:.2f}× |"
            )
        else:
            lines.append(f"| `{r['model']}` | ❌ | — | — | — | — | {r.get('error','')[:60]} |")
    lines.append("\n> **normalized**: 簡→繁 + 全形標點→半形 後算 CER（讓 Whisper 系列公平受比）。")
    lines.append("> **raw**: 原始輸出直接比，含繁簡與標點差異懲罰。")
    lines.append("\n## Ground Truth\n")
    lines.append("```\n" + ground_truth.strip() + "\n```\n")
    lines.append("\n## 各引擎輸出\n")
    for r in results:
        lines.append(f"\n### `{r['model']}`")
        if r.get("ok"):
            lines.append("```\n" + r["text"].strip() + "\n```")
        else:
            lines.append(f"❌ {r.get('error','unknown')}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="large-v3,large-v3-turbo",
                    help="逗號分隔 model name；含 gemma-4-e4b 需 daemon ≥ v1.9.0")
    ap.add_argument("--out", default=None, help="輸出 markdown 路徑（預設 docs/<TW-ts>_asr-accuracy-report.md）")
    args = ap.parse_args()

    if not WAV.exists() or not TXT.exists():
        sys.exit(f"[FAIL] 缺基準檔。先跑 ./generate_reference.sh")
    ground_truth = TXT.read_text(encoding="utf-8").strip()

    # 取音檔長度
    import subprocess
    audio_s = float(subprocess.check_output([
        "/opt/homebrew/bin/ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(WAV)
    ]).decode().strip())

    port, token = daemon_creds()
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    results = [run_one(port, token, m, WAV, ground_truth) for m in models]

    md = render_markdown(results, ground_truth, audio_s)
    if args.out:
        out_path = Path(args.out)
    else:
        ts = time.strftime("%Y-%m-%d_%H%M%S")
        out_path = HERE.parent.parent / "docs" / f"{ts}_asr-accuracy-report.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(md, encoding="utf-8")
    print(f"\n[OK] 報告寫入 {out_path}")


if __name__ == "__main__":
    main()
