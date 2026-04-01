# curl | bash 安裝腳本地雷經驗

> 2026-04-01 16:00 TST

## 問題描述

`curl -fsSL https://...install.sh | bash` 模式下，腳本執行到 `brew install opencc` 時，brew 從 stdin 讀取資料，把剩餘的腳本內容吃掉，導致後續步驟（部署 Lua、設定 API Key、啟動 Hammerspoon）全部未執行。

## 根本原因

在 `curl | bash` 管線中：
- curl 的輸出透過 pipe 餵給 bash 的 stdin
- `brew install` (以及 Homebrew 自身安裝腳本) 會從 stdin 讀取
- 這會消耗 pipe 中尚未被 bash 讀取的腳本內容
- 結果：腳本在 brew install 之後就「斷掉」了

## 修正方式

### 1. 所有 brew install 加上 `< /dev/null`

```bash
# 錯誤
brew install ffmpeg
brew install --cask hammerspoon

# 正確
brew install ffmpeg < /dev/null
brew install --cask hammerspoon < /dev/null
```

### 2. Homebrew 自身安裝也要隔離 stdin

```bash
# 錯誤
/bin/bash -c "$(curl -fsSL .../install.sh)"

# 正確
/bin/bash -c "$(curl -fsSL .../install.sh)" < /dev/null
```

### 3. SCRIPT_DIR 在 pipe 模式下會報錯

```bash
# 錯誤 — curl|bash 時 BASH_SOURCE[0] 為空
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 正確 — 加上 2>/dev/null 防護，空值時走 curl 下載路徑
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"
```

### 4. read 互動輸入改用 /dev/tty

```bash
# 錯誤 — curl|bash 時 stdin 是 pipe，read 會失敗
read -p "API Key: " INPUT

# 正確 — 明確從 tty 讀取
read -p "API Key: " INPUT < /dev/tty
```

## macOS Accessibility 權限地雷

### 問題
Hammerspoon 需要「輔助使用 (Accessibility)」權限才能：
- 監聽全域快捷鍵（F5/F6/F7）
- 模擬鍵盤輸入（Cmd+V 貼上）

### 限制
- macOS 無法透過腳本自動授予 Accessibility 權限（受 SIP/TCC 保護）
- 只能引導使用者手動開啟

### 解法（雙層防護）

**安裝層（install.sh）**：首次安裝 Hammerspoon 時自動開啟設定頁
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

**執行層（Lua）**：每次啟動時用 `hs.accessibilityState()` 檢查，缺權限時 alert + 自動開設定頁

## 通用規則（可 reuse）

任何使用 `curl | bash` 模式的安裝腳本：
1. **所有可能讀 stdin 的指令**都必須加 `< /dev/null`
2. **互動式 read** 必須用 `< /dev/tty`
3. **BASH_SOURCE** 在 pipe 模式下為空，需防護
4. **set -e** 搭配上述防護避免 silent failure
5. **macOS 權限**無法自動授予，只能自動開啟設定頁引導
