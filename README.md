# Botrun Hammer 🔨 波特槌「一槌定音」

**Mac Voice-to-Text Tool** - Press F5 to speak, text auto-types at cursor

## Quick Install

**一鍵安裝 / One-liner install (macOS only):**

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

**帶 API Key 靜默安裝 / Silent install with API keys:**

```bash
GEMINI_API_KEY=your_key NCHC_GENAI_API_KEY=your_key curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

---

## 🎉 Release Notes

### v1.5.x - 更聰明更穩定

- **v1.5.1** - 完全移除 ESC 按鍵綁定，不再攔截系統 ESC，不影響其他應用程式
- **v1.5.0** - 智慧麥克風偵測，自動跳過 Teams/Zoom 等虛擬音訊裝置
- **v1.4.4** - Gemini API 失敗自動重試一次，再失敗才切換 NCHC
- **v1.4.0** - 自動更新功能，啟動時及每 4 小時自動檢查 GitHub 最新版本

### v1.3.0 - 後悔藥來了！

你有沒有這種經驗：剛剛講了一段超厲害的話，結果忘記貼到哪裡了？或是想說「欸剛剛那段再用一次」但已經消失在茫茫的剪貼簿歷史中？

**不用怕，F6 和 F7 來救你了！**

| 快捷鍵 | 功能 | 白話文 |
|--------|------|--------|
| **fn+F6** | 轉錄文字歷史 | 最近 30 筆講過的話，選一個直接複製 📋 |
| **fn+F7** | 錄音檔案歷史 | 最近 30 個錄音檔，選一個在 Finder 打開 📁 |

**還有！** 現在 Gemini API 當主力，國網中心 NCHC 當備胎。Gemini 掛了？沒關係，自動切換，你連感覺都沒有 🔄

### v1.2.x - 穩定好用

- 即時 FFmpeg 壓縮，錄音檔變小不佔空間
- 支援 Gemini + NCHC 雙 API 備援
- 簡繁自動轉換，不用再看簡體字

使用國網中心（NCHC）Whisper API 進行語音辨識，支援中文、英文等多種語言。

---

## 功能特色

- ⌨️ **fn+F5 快捷鍵** - 一鍵開始/停止錄音
- 🎯 **游標位置輸入** - 轉錄文字自動貼到游標位置
- 🔄 **簡繁轉換** - 自動將簡體轉為繁體中文
- 🚀 **開機自動啟動** - 安裝後自動常駐
- 🎤 **智慧麥克風偵測** - 自動跳過虛擬音訊裝置
- 🔁 **自動更新** - 每 4 小時檢查 GitHub 最新版本

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
| **F6** | 瀏覽轉錄文字歷史（複製到剪貼簿） |
| **F7** | 瀏覽錄音檔案歷史（在 Finder 顯示） |

### 操作流程

1. 把游標放在你想輸入文字的地方
2. 按 **F5** 開始錄音（會看到提示）
3. 說話...
4. 再按 **F5** 停止錄音
5. 等待轉錄完成，文字會自動輸入

---

## API Key 設定

本工具使用 **Gemini API** 作為主要轉錄引擎，國網中心 NCHC 作為備援。

### 設定 Gemini API Key（主要）

1. 前往 [Google AI Studio](https://aistudio.google.com/apikey) 取得 API Key
2. 編輯設定檔：

```bash
nano ~/.botrun-hammer/.env
```

填入：

```
GEMINI_API_KEY=你的Gemini_API_Key
```

### 設定 NCHC API Key（備援）

1. 前往 [NCHC GenAI Portal](https://portal.genai.nchc.org.tw/)
2. 註冊/登入帳號
3. 申請 API Key

填入：

```
NCHC_GENAI_API_KEY=你的NCHC_API_Key
```

> 安裝時會自動詢問 API Key，也可以之後手動設定。

---

## 系統需求

- macOS 10.15 以上
- Homebrew（安裝腳本會自動安裝）

### 自動安裝的依賴

- **Hammerspoon** - macOS 自動化工具
- **ffmpeg** - 錄音與音訊處理
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
2. 確認 ffmpeg 已安裝：`brew install ffmpeg`

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

## English

### What is Botrun Hammer?

Botrun Hammer is a Mac voice-to-text tool powered by Hammerspoon. Press **F5** to start recording, press **F5** again to stop -- your speech is transcribed and typed at the cursor position automatically. It works everywhere: Claude Code, Gemini CLI, any text field on macOS.

### Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

### Setup

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey)
2. Add it to `~/.botrun-hammer/.env`:
   ```
   GEMINI_API_KEY=your_key_here
   ```
3. Grant Hammerspoon **Accessibility** and **Microphone** permissions in System Settings

### Shortcuts

| Key | Action |
|-----|--------|
| **F5** | Start / stop recording & transcribe |
| **F6** | Browse transcription history |
| **F7** | Browse audio file history |

---

## 授權

MIT License

---

## 致謝

- [Google Gemini](https://aistudio.google.com/) - 主要語音轉錄 API
- [NCHC GenAI](https://portal.genai.nchc.org.tw/) - 備援 Whisper API
- [Hammerspoon](https://www.hammerspoon.org/) - macOS 自動化框架
