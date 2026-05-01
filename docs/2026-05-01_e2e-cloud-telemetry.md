# E2E 雲端 Telemetry — 涵蓋成功+失敗+原因（v1.6.9）

**情境**：v1.6.8 已把 record 事件送雲，但測試只測 record→ffprobe，沒測 transcribe；雲端日誌只送 happy path 不送失敗原因。使用者糾正：「自動日誌的奧義是錄音沒有成功失敗等等的我要能除錯的日誌才有用，否則沒有用」。

## 結論

**E2E 測試 = record→ffprobe→transcribe→驗證 history.text 非空**。雲端日誌涵蓋 16 種事件，每個失敗事件帶足以定位的 `reason` + `*_tail` 片段。

## 八條跨專案教訓

### 1. 「測完容器層 = 測完」是工程師思維陷阱

容器層（檔案、moov、duration）只是冰山。使用者買的是「按下 → 5 分鐘後看到文字」整鏈。漏掉 transcribe 等於沒測。**測試邊界要劃在使用者價值，不是技術組件。**

### 2. 不可中途取消測試 — 取消 = 工程師視角污染

使用者真實流程不會中斷。測試腳本 toggle 取消是「我只想驗一個小東西」的工程師反射。**規則**：測試一旦發起，必須讓真實流程跑到底（含等 transcribe）才驗結果。

### 3. Telemetry 的價值在 90% 的失敗欄位、10% 的成功欄位

只送 `transcribe_success` 等於沒送。要送：
- `transcribe_failed` + `reason` 列舉（no_api_key / shell_nonzero_exit / empty_or_null_text / file_not_found）
- `*_tail` 字串（stderr 末段、API response 末段）— **這才是除錯命脈**
- HTTP/exit codes
- latency_s（超時還是 quick fail？意義完全不同）

**規則**：寫 cloudLog 時先列「會在哪些情況失敗」，每種都要有專屬 event + `reason` 欄位。

### 4. recording_finalized 必須延遲發送等 ffmpeg flush

```lua
-- 錯：stopRecording 直接讀 attrs.size → 拿到 28 bytes（moov header only）
cloudLog("recording_finalized", { file_size = attrs.size, ... })

-- 對：延遲 3 秒等 ffmpeg SIGTERM 後 flush 完
hs.timer.doAfter(3, function()
  local finalAttrs = hs.fs.attributes(file)
  cloudLog("recording_finalized", { file_size = finalAttrs.size, ... })
end)
```

### 5. 等待 async 完成用 polling busy-flag，不要 sleep 固定時間

`sleep 60`（猜 transcribe 1 分鐘）會：(1) 短檔浪費時間，(2) 長檔還在跑就進下一輪汙染。
正解：`while busy=$(hs -c 'return tostring(botrunHammerIsBusy())') && [ "$busy" = "true" ]; do sleep 3; done`，**配 timeout** 防無限掛。

timeout 公式：基本 120s + 檔案 MB × 3s（粗估 Gemini upload + inference）。

### 6. 跨工具狀態互通用 single-source history.json，不要重新發明

lua 已有 `history.json` 紀錄每筆錄音的 status/text。測試腳本驗證直接讀這個 JSON 就好：
```bash
hist_status=$(jq --arg fn "$rec_basename" '.[] | select(.filePath | endswith($fn)) | .status' "$HISTORY_FILE")
hist_text_len=$(jq --arg fn "$rec_basename" '.[] | select(.filePath | endswith($fn)) | (.text // "") | length' "$HISTORY_FILE")
[ "$hist_status" = "done" ] && [ "$hist_text_len" -gt 0 ] && echo PASS
```

### 7. 機敏邊界：text_length 上雲，text 內容不上雲

```lua
cloudLog("transcribe_success", {
  text_length = #text,        -- ✅ 數字 metric
  -- text 字串不送                ❌ 隱私
})
```

但 API 失敗時 `api_response_tail` 上雲（含 Gemini 錯誤訊息）— 接受這個風險換除錯能力。Gemini 失敗 response 通常是 "RESOURCE_EXHAUSTED" / "INVALID_ARGUMENT" 等錯誤訊息，不會含使用者錄音內容。

### 8. Hammerspoon 用 `_G` 暴露 API 給 hs CLI 取代 `hs.eventtap.keyStroke`

合成 F5 keypress 受 keyboard focus 影響、會卡死。直接 expose：
```lua
_G.botrunHammerToggle = toggleRecording
_G.botrunHammerIsBusy = function() return state.isRecording or state.isTranscribing end
_G.botrunHammerHistoryFile = function() return config.historyFile end
```
然後 `hs -c "botrunHammerToggle()"` 完全繞過鍵盤事件。

## 雲端事件 schema（v1.6.9）

| event | severity | 必含欄位 | 觸發點 |
|---|---|---|---|
| `load` | INFO | script_path | lua 模組載入 |
| `start` | INFO | file_basename, pid | 錄音啟動 |
| `heartbeat` | INFO | tick, elapsed_s, file_size, log_size, disk_free_kb, task_running, pid | 每 30 秒 |
| `stop` | INFO | elapsed_s, tick_count | 使用者停止 |
| `recording_finalized` | INFO | **file_size（flush 後）**, duration_s | 延遲 3 秒於 stopRecording 內 |
| `exit_unexpected` | ERROR | exit_code, file_size, **stderr_tail** | ffmpeg 非預期退出 |
| `transcribe_start` | INFO | file_size | transcribe() 入口 |
| `transcribe_request_start` | INFO | file_size, model | transcribeWithGemini 入口 |
| `transcribe_request_done` | INFO | latency_s, stdout_bytes | shell 任務完成 |
| `transcribe_success` | INFO | text_length, file_size, latency_s | parse 出非空文字 |
| `transcribe_done` | INFO | outer_latency_s, text_length, is_retry | 整個 pipeline 完成（含 retry）|
| `transcribe_retry` | WARNING | first_error | 第一次失敗，準備 retry |
| `transcribe_failed` | ERROR | reason, exit_code\|api_response_tail | 任一階段失敗 |
| `transcribe_final_failed` | ERROR | last_error, outer_latency_s | retry 也掛 |
| `transcribe_cancelled` | WARNING | file_basename | 使用者按 ESC（測試應永不出現）|
| `error` | ERROR | title, body | showPersistentError 觸發 |

## 反模式

- ❌ 只測 record 不測 transcribe
- ❌ 中途取消（toggle）測試
- ❌ Telemetry 只送 success path
- ❌ recording_finalized 立即抓 file_size（會抓到 moov header 28 bytes）
- ❌ 用 sleep 固定時間等 async 完成
- ❌ 重新發明 history 紀錄系統（lua 已有 history.json）
- ❌ text 字串上雲（隱私 + 流量）
- ❌ 靠 hs.eventtap.keyStroke 自動驅動（focus 一變就死）

## 失敗 triage 流程（從雲端日誌）

```
1. gcloud logging read ... | head -10  → 看最後一筆事件
2. 是 heartbeat → 看 elapsed_s 對應實際錄音時刻 → 推斷 ffmpeg 卡點
3. 是 transcribe_failed/transcribe_final_failed
   → reason 欄位 = 故障類型
   → api_response_tail/stderr_tail = 故障細節
4. 是 exit_unexpected → exit_code + stderr_tail = ffmpeg 真正死因
5. 都沒有 → lua VM 凍結（Hammerspoon 整個掛掉）→ 看 hs console
```
