# 波特槌 v1.7.0 — lightning-whisper-mlx daemon 整合 DAG

**台北時間戳**: 2026-05-06 20:37:38
**目標**: 讓波特槌支援本機 STT（lightning-whisper-mlx），選單可切換引擎/模型，記憶最後一次選擇
**方案**: B — 常駐 Python HTTP server（模型常駐記憶體，切換瞬間，HTTP fire-and-forget 對齊現有 Gemini pattern）

---

## 動機（背後五點 Why）

1. **離線可用** — 飛機/敏感會議/網路差，雲端 Gemini 掛掉時要有兜底
2. **成本控制** — 5 小時長錄音常用，雲端 Files API 燒配額；本機零邊際成本
3. **延遲掌控** — daemon 模型常駐 → 切換瞬間，不像每次 spawn process 重載
4. **模型選擇權** — 「省 vs 準」拉桿（distil-medium vs large-v3）
5. **故障切換信心** — 與 v1.6.9 telemetry 同源動機：永遠給使用者一條退路

---

## 架構圖

```
F5 toggleRecording
    │
    ▼
stopRecording() → recordingFile (mp4)
    │
    ▼
transcribe(file, callback)  ← dispatcher (line 1100)
    │
    ├─ engine == "gemini" ──▶ transcribeWithGemini()      [既有]
    │
    └─ engine == "lwm"    ──▶ transcribeWithLightningWhisperMLX()  [新增]
                                  │
                                  ▼ hs.task curl
                              POST http://127.0.0.1:18120/transcribe
                              ?model=large-v3&quant=4bit
                              Authorization: Bearer <token>
                              Content-Type: application/octet-stream
                              body=binary audio
                                  │
                                  ▼
                          lwm_daemon.py (常駐)
                          - stdlib http.server
                          - 模型 lazy load + LRU cache
                          - 127.0.0.1 only (不對外)
                          - Bearer token 防本機其他程序誤打
                                  │
                                  ▼
                          {text, latency_ms, model, quant}
```

---

## 平行 DAG（任務依賴）

```
[1] DAG 文件 ─────────────┐
[15] 讀 lua 結構 ─────────┤ (前置)
                         │
[2] daemon HTTP API spec ┤
                         │
       ┌─────────────────┼─────────────────┐
       ▼                 ▼                 ▼
[3] lwm_daemon.py    [4] lwm_daemon_ctl.sh   [5] install.sh 偵測
       │                 │
       └────────┬────────┘
                ▼
         [11] daemon 煙測
                │
                ▼
       ┌────────┼────────┐
       ▼        ▼        ▼
[6] transcribeWithLWM  [9] cloudLog engine 欄位
       │        │
       └───┬────┘
           ▼
       [7] dispatcher
           │
           ▼
       [8] buildEngineMenu
           │
           ▼
       [10] VERSION 1.6.9 → 1.7.0
           │
           ▼
       [E2E 手動驗證]
           │
           ▼
       [12] 地雷文件
           │
           ├─▶ [13] CLAUDE.md 索引
           └─▶ [14] botrun-horse reuse doc
```

---

## 子任務狀態（隨進度更新）

