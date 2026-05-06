# 本機 STT — lightning-whisper-mlx daemon 整合（v1.7.0）

**日期**: 2026-05-06
**版本**: 1.7.0
**對應 DAG**: [2026-05-06_203738_lightning-whisper-mlx-daemon-DAG.md](2026-05-06_203738_lightning-whisper-mlx-daemon-DAG.md)

> 把 [`lightning-whisper-mlx`](https://github.com/mustafaaljadery/lightning-whisper-mlx) 接進波特槌，作為 Gemini 雲端轉錄之外的本機選項。menubar 切換、`hs.settings` 記憶最後一次。

---

## 為什麼要做這件事 — 五個動機

1. **離線/隱私** — 飛機、敏感會議、網路差時雲端 Gemini 會掛掉
2. **成本** — 5 小時長錄音不再吃 Files API 配額
3. **延遲** — daemon 模型常駐，切換瞬間
4. **模型選擇權** — 「省 vs 準」拉桿給使用者
5. **故障切換信心** — 跟 v1.6.9 telemetry 同源動機：永遠給使用者退路

---

## 架構決策

### 為什麼選 daemon（方案 B）而非每次 spawn process（方案 A）

| 維度 | A. CLI wrapper | **B. daemon** |
|---|---|---|
| 模型載入延遲 | 每次 3-8s | **一次性，後續毫秒級** |
| 模型切換 | 每次重載 | **常駐，立即切** |
| Lua 端複雜度 | 低（hs.task fork） | 中（需 ensureRunning） |
| 偵錯難度 | 低（CLI 直跑） | 中（需 curl） |

> daemon 模式對使用者的體感差很大：「我選 large-v3 後想換 distil-medium 試準度」這個動作從 8 秒降到 < 1 秒。

### 為什麼選 stdlib http.server 而非 FastAPI/Flask

KISS — 多一個 web framework 依賴等於多一個破口。stdlib 夠用：
- HTTP 1.1 / Authorization header / multipart 都能處理
- `ThreadingHTTPServer` 多執行緒
- 無外部依賴 = 安裝失敗點少 = 使用者好維護

### 為什麼用 raw bytes 而非 multipart

stdlib 解 multipart 痛苦。改用 `application/octet-stream` raw body + query string 傳 model/quant，client 端 `curl --data-binary @file`，server 端 `self.rfile.read(content_length)`。一句搞定。

---

## 十六條地雷（踩過 / 預防）

### 1. `--port 0` 寫進 PORT_FILE 是 0 不是實際 port

`server_address` 是 `(host, port)` tuple，當 bind 到 port 0 時 OS 才會分配實際 port。**必須在 bind 後從 `server.server_address[1]` 讀回**，不能用 args.port。否則 client 連 `http://127.0.0.1:0/` 直接 Connection refused。

```python
server = ThreadingHTTPServer(("127.0.0.1", port), handler_cls)
actual_port = server.server_address[1]   # ← 關鍵
PORT_FILE.write_text(str(actual_port))
```

### 2. `lightning-whisper-mlx` import cost 不容小覷

`from lightning_whisper_mlx import LightningWhisperMLX` 會連帶把 mlx、numpy、transformers 拉進來，冷啟動 1-2 秒。**daemon 啟動時不要 import**，把 import 放到 `ModelCache.get` 裡 lazy load。這樣 daemon 啟動瞬間就能回 health check，模型真正要用才載。

### 3. 模型切換要先釋放舊模型，否則 OOM

LRU(1)：切到新模型前 `self._whisper = None` + 等 GC，再實例化新的。large-v3 約 3GB，distil-large-v3 約 1.5GB，兩個同時在記憶體很容易在 16GB Mac 上 OOM。

### 4. Bearer token 必用 `secrets.compare_digest` 而非 `==`

`==` 短路比較會洩漏時序資訊（雖然本機攻擊很難利用，但養成習慣）。

### 5. 綁 `127.0.0.1` 不可省

千萬不要 `0.0.0.0`。Mac 在 Wi-Fi 上很可能被同網段掃到，token 雖在那擋著但**多一個攻擊面就少一個面**。

### 6. Port 自動避撞

不能假設 18120 永遠空著。`pick_port()` 在 18120-18130 範圍找空 port，**寫到 PORT_FILE**，lua 端從那讀，不要 hardcode。

### 7. `hs.settings` 預設值要在 lua 端守

第一次安裝/升級的使用者沒有設定值，`hs.settings.get("botrun.engine")` 回 `nil`。**所有讀取都要 `or "gemini"`** 兜底，否則 transcribe() 會走進 lwm 分支但 daemon 不存在。

### 8. `.gitignore` 整目錄忽略時無法 re-include 子檔

本專案 `.gitignore` 原本寫 `scripts/`（整目錄 ignore，因為原本是「本地開發腳本」）。新增 `scripts/lwm_daemon.py` 後即使加 `!scripts/lwm_daemon.py` **也不生效** — Git 規則：父目錄整個被 exclude 時無法 re-include 子檔。

修法：把 `scripts/` 改成 `scripts/*`（globbing 子檔而不是整目錄），re-include 才會生效：

```gitignore
scripts/*
!scripts/lwm_daemon.py
!scripts/lwm_daemon_ctl.sh
!scripts/test_lwm_daemon.sh
```

驗證：`git check-ignore -v scripts/lwm_daemon.py` 應顯示 `!scripts/lwm_daemon.py` 是決定規則。

> 這個坑特別陰：本地測試完全正常（檔案在硬碟上），但 push 後 curl|bash 安裝完全找不到檔案。安裝完還是要 git ls-files 確認真的進版控。

### 9. JSON parse stdout 進 shell 要用單引號跳脫

跟 Gemini 一樣的坑：

```lua
-- 對 ✅
"echo '" .. stdout:gsub("'", "'\\''") .. "' | jq ..."
-- 錯 ❌（string.format("%q", ...) 用 Lua 引號規則，shell 看不懂）
```

---

### 10. PEP 668 — Homebrew Python 拒絕 pip install（v1.7.5 修）

macOS Homebrew Python 預設 `EXTERNALLY-MANAGED`，直接 `pip install --user` 會 hard fail：

```
error: externally-managed-environment
× This environment is externally managed
```

**修法：用獨立 venv。** `~/.botrun-hammer/venv/`，daemon 指向該 venv 的 python。好處：
- 完全隔離，不污染系統 / Homebrew 環境
- 解除安裝直接 `rm -rf venv`
- 不需 sudo、不需 `--break-system-packages`
- 用戶機器有多版本 python 也不會撞

對應 `lwm_daemon_ctl.sh`：
```bash
SYSTEM_PYTHON  # 用來 python -m venv
VENV_PY        # daemon 真正執行的 python
PYTHON_BIN     # 自動 fallback：venv 優先，沒有則系統 python（給 install 階段用）
```

### 11. Hammerspoon 子程序的 PATH 不含 `/opt/homebrew/bin`（v1.7.6 修）

`hs.task` spawn 出來的 daemon 預設 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。但 lightning-whisper-mlx 內部用 `subprocess.run(["ffmpeg", ...])` 解碼音訊 — `ffmpeg` 在 `/opt/homebrew/bin/ffmpeg`，於是 daemon 跑出 `FileNotFoundError(2)`。

**修法**：在 `lwm_daemon_ctl.sh cmd_start` 裡 `nohup` 之前 `export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$PATH"`。

> **這個坑很容易誤判成 audio file 找不到** — 錯誤訊息一樣是 FileNotFoundError，得回去看 `subprocess` 的源碼才知道是 ffmpeg。

### 12. lightning-whisper-mlx 0.0.10 + mlx 0.31.2 的 4bit 量化破損（上游 bug）

```
AttributeError: type object 'QuantizedLinear' has no attribute 'quantize_module'
```

mlx ≥ 某版把 `QuantizedLinear.quantize_module` 拔掉，但 lightning-whisper-mlx 0.0.10 還在呼叫。**v1.7.6 預設 quant 改 `none` 直到上游修復**。

未來修復路徑：upstream PR、或 pin 舊版 mlx (`mlx==0.20.x`) 同時也 pin `mlx-metal`。

### 13. hs.task streaming callback 是 progress bar UI 的關鍵（v1.7.4 引進）

`hs.task.new(launchPath, doneFn, streamFn, args)` 的第三個參數是 streaming callback，每次子程序 stdout/stderr 有資料就會被叫到。可以拿來解析 pip 輸出：

```lua
local function parsePipLine(line)
  local pkg = line:match("^Collecting%s+([%w%-%._]+)")
  if pkg then return "下載: " .. pkg end
  ...
end

local task = hs.task.new("/bin/bash",
  function(exitCode, stdout, stderr) ... end,        -- done
  function(task, stdoutChunk, stderrChunk)           -- streaming
    for line in (stdoutChunk or ""):gmatch("[^\r\n]+") do
      local label = parsePipLine(line)
      if label then lwmProgress:update(2, label) end
    end
    return true
  end,
  args
)
```

進度條本體用 `hs.canvas` — 一個浮動 rectangle + text + 進度條 fill rectangle（filtered width）。比 `hs.alert` 連發好太多 — 不會閃爍、可以即時更新。

### 14. 所有 `distil-*` 模型都是英文專用！（v1.7.8 修）

**這個坑超隱形**：Distil-Whisper 是 HuggingFace 的論文，**只蒸餾了英文部分**。所以 lightning-whisper-mlx 的：
- `distil-small.en`、`distil-medium.en` — 名字有 `.en` 看得出來 ✅
- `distil-large-v2`、`distil-large-v3` — **沒** `.en` 但**仍是英文專用** ❌

實測：丟繁中音訊給 `distil-large-v3` + `language=zh`，模型完全忽略 lang hint，硬把語音當英文聽，吐出英文翻譯而不是中文轉錄。

```
輸入: 「今天天氣很好，我們去公園散步好不好」
distil-large-v3 → "Today, we're good we're going to park"  ❌
large-v3        → "今天天气很好,我们去公园散步好不好?"     ✅（再 convertToTraditional）
```

**繁中可用的多語模型**：`tiny`、`base`、`small`、`medium`、`large`、`large-v2`、`large-v3`。波特槌 v1.7.8 選單只露 small/medium/large-v3 三個有意義選擇。

> 教訓：模型名稱不含 `.en` 不等於多語。**永遠看上游 model card 的訓練資料說明**，不要從命名推斷。

### 15. lightning-whisper-mlx 寫死的模型清單，**沒有 large-v3-turbo**（v1.7.9 換 backend）

`lightning-whisper-mlx 0.0.10` 模型清單在 source 寫死：tiny/small/base/medium/large/large-v2/distil-large-v2/large-v3/distil-large-v3 + `.en` 變體。**沒有 turbo**。

加上前面遇到的 4bit broken（地雷 12），決定**整個 backend 換成 Apple 官方 `mlx-whisper`**：
- ✅ 支援 large-v3-turbo（0.67s 轉錄 vs large-v3 的 2.9s，繁中品質相近）
- ✅ 任何 HF MLX repo 都能載（不需上游加白名單）
- ✅ Apple 維護，跟 mlx 版本同步
- ✅ 沒有 4bit bug
- ⚠️ 沒有 batch_size / 自家量化選項，但對「每次轉錄一個檔」的 use case 不需要

API 簡單到不需要 wrapper class：
```python
import mlx_whisper
result = mlx_whisper.transcribe(audio_path, path_or_hf_repo="mlx-community/whisper-large-v3-turbo", language="zh")
text = result["text"]
```

模型物件可預載：
```python
from mlx_whisper.load_models import load_model
model = load_model("mlx-community/whisper-large-v3-turbo")
# mlx-whisper 內部 mmap，cached 後再呼叫 transcribe 不會重載
```

> 教訓：**第三方包裝庫換 backend 比 fork 上游划算**。lightning-whisper-mlx 雖快但小團隊維護，跟不上 mlx 版本；mlx-whisper 是 Apple 官方範例 + PyPI 套件，週期長。

### 16. Daemon 健康檢查 + 自動重啟 watchdog（v1.7.9）

實際碰到的事故：daemon 不知為何卡住（既不回 /health，也不處理 POST），curl 一直等到 ESC 取消才知道。如果使用者沒注意，會以為「波特槌壞了」。

修法：lua 端加 watchdog timer：

```lua
hs.timer.doEvery(60, function()
  if engine ~= "lwm" or state.isTranscribing then return end  -- 不打：非本機/正轉錄中
  curl /health (timeout=4s)
  if 連續 2 次 fail then
    if 距上次 restart < 30s then return end  -- 防 loop
    lwm_daemon_ctl.sh restart
    notify "daemon 自動重啟"
  end
end)
```

關鍵設計：
- **連續 2 次** 才動手（短暫 hiccup 不重啟）
- **30 秒防 loop**（avoid thrashing 如果 daemon 啟動就死）
- **轉錄中不打 health**（避免干擾 long-running transcribe）
- **重啟用 hs.notify 通知使用者**（黑盒重啟很可怕；要透明）
- **單一進入點**：lwm_daemon_ctl.sh restart 同步處理 stop+start，pidfile cleanup

> 教訓：**常駐 daemon 一定要外部 watchdog**。daemon 自己的「我還活著」迴圈不可信（卡住的程式不知道自己卡住）。

## API 介面

```
GET  /health                              → {ok, model_loaded, model_name, quant, uptime_s}
GET  /models                              → {models: [...11 names...], quants: [null,"4bit","8bit"]}
POST /transcribe?model=X&quant=Y&ext=.m4a → {text, latency_ms, model, quant, audio_bytes}
POST /switch_model?model=X&quant=Y        → {ok, loaded_in_s}
POST /shutdown                            → {ok}
```

所有請求 Header: `Authorization: Bearer <token>`，token 在 `~/.botrun-hammer/lwm.token`，0600 權限，首次啟動產生。

---

## 選單記憶設計

```lua
hs.settings.set("botrun.engine", "gemini" | "lwm")
hs.settings.set("botrun.lwm.model", "distil-large-v3")
hs.settings.set("botrun.lwm.quant", "4bit")
```

Hammerspoon `hs.settings` 用 macOS NSUserDefaults，跨 reload 自動持久化，不需自寫檔案。

選單只露 3 個模型（KISS）：
- `distil-medium.en` — 快、省記憶體
- `distil-large-v3` — **預設、平衡**
- `large-v3` — 高準

點下去就立刻 `hs.task` 起 `lwm_daemon_ctl.sh ensure`，背景預載模型，避免使用者第一次 F5 時呆等。

---

## 安裝引導（Lazy）

```
1. install.sh 部署 scripts → ~/.botrun-hammer/scripts/
2. 不強裝 lightning-whisper-mlx（pip 拉 mlx + transformers 約 1GB）
3. 使用者第一次點選單「💻 distil-large-v3」
   → setEngineLwm() 觸發 ensure
   → ensure 偵測未裝 → 回非零
   → menubar「🔧 安裝 lightning-whisper-mlx (pip)」按鈕引導
4. 使用者按「安裝」→ 進度 alert → 完成 alert
```

> 比起 install.sh 全包，lazy 安裝的好處是雲端使用者不被強迫吃 1GB 依賴。

---

## 雲端 telemetry 增補

所有 `transcribe_*` 事件加：
- `engine`: `"gemini"` | `"lwm"`
- `lwm_model`: 當 engine=lwm 時填模型名
- `lwm_quant`: 量化等級

**不送音訊內容、不送轉錄文字** — 沿用 v1.6.8 隱私邊界。

---

## 測試策略

### 階段 A — 不需模型（CI 友善）
- /health 200
- /models 列出 11 個
- 缺/錯 token 401
- 未知路徑 404
- /transcribe 空 body 400

### 階段 B — 需 LWM 已裝（本機驗證）
- 30 秒合成 wav → 取得非空 text、latency_ms 合理
- 切換模型 → /switch_model 成功，舊模型釋放

腳本：[scripts/test_lwm_daemon.sh](../scripts/test_lwm_daemon.sh)。Stage A 已 passing（2026-05-06 20:42）。

---

## DoD（v1.7.0 完工標準）

- [x] VERSION 1.6.9 → 1.7.0（lua 第 27 行 + 第 2 行檔頭）
- [x] daemon stdlib 實作 + smoke test stage A pass
- [x] menubar 引擎子選單，目前選中打勾
- [x] `hs.settings` 持久化引擎/模型/量化
- [x] dispatcher OCP 分流（未來新增引擎只需 elseif）
- [x] cloudLog 加 engine / lwm_model / lwm_quant 欄位
- [x] install.sh 部署 scripts/ 到 `~/.botrun-hammer/scripts/`
- [ ] 真實 Mac 上 F5 端到端驗證（待使用者跑）
- [ ] Stage B 煙測（待 pip install 後跑）

---

## 跨專案可重用模式（→ botrun-horse）

抽取出三個可重用模式（也已寫進 botrun-horse 對應 reuse 文件）：

1. **stdlib HTTP daemon + Bearer token + 127.0.0.1-only**：適用於任何「LLM 模型常駐」場景
2. **Port file + token file 約定**：避免 hardcode、避免設定漂移
3. **lazy install on first user gesture**：不強迫所有使用者吃大依賴

詳見 [`/Users/40gpu/coding_projects/botrun-horse/docs/2026-05-06_local-stt-daemon-reuse.md`](../../botrun-horse/docs/2026-05-06_local-stt-daemon-reuse.md)。
