## 波特槌版本規則

**當前版本: 1.6.5**

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
