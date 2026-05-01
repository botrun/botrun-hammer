## 波特槌版本規則

**當前版本: 1.6.9**

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
- [離線優先錄音架構](docs/2026-03-22_offline-first-recording.md) — 錄音必須先存檔再轉錄，歷史紀錄寫入時機與非同步順序風險
- [curl|bash 安裝腳本地雷](docs/2026-04-01_curl-bash-stdin-pitfall.md) — brew install 吃掉 stdin 導致腳本截斷 + Accessibility 權限引導
- [5 小時長錄音穩定性架構](docs/2026-04-10_long-recording-5hr-stability.md) — hs.task pipe buffer 塞爆 + MP4 moov atom + iCloud Documents + fragmented MP4 + 錯誤可視化
- [⭐ 長錄音指數驗證測試（v1.6.7）](docs/2026-05-01_long-recording-exponential-test.md) — 合成 fMP4 30 秒驗 4→300 分鐘 8 點、heartbeat logger、scripts/synth_validate.sh + scripts/realtime_drive.sh、hs.ipc 驅動 F5 自動化（[DAG](docs/2026-05-01_060814_long-recording-exponential-test-DAG.md)）
- [⭐⭐ curl|bash 分發工具的雲端日誌（v1.6.8）](docs/2026-05-01_cloud-logging-curl-bash.md) — Cloud Run logsink + Bearer token 烘進 install.sh、Secret Manager 可 rotate、alpine image 40MB、多層機器識別（hostname + ComputerName + persisted UUID + os_user）、lua hs.task curl async fire-and-forget、隱私邊界（metadata 上雲不送內容）。8 條跨專案教訓
- [⭐⭐⭐ E2E 雲端 Telemetry — 涵蓋成功+失敗+原因（v1.6.9）](docs/2026-05-01_e2e-cloud-telemetry.md) — 測試邊界要劃在使用者價值不是技術組件（record→ffprobe→transcribe→驗證 history.text 非空）；雲端日誌 16 種事件含 transcribe_failed/cancelled/timeout 等失敗路徑及 api_response_tail/stderr_tail 除錯片段；recording_finalized 必延遲 3 秒等 ffmpeg flush；async 完成用 polling busy-flag 不要 sleep 固定時間；測試永不 toggle 取消（[DAG](docs/2026-05-01_065708_e2e-transcribe-cloud-telemetry-DAG.md)）
