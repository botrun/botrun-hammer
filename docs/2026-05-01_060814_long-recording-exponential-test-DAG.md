# 長錄音指數驗證測試 DAG（2026-05-01 06:08:14）

**觸發**：使用者同事回報「長錄音會壞」，4 分鐘已驗證 OK，需指數方式找臨界點，且要有重 log 抓壞點。
**核心策略**：**雙軌並行** — 30 秒合成快驗 + 必要時真錄煙霧確認。

## 動機分析（5）

1. 同事提報無重現步驟 → 系統化定位臨界長度
2. 怕錄到一半才壞 → 自動驅動，不人肉守
3. 怕壞了不知道哪壞 → 加重 log（每 30 秒 heartbeat）
4. 不想等太久 → 合成路徑 30 秒驗 5 小時等價檔
5. 指數逼近 4→8→16→…→300 比線性快

## 三方案打分

| 方案 | 真實度 | 速度 | 抓 bug 精度 | 成本 | 總分 |
|---|---|---|---|---|---|
| A. 真錄指數遞增（4→256min） | 10 | 2 | 8 | 高（佔機一整天） | 23/40 |
| **B. 合成 fMP4 + 真 ffmpeg pipeline** | 7 | 10 | 9 | 低 | **35/40** ✅ |
| C. 純 unit test mock hs.task | 3 | 10 | 4 | 低 | 20/40 |

**選 B 為主、A 為輔**。B 仍走真 ffmpeg + 真 movflags 編碼器，moov / 容器 / 大檔 IO 全會原汁原味爆出來；只有「avfoundation 即時擷取」與「pipe buffer 真實累積」需 A 補。

## 並行 DAG

```
                  ┌────────────────────────────┐
                  │ T1 lua heartbeat logger    │
                  │ + VERSION 1.6.6→1.6.7      │
                  └────────────┬───────────────┘
                               │（不阻擋下游，因為合成不走 lua）
        ┌──────────────────────┼──────────────────────────┐
        ▼                      ▼                          ▼
┌────────────────┐  ┌──────────────────────┐   ┌────────────────────┐
│ T2 synth_      │  │ T3 realtime_drive.sh │   │ T4 docs + index    │
│ validate.sh    │  │ (依賴 T1 心跳)        │   │ (DAG/lessons/horse)│
│ 30 秒驗 8 點    │  │ 4→32min 真錄         │   │                    │
└────────┬───────┘  └──────────┬───────────┘   └─────────┬──────────┘
         │                     │                          │
         └─────────────┬───────┴──────────────┬───────────┘
                       ▼                      ▼
               ┌────────────────┐    ┌──────────────────┐
               │ 全綠 → 確認     │    │ 失敗 → 從心跳     │
               │ 5hr 路徑通      │    │ log 找最後一拍    │
               └────────────────┘    └──────────────────┘
```

## TODO 進度

| ID | 任務 | 狀態 | 結果 |
|----|------|------|------|
| T1 | lua heartbeat logger + VERSION 1.6.7 | ✅ | startRecording 啟、stopRecording 停、exit cb 停；30 秒一拍含 elapsed/file_size/log_size/disk_free/pid |
| T2 | scripts/synth_validate.sh | ✅ | 8 點預設 4/8/16/32/64/128/256/300min；ffmpeg lavfi sine 生成→ffprobe→全檔解碼三段；煙霧 1/2/4min 全綠 |
| T3 | scripts/realtime_drive.sh | ✅ | 用 hs.eventtap.keyStroke F5 驅動；hs.ipc 預檢；每分鐘 tick 紀錄 file_size；ffprobe 驗 |
| T4 | docs + lessons + CLAUDE.md + horse mirror | ⏳ | 進行中 |

## 使用者下一步

```bash
# 30 秒快驗：直接跑（不需任何前置）
./scripts/synth_validate.sh

# 真錄煙霧：只在快驗有疑慮或要驗 avfoundation 時才跑
# 1) Hammerspoon → reload config 載入 v1.6.7
# 2) Hammerspoon console → hs.ipc.cliInstall()  （只需一次）
# 3) ./scripts/realtime_drive.sh 1 2     # 先用 1/2 分鐘煙霧
# 4) ./scripts/realtime_drive.sh         # 預設 4/8/16/32 分鐘
```

失敗時去 Hammerspoon Console (cmd+shift+C) 看 `[波特槌][heartbeat]` 的最後一拍時間 = 故障時刻。

## 快驗 vs 真錄分工

| 故障模式 | synth | realtime |
|---|---|---|
| moov atom 寫入 | ✅ | ✅ |
| fragmented MP4 fragment 完整性 | ✅ | ✅ |
| 大檔案 IO（256MB+） | ✅ | ✅ |
| Gemini 上傳大小限制 | ✅（檔案大小） | ✅ |
| avfoundation 即時擷取穩定性 | ❌ | ✅ |
| hs.task pipe buffer 真實累積 | ❌ | ✅ |
| 系統睡眠抑制是否真有效 | ❌ | ✅ |
| iCloud 干擾（v1.6.6 已搬離） | ❌ | ✅（regression） |

## 風險與假設

- **假設**：v1.6.6 的「fragmented MP4 + stderr→log file + caffeinate + Application Support 路徑」已蓋掉所有已知 5 小時級故障。本次驗證在驗這個假設。
- **風險 1**：同事的環境可能不是 v1.6.6（用 `print(VERSION)` 確認）→ 把版本號加在 heartbeat log 裡。
- **風險 2**：synth 用 sine wave，aac 編碼負載不同於真語音 → 但 codec 路徑相同，moov/movflags 邏輯一致，足以驗容器層；codec 算術差異不會引發容器 bug。
- **風險 3**：realtime 真錄期間 F5 可能撞到使用者操作 → 腳本執行時不要動鍵盤。
