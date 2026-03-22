# 離線優先錄音架構 (Offline-First Recording)

**建立時間**: 2026-03-22 00:00:00 TST
**狀態**: 完成

## DAG 任務追蹤

```
[修改 addToHistory 支援 status] ──┐
                                  ├──> [修改 toggleRecording 先存再轉錄] ──> [更新歷史紀錄回寫] ──> [bump 版本] ──> [commit + push]
[新增 updateHistoryEntry 函數] ──┘
```

## 任務清單

- [x] 分析痛點與動機 (2026-03-22 00:00:00 TST)
- [x] BDD 場景定義 (2026-03-22 00:00:00 TST)
- [x] 新增 `updateHistoryEntry` 函數 — 根據 filePath 回寫轉錄文字 (2026-03-22 00:01:00 TST)
- [x] 修改 `addToHistory` 支援 status 欄位 (2026-03-22 00:01:00 TST)
- [x] 修改 `toggleRecording` — 停止錄音後立即寫入歷史，再呼叫轉錄 (2026-03-22 00:01:00 TST)
- [x] 轉錄成功/失敗時更新歷史紀錄 status (2026-03-22 00:01:00 TST)
- [x] bump 版本號 1.5.1 → 1.6.0 (2026-03-22 00:01:00 TST)
- [ ] commit + push

## 地雷經驗

### 1. 歷史紀錄寫入時機錯誤
**問題**: 原本 `addToHistory` 只在轉錄成功的 callback 裡呼叫，轉錄失敗時錄音檔存在但歷史紀錄沒有記錄，F7 看不到。
**修正**: 停止錄音後**立即**寫入歷史（status=transcribing），轉錄完再更新。

### 2. 非同步回呼的順序風險
**問題**: 如果使用者快速連續錄兩段，第一段的轉錄 callback 可能在第二段停止錄音之後才回來，導致歷史順序混亂。
**修正**: 停止錄音的瞬間就寫入歷史（FIFO 插入位置固定），轉錄結果只做 in-place update，不改變順序。
