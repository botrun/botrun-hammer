# Botrun Whisper 🎤

**Mac 語音轉文字工具** - 按 F5 說話，文字自動輸入

使用國網中心（NCHC）Whisper API 進行語音辨識，支援中文、英文等多種語言。

---

## 功能特色

- ⌨️ **F5 快捷鍵** - 一鍵開始/停止錄音
- 🎯 **游標位置輸入** - 轉錄文字自動貼到游標位置
- 🔄 **簡繁轉換** - 自動將簡體轉為繁體中文
- 🚀 **開機自動啟動** - 安裝後自動常駐

---

## 快速安裝

### 方法一：一鍵安裝（推薦）

打開終端機，貼上：

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

### 方法二：手動安裝

```bash
git clone https://github.com/botrun/botrun-hammer.git
cd botrun-hammer
./install.sh
```

---

## 使用方式

| 快捷鍵 | 功能 |
|--------|------|
| **F5** | 開始錄音 / 停止錄音並轉文字 |
| **ESC** | 取消錄音 |

### 操作流程

1. 把游標放在你想輸入文字的地方
2. 按 **F5** 開始錄音（會看到提示）
3. 說話...
4. 再按 **F5** 停止錄音
5. 等待轉錄完成，文字會自動輸入

---

## API Key 設定

本工具使用國網中心 GenAI API，需要申請 API Key：

### 申請 API Key

1. 前往 [NCHC GenAI Portal](https://portal.genai.nchc.org.tw/)
2. 註冊/登入帳號
3. 申請 API Key

### 設定 API Key

安裝時會自動詢問，也可以手動設定：

```bash
# 編輯設定檔
nano ~/.botrun-hammer/.env
```

填入：

```
NCHC_GENAI_API_KEY=你的API_Key
```

---

## 系統需求

- macOS 10.15 以上
- Homebrew（安裝腳本會自動安裝）

### 自動安裝的依賴

- **Hammerspoon** - macOS 自動化工具
- **sox** - 錄音工具
- **jq** - JSON 解析
- **opencc** - 簡繁轉換

---

## 首次使用設定

### 授權 Accessibility 權限

首次使用需要授權 Hammerspoon 使用輔助使用權限：

1. 開啟「系統設定」
2. 選擇「隱私權與安全性」
3. 選擇「輔助使用」
4. 將 **Hammerspoon** 加入並打勾

### 授權麥克風權限

首次錄音時，系統會詢問麥克風權限，請允許。

---

## 疑難排解

### Q: 按 F5 沒反應？

1. 確認 Hammerspoon 正在執行（選單列有 🔨 圖示）
2. 確認已授權 Accessibility 權限
3. 重新載入設定：點選 🔨 → Reload Config

### Q: 錄音失敗？

1. 確認已授權麥克風權限
2. 確認 sox 已安裝：`brew install sox`

### Q: 轉錄失敗？

1. 確認 API Key 已設定：`cat ~/.botrun-hammer/.env`
2. 確認網路連線正常
3. 確認 API Key 有效

### Q: 簡體沒轉繁體？

確認 opencc 已安裝：`brew install opencc`

---

## 檔案位置

| 檔案 | 位置 |
|------|------|
| Lua 腳本 | `~/.hammerspoon/botrun-whisper.lua` |
| API Key 設定 | `~/.botrun-hammer/.env` |
| Hammerspoon 設定 | `~/.hammerspoon/init.lua` |

---

## 解除安裝

```bash
./uninstall.sh
```

或手動：

```bash
# 移除 Lua 腳本
rm ~/.hammerspoon/botrun-whisper.lua

# 移除設定目錄（包含 API Key）
rm -rf ~/.botrun-hammer

# 編輯 init.lua 移除載入指令
nano ~/.hammerspoon/init.lua
# 刪除 require("botrun-whisper") 那行
```

---

## 授權

MIT License

---

## 致謝

- [NCHC GenAI](https://portal.genai.nchc.org.tw/) - 提供 Whisper API
- [Hammerspoon](https://www.hammerspoon.org/) - macOS 自動化框架
