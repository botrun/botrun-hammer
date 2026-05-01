# curl|bash 分發工具的雲端日誌（v1.6.8）

**情境**：botrun-hammer 用 `curl ... | bash` 分發給同事們。同事的 Mac 上錄音壞掉時，希望日誌**自動上雲**，不必請同事複製貼上 console。

## 結論先講

**Cloud Run logsink + 烘進 install.sh 的共享 token + lua async POST**，搭配多層機器識別欄位，30 分鐘從 0 到端到端通。

## 核心架構

```
同事 Mac
  Hammerspoon (lua v1.6.8)
    └─ heartbeat / start / stop / exit / error
       └─ cloudLog() ──[async hs.task curl]──┐
                                              ▼
                              Cloud Run (alpine, 256Mi, max-instances=1, scale-to-zero)
                                  POST /log + Bearer token
                                  └─ google-cloud-logging client
                                     └─ Cloud Logging logName=botrun-hammer
                                        labels: machine_id / computer_name / version / event ...
                                        ▼
                              你的瀏覽器 / gcloud logging read
```

## 八條跨專案教訓

### 1. curl|bash 分發場景：token 烘進 install.sh，使用者免設

「使用者只要把 LOG_URL 寫進 .env」聽起來很簡單，但 curl|bash 流程下任何「請使用者編輯檔案」都是體驗黑洞。**直接把 URL+TOKEN 當常數寫在 install.sh**，使用者啥都不用做。

公開 repo 的 token 暴露怎麼辦？接受 + 設計可 rotate：
- token 存 GCP Secret Manager，Cloud Run 用 `--update-secrets` 注入
- 要 rotate：產新版本 → `gcloud secrets versions add` → 重部署 → push 新 install.sh
- Cloud Run 加 `max-instances=1` + 月配額限制，限制濫用爆發傷害

### 2. 機器識別必須多層欄位、不能只送 hostname

`hostname -s` 在 macOS 上常常都是 "Mac"。送上去全部一樣根本沒意義。多層送：
- `hostname` — 短主機名（hostname -s）
- `computer_name` — `scutil --get ComputerName`，使用者人類可讀（如「Bowen 的 MacBook Pro」）
- `machine_id` — first-run 生成 8 位 UUID 存 `~/.botrun-hammer/machine-id`，**永久去重**
- `os_user` — 登入帳號

全送，Cloud Logging 全部設為 labels 方便 `labels.machine_id="042282b5"` filter。

### 3. Flask `request.get_data(cache=False)` 會吃掉 body

```python
# 錯誤
raw = request.get_data(cache=False, as_text=False)  # ← cache=False 表示「讀完就丟」
data = request.get_json(...)  # ← 永遠 None / 拋例外
```
這個 bug 讓 logsink 上線初期所有 POST 回 400 "bad json"。修法：刪掉 raw 讀取（用 `request.content_length` 做大小限制），讓 `get_json` 自己第一次讀。

### 4. lua hs.task fire-and-forget 不能用 echo|pipe，要 tmpfile

```lua
-- 錯：cmdline 會被特殊字元破壞 / Lua 字串 escape 雙重轉義很容易出錯
local cmd = "curl ... -d '" .. body .. "'"

-- 對：body 寫 tmpfile，curl 讀 @tmpfile
local f = io.open(tmpFile, "w"); f:write(body); f:close()
local cmd = "curl ... --data-binary @" .. tmpFile .. "; rm -f " .. tmpFile
```

`exec ... ; rm -f` 同一行 bash 處理，避免 leak。

### 5. lua → curl 的 async 不要等回應

`hs.task.new("/bin/bash", function(_) end, ...)` callback 收 result 但不檢查 — 任何網路問題都不該阻擋錄音。**failure must be silent**，這是「telemetry」不是「critical path」。

### 6. alpine vs slim：image 縮 32% 但要編 grpcio

google-cloud-logging 依賴 grpcio，alpine 沒 wheel，要自己編：
```dockerfile
RUN apk add --no-cache --virtual .build-deps gcc g++ musl-dev linux-headers python3-dev && \
    pip install -r requirements.txt && \
    apk del .build-deps
```
換來 image：59.8 MB → **40.6 MB**（壓縮 layer 大小）。
Cloud Run 對 image 大小不敏感（cold start 也才幾百毫秒差），但檔案小 = 部署快。

