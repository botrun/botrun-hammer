## 波特槌版本規則

**當前版本: 1.12.0**

### 🔑 GCP 專案與認證（永久規則，v1.10.1 起；v1.10.2 加開 @cameo.tw 全網域）
- **本案專屬 GCP 專案＝`botrun-hammer`**（<https://console.cloud.google.com/welcome?project=botrun-hammer>），所有 Vertex AI 呼叫一律走這顆；程式預設值與 `.env` 的 `VERTEX_PROJECT` 皆為 `botrun-hammer`。
- **認證一律 gcloud ADC，永久禁用 Gemini API key**（公司曾遭盜用損失三十餘萬）。使用者／夥伴各自跑 `gcloud auth application-default login`，用自己的 Google 帳號。
- **最小權限授權（2026-07-23 起）**：不給 `roles/aiplatform.user`（含訓練／部署／刪除端點），改用自訂角色 **`projects/botrun-hammer/roles/botrunHammerPredict`**，只含 `aiplatform.endpoints.predict` 一條權限——ASR 需要的就只有這條，已實測 200 且真錄音 E2E 通過。加人指令：`gcloud projects add-iam-policy-binding botrun-hammer --member="user:<帳號>" --role="projects/botrun-hammer/roles/botrunHammerPredict"`。
- **@cameo.tw 全網域已授權**：`domain:cameo.tw` 已綁上述最小權限角色於 `botrun-hammer`，公司同仁只要用 **@cameo.tw 帳號**跑 ADC 登入即可直接使用，管理者無須逐一開通。個人 Gmail 登入會 403 —— 程式與安裝腳本會偵測帳號網域並引導改用公司帳號重登。
- **夥伴上機三步**：① `curl -fsSL .../install.sh | bash`（會自動裝 gcloud 並引導 ADC 登入）② 安裝腳本會實測一次 Vertex 連線 ③ 若 403，腳本／F5 會把「請幫我開通波特槌：<帳號>」複製到剪貼簿，管理者執行 `gcloud projects add-iam-policy-binding botrun-hammer --member="user:<帳號>" --role="projects/botrun-hammer/roles/botrunHammerPredict"` 即可，不需重裝。
- **⚠️ ADC 全機只有一份，會被別的專案登入蓋掉（v1.11.3 治本）**：`gcloud auth application-default login` 寫的是**唯一**一份 `~/.config/gcloud/application_default_credentials.json`——只要為了別的 GCP 專案登入一次，波特槌的身分就被換掉，之後每次 F5 都 403。這跟 `gcloud auth login`（CLI 身分，多帳號並存不互蓋）**是兩套憑證**，`gcloud config get-value account` 顯示正常不代表 ADC 正常。v1.11.3 起程式會自己查 ADC 真實身分（tokeninfo，以 ADC 檔 mtime 當快取鍵），非授權網域就**自動改用本機已登入的 @cameo.tw 帳號** user token，使用者無感；真的無帳號可接手才引導重登，且彈窗印的是**實際送出請求的身分**（舊版印 CLI 身分，會指著無辜帳號害人查半天）。
- **地雷**：`gemini-3.5-flash` 只在 `global`／`us`／`asia-southeast1`；`thinkingConfig` 必須包在 `generationConfig` 內（放外層 400）；絕不可加 `x-goog-user-project` header（HTML 404）。

### 永久規則
每次修改 `hammerspoon/botrun-hammer.lua` 時，必須遞增版本號碼：
1. 第 29 行的 `VERSION` 常數（所有版本顯示共用此常數）
2. 檔案開頭註解的版本號

版本號位置：
- 第 2 行：`波特槌 v{版本號} - Mac 語音轉文字`
- 第 29 行：`local VERSION = "{版本號}"`（其餘 alert/print 均引用此常數）

