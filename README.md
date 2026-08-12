# Botrun Hammer 🔨 波特槌「一槌定音」

**Mac Voice-to-Text Tool** - Press fn+F5 to speak, text auto-types at cursor

## 一鍵安裝 / Install（複製這行貼到終端機）

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

> macOS 專用・不需 GitHub 帳號或 token・Homebrew／Hammerspoon／ffmpeg 等依賴會自動安裝。
> 需先有 `gcloud` ADC 登入（雲端轉錄用），詳見下方 Prerequisites；安裝腳本也會引導你登入。

## Quick Install

> **不需要 GitHub 帳號或 token** — 本專案完全公開
>
> **No GitHub account or token needed** — this project is fully public

### 安裝前你需要 / Prerequisites

| 需求 | 說明 | 怎麼取得 |
|------|------|----------|
| **macOS 10.15+** | 唯一支援的作業系統 | 你的 Mac |
| **gcloud CLI + ADC 登入** | 雲端轉錄認證（v1.10.0 起不用 API Key） | `brew install --cask gcloud-cli` 後 `gcloud auth application-default login` |
| **有 Vertex AI 權限的 GCP 專案** | 呼叫 gemini-3.5-flash | 專屬專案 [`botrun-hammer`](https://console.cloud.google.com/welcome?project=botrun-hammer)（預設值）；**@cameo.tw 全網域已授權**（最小權限角色 `botrunHammerPredict`），外部帳號需管理者加入 |

> 其他依賴（Homebrew、Hammerspoon、ffmpeg、jq、opencc）安裝腳本會**自動處理**

### 方法一：一鍵安裝（推薦）

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

安裝過程會檢查 gcloud 與 ADC 登入狀態，未登入會引導你直接完成登入。

### 方法二：先登入再安裝（批次部署）

```bash
gcloud auth application-default login
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

伺服器／CI 環境可改用 service account：`gcloud auth application-default login --impersonate-service-account=...`，同樣不需要任何 API Key。

### 方法三：clone 安裝

```bash
git clone https://github.com/botrun/botrun-hammer.git
cd botrun-hammer
./install.sh
```

### 安裝後首次設定

安裝完成後，系統會要求兩個權限（僅首次）：

1. **輔助使用權限** — 系統設定 → 隱私權與安全性 → 輔助使用 → 勾選 Hammerspoon
2. **麥克風權限** — 首次按 fn+F5 錄音時，系統會自動彈窗詢問

---

## 🎉 Release Notes

### v1.12.0 - 錄音救回來了！補轉未完成的錄音

轉錄失敗（最常見的原因是 gcloud 還沒登入）時，錄音檔一直都有保留——但在這版之前，
**保留完就沒有下一步了**，你沒有任何地方可以叫它再轉一次。

現在登入好之後按 **fn+F6**，選單第一列就會出現：

```
🔁 補轉 2 筆未完成錄音…
```

點下去，它會一筆一筆幫你轉完。也可以進「🎵 錄音檔案…」單獨挑一筆補轉
（🔁 圖示的那幾筆＝點下去就會補轉；已完成的那些按右鍵可以用目前引擎重轉一次）。

- **補轉的文字只會複製到剪貼簿，不會自動貼上**——因為補轉是事後行為，
  你這時候游標可能在 Terminal 或聊天室，自動貼上會出事。要貼請自己按 ⌘V。
- 待補轉的錄音**不會被 30 筆歷史上限沖掉**，不會變成資料夾裡找不到的孤兒檔。
- 錄音成功轉錄後，如果還有沒補完的，會提醒你一次（那一刻正是最容易成功的時機）。

### v1.6.0 - 離線優先錄音

停止錄音後立即寫入歷史紀錄，不再等轉錄結果。轉錄失敗的錄音也會出現在 fn+F7 檔案歷史中（⚠️ 標記），不怕找不到。

> **已安裝的使用者**：不用做任何事，波特槌每 4 小時自動檢查更新，會自動升級。
>
> **新安裝**：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
> ```

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

## 使用方式

| 快捷鍵 | 功能 |
|--------|------|
| **fn+F5** | 開始錄音 / 停止錄音並轉文字（轉錄中按 F5 或 ESC 可取消） |
| **fn+F6** | 統一選單：🔁 補轉未完成錄音（有才顯示）／切換引擎／文字歷史／錄音檔案 |

### 操作流程

1. 把游標放在你想輸入文字的地方
2. 按 **fn+F5** 開始錄音（會看到提示）
3. 說話...
4. 再按 **fn+F5** 停止錄音
5. 等待轉錄完成，文字會自動輸入

---

## 認證設定（Google Cloud ADC）

v1.10.0 起**永久移除 API Key**，雲端轉錄一律走 gcloud ADC（Application Default Credentials）——憑證會自動換發、可即時撤銷，不會有 key 外流被盜刷的風險。

### 登入

```bash
brew install --cask gcloud-cli          # 尚未安裝 gcloud 才需要
gcloud auth application-default login   # 瀏覽器授權，一次即可
```

### 選擇 Vertex 專案

**本專案一律使用專屬 GCP 專案 [`botrun-hammer`](https://console.cloud.google.com/welcome?project=botrun-hammer)**（`VERTEX_PROJECT` 預設值，無須設定）。

若要改用其他專案（該專案需給你 `aiplatform.endpoints.predict` 權限）：

```bash
nano ~/.botrun-hammer/.env
```

```
VERTEX_PROJECT=botrun-hammer   # 預設；改成你自己的專案 ID 才需要設
VERTEX_LOCATION=global         # 只有 global / us / asia-southeast1 有 gemini-3.5-flash
```

### 夥伴第一次使用

**@cameo.tw 同仁：不需要任何人開通。** `botrun-hammer` 專案已對整個 `cameo.tw` 網域授予最小權限角色 `botrunHammerPredict`（只能呼叫模型推論），你只要：

```bash
gcloud auth application-default login   # 選帳號時選你的 @cameo.tw 帳號
```

⚠️ **最常見的卡關**：ADC 登入時選到個人 Gmail → 403。安裝腳本與 F5 都會偵測到並提示你改用公司帳號重登。

**非 @cameo.tw 的外部夥伴**：安裝腳本會把「請幫我開通波特槌語音轉文字：你的帳號」複製到剪貼簿，貼給管理者即可：

```bash
gcloud projects add-iam-policy-binding botrun-hammer \
  --member="user:夥伴帳號@example.com" \
  --role="projects/botrun-hammer/roles/botrunHammerPredict"
```

> 這是自訂的**最小權限角色**，只含 `aiplatform.endpoints.predict`（語音轉文字唯一需要的權限），拿不到訓練、部署端點、刪除資源等能力。

兩種情況都**不用重裝**，處理完直接按 F5 就會通。

### 更新

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

重跑安裝腳本即可升級（設定與 ADC 登入都會保留）。程式本身每 4 小時也會自動檢查 GitHub 上的新版並更新。

### 常見錯誤

| 畫面提示 | 原因 | 處理 |
|---|---|---|
| 🔑 尚未登入 Google Cloud ADC | 沒登入或憑證過期 | 指令已自動複製到剪貼簿，貼上執行即可 |
| 🚫 你登入的是個人帳號 | ADC 登入時選到個人 Gmail | 改用 @cameo.tw 帳號重跑 `gcloud auth application-default login` |
| 🚫 帳號無法使用該專案 | 非 cameo.tw 且未開通 | 剪貼簿已備好開通請求，貼給管理者 |
| ⚠️ 錄音太長超過雲端單次上限 | 單次 inline 上限約 15MB | F6 切換到本機引擎後，用「🔁 補轉」轉這一筆 |
| 沒登入就錄了音，轉錄失敗 | 錄音**有保留**，只是還沒轉 | 登入後按 F6 →「🔁 補轉 N 筆未完成錄音」 |

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

## 疑難排解

### Q: 按 fn+F5 沒反應？

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
| Lua 腳本 | `~/.hammerspoon/botrun-hammer.lua` |
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
rm ~/.hammerspoon/botrun-hammer.lua

# 移除設定目錄（包含 API Key）
rm -rf ~/.botrun-hammer

# 編輯 init.lua 移除載入指令
nano ~/.hammerspoon/init.lua
# 刪除 require("botrun-hammer") 那行
```

---

## English

### What is Botrun Hammer?

Botrun Hammer is a Mac voice-to-text tool powered by Hammerspoon. Press **fn+F5** to start recording, press **fn+F5** again to stop -- your speech is transcribed and typed at the cursor position automatically. It works everywhere: Claude Code, Gemini CLI, any text field on macOS.

### Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

### Setup

1. Install gcloud and sign in with ADC (no API key needed since v1.10.0):
   ```bash
   brew install --cask gcloud-cli
   gcloud auth application-default login
   ```
2. The app uses the dedicated GCP project [`botrun-hammer`](https://console.cloud.google.com/welcome?project=botrun-hammer) by default. To use your own (needs `aiplatform.endpoints.predict`), set it in `~/.botrun-hammer/.env`:
   ```
   VERTEX_PROJECT=your-project-id
   ```
3. Grant Hammerspoon **Accessibility** and **Microphone** permissions in System Settings

### Shortcuts

| Key | Action |
|-----|--------|
| **fn+F5** | Start / stop recording & transcribe |
| **fn+F6** | Browse transcription history |
| **fn+F7** | Browse audio file history |

---

## 授權

MIT License

---

## 致謝

- [Google Vertex AI Gemini](https://cloud.google.com/vertex-ai) - 主要語音轉錄 API（ADC 認證）
- [NCHC GenAI](https://portal.genai.nchc.org.tw/) - 備援 Whisper API
- [Hammerspoon](https://www.hammerspoon.org/) - macOS 自動化框架
