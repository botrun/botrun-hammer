# 長錄音指數驗證測試地雷經驗（2026-05-01）

**情境**：botrun-hammer v1.6.6 已修「5 小時錄音遺失」一系列 bug（fMP4、stderr 導向 log file、caffeinate、Application Support 路徑）。同事仍回報「長錄音會壞」，4 分鐘正常但無重現步驟。需自動化指數驗證。

## 結論先講（給趕時間的人）

1. **不要每次都真錄 5 小時**。用 `ffmpeg -f lavfi -i sine=...` 合成同 codec/movflags 的 m4a，30 秒驗完 4→300 分鐘 8 個指數點，moov / 容器 / 大檔 IO 全會原汁原味爆。
2. **真錄煙霧只用來補合成蓋不到的部分**：avfoundation 即時擷取、hs.task pipe buffer 真實累積、系統睡眠抑制有效性。預設 4/8/16/32 分鐘四點即可。
3. **Hammerspoon 長子程序**一律加 30 秒級 heartbeat logger 寫到 console；最後一拍 = 故障時刻；沒有 heartbeat 等於壞了不知道哪壞。

## 八條可攜跨專案教訓

### 1. 「容器層 bug」用合成資料 30 秒驗，不要真等
任何「N 小時長檔案」測試，先問：「故障是發生在 codec/容器層，還是擷取/IO 層？」
- 容器/codec/movflags：合成 sine wave 走真 ffmpeg 完全等價，30 秒搞定 5 小時等價檔
- 擷取/IO/即時性：才需真錄

別把兩種混在一起跑 5 小時。

### 2. 指數遞增比線性更快找臨界點
4→8→16→32→64→128→256→300 八點覆蓋 4 分鐘到 5 小時，每點獨立 PASS/FAIL。
線性等距（30/60/90/…）會在中段浪費時間、邊界粒度反而粗。

### 3. 心跳 logger 是「黑盒長 process」的唯一除錯線索
Hammerspoon `hs.task` 跑 ffmpeg 5 小時若爆掉，沒有 heartbeat 就只能猜。
在錄音期間每 30 秒寫一行：`elapsed / file_size / log_size / disk_free / task_running / pid`。
**最後一拍的時間 = 故障時刻**，最後一拍 file_size 是否還在長 = 區分 ffmpeg 卡住 vs 整個 lua VM 卡住。

### 4. 合成 fMP4 必須與正式錄音 codec 完全對齊
不要圖方便寫 `-acodec copy` 從 wav。要逐字對齊：
```
-acodec aac -b:a 64k -ar 16000 -ac 1
-movflags +frag_keyframe+empty_moov+default_base_moof
-frag_duration 1000000
```
否則 fragment 結構不一樣，moov atom 的 bug 不會復現。

### 5. ffprobe 驗 duration 必設容差
ffmpeg 預設輸出可能多 0.064 秒（一個 AAC frame priming）。容差設 ±2 秒（合成）/ ±5 秒（真錄含啟停延遲）。

### 6. 全檔解碼測試比 ffprobe metadata 嚴格
`ffprobe` 只看 metadata（moov atom）。要驗每個 fragment 都合法，得跑 `ffmpeg -i in.m4a -f null -`，整檔 decode-only，這才能抓「moov 寫對但中段 mdat 截斷」這種詭異 bug。

### 7. 透過 hs CLI 自動驅動 Hammerspoon
`hs.ipc.cliInstall()` 一次性啟用 → `hs -c "hs.eventtap.keyStroke({}, 'F5')"` 即可從 bash 模擬熱鍵。比 AppleScript `tell application "System Events"` 快、無沙盒問題。
**前置檢查**：`hs -c "1+1"` 應回 `2`，不回就是 ipc 沒裝。

### 8. 假設可能不在最新版 — 把版號塞進 log
同事「會壞」的環境可能根本不是 v1.6.6。heartbeat log 第一行印 `version=1.6.7`，省下排錯半小時。

## 失敗時的 triage 流程

```
1. 看 docs/test-logs/synth_<ts>.log  → 哪個分鐘點 FAIL？
2. 看 /tmp/botrun-hammer-synth/<min>min.{gen,probe,decode}.err
3. 真錄失敗 → 開 Hammerspoon Console (cmd+shift+C)
4. 找最後一個 [波特槌][heartbeat] 行 → 故障時刻
5. 看故障時刻附近的 [波特槌][exit] 行 → ffmpeg exit code
6. 看 ~/Library/Application Support/botrun-hammer/recordings/<ts>.log
   → ffmpeg stderr 末段（v1.6.6 已導向此檔）
```

## 反模式（不要再犯）

- ❌ 真錄 5 小時驗 codec bug（30 秒就能驗的事，浪費一個下午）
- ❌ 線性等距驗證（4/30/60/120 → 邊界精度差）
- ❌ 長 process 不加 heartbeat（壞了不知道哪壞）
- ❌ 合成檔用 `-acodec copy` 跳過 codec 路徑（bug 不復現）
- ❌ 只看 ffprobe metadata 不做整檔 decode（漏 mdat 截斷類 bug）
- ❌ 假設使用者/同事用最新版（→ heartbeat log 印 version）
