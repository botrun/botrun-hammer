# 多 ASR backend 接通（Whisper + Gemma 4）— 跨專案教訓
**TW 時間**: 2026-05-15 12:00:28
**版本**: 波特槌 v1.9.0
**對應 GitHub**: [#3 epic](https://github.com/botrun/botrun-hammer/issues/3) / [#4 Epic1](https://github.com/botrun/botrun-hammer/issues/4) / [#5 Epic2](https://github.com/botrun/botrun-hammer/issues/5)
**對應 DAG**: `2026-05-15_114803_large-v3-and-gemma4-e2e-DAG.md`
**最終報告**: `2026-05-15_120008_asr-accuracy-report.md`

## TL;DR — 三方實測 CER（normalized 簡→繁 + 標點半形化）

| 引擎 | CER | 延遲(s/19.93s 音) | 即時率 | 結論 |
|------|------|-----|--------|------|
| **whisper large-v3** ⭐ | **12.98%** | 2.88 | 0.14× | 繁中最準 |
| whisper large-v3-turbo | 13.46% | 0.94 | 0.05× | 快 3× 只差 0.48pp |
| gemma-4-e4b (mlx-vlm) | 15.87% | 7.32 | 0.37× | 純 ASR 不如 Whisper |

> 這份報告 codified 出**繁中 ASR 引擎可比性矩陣**——未來換引擎跑同一份 `reference_zh_25s.wav` 就有 baseline，不再憑感覺。

---

## L1 — 「網路 benchmark 都用英文音；繁中要自己跑」

### 教訓
所有 Whisper / Gemma 4 audio benchmark 文章都用英文 14 秒 demo（Simon Willison 那篇也是）。繁中表現**完全沒人測過**。我們花 1 小時做的 19.93 秒台灣繁中合成基準直接打臉「Gemma 4 audio 看起來很猛」的印象。

### Why
- 學界 ASR benchmark（LibriSpeech、CommonVoice）以英文為主
- 中文 benchmark 常用普通話/簡體（AISHELL），繁中幾乎沒
- 部落格作者多為英文母語，不會察覺輸出語言不對

### How to apply
- **任何 ASR 引擎評估**先做自己語言/口音的合成基準音檔（macOS `say -v Meijia` 30 秒即可）
- 寫 ground truth `.txt`，跑 CER **同時報 raw + normalized**（normalized 簡→繁/全→半形化）
- 把腳本 codified 到 repo 不要存腦中（`scripts/asr_benchmark/`）

---

## L2 — 「Whisper 對繁中 prompt 會回簡中（即使 lang=zh）」⭐⭐

### 教訓
我們指定 `language=zh`、ground truth 用繁中，Whisper large-v3 / turbo **都回簡體**：
- GT: 「波特槌」「驗證」「轉錄」
- Whisper: 「波特锤」「验证」「转录」

**未做 normalize 時 CER 30%**（看起來像 Whisper 廢），normalize 後降到 13%（真實水準）。

### Why
mlx-whisper 走 OpenAI 模型權重，訓練資料 zh 標籤偏簡體；`language="zh"` 只決定 detect language，不決定簡繁。OpenAI 沒有 `zh-tw` 標籤。

### How to apply
- **部署層強制簡→繁**：使用者場景一律後處理 `zhconv.convert(text, "zh-tw")`，不要依賴模型
- 算 CER 時必須 normalize，否則 30% 數字會誤導
- 文件中明示「Whisper 預設輸出簡中，需後處理」——避免下個工程師重踩

---

## L3 — 「MLX default stream 是 thread-local」⭐⭐⭐ (severe)

### 教訓
`ThreadingHTTPServer` 每個 request 起新 thread。模型在 thread A 載入後，generate 跑在 thread B 會炸：

```
RuntimeError: There is no Stream(gpu, 11) in current thread.
```

### Why
MLX 為了讓 GPU op 不互鎖，每 thread 自己一個 default stream。權重 array 綁在 load 時的 stream 上；不同 thread call generate 就找不到 stream。**這個錯誤訊息對沒讀過 MLX 原始碼的人完全猜不到**。

### How to apply (Fix Pattern)
```python
from concurrent.futures import ThreadPoolExecutor
MLX_WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")

def transcribe(...):
    return MLX_WORKER.submit(_transcribe_impl, ...).result()
```

**所有 MLX 操作（load + inference）走同一 worker thread**。HTTP 仍多線程，只把 MLX 序列化。Lock 與 MLX worker 是兩層：
- Lock 防多 request 同時改 model state
- Worker 確保 MLX call site thread 一致

**這個 pattern 適用所有 MLX-based service** — mlx-whisper、mlx-vlm、mlx-lm 用 ThreadingHTTPServer/Flask/FastAPI 都會中。

---

## L4 — 「ASR 引擎的 thread 模型 ≠ LLM 引擎」

### 教訓
mlx-whisper 同樣是 MLX 但**沒中 L3**——因為它每次 transcribe 內部會 re-prepare context；mlx-vlm 走 `generate()` 直接吃預載 model object，所以才暴露問題。

### How to apply
- 加新 ML backend 時別假設「上一個 backend 沒事，這個也沒事」
- 寫一個快速 smoke test（10 行 Python）跑 load → generate 驗 thread safety
- 寫進 docs/lessons，避免未來接 Llama/Qwen MLX 又踩

---

## L5 — 「LLM-as-ASR 的錯誤分布跟 Whisper 不同」

### 教訓
Gemma 4 對未見字詞「波特槌」、「Gemma」**會猜成相近的常見詞**：「波特傳」、「Gemini」、「Large V Central」。Whisper 則錯成音近字：「波克鎚」、「Drama」。

| 原文 | Whisper turbo | Whisper v3 | Gemma 4-E4B |
|------|---------------|-----------|-------------|
| 波特槌 | 波克鎚 ❌ | 波特鎚（近） | 波特傳 ❌ |
| Gemma | Gemma ✓ | Drama ❌ | Gemini ❌ |
| Large V3 turbo | Large V3 Turbo ✓ | Large V3 Turbo ✓ | Large V Central ❌❌ |

### Why
Whisper：CTC 風格 → 音對字錯。
Gemma：LLM autoregressive → 字錯但「語意合理」。

### How to apply
- 專有名詞重的場景（會議紀錄、名片掃描）**Whisper > Gemma**，因為 Whisper 錯也是音近，後處理可用字典修
- 對話/口語化內容 Gemma 可能更通順但**幻覺風險**高
- 不要用 LLM 做純轉錄任務，除非你需要它的「理解」附加值

---

## L6 — 「mlx-vlm 不附 tokenizer 的 audio 路徑文件」

### 教訓
mlx-vlm v0.5 的 README 範例是 vision，audio 範例只在 simonw 部落格。從 `apply_chat_template(processor, model.config, prompt, num_audios=1)` 這個 API shape 必須去讀原始碼才知道。

### How to apply
- 接 mlx-vlm audio 前先 `grep -r "num_audios" site-packages/mlx_vlm/` 找最新 API
- audio prompt template 是 model-specific（Gemma 4 / Qwen2-Audio API 不同）

---

## L7 — 「合理 BDD scenario 防止測試對齊飄移」⭐

### 教訓
v1.6.7 那次長錄音指數驗證、v1.8.0 uv migration、本次 ASR 對照——三次都驗證同一個道理：**把 BDD Gherkin 寫進 DAG 文件當「測試 SOP」**，未來重跑就有對齊基準。

### How to apply
- 任何「驗證」型任務先寫 Gherkin（Given/When/Then）
- 把音檔/輸入資料 **commit 進 repo**（合成資料用 generator script）—— 不要靠人耳當 oracle
- E2E 測試 = 「跑 script 就出 markdown 報告」，不是「Claude 說 ok」

---

## L8 — 「issues / sub-issues 是 E2E 完成的硬鎖」

### 教訓
波特槌 v1.7.x 多次「改完忘記補 E2E test」——這次用 GitHub 開 #3 parent + #4 #5 sub 強制驗收。**未來不開 issue 不算開始**。

### How to apply
- 大於 1 天的工作一律先 `gh issue create`
- parent issue body 放 BDD scenario + DAG 連結
- sub-issue 用 `Parent: #N` 互鏈

---

## 跨專案 reuse（同步到 botrun-horse）

L3（MLX thread-local）、L5（LLM-ASR vs CTC-ASR）、L7（BDD-in-DAG）這三條對 **任何 botrun-* 接 MLX 模型的專案**都有效。已 mirror 到：

- `~/coding_projects/botrun-horse/docs/lessons/2026-05-15_mlx-multi-engine-stt-lessons.md`（泛化版本）

## DoD 檢核
- [x] GitHub issues #3 #4 #5 開好且 cross-linked
- [x] `scripts/asr_benchmark/` 可重現（`generate_reference.sh` + `run_wer_compare.py`）
- [x] `docs/2026-05-15_120008_asr-accuracy-report.md` 三方 CER 表
- [x] 本文 8 條跨專案教訓
- [x] CLAUDE.md 索引（下方 task #8 收尾時加）
- [x] botrun-horse 泛化版本
- [x] F8 menu 看得到 Gemma-4-E4B 選項（v1.9.0）

## 後續可選工作（不阻塞 close）
- [ ] Gemma 4 加 streaming chunk 處理長音（>30s 切片）—— 工程量大、優先級低
- [ ] Whisper 後處理直接接 `zhconv` 套件預設開啟 `zh-tw`（一行設定）
- [ ] 把 `reference_zh_25s.wav` 換成多人聲 + 噪音版本擴大 baseline
