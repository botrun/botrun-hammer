# Botrun Whisper

**Mac 語音轉文字工具** - 按 `fn + F5` 說話，文字自動輸入到游標位置

版本：1.2.4

---

## 這是什麼？

Botrun Whisper 是一個 Mac 專用的語音輸入工具。只要按下鍵盤上的 **fn + F5** 鍵，就可以開始說話，說完再按一次 **fn + F5**，你說的話就會自動變成文字，輸入到游標所在的位置。

**適用場景：**
- 在任何 App 中輸入文字（Word、Pages、記事本、網頁表單...）
- 快速輸入長篇文字，不用打字
- 中文、英文都能辨識

---

## 安裝教學（5 分鐘完成）

### 步驟一：開啟「終端機」

1. 按下鍵盤 `Command + 空白鍵`，會出現 Spotlight 搜尋框
2. 輸入「**終端機**」或「**Terminal**」
3. 按 Enter 開啟

> 💡 終端機是 Mac 內建的程式，不用另外安裝

### 步驟二：貼上安裝指令

在終端機視窗中，**複製並貼上**以下這段文字，然後按 Enter：

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
```

> 💡 複製方法：用滑鼠選取上面的文字，按 `Command + C` 複製，在終端機按 `Command + V` 貼上

### 步驟三：輸入 API Key

安裝過程中會詢問你的 API Key。如果你還沒有，請先申請：

1. 前往 [NCHC GenAI Portal](https://portal.genai.nchc.org.tw/)
2. 點選「註冊」建立帳號（或用 Google 登入）
3. 登入後，在控制台找到「API Key」，複製下來
4. 貼到終端機中，按 Enter

### 步驟四：授權權限（重要！）

首次使用需要授權兩個權限，否則無法運作：

#### 輔助使用權限

1. 開啟「**系統設定**」（點選螢幕左上角蘋果圖示 → 系統設定）
2. 點選左側「**隱私權與安全性**」
3. 點選右側「**輔助使用**」
4. 找到「**Hammerspoon**」，將開關打開（會需要輸入密碼）

#### 麥克風權限

首次錄音時，系統會自動詢問，請點選「**允許**」。

---

## 使用方式

| 按鍵 | 功能 |
|------|------|
| **fn + F5** | 開始錄音 / 停止錄音並轉文字 |
| **ESC** | 取消錄音（不轉文字） |

> ⚠️ **重要：** Mac 鍵盤預設 F5 是螢幕亮度鍵，需要搭配 **fn** 鍵才能觸發 F5 功能

### 操作流程

1. **把游標放在你想輸入文字的地方**（例如打開 Word，點一下編輯區）
2. **按 fn + F5** 開始錄音（會看到「錄音中...」提示）
3. **對著麥克風說話**
4. **再按一次 fn + F5** 停止錄音
5. **等待幾秒**，文字會自動輸入到游標位置

> 💡 錄音時間太短（少於 0.5 秒）會被忽略

### 想要只按 F5 就能用？

如果你希望不用按 fn，可以在「系統設定」調整：

1. 開啟「**系統設定**」
2. 點選「**鍵盤**」
3. 開啟「**將 F1、F2 等鍵作為標準功能鍵使用**」

這樣就可以直接按 F5，不用再按 fn 了。

---

## 確認是否安裝成功

安裝完成後，你應該會在螢幕右上角的選單列看到一個 **🔨 圖示**，這就是 Hammerspoon。

如果沒看到：
1. 開啟「終端機」
2. 輸入 `open -a Hammerspoon` 然後按 Enter

---

## 常見問題

### Q: 按 fn + F5 沒反應？

1. 確認你按的是 **fn + F5**（不是只按 F5）
2. 確認螢幕右上角有 🔨 圖示（沒有的話開啟 Hammerspoon）
3. 確認已授權「輔助使用」權限
4. 點選 🔨 圖示 → 選「Reload Config」重新載入

### Q: 出現「錄音失敗」？

確認已授權麥克風權限：
1. 開啟「系統設定」→「隱私權與安全性」→「麥克風」
2. 找到「Hammerspoon」，確認開關已打開

### Q: 出現「找不到 API Key」？

API Key 可能沒有正確設定。手動設定方式：
1. 開啟「終端機」
2. 輸入 `vi ~/.botrun-hammer/.env` 按 Enter
3. 按 `i` 進入編輯模式
4. 輸入 `NCHC_GENAI_API_KEY=你的API_KEY`（把「你的API_KEY」換成真正的 Key）
5. 按 `ESC`，然後輸入 `:wq` 按 Enter 儲存離開

### Q: 轉譯結果是簡體字？

正常情況會自動轉成繁體字。如果沒有，請在終端機執行：
```bash
brew install opencc
```
然後點選 🔨 → Reload Config

---

## 解除安裝

如果你想移除 Botrun Whisper：

1. 開啟「終端機」
2. 輸入以下指令：

```bash
curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/uninstall.sh | bash
```

---

## 技術資訊

本工具使用以下技術：

- **[NCHC GenAI](https://portal.genai.nchc.org.tw/)** - 國網中心提供的 Whisper 語音辨識 API
- **[Hammerspoon](https://www.hammerspoon.org/)** - macOS 自動化框架
- **sox** - 錄音工具
- **opencc** - 簡繁轉換

### 檔案位置

| 檔案 | 位置 |
|------|------|
| 主程式 | `~/.hammerspoon/botrun-whisper.lua` |
| API Key 設定 | `~/.botrun-hammer/.env` |
| Hammerspoon 設定 | `~/.hammerspoon/init.lua` |

---

## 授權

MIT License

---

## 意見回饋

如果遇到問題或有建議，歡迎到 [GitHub Issues](https://github.com/botrun/botrun-hammer/issues) 回報。
