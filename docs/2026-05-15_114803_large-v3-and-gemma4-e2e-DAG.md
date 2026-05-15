# 多引擎 ASR 精準度驗證 — Parallel DAG TODO
**建立時間（TW）**: 2026-05-15 11:48:03  
**版本目標**: v1.8.1 (large-v3 預設) + v1.9.0 (Gemma 4 實驗引擎)  
**最終交付**: `docs/2026-05-15_<HHMMSS>_asr-accuracy-report.md` — 繁中 25s 基準音對照 large-v3 / large-v3-turbo / gemma-4-e4b 三方 CER + 延遲

---

## 動機 (五點)
1. 科學驗證 over 推測（拿實測 WER 取代部落格二手結論）
2. 建立 ASR 引擎可比性矩陣（gemini / whisper-turbo / whisper-v3 / gemma-4-e4b）
3. 抗 vendor lock-in（保留 Google 多模態路線當 fallback）
4. 流程紀律 — issue/sub-issue 追到 E2E 才 close
5. 教訓資產化 → docs + CLAUDE.md + botrun-horse reuse

## 痛點 (使用者中心)
- 「我不要 AI 替我下結論說 Gemma 4 不行，我要親耳聽 25 秒繁中誰準」
- 「我需要一份**可重現**基準，未來換引擎跑同一份檔就有答案」
- 「issues 不開永遠忘記 E2E 驗收」

---

## DAG 圖

```
        ┌──────────────────────────────────────────────┐
        │  #1 DAG doc（in_progress）                    │
        └──────────────────────────────────────────────┘
                            │
                            ▼
        ┌──────────────────────────────────────────────┐
        │  #2 GitHub issues (parent + 2 epics)          │
        └──────────────────────────────────────────────┘
              │                                  │
              ▼                                  ▼
   ┌──── Epic 1: large-v3 預設 ─────┐    ┌──── Epic 2: Gemma 4 接通 ────┐
   │                                │    │                              │
   │  #3 基準音檔 zh_25s.wav         │    │  #5 lwm_daemon 加 Gemma backend
   │       │                        │    │       │
   │       ▼                        │    │       ▼
   │  #4 WER 對照腳本 (v3 vs turbo) │    │  #6 lua 選單加 Gemma-4-E4B
   │                                │    │                              │
   └────────────┬───────────────────┘    └──────────────┬───────────────┘
                │                                       │
                └──────────────────┬────────────────────┘
                                   ▼
                    #7 三方對照 (gemma vs v3 vs turbo) ← 阻塞於 #3,#5,#6
                                   │
                                   ▼
                    #8 地雷文章 + CLAUDE.md + horse reuse
```

