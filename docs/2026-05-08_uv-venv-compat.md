# uv 自管 Python — 同事 venv 相容性的根治解（v1.8.0）

時間：2026-05-08
版本：v1.7.16 → v1.8.0

## 觸發場景

curl|bash 安裝後，同事不同機器上 venv 安裝失敗五花八門：
1. 有的踩 PEP 668 紅字（brew python 3.12+ 拒絕 pip install）
2. 有的 brew 自動升 3.12→3.13 後 venv 整個斷光（`bin/python` 變空指向）
3. 有的同時裝 python.org installer + brew + Apple stub，`which python3` 順位錯，venv 選到 framework 版
4. 有的卡 Rust toolchain（mlx 在 Python 3.13 沒 wheel，build from source 失敗）
5. 維護者每個同事壞掉都得遠端共螢幕 30 分鐘

## 根因

- **Homebrew Python 不是穩定平台**：自動升版打爆既有 venv 的 ABI 鎖定，這是 Homebrew 官方文件自己承認的限制
- **`python -m venv` 綁死當下 Python ABI**：venv 內 `bin/python` 是 symlink，指向當時的 brew python；那個 python 被升版 unlink → venv 死
- **`which python3` 在 macOS 是不可預測的**：4 個來源（Apple stub / framework / brew / pyenv）競爭 `$PATH`，順序由使用者過往安裝歷史決定

## 解法（KISS）

**用 [uv](https://docs.astral.sh/uv/)（Astral 出品的 Rust 寫成 Python 工具）取代 brew python + `python -m venv` 組合。**

關鍵差異：
- uv 下載**預編譯 standalone CPython interpreter** 到 `~/.local/share/uv/python/cpython-X.Y.Z-macos-aarch64-none/`
- venv 的 `bin/python` symlink 指向那個獨立路徑
- brew 升 / 降 / 移除 / 重灌 python 都**不影響** uv 自管的 Python
- 5 秒下載（~16MB pre-compiled），不需 Rust 編譯
- 一個工具同時做 pyenv + venv + pip + pipx 的事

## 7 條跨專案可攜鐵律

1. **L1：別把 Homebrew Python 當穩定平台**
   - 任何依賴 `brew install python` 並建 venv 的腳本都是定時炸彈，brew 升版頻率比你的 release 頻率高
   - **適用情境**：任何分發到非工程師同事機器的 Python CLI 工具

2. **L2：venv symlink 是 ABI 鎖定，不是路徑黏著**
   - `bin/python -> /opt/homebrew/.../python3.12` 看似只是 symlink，實則綁死 site-packages 的 wheel ABI
   - 解法不是 symlink 修復，是換 Python 來源（uv 自管路徑不會被 brew 動到）

3. **L3：偵測 venv 來源用 readlink 而非版本比對**
   - `readlink venv/bin/python` 看 absolute target 含不含 `/uv/python/` 比看 `python --version` 可靠
   - 因為版本字串相同（都 3.12.12）但 ABI 來源不同 — uv 與 brew 的 3.12.12 不是同一份二進位

4. **L4：既有 venv 自動備份重建勝過要求使用者手動清理**
   - 偵測到非 uv-managed → `mv venv venv.bak-<timestamp>`，重建。同事不需任何認知
   - 模型 cache（HF `~/.cache/huggingface/`）跨 venv 共用，重建不重下載 1.5GB

5. **L5：install.sh 預先裝 uv 比首次點功能才裝體驗好**
   - 把 uv 安裝放在 install.sh 主流程（5 秒），而非 lazy 到使用者第一次點本機引擎才下載
   - 因為 lazy 路徑通常是**使用者期待功能立刻發生**的時候，多 5 秒等待心理體感差很多

6. **L6：uv venv 的 symlink 結構是「python 為主，python3/pythonX.Y 為 relative alias」**
   - 不要只查 `bin/python3.12`（可能是 relative symlink → "python"），要查 `bin/python` 的 readlink
   - 這個踩過：v1.8.0 第一版測試腳本就是查錯位置 fail

7. **L7：codified E2E 腳本 > 文字 SOP**
   - 寫 `scripts/test_uv_install.sh` 8 步全程驗證，比 README 寫「請依序執行 X、Y、Z」可靠
   - 同事/未來自己/CI 都用同一份腳本，零分歧

## 同事零認知負擔的安裝路徑（v1.8.0 後）

```
1. 同事執行：curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
2. install.sh 自動：偵測/安裝 uv（5 秒）
3. 同事按 F5 想用本機引擎 → 選單觸發 lwm_daemon_ctl.sh install
4. ctl.sh 自動：uv python install 3.12 → uv venv → uv pip install mlx-whisper
5. 整個過程同事只需有網路，不需懂 python3/venv/PEP 668/brew/Rust 任一詞彙
```

## 配套產出

- `scripts/lwm_daemon_ctl.sh` — `cmd_install` 改 uv-first，含 `is_uv_managed_venv` 偵測 + 既有 brew venv 自動 backup migrate
- `install.sh` — 預先確保 uv 可用
- `scripts/test_uv_install.sh` — 8 步 E2E codified 驗證
- DAG todo：`docs/2026-05-08_063820_uv-venv-compat-DAG.md`
- Reuse 文章：`botrun-horse/docs/lessons-uv-venv-compat-from-botrun-hammer-2026-05-08.md`

## 適用 reuse 範圍

- 任何分發到 macOS 同事機器、需要 Python venv 的 CLI 工具
- 任何依賴 mlx / torch / wheel ABI 鎖定的 ML inference 工具
- botrun-hippo / botrun-chicken / botrun-pi / 任何用 `python -m venv` + brew python 組合的專案

## 參考

- [uv Python versions docs](https://docs.astral.sh/uv/concepts/python-versions/)
- [Homebrew Python guidance](https://docs.brew.sh/Homebrew-and-Python)
- [pyenv vs venv vs uv 2026 guide](https://aduce.jp/en/lab/pyenv-venv-uv-python-environment-guide)
- [mlx-whisper Python 3.13 wheel issue](https://github.com/ml-explore/mlx-examples/issues/1083)
