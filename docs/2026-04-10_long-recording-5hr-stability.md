# 5 小時長錄音穩定性架構（v1.6.6）

**日期**：2026-04-10
**觸發事件**：使用者多次回報「錄音超過 10 分鐘就閃一下消失，沒存檔、沒轉錄」
**目標**：支援 5 小時不間斷錄音，**檔案絕對不能遺失**，錯誤必須顯眼可回報

---

## 症狀

- 錄音按下 F5 開始，約 10 分鐘後畫面「閃一下」
- 錄音檔沒有存下來、也沒有進入轉錄流程
- 沒有任何錯誤訊息，使用者根本不知道哪裡出事
- 歷史紀錄沒有這筆，F7 找不到

## 根本原因（按影響度排序）

### 🔴 #1 主凶：`hs.task` stdout/stderr pipe buffer 被 ffmpeg 灌爆

Hammerspoon 官方 issue 原文：

> "it is possible to run processes with hs.task that never exit, it is not possible to read their output while they run and if they produce significant output, eventually the internal OS buffers will fill up and the task will be suspended."

**機制**：
- `hs.task.new(path, nil, args)` 用 `nil` callback 時，stdout/stderr 仍會被 hs.task 以 pipe 捕獲
- macOS pipe buffer 只有 ~16-64KB
- ffmpeg 在預設 loglevel 下每秒印一行進度到 **stderr**（`size=... time=... bitrate=...`），約 80 bytes/行
- 算式：64KB ÷ 80 bytes ÷ 60 秒 ≈ **13 分鐘**（跟實測 10 分鐘吻合）
- pipe 塞滿後，ffmpeg 下次 `write(stderr)` 會 block，整個 ffmpeg 凍結在 kernel 內
- avfoundation 的 audio queue 沒人消費 → 錄音實質停止

### 🔴 #2 幫凶：MP4/M4A moov atom 在 SIGTERM 下不會寫入

- MP4/M4A 容器的 metadata（`moov` atom）預設只在 ffmpeg **正常結束**時才寫入檔尾
- `hs.task:terminate()` 送 SIGTERM；ffmpeg 在被 #1 卡住時再被 SIGTERM，來不及 flush moov
- 結果：檔案只剩一顆 `mdat` 廢檔，播放器看到「moov atom not found」→ 使用者感覺「檔案消失了」

### 🟡 #3：錄音目錄在 `~/Documents/`，被 iCloud Drive 同步干擾

- `~/Documents` 預設會被 iCloud Drive 同步
- 長錄音檔大，iCloud 可能在錄音中試圖上傳、產生 placeholder、搬離本地
- 使用者在本地路徑看不到原檔，以為消失

### 🟡 #4：沒加 `-nostdin`，ffmpeg 會讀自己的 stdin

- ffmpeg 預設會監聽 stdin 的 `q` 鍵自動退出
- `hs.task` 的 stdin 行為不保證；Hammerspoon reload 或其他狀況可能送 bytes 進去，ffmpeg 自動退出

### 🟡 #5：macOS 系統睡眠會中斷 avfoundation capture

- 長錄音橫跨系統 idle 時間時，系統 sleep / display sleep 會讓麥克風輸入中斷
- ffmpeg 回報 I/O error 退出

---

## 對策（全部落在 `hammerspoon/botrun-hammer.lua:startRecording`）

### 1. 用 bash 包 ffmpeg，stderr 改導向「日誌檔」而非 pipe

```lua
local ffmpegCmd = string.format(
  "exec %s -nostdin -hide_banner -loglevel warning -y "
  .. "-f avfoundation -i %s "
  .. "-acodec aac -b:a %s -ar %d -ac %d "
  .. "-movflags +frag_keyframe+empty_moov+default_base_moof "
  .. "-frag_duration %d "
  .. "%s < /dev/null 2> %s",
  shellQuote(ffmpegPath), shellQuote(micIndex),
  config.audioBitrate, config.sampleRate, config.channels,
  config.fragDurationUs,
  shellQuote(recordingFile), shellQuote(stderrLog)
)
state.recordingTask = hs.task.new("/bin/bash", exitCb, {"-c", ffmpegCmd})
```

