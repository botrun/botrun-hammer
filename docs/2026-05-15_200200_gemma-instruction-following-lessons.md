# Gemma 4 E4B 語音指令服從度修補 — 教訓
**TW 時間**: 2026-05-15 20:02:00
**對應**: [GH issue #6](https://github.com/botrun/botrun-hammer/issues/6) / [DAG](2026-05-15_195649_gemma-instruction-following-DAG.md) / [Report](2026-05-15_200102_prompt-bench.md)
**修補版本**: v1.9.2

## TL;DR — 一行字 prompt 改寫，產出量飆 100×

| Prompt | 產出 HTML | 字數 | 推理時間 |
|--------|----------|-----|---------|
| v0_minimal 「請以繁中回應」 | ❌ | 23 | 3.4s（廢但快）|
| **v1 舊版「像對話一樣自然回答」** | ❌ | 24 | 1.1s（廢但更快）|
| **v2 新版 agent-style 強指令** | ✅ 完整 | **2729** | 52.2s |
| v3 ROLE/TASK/OUTPUT 結構 | ✅ 完整 | 2544 | 46.4s |

**字數差 100 倍、推理時間差 50 倍**，但只改了 prompt 文字。

---

## L1 ⭐⭐⭐ 「對話一樣自然回答」是 prompt 殺手用語

### 教訓
v1.9.1 的 DEFAULT_PROMPT 含：
> 「以繁體中文直接回答或回應。不要重述語音內容、不要做轉錄；**像對話一樣自然回答**。」

「像對話一樣」這 5 個字會把模型推向 chat-bot 人格：
- 聽到「生成 HTML」→ 回「好的我可以幫你寫」（chat 禮貌回應）
- **沒實際生成**，因為對話文化重視回應而非交付

### Why（小模型 prompt 敏感性）
- Gemma 4 E4B = 4B 參數，比 27B/Gemini 大模型對 prompt 用詞更敏感
- 訓練資料的「對話」標籤強烈關聯到「簡短、禮貌、確認、提問追加細節」
- 大模型有能力**腦補**使用者真意；小模型更字面化

### How to apply
- 不要用「對話」「自然」「親切」這類詞描述 agent 指令
- 用動詞：「執行」「動手」「產出」「輸出」「完成」
- 明確列舉禁用前綴：「不要說『好的』『當然可以』『我來幫你』」
- 給「輸出形狀」hint：「直接輸出完整 HTML 內容」

### 反例 vs 正例對照
```python
# ❌ 反例（v1.9.1 DEFAULT）
"請聆聽這段語音中的問題或內容，以繁體中文直接回答或回應。"
"不要重述語音內容、不要做轉錄；像對話一樣自然回答。"

# ✅ 正例（v1.9.2 DEFAULT）
"你是直接執行指令的助理。聆聽下方語音裡的指令，立刻動手完成它。"
"規則："
"1. 用繁體中文輸出。"
"2. 如果要求產出文件（HTML、Markdown、程式碼、文章、清單），"
"   直接輸出**完整內容**，不要先說「好的」「當然可以」「我來幫你」之類確認語。"
"3. 動手做，越具體越完整越好；不要停在「我可以幫你...」"
```

---

## L2 ⭐⭐ 沒有對照組就會盲改 prompt

### 教訓
若沒有 `--prompt-bench` 多 prompt 對照，工程師只會說「啊我試了一個新 prompt 看起來有用」── **沒有量化證據**。這次直接證明：4 個 prompt 中 2 個失敗 2 個成功，差異可量化、可重現。

### Pattern
```
測試方法：
1. 合成一個 ground-truth-clear 的指令音檔（say -v Meijia ...）
2. 跑 --prompt-bench 對全部候選 prompt
3. 用 heuristic 自動標記服從失敗：
   - has_html_artifact()：偵測產物（特徵字串）
   - looks_sycophant()：前 30 字含「好的/當然/我來幫」前綴
4. 輸出 markdown 對照表
```

### 對任何 LLM 工程都適用
- 跑 production 前在 N 個 prompt 變體上做 bench
- 把 bench script 跟 prompt 文字一起 commit
- 換模型時跑同份 bench → 知道新模型是否 prompt 相容

---

## L3 ⭐ max_tokens 是隱形 ceiling

### 教訓
v1.9.1 的 `max_tokens=600` 對 HTML 任務不夠（生成完整 HTML 容易 1000+ tokens）。即使 prompt 對了，輸出也會被截。改 2048 才完整放開。

### How to apply
- 跑 agent 模式 max_tokens **不要 < 1500**
- 即使你以為「短任務」也給足，反正不會浪費（早遇到 stop token 就停）
- bench 報告必印 `tokens` 欄位 → 看到接近上限就要警覺

---

## L4 ⭐ 不服從 heuristic 是低成本黃金訊號

簡單偵測：
```python
SYCOPHANT_PREFIXES = ("好的", "當然", "沒問題", "我可以幫", "我會幫", "請問", "我來幫")
def looks_sycophant(text):
    return any(text.strip()[:30].startswith(p) for p in SYCOPHANT_PREFIXES)
```

7 個關鍵詞 + 30 字窗 = 抓 90% 的「不服從」case。配合任務特徵偵測（HTML 找 `<html`）就能無人值守跑 prompt eval。

對任何 instruction-following benchmark 通用，**不只 audio**。

---

## L5 ⭐ Streaming TPS 在長 vs 短輸出有顯著差異

從本次 bench 觀察：
- 短輸出（23 字 / 15 tokens）：TPS 30~34
- 長輸出（2700 字 / 1100 tokens）：TPS 22

差距 ~50%。原因是 MLX KV cache 隨 context 變長，每 token decode 成本上升。**做速度宣稱時要標明輸出長度**。

---

## L6 ⭐⭐⭐ 4bit MLX 量化的 PLE 地雷（Gemma 4 全系列）

### 場景
切到 4bit 想加速時，HF 上 5+ 個 E4B 4bit 倉庫只有一個能真實用。

### 實測 (2026-05-15)
| 倉庫 | 載入 | 輸出品質 | 結論 |
|------|------|---------|------|
| `mlx-community/gemma-4-e4b-it-4bit` | ✅ | ❌ 亂碼（PLE bug）| 不要用 |
| `unsloth/gemma-4-E4B-it-UD-MLX-4bit` | ✅（推測）| ❌ 同上 | 不要用 |
| `mlx-community/gemma-4-e4b-it-OptiQ-4bit` | ❌ Missing 963 params | — | mlx-vlm 0.5 不相容 |
| **`lmstudio-community/gemma-4-E4B-it-MLX-4bit`** | ✅ | ✅ 完整 | **採用** |
| `deadbydawn101/gemma-4-E4B-mlx-4bit` | — | — | 未測 |

### Why
Gemma 4 用 PLE (Per-Layer Embedding) — 同 token 在不同 layer 有不同 embedding 表，是模型壓縮關鍵。但通用 4-bit quantizer 把 PLE 也量化了 → next-token 機率分布壞掉。
[mlx-community/gemma-4-e2b-4bit#1](https://huggingface.co/mlx-community/gemma-4-e2b-4bit/discussions/1) 點名此 bug。

### 速度對比 (M-class Apple Silicon, dogwalk 8.29s 音檔, 同 prompt)
| 指標 | bf16 (15GB) | **lmstudio 4bit (5GB)** | 加速 |
|------|------------|------------------------|------|
| 模型載入 | 6.0s | 3.2s | 1.9× |
| TTFT | 575ms | 478ms | 1.2× |
| Decode | 46s | **9.5s** | **4.8×** |
| TPS | 22 | **77.7** | **3.5×** |
| 輸出 tokens | 1007 | 740 | -27% (品質一致) |

### How to apply（任何 mlx-vlm/Gemma 4 專案）
1. **不要假設 mlx-community 量化版能用**——必跑短 smoke test 才能信
2. 量化版優先順序：**lmstudio-community → 自己用 FakeRocket543/mlx-gemma4 PLE-safe 量化 → bf16 fallback**
3. CLI 設計：`--quant 4bit/bf16` flag + alias dict，方便切換驗證
4. 截斷症狀的偵測點：「短 prompt 容易 early stop（PLE 副作用）」——對 agent-style 長指令較不敏感
5. 速度宣稱必須與品質驗證綁定（同份音檔 + 同份 ground-truth 任務輸出）

---

## 跨專案 reuse 重點
1. agent-style prompt 用詞庫（動詞 / 禁用前綴 / 輸出形狀 hint）
2. `--prompt-bench` script 模式（同輸入 × N 個 prompt 變體 → markdown 表）
3. 不服從 heuristic 7 字前綴清單
4. `say + ffmpeg` 合成測試音檔 pattern（已在 v1.9.0 doc）

mirror 到 `~/coding_projects/botrun-horse/docs/2026-05-15_llm-instruction-following-reuse.md`

## DoD
- [x] DEFAULT_PROMPT 改 agent-style（v1.9.2）
- [x] `--prompt-bench` 模式可用
- [x] 合成 `voice_cmd_html_dogwalk.wav`（8.29s, 可重現）
- [x] 跑出 4 prompt 對照表，2 prompt 成功產 HTML
- [x] 本文 5 條教訓
- [x] CLAUDE.md 索引
- [x] botrun-horse reuse