| # | 任務 | 狀態 | 備註 |
|---|---|---|---|
| 1 | 建立 DAG 文件 | ✅ done | 本檔 |
| 2 | 設計 daemon HTTP API | ✅ done | spec 確定 |
| 3 | 實作 lwm_daemon.py | ✅ done | stdlib http.server，294 行 |
| 4 | lwm_daemon_ctl.sh | ✅ done | start/stop/status/restart/ensure/install |
| 5 | install.sh 加 LWM 偵測 | ✅ done | 部署到 ~/.botrun-hammer/scripts/ |
| 6 | transcribeWithLightningWhisperMLX() | ✅ done | hs.task curl 沿用 Gemini pattern |
| 7 | transcribe() dispatcher | ✅ done | OCP 分流 if/elseif |
| 8 | buildEngineMenu() | ✅ done | menubar，記憶 hs.settings |
| 9 | cloudLog engine 欄位 | ✅ done | 全 transcribe_* 含 engine/lwm_model |
| 10 | VERSION 1.6.9 → 1.7.0 | ✅ done | 第 2 行 + 第 27 行 |
| 11 | TDD 煙測 | ✅ done | Stage A 全綠，Stage B 待 LWM 安裝 |
| 12 | 地雷文件 | ✅ done | 9 條地雷 |
| 13 | CLAUDE.md 索引 | ✅ done | 加在地雷索引最末 |
| 14 | botrun-horse reuse | ✅ done | 7 條跨專案教訓 |
| 15 | 讀 lua 結構 | ✅ done | 已掌握插入點 |
| 16 | 修 .gitignore（額外發現） | ✅ done | scripts/* + whitelist |

---

## API 設計（Spec）

### 端點

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/health` | — | `{ok:true, model_loaded, model_name, quant, uptime_s}` |
| GET | `/models` | — | `{models:[...11 names...], quants:[null,"4bit","8bit"]}` |
| POST | `/transcribe?model=X&quant=Y` | raw audio bytes | `{text, latency_ms, model, quant, audio_bytes}` |
| POST | `/switch_model?model=X&quant=Y` | — | `{ok, loaded_in_s}` (預載) |
| POST | `/shutdown` | — | `{ok}` (graceful) |

### 安全
- 綁 `127.0.0.1` (絕不 `0.0.0.0`)
- Bearer token：`~/.botrun-hammer/lwm.token`（首次啟動產生 32 byte hex），所有請求需 `Authorization: Bearer <token>`
- 拒絕 Origin header（非瀏覽器來源）

### Port
- `18120`（不常用、不易撞）— 可在 lua config 改

### 模型 cache
- 單例 LRU(1)：切換模型時釋放舊的
- 預設模型在 `~/.botrun-hammer/.env` 的 `LWM_DEFAULT_MODEL` (預設 `distil-large-v3`，平衡)

---

## 選單記憶設計

```
hs.settings.set("botrun.engine", "gemini" | "lwm")
hs.settings.set("botrun.lwm.model", "distil-large-v3")
hs.settings.set("botrun.lwm.quant", "4bit" | "8bit" | "none")
```

選單顯露的模型（KISS — 只 3 個有意義選擇）：
- 💻 distil-medium（快、省記憶體）
- 💻 distil-large-v3（平衡，預設）
- 💻 large-v3（高準）

---

## 風險與緩解

| 風險 | 緩解 |
|---|---|
| daemon crash 後使用者不知道 | health check + auto restart by hammerspoon timer |
| 首次切到 lwm 但 daemon 未啟動 | lua 偵測連線失敗 → spawn `lwm_daemon_ctl.sh start` → 等就緒 |
| pip install 太慢 (mlx, transformers) | lazy install：第一次點本機選項才裝，過程顯示 alert |
| 模型下載很大（large-v3 ~3GB） | 第一次切換顯示「下載中…」alert，HF cache 後續秒切 |
| port 18120 被佔 | 起 daemon 前 `lsof -i:18120` 探測；佔用則往 18121.. 找空 port，寫到 token 檔 |
| 雲端 telemetry 隱私 | engine/lwm_model 上雲，**不送 text**（沿用 v1.6.8 隱私邊界） |
| 5 小時長錄音 daemon OOM | 每次 transcribe 後 GC；超大檔案警告 alert |

---

## 完成驗收（DoD）

- [ ] lua VERSION = 1.7.0，第 2 行檔頭一致
- [ ] menubar 顯示「引擎」子選單，目前選中打勾
- [ ] 切換 lwm + distil-large-v3 → F5 錄音 → 文字成功貼到游標
- [ ] 切換回 gemini → F5 錄音 → 維持原行為
- [ ] 重啟 Hammerspoon → 上次的引擎選擇被恢復
- [ ] 雲端 telemetry 包含 `engine` / `lwm_model` 欄位
- [ ] 30s 合成 wav 煙測通過
- [ ] daemon kill 後再 F5 → 自動重啟、不需人工介入
- [ ] CLAUDE.md 索引地雷新文件
- [ ] botrun-horse 收到跨專案教訓