關鍵點：
- `exec` 讓 bash 被 ffmpeg 取代，hs.task 的 PID 直接就是 ffmpeg，`terminate()` 直達
- `2> <logfile>` 把 stderr 寫到磁碟檔（**不是 /dev/null**，要保留給錯誤回報）
- `< /dev/null` 明示 stdin 為空
- `-loglevel warning` 平時幾乎沒輸出，有問題才寫 log
- hs.task 的 stdout/stderr pipe 完全空閒，永遠不會塞爆

### 2. Fragmented MP4：moov 一開始就寫、每秒寫一顆 moof

```
-movflags +frag_keyframe+empty_moov+default_base_moof
-frag_duration 1000000
```

效果：
- `empty_moov`：檔案一開始就寫入空的 moov atom（帶 metadata 但無 sample table）
- `default_base_moof` + `frag_keyframe`：每段音訊封裝成獨立的 `moof` + `mdat`
- `-frag_duration 1000000`（微秒）：每 1 秒切一個 fragment
- **不管錄音何時被 kill，檔案隨時都是合法的 fragmented MP4，可被任何播放器/Gemini API 解碼**
- 最糟情況：遺失最後 <1 秒

### 3. 錄音目錄搬離 iCloud

```lua
recordingDir = os.getenv("HOME") .. "/Library/Application Support/botrun-hammer/recordings",
```

並加一次性 migration：啟動時自動把舊的 `~/Documents/botrun-hammer-recordings/` 內容搬過來。

### 4. 防睡眠

```lua
hs.caffeinate.set("systemIdle", true, true)   -- 第三參數 acAndBattery=true
hs.caffeinate.set("displayIdle", true, true)
```

停止錄音時釋放。

### 5. 錯誤必須顯眼

設計原則：**絕不能閃一下就消失**。

- **每次錄音獨立 stderr log**（`<timestamp>.log` 伴隨 `<timestamp>.m4a`）
- **hs.task exit callback** 偵測非預期退出：`state.isRecording` 還是 `true` 就表示使用者沒按停止
- 讀取 log 末段 800 bytes，組成完整錯誤訊息
- `hs.alert` 顯示 15 秒 + `hs.notify` 發送**永久通知**（`withdrawAfter = 0`，需使用者手動點擊）
- 同時 `print` 到 Hammerspoon console，可事後回查
- 把失敗記錄寫入 `history.json`，F7 找得到壞檔（fMP4 通常仍可播）
- `stopRecording` 結尾驗證檔案 `attrs.size > 0`，否則也跑同樣的錯誤通知流程

```lua
local function showPersistentError(title, body)
  hs.alert.show(title .. "\n" .. body, 15)
  hs.notify.new({
    title = title,
    informativeText = body,
    withdrawAfter = 0,
    hasActionButton = true,
    actionButtonTitle = "知道了",
    soundName = hs.notify.defaultNotificationSound,
  }):send()
  print("[波特槌][ERROR] " .. title .. " | " .. body)
end
```

---

## 測試方法

1. **10 分鐘閾值測試**：按 F5 錄 15 分鐘，確認停止後能正常轉錄
2. **長錄音測試**：按 F5 錄 1 小時，確認檔案大小與時長吻合
3. **5 小時極限測試**：錄 5 小時，檔案應約 140MB（64kbps × 5h），仍可播放
4. **強殺測試**：錄音中 `kill -9 <ffmpeg pid>`，檔案仍應可播放（fMP4 的保證）
5. **錯誤可見性測試**：故意斷麥克風（拔 USB），確認跳出永久通知 + log 檔內容

## 絕對不能再做的事

- ❌ 不可以用 `hs.task.new(path, nil, args)` 跑長時間會產生 stderr 的子程序
- ❌ 不可以把長錄音檔寫到 `~/Documents`（iCloud 地雷）
- ❌ 不可以用 `-f mp4`/`-f m4a` 不加 `-movflags frag_*`（SIGTERM 必壞檔）
- ❌ 錯誤只用 `hs.alert.show(..., 2)` 就完事（2 秒閃一下就消失，等於沒報錯）
- ❌ 錄音期間不設 `hs.caffeinate`（5 小時必定遇到系統睡眠）

## 參考資料

- Hammerspoon issue #1963 — hs.task stdout/stderr crash
- Hammerspoon discussion #3602 — long-running tasks via hs.task 的實際問題
- ffmpeg-user mailing list — mp4 fragmented moov
- Arch Linux Forum — SIGTERM 與 MP4 moov atom 損毀案例