### 版本號格式
採用語意化版本 (Semantic Versioning)：`主版本.次版本.修訂版`
- 修訂版 (patch)：bug 修正、小改動
- 次版本 (minor)：新功能、向下相容
- 主版本 (major)：重大變更、不相容

### 地雷經驗文件索引
- [⭐⭐⭐ v1.12.0 補轉未完成錄音（Re-transcribe）8 條地雷](docs/2026-08-12_211413_v1.12.0-補轉未完成錄音-地雷傳承.md) — **錯誤訊息裡每一句「按 X 可以 Y」都是規格**：v1.11.4 彈窗寫「登入後可從 F6 重轉」但那功能從不存在，使用者照做只得到 Finder 視窗（broken promise 比不說更傷）；**事後補救不可沿用當下的輸出方式**——補轉一律只進剪貼簿不自動貼上（游標可能在 Terminal 被當指令執行），並用「pasteText 會還原剪貼簿」的副作用當哨兵做動態驗證；**非同步回呼會遺失（7 次批次 2 次），批次必須有監督者**，否則 running 卡 true 讓整個功能按不動（局部故障升級成全域故障），配套 token 版號＋timer 強引用＋失聯狀態退回；另含 `hs -c` 非同步 print 不回終端機（害我誤判 3 次）、殘留狀態讓重跑靜默不執行、**bash 變數後接全形字元變 unbound variable**（`${VAR}` 一律加括號）、`hs -c` 首次載入 extension 污染 stdout、FIFO 淘汰必須保護待處理項否則音檔變孤兒。驗收 `scripts/test_retranscribe.sh` S1–S8 全過，真實救回本機 3 筆躺著沒轉的錄音（[DAG](docs/2026-08-12_203824_v1.12.0-補轉未完成錄音-DAG.md)）
- [⭐⭐⭐ v1.11.2 anaconda PATH 污染二連擊（curl 417 + x86_64 uv/venv）](docs/2026-07-23_v1.11.2-anaconda-path-pollution-debug-fix.md) — 「另一台可以、這台不行」先 `which -a` + `file` 查 PATH：anaconda x86_64 curl 7.68 對大 POST 送 `Expect: 100-continue` 被 Google 前端 417 封鎖（修法：固定 `/usr/bin/curl` + `-H "Expect:"`）；anaconda x86_64 uv 在 Apple Silicon 建出 x86_64 venv 使 arm64-only 的 mlx 裝不上（修法：`pick_uv()` 按 `uname -m` 挑原生架構 + venv 架構不符自動備份重建 + 新增 `install-breeze` 指令）；缺 `require("hs.ipc")` 會讓所有 `hs -c` E2E SOP 無聲失效
- [v1.9.4 雲端模型升級 gemini-3.5-flash](docs/2026-07-11_214041_gemini35-flash-upgrade.html) — 查證 3 件事只需改 1 件（model id）；Gemini 3.x 禁 thinkingLevel＋thinkingBudget 並用（400）、thinking 無法全關 MINIMAL 是地板、官方建議移除 temperature/top_p/top_k；Files API resumable 上傳 3.5 沒變；「一樣就不用改」的查證價值
- [⭐⭐⭐ v1.11.1 Breeze-ASR-26 全精度（fp32）本機引擎 + 發布缺口治本](docs/2026-07-23_breeze-asr-26-fp32-本機引擎.html) — 三傳承節點：(A) 「全精度」是需求硬約束——官方僅出 F32 safetensors、無 MLX 權重，故走 `transformers` fp32（MPS `torch_dtype=float32`）而非既有 mlx-whisper；(B) 使用者質疑「真的是 fp32 嗎、怎麼這麼快」→ 用三方對帳（下載 6.18GB／RAM 6.17GB／15.43 億參數×4bytes）把宣稱逼成鐵證，執行期印 `param.dtype`+`bytes/param`（fp32=4·fp16=2·8bit=1·4bit=0.5）；(C) **發布缺口**：lua 前端 auto-update 讓同事看到新選單，但 `ensureLwmScriptsDeployed` 舊邏輯只「缺檔才補」→ 既有 daemon 停 1.9.0 不認 breeze、一選就 400，治本改「版本落後即重抓+重啟」（L3 通則：任何自我修復要從缺檔判斷升級為版本判斷）；真實 E2E 25s 音檔 MPS fp32 轉錄 23s、專有名詞正確。IAP 已發布（botrun-five）。
- [⭐⭐⭐ v1.9.3 Gemma 4 E4B 服從度 + 4bit MLX 量化地雷](docs/2026-05-15_200200_gemma-instruction-following-lessons.md) — 兩條合一：(A) 「像對話一樣自然回答」這 5 字是 chat-bot 殺手，改 agent-style 後輸出字數差 100×；(B) **mlx-community/unsloth 的 Gemma 4 4bit MLX 有 PLE bug** 輸出亂碼/截斷、OptiQ 4bit 與 mlx-vlm 0.5 不相容（missing 963 params），**lmstudio-community/gemma-4-E4B-it-MLX-4bit 才是唯一可用 4bit**，TPS 22→77.7（+3.5×）、模型 15→5GB；6 條教訓含 L1 小模型 prompt 敏感性 / L2 prompt-bench 必須 / L3 max_tokens=600 隱形 ceiling / L4 不服從 heuristic 7 字前綴 / L6 4bit 量化必跑 smoke test 才能信；對應 [GH #6](https://github.com/botrun/botrun-hammer/issues/6)（[DAG](docs/2026-05-15_195649_gemma-instruction-following-DAG.md)）（[Bench](docs/2026-05-15_200102_prompt-bench.md)）
- [⭐⭐⭐ v1.9.0 多 ASR backend（Whisper + Gemma 4 audio）](docs/2026-05-15_120028_multi-asr-backend-lessons.md) — 繁中 19.93s 基準音實測：whisper large-v3 CER 12.98%（最準）/ turbo 13.46%（快 3× 只差 0.48pp）/ gemma-4-e4b 15.87%；8 條跨專案教訓含 L3 **MLX default stream 是 thread-local（嚴重坑）** 修法 = `ThreadPoolExecutor(max_workers=1)` 序列化所有 MLX call、L2 **Whisper 對 lang=zh 仍回簡中**（CER 30→13% 落差）、L5 LLM-ASR 錯誤分布跟 CTC-ASR 不同、L7 BDD Gherkin 寫進 DAG 當 SOP；配套 `scripts/asr_benchmark/` 可重現（`generate_reference.sh` macOS say + `run_wer_compare.py` normalized CER）；對應 GitHub [#3](https://github.com/botrun/botrun-hammer/issues/3) [#4](https://github.com/botrun/botrun-hammer/issues/4) [#5](https://github.com/botrun/botrun-hammer/issues/5)（[DAG](docs/2026-05-15_114803_large-v3-and-gemma4-e2e-DAG.md)）（[Report](docs/2026-05-15_120008_asr-accuracy-report.md)）
- [離線優先錄音架構](docs/2026-03-22_offline-first-recording.md) — 錄音必須先存檔再轉錄，歷史紀錄寫入時機與非同步順序風險
- [curl|bash 安裝腳本地雷](docs/2026-04-01_curl-bash-stdin-pitfall.md) — brew install 吃掉 stdin 導致腳本截斷 + Accessibility 權限引導
- [5 小時長錄音穩定性架構](docs/2026-04-10_long-recording-5hr-stability.md) — hs.task pipe buffer 塞爆 + MP4 moov atom + iCloud Documents + fragmented MP4 + 錯誤可視化
- [⭐ 長錄音指數驗證測試（v1.6.7）](docs/2026-05-01_long-recording-exponential-test.md) — 合成 fMP4 30 秒驗 4→300 分鐘 8 點、heartbeat logger、scripts/synth_validate.sh + scripts/realtime_drive.sh、hs.ipc 驅動 F5 自動化（[DAG](docs/2026-05-01_060814_long-recording-exponential-test-DAG.md)）
- [⭐⭐ curl|bash 分發工具的雲端日誌（v1.6.8）](docs/2026-05-01_cloud-logging-curl-bash.md) — Cloud Run logsink + Bearer token 烘進 install.sh、Secret Manager 可 rotate、alpine image 40MB、多層機器識別（hostname + ComputerName + persisted UUID + os_user）、lua hs.task curl async fire-and-forget、隱私邊界（metadata 上雲不送內容）。8 條跨專案教訓
- [⭐⭐⭐ E2E 雲端 Telemetry — 涵蓋成功+失敗+原因（v1.6.9）](docs/2026-05-01_e2e-cloud-telemetry.md) — 測試邊界要劃在使用者價值不是技術組件（record→ffprobe→transcribe→驗證 history.text 非空）；雲端日誌 16 種事件含 transcribe_failed/cancelled/timeout 等失敗路徑及 api_response_tail/stderr_tail 除錯片段；recording_finalized 必延遲 3 秒等 ffmpeg flush；async 完成用 polling busy-flag 不要 sleep 固定時間；測試永不 toggle 取消（[DAG](docs/2026-05-01_065708_e2e-transcribe-cloud-telemetry-DAG.md)）
- [⭐⭐⭐ v1.8.0 uv 自管 Python — 同事 venv 相容性根治解](docs/2026-05-08_uv-venv-compat.md) — 把 brew python + `python -m venv` 換成 uv（standalone CPython 自管），brew 升版完全不影響 venv；既有非 uv venv 自動備份重建（不需同事手動清理）；install.sh 預先裝 uv 不 lazy；7 條跨專案鐵律（L1 brew 不是穩定平台 / L2 venv symlink 是 ABI 鎖 / L3 readlink 比版本比對可靠 / L4 自動 migrate / L5 預先裝 / L6 uv venv 結構 python 為主 / L7 codified E2E ＞ SOP）。配套 `scripts/test_uv_install.sh` 8 步全鏈 E2E 驗證；reuse 文章在 botrun-horse。
- [⭐ v1.7.14 隱藏「重啟 daemon / 重新安裝 pip」內務按鈕](docs/2026-05-07_151019_v1.7.14-hide-internal-controls-DAG.md) — 自動化做了就該把對應手動 UI 撤掉，否則按鈕反向暗示自動化不可靠；工程除錯改走 `_G.botrunHammer.*` + `hs -c`，UI 對使用者乾淨；選單命名是產品語言試紙（daemon/pip 詞彙洩露技術棧）
- [v1.7.12 升級指南 — 啟用本機 large-v3-turbo（0.5 秒轉錄）](docs/2026-05-07_v1.7.12-upgrade-turbo.md) — curl|bash 一鍵升級；自動同步 lua + lwm 腳本，但 `lightning-whisper-mlx` 與模型權重採 lazy install（避免雲端使用者吃 1GB）；4 步驟啟用 + 驗證指令
- [⭐⭐ 本機 STT — lightning-whisper-mlx daemon（v1.7.0）](docs/2026-05-06_lightning-whisper-mlx-daemon.md) — 本機 Whisper 引擎以 stdlib http.server daemon 模式常駐記憶體（KISS，無 FastAPI）；模型 LRU(1) + 切換瞬間；`bind 127.0.0.1` + Bearer token；port 0 須從 `server_address[1]` 讀回避免寫入 0；`hs.settings` 持久化引擎/模型/量化；menubar 露三個有意義模型；雲端 telemetry 加 `engine`/`lwm_model` 欄位但不送內容；lazy install 不強迫雲端使用者吃 1GB 依賴；OCP dispatcher 未來加引擎只需 elseif（[DAG](docs/2026-05-06_203738_lightning-whisper-mlx-daemon-DAG.md)）