### 7. heartbeat + 雲端日誌 = 過夜無人值守的真錄測試解鎖

之前長錄音測試必須人在現場守 console。加雲端日誌後：
- 過夜跑 8.5hr 真錄
- 人離開電腦
- 隔天 `gcloud logging read` 拉每拍 heartbeat
- 故障時刻 = 最後一拍時間，附帶當時 file_size / disk_free / pid，根本不用同事/自己貼 log

這個方法可攜到任何「過夜壓測」場景（fuzz / soak / endurance test）。

### 8. 隱私邊界：metadata 上雲，內容絕不上雲

明文寫進 lua 註解：
```
機敏邊界：只送 metadata（檔名 basename / 大小 / 時間 / pid / stderr 末段），不送錄音內容/轉錄文字
```
- ✅ basename（`2026-05-01_063505.m4a`）
- ❌ 完整路徑（含使用者 home）
- ❌ 錄音內容（mp4 binary）
- ❌ 轉錄文字
- ❌ Gemini API key

stderr 末段 800 bytes 是灰色地帶（ffmpeg 不會印機敏內容，但理論上錯誤訊息可能含路徑）— 接受這個風險換故障可除錯性。

## 部署 checklist（30 分鐘從 0 到通）

```bash
# 1. 啟用 API（已啟用就跳過）
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  secretmanager.googleapis.com logging.googleapis.com artifactregistry.googleapis.com

# 2. 產 token + 存 Secret Manager
LOG_TOKEN=$(openssl rand -hex 32)
echo -n "$LOG_TOKEN" | gcloud secrets create botrun-hammer-log-token --replication-policy=automatic --data-file=-

# 3. 給 Cloud Run 預設 SA secret 存取權
PROJECT_NUMBER=$(gcloud projects describe $(gcloud config get-value project) --format="value(projectNumber)")
gcloud secrets add-iam-policy-binding botrun-hammer-log-token \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 4. 部署
cd cloud/logsink
gcloud run deploy botrun-hammer-logsink --source . --region asia-east1 \
  --allow-unauthenticated --update-secrets="LOG_TOKEN=botrun-hammer-log-token:latest" \
  --memory 256Mi --cpu 1 --max-instances 1 --timeout 15s --quiet

# 5. 把 URL+TOKEN 烘進 install.sh，commit、push GitHub
# 6. lua 加 cloudLog() 函式
# 7. 同事下次 curl|bash 升級即帶上
```

## Cloud Logging 查詢 cheatsheet

```bash
# 看某台機器最近 100 筆
gcloud logging read 'logName="projects/botrun-c/logs/botrun-hammer" AND labels.machine_id="042282b5"' --limit=100

# 只看錯誤事件
gcloud logging read 'logName="projects/botrun-c/logs/botrun-hammer" AND severity="ERROR"' --limit=20

# 某台機器最近一場錄音的所有 heartbeat（按時間升冪）
gcloud logging read 'logName="projects/botrun-c/logs/botrun-hammer"
  AND labels.machine_id="042282b5"
  AND jsonPayload.event="heartbeat"' --limit=50 --order=asc

# 所有版本分布
gcloud logging read 'logName="projects/botrun-c/logs/botrun-hammer"' \
  --format="value(labels.version)" --limit=1000 | sort | uniq -c
```

## 反模式

- ❌ SA key 下載到使用者機器（洩漏難 rotate / curl|bash 流程裡無法處理）
- ❌ 只送 `hostname -s`（macOS 全部回 "Mac"）
- ❌ lua 同步等 curl 回應（網路抖一下錄音就卡）
- ❌ 用 `os.execute` 跑 curl（同步阻擋 + 沒法處理特殊字元）
- ❌ 把錄音內容/轉錄文字上雲（隱私、頻寬、合規問題一次來）
- ❌ token 存 Cloud Run env var（不可 rotate / 不可 audit）— 一定走 Secret Manager