平行區段：**Epic 1 (#3,#4) 與 Epic 2 (#5,#6) 可同時跑**；#7 是匯流點。

---

## TODO 追蹤表

| ID | 任務 | 狀態 | 阻塞於 | 交付物 |
|----|------|------|--------|--------|
| 1 | 寫 DAG doc | 🟡 in_progress | — | 本檔 |
| 2 | GitHub parent + sub-issues | ⬜ pending | #1 | 3 個 issue URL |
| 3 | 繁中 25s 基準音檔 | ⬜ pending | #2 | `scripts/asr_benchmark/reference_zh_25s.{wav,txt}` |
| 4 | WER 對照腳本 (v3 vs turbo) | ⬜ pending | #3 | `scripts/asr_benchmark/run_wer_compare.py` |
| 5 | lwm_daemon Gemma backend | ⬜ pending | #2 | `lwm_daemon.py` 新增 `GemmaAudioBackend` |
| 6 | lua 選單加 Gemma-4-E4B | ⬜ pending | #5 | `botrun-hammer.lua` menuModels +1 |
| 7 | 三方對照 ≤25s | ⬜ pending | #3,#5,#6 | `docs/2026-05-15_*_asr-accuracy-report.md` |
| 8 | 地雷提煉 | ⬜ pending | #4,#7 | docs + CLAUDE.md + horse |

---

## BDD Scenarios (Gherkin)

```gherkin
Feature: 多引擎 ASR 切換 + 精準度可驗證

  Scenario: F8 切換 large-v3 精準模式
    Given 波特槌 v1.8.1 已啟動
    When 我從 F8 選單選「💻 本機 large-v3 (繁中・精準)」
    Then daemon 應載入 mlx-community/whisper-large-v3-mlx
    And menubar 應顯示「🔨 lwm:large-v3」

  Scenario: F8 切換 Gemma 4 實驗引擎
    Given 波特槌 v1.9.0 已啟動且已安裝 mlx-vlm
    When 我從 F8 選單選「🧪 本機 Gemma-4-E4B (實驗・≤30s)」
    Then 應跳出 alert 提示「Gemma 4 audio 30s 上限，超過會截斷」
    And daemon 切到 GemmaAudioBackend

  Scenario: 三引擎跑同一份 25s 繁中音檔
    Given scripts/asr_benchmark/reference_zh_25s.wav 存在
    And reference_zh_25s.txt 為 ground truth
    When 跑 python scripts/asr_benchmark/run_wer_compare.py
    Then 應輸出 markdown 表含三列：large-v3 / large-v3-turbo / gemma-4-e4b
    And 每列含 CER、延遲秒數、轉錄結果前 100 字
    And 結果寫入 docs/2026-05-15_*_asr-accuracy-report.md

  Scenario: Gemma 4 超過 30 秒回 422
    Given 我送 31 秒音檔到 daemon /transcribe?engine=gemma-4-e4b
    Then HTTP 應回 422
    And error 訊息含「Gemma 4 audio max 30s, got 31.0s」
```

---

## 設計原則對照

- **DDD**：daemon 內把 `transcribe()` 抽 `Backend` 介面（兩個實作 `WhisperBackend`/`GemmaAudioBackend`），領域語言 = 「引擎、模型、轉錄、音檔長度限制」
- **SOLID-OCP**：dispatcher 用 model name 前綴判別 (`large-*`→whisper, `gemma-*`→vlm)；新引擎 elseif 一行
- **SOLID-SRP**：Backend 只管「給音檔出文字」；ModelCache 只管 LRU；HTTP handler 只管路由
- **KISS**：不引 web framework；不寫 streaming（既然只驗 ≤25s 用不到）
- **DRY**：CER 計算共用 `editdistance`，不自寫 Levenshtein
- **TDD/BDD**：每個 Scenario 對應一個 pytest case + 一個手動 F8 步驟

---

## 風險登記

| 風險 | 機率 | 衝擊 | 緩解 |
|------|------|------|------|
| mlx-vlm 安裝吃 ~2GB 依賴 | 高 | 中 | lazy install，預設不裝（沿用 v1.7.12 模式）|
| Gemma 4 E4B 模型 ~10GB | 高 | 中 | UI alert 警告下載；menu 標「實驗」|
| 25s 基準音檔錄一份 ground truth 主觀偏差 | 中 | 中 | 用合成 TTS (macOS `say`) 確保 ground truth 100% 確定 |
| Gemma 4 transcribe 輸出帶 prompt echo | 中 | 低 | 後處理 strip "Transcribe this audio" prefix |
| mlx-vlm 與 mlx-whisper 不同 mlx 版本衝突 | 低 | 高 | 用 uv 開獨立 venv `~/.botrun-hammer/.venv-vlm` |

---

## 完成定義 (DoD)
- [ ] GitHub 3 個 issues 開好、互鏈、E2E 完成才能 close
- [ ] `scripts/asr_benchmark/` 可重現跑出 report
- [ ] `docs/2026-05-15_*_asr-accuracy-report.md` 含三引擎實測數字
- [ ] `docs/2026-05-15_*_multi-asr-backend-lessons.md` 含 ≥5 條跨專案教訓
- [ ] `CLAUDE.md` 索引兩份新文章
- [ ] `~/coding_projects/botrun-horse` 同步泛化版本
- [ ] 波特槌 F8 選單看得到 Gemma-4-E4B 選項
