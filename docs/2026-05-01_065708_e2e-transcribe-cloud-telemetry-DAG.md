# E2E 轉錄 + 雲端 telemetry DAG（2026-05-01 06:57:08）

**觸發**：使用者強烈糾正：(1) 測試必須跑完轉錄，不可用 toggle 取消 — 那是測試的一環；(2) 雲端日誌必須涵蓋成功/失敗/錯誤原因，否則沒用。

## 動機 5 點

1. **同事「壞」可能不在錄音層** — 4hr m4a 容器 OK 但 Gemini 上傳超 size limit / quota / timeout
2. **轉錄是 Gemini Files API + generateContent** — 真實 API 鏈，長檔才會曝光各種 limit
3. **「除錯日誌」要含 user-visible state** — `transcribe_failed reason=empty_or_null_text http_response_tail=...`
4. **toggle 取消 = 工程師視角污染測試** — 真實使用者不會中斷
5. **Telemetry 沒失敗事件等於沒做** — 失敗才是金礦

## 三方案打分

| 方案 | 涵蓋度 | 雲端可除錯度 | 工程量 | 真實度 | 總分 |
|---|---|---|---|---|---|
| A. 只 record→ffprobe（前次）| 2 | 3 | 已做 | 5 | 10/40 |
| **B. record→ffprobe→transcribe→verify text，全程事件雲端** | 10 | 10 | 中 | 9 | **39/40** ✅ |
| C. 只測 transcribe（餵合成 m4a 給 Gemini）| 5 | 7 | 低 | 6 | 23/40 |

選 **B**。

## 並行 DAG

```
                    ┌──────────────────────────┐
                    │ T11 lua transcribe 事件  │
                    │  + recording_finalized   │
                    │  VERSION 1.6.8→1.6.9     │
                    └────────────┬─────────────┘
                                 │
        ┌────────────────────────┼─────────────────────────┐
        ▼                        ▼                         ▼
┌────────────────┐  ┌──────────────────────┐   ┌────────────────────┐
│ T12 realtime_  │  │ T-launch 真錄 5.5hr  │   │ T13 docs DAG/      │
│ drive.sh 等轉  │  │ 600/1200/2400/4800/  │   │ lessons + horse    │
│ 錄完成才下一輪 │  │ 10800s             ▼  │   │ mirror             │
│ + history 驗證 │  │ 雲端日誌即時觀察     │   │                    │
└────────┬───────┘  └──────────┬───────────┘   └─────────┬──────────┘
         │                     │                          │
         └─────────────┬───────┴──────────────┬───────────┘
                       ▼                      ▼
               ┌────────────────┐    ┌──────────────────┐
               │ 5/5 PASS：E2E   │    │ 任何 FAIL：雲端  │
               │ 含轉錄全綠      │    │ 日誌定位故障時刻 │
               └────────────────┘    └──────────────────┘
```

## TODO 進度

| ID | 任務 | 狀態 | 備註 |
|----|------|------|------|
| T11 | lua transcribe 事件 + VERSION 1.6.9 | ✅ | transcribe_start / request_start / request_done / success / done / retry / final_failed / cancelled / recording_finalized |
| T12 | realtime_drive.sh 等轉錄 + history 驗證 | ✅ | botrunHammerIsBusy() 輪詢；timeout=120s + file_mb×3s；history.json 比對 status=done && text_length>0 |
| T-launch | C 序列真錄啟動 | ⏳ | PID 74923 跑中，5.5hr |
| T13 | DAG / lessons / horse mirror | ⏳ | 進行中 |

## 雲端事件清單

每個事件帶 labels（machine_id / computer_name / version / event）+ jsonPayload。

| event | severity | 重點欄位 |
|---|---|---|
| `load` | INFO | script 啟動 |
| `start` | INFO | file_basename, pid |
| `heartbeat` | INFO | tick, elapsed_s, file_size, log_size, disk_free_kb, task_running, pid |
| `stop` | INFO | elapsed_s, file_basename, tick_count |
| `recording_finalized` | INFO | file_size（**真正 flush 後**，延遲 3 秒抓）, duration_s |
| `transcribe_start` | INFO | file_size |
| `transcribe_request_start` | INFO | file_size, model |
| `transcribe_request_done` | INFO | latency_s, stdout_bytes |
| `transcribe_success` | INFO | text_length, file_size, latency_s |
| `transcribe_done` | INFO | outer_latency_s, text_length, is_retry |
| `transcribe_retry` | WARNING | first_error |
| `transcribe_failed` | ERROR | reason, http/exit code, latency_s, **api_response_tail** / stderr_tail |
| `transcribe_final_failed` | ERROR | last_error, outer_latency_s |
| `transcribe_cancelled` | WARNING | （測試應永不出現）|
| `exit_unexpected` | ERROR | exit_code, file_size, **stderr_tail** |
| `error` | ERROR | title, body |

## 即時雲端觀察方式

```bash
# 開另一個 terminal，每 30 秒看本機最新事件
MID=$(cat ~/.botrun-hammer/machine-id)
watch -n 30 "gcloud logging read 'logName=\"projects/botrun-c/logs/botrun-hammer\" AND labels.machine_id=\"$MID\"' --order=desc --limit=10 --format='value(timestamp,labels.event,severity,jsonPayload.elapsed_s,jsonPayload.text_length)'"

# 只看錯誤
gcloud logging read 'logName="projects/botrun-c/logs/botrun-hammer" AND severity>="WARNING"' --order=desc --limit=20

# Cloud Console 網頁版（可即時 stream）
open "https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2Fbotrun-c%2Flogs%2Fbotrun-hammer%22"
```

## 失敗 triage

從雲端日誌找最後一拍 → 判斷哪一階段死的：

```
final event       原因
──────────────  ────────────────────────────
heartbeat（只到 N 拍）  ffmpeg 卡住或 Hammerspoon 凍結
stop                  ffmpeg flush 失敗或 file 為 0 bytes（看 recording_finalized）
recording_finalized   轉錄沒被觸發（lua bug）
transcribe_request_done（無 success） 解析失敗 — 看 api_response_tail
transcribe_failed     Gemini 拒絕 — 看 reason + api_response_tail
transcribe_final_failed 兩次 retry 都掛 — last_error 是最後一次的訊息
```

## 風險

- **5.5hr 期間 Hammerspoon 必須持續活著** — 若 reload 中斷，realtime_drive 會跑回 `botrunHammerIsBusy() = nil`（global 還沒載完），可能誤判
- **Mac 不能闔 lid / 不能斷電** — caffeinate 已開啟（systemIdle + displayIdle），但 lid 闔上仍會 sleep
- **Gemini 配額** — 5 個檔案最大 180MB，總計 ~365MB，應在免費 tier 內，但若觸發 rate limit 會看到 `transcribe_failed reason=...rate limit...`，這也是有用資料
