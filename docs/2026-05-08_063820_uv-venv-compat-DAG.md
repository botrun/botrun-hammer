# DAG: uv-venv 相容性升級（v1.8.0）

時間戳：2026-05-08 06:38:20 (Asia/Taipei)

## 目標
讓同事 curl|bash 安裝後，本機 STT 引擎裝設過程**完全脫離 brew Python**，未來 brew 升版（3.12→3.13→3.14）不會斷 venv。

## 動機回顧
1. brew python 自動升版打爆 venv（python symlink 變空指向）
2. 同事多 python3 路徑競爭（Apple stub / framework / brew / pyenv）
3. PEP 668 紅字嚇退非工程師
4. mlx-whisper wheel ABI 鎖死特定 Python minor 版
5. 維護者遠端除錯時間是稀缺資源

## E2E 驗證（已通過 ✅，2026-05-08 06:33）
- uv 0.9.8 已在使用者機器
- `uv python install 3.12.12` → 4.6 秒
- `uv venv --python 3.12 /tmp/lwm-uv-e2e/venv` → 0.9 秒
- `uv pip install mlx-whisper` → 50 秒（含 torch 700MB）
- daemon 啟動 + Stage A 6 項全綠
- large-v3-turbo 5s 音檔轉錄成功，latency_ms=620
- HF cache 共用，無重下 1.5GB 模型
- 現有 `~/.botrun-hammer/venv` 與 daemon (pid 67545) 全程未動

## 平行 DAG

```
[T1 DAG]──────┐
              │
[T2 ctl.sh]───┼──→[T6 local E2E test]──→[T7 commit]──→[T8 push main]──→[T9 verify curl|bash]
[T3 install.sh]┤
[T4 test_uv]──┘
[T5 lessons]──→[T5b CLAUDE.md index]
[T5c reuse]───→[T5d horse CLAUDE.md]
```

## 任務清單

| ID | 標題 | 狀態 | 產出 |
|---|---|---|---|
| T1 | 寫 DAG todo（本檔） | ✅ | `docs/2026-05-08_063820_uv-venv-compat-DAG.md` |
| T2 | 改 `scripts/lwm_daemon_ctl.sh` cmd_install 走 uv，含 `is_uv_managed_venv` 偵測 + 既有非 uv venv 自動備份重建 | ⏳ | `scripts/lwm_daemon_ctl.sh` |
| T3 | 改 `install.sh`：預先確保 uv 可用，更新訊息字串 | ⏳ | `install.sh` |
| T4 | 新增 `scripts/test_uv_install.sh`：定稿 E2E 驗證腳本 | ⏳ | `scripts/test_uv_install.sh` |
| T5 | bump v1.7.16 → v1.8.0 (lua VERSION + CLAUDE.md) | ✅ | `hammerspoon/botrun-hammer.lua`, `CLAUDE.md` |
| T6 | 在自己機器跑 `bash scripts/test_uv_install.sh` 驗證最終腳本 | ⏳ | E2E PASS log |
| T7 | git commit | ⏳ | git history |
| T8 | git push main（curl|bash 來源） | ⏳ | github.com/botrun/botrun-hammer |
| T9 | 模擬同事 curl|bash 一次（temp dir + clean env） | ⏳ | smoke log |
| T10 | 寫地雷文章 `docs/2026-05-08_uv-venv-compat.md` | ⏳ | docs |
| T10b | 索引到 `CLAUDE.md` 地雷文件清單 | ⏳ | CLAUDE.md |
| T11 | 寫 reuse 文章到 botrun-horse | ⏳ | botrun-horse/docs |
| T11b | 索引到 botrun-horse `CLAUDE.md` | ⏳ | botrun-horse/CLAUDE.md |

## 關鍵設計決策

- **不保留 brew python fallback**：uv 5 秒下載 + standalone interpreter，不需要備援，加 fallback 只增加除錯路徑
- **既有非 uv venv 自動備份**：偵測 `venv/bin/python3.12` 的 readlink 是否含 `/uv/python/`，若否則 mv `venv` 至 `venv.bak-<timestamp>` 後重建
- **install.sh 預先裝 uv**：避免使用者第一次點本機引擎時還要等 uv 下載
- **HF cache 不變**：模型快取維持在 `~/.cache/huggingface/`，跨 venv 共用，重建 venv 不重下載 1.5GB 模型
