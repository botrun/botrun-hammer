# Gemma 4 E4B 語音指令服從度修補 — DAG TODO
**TW 時間**: 2026-05-15 19:56:49
**Parent**: 此次任務從使用者實測發現 v1.9.1 py CLI prompt 設計缺陷

## Bug 重現
使用者語音輸入「請幫我生成 HTML 網頁介紹如何遛狗」（8 秒）：

```
Run #6:
🤖 Gemma 4 E4B 回應：
「好的，我可以幫你寫一個介紹如何遛狗的 HTML 網頁。」
（16 tokens 後停止 — 沒有實際 HTML）
```

## 根因
`py/gemma_voice_qa.py` 預設 prompt 含「**像對話一樣自然回答**」誤導模型走「聊天 / 確認」路線，而非「執行 / 產出」。Gemma 4 E4B 對 prompt 用詞敏感（小模型）。

## 動機（5）
1. 真實服從度驗證（不只 ASR / 點頭）
2. 離線 agent 評估
3. 找 CLI prompt 盲點
4. 量化不服從率
5. 小模型 prompt 敏感性校準

## 方案打分 → 採 A+D

| 方案 | 工程 | 驗證 | 泛化 | 風險 | 總 |
|------|-----|------|-----|------|---|
| **A. agent-style prompt 重寫** | 5 | 4 | 5 | 5 | **19** ⭐ |
| B. 兩段式（複述再執行）| 3 | 3 | 3 | 4 | 13 |
| C. 自動 retry 敷衍偵測 | 2 | 4 | 3 | 2 | 11 |
| **D. --prompt-bench 對照** | 3 | 5 | 4 | 4 | **16** ⭐ |

## DAG

```
#9 查 mlx-vlm system role ✅
        │
        ▼
#10 DAG doc + GH issue (in_progress)
        │
        ├──→ #11 改 DEFAULT_PROMPT (agent)
        │           │
        │           ▼
        │       #13 合成測試音檔 (dogwalk HTML)
        │           │
        │           ▼
        │       #14 E2E + 地雷文 + horse reuse
        │
        └──→ #12 加 --prompt-bench 模式
                    │
                    ▼ (同 #14)
```

## BDD Scenarios

```gherkin
Feature: 語音指令真實服從度

  Scenario: 語音要求產出 HTML 應實際輸出 HTML 而非確認
    Given Gemma 4 E4B 已載入
    And 我送入語音檔 voice_cmd_html_dogwalk.wav（內容：請幫我生成 HTML 網頁介紹如何遛狗）
    When 我跑 gemma_voice_qa.py --file voice_cmd_html_dogwalk.wav --prompt <agent_prompt>
    Then 輸出應該包含 "<html" 或 "<!DOCTYPE"
    And 輸出長度應 > 300 字
    And 輸出不應只是「好的我可以...」之類確認句

  Scenario: --prompt-bench 量化多 prompt 服從度
    Given 同一份音檔
    When 跑 gemma_voice_qa.py --file X --prompt-bench
    Then 輸出 markdown 表，每列含：
      | prompt 名 | 輸出長度 | 含 HTML | 含敷衍字串 | tokens | TTFT | TPS |
    And 至少有一個 prompt 真實產出 HTML
```

## 不服從訊號（heuristic）
- 含「好的我可以」「當然」「我會幫你」「請問」前綴
- 長度 < 50 chars
- 沒有任務要求的關鍵特徵（HTML 任務無 `<` 符號）

## TODO 表
| ID | 任務 | 狀態 | blockedBy |
|----|------|------|-----------|
| 9 | 查 system role | ✅ | — |
| 10 | DAG + issue | 🟡 | 9 |
| 11 | 改 DEFAULT_PROMPT | ⬜ | 10 |
| 12 | --prompt-bench | ⬜ | 10 |
| 13 | 合成測試音檔 | ⬜ | 10 |
| 14 | E2E + 地雷 | ⬜ | 11,12,13 |

## DoD
- [ ] DEFAULT_PROMPT 改完，跑 dogwalk wav 至少 1 個版本能吐 HTML
- [ ] `--prompt-bench` 跑出對照表
- [ ] `docs/2026-05-15_*_instruction-following-lessons.md` 含 ≥3 條教訓
- [ ] CLAUDE.md 索引
- [ ] botrun-horse reuse
