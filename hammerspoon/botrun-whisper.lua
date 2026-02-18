--[[
  🔨 波特槌 v1.5.0 - Mac 語音轉文字

  由 Gemini API 驅動的語音輸入助手
  備案：NCHC Whisper API（Gemini 故障時自動切換）

  功能：
  - F5 開始/停止錄音
  - 自動呼叫 Gemini API 轉錄
  - Gemini 失敗時自動切換 NCHC Whisper API
  - 轉錄文字貼到游標位置
  - 再按 F5 停止錄音
  - F6 瀏覽最近 30 筆轉錄文字歷史（選擇後複製到剪貼簿）
  - F7 瀏覽最近 30 個錄音檔案（選擇後在 Finder 顯示）
  - 自動更新：啟動時及每 4 小時檢查 GitHub 最新版本

  安裝：
  - ./install.sh

  需求：
  - Hammerspoon
  - ffmpeg (brew install ffmpeg)
  - jq (brew install jq)
  - GEMINI_API_KEY 環境變數
  - NCHC_GENAI_API_KEY 環境變數（備案用）
]]--

-- 版本號（所有版本顯示共用此常數）
local VERSION = "1.5.0"

-- 目前腳本檔案路徑（用於自動更新）
local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$")
  or (os.getenv("HOME") .. "/.hammerspoon/botrun-whisper.lua")

-- ========================================
-- 設定
-- ========================================

local config = {
  -- NCHC API（主要）
  nchcApiUrl = "https://portal.genai.nchc.org.tw/api/v1/audio/transcriptions",
  nchcModel = "Whisper-Large-V3",
  language = "zh",

  -- Gemini API（備案）
  geminiApiUrl = "https://generativelanguage.googleapis.com/v1beta",
  geminiModel = "gemini-3-flash-preview",
  geminiUploadUrl = "https://generativelanguage.googleapis.com/upload/v1beta/files",

  -- 錄音設定
  recordingDir = os.getenv("HOME") .. "/Documents/botrun-whisper-recordings",
  sampleRate = 16000,
  channels = 1,
  audioBitrate = "64k",  -- AAC 位元率

  -- ffmpeg 路徑（Homebrew）
  ffmpegPath = "/opt/homebrew/bin/ffmpeg",
  ffmpegPathIntel = "/usr/local/bin/ffmpeg",

  -- 保留成功的錄音檔（true=保留，false=刪除）
  keepSuccessfulRecordings = true,

  -- 快捷鍵
  hotkey = "F5",
  historyTextKey = "F6",
  historyFileKey = "F7",

  -- 歷史紀錄
  historyFile = os.getenv("HOME") .. "/Documents/botrun-whisper-recordings/history.json",
  maxHistory = 30,

  -- 自動更新
  autoUpdate = {
    enabled = true,
    githubRawUrl = "https://raw.githubusercontent.com/botrun/botrun-hammer/main/hammerspoon/botrun-whisper.lua",
    checkInterval = 4 * 60 * 60,  -- 每 4 小時檢查一次
    startupDelay = 10,            -- 啟動後 10 秒開始第一次檢查
  },
}

-- ========================================
-- 狀態
-- ========================================

local state = {
  isRecording = false,
  recordingTask = nil,
  startTime = nil,
  currentRecordingFile = nil,  -- 目前錄音檔案路徑
  transcribeTimer = nil,       -- 轉錄動畫 timer
  transcribeEmojiIndex = 1,    -- 目前 emoji 索引
}

-- 轉錄中動畫 emoji 列表
local transcribeEmojis = {"✨", "🌟", "💫", "⭐", "🔮", "💭", "📝", "✍️"}

-- ========================================
-- 工具函數
-- ========================================

-- 從 .env 檔案讀取指定的 key
local function getEnvKey(keyName)
  -- 先嘗試環境變數
  local key = os.getenv(keyName)
  if key and key ~= "" then
    return key
  end

  -- 嘗試讀取 .env 檔案
  local envPaths = {
    os.getenv("HOME") .. "/coding_projects/botrun-hammer/.env",  -- 本案開發目錄
    os.getenv("HOME") .. "/.botrun-hammer/.env",
    os.getenv("HOME") .. "/.env",
  }

  for _, path in ipairs(envPaths) do
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        local pattern = "^" .. keyName .. "=(.+)$"
        local k = line:match(pattern)
        if k then
          file:close()
          -- 去除引號
          return k:gsub("^[\"']", ""):gsub("[\"']$", "")
        end
      end
      file:close()
    end
  end

  return nil
end

-- 取得 NCHC API Key
local function getNchcApiKey()
  return getEnvKey("NCHC_GENAI_API_KEY")
end

-- 取得 Gemini API Key
local function getGeminiApiKey()
  return getEnvKey("GEMINI_API_KEY")
end

-- 取得 ffmpeg 路徑
local function getFFmpegPath()
  -- Apple Silicon
  if hs.fs.attributes(config.ffmpegPath) then
    return config.ffmpegPath
  end
  -- Intel Mac
  if hs.fs.attributes(config.ffmpegPathIntel) then
    return config.ffmpegPathIntel
  end
  -- 嘗試 PATH
  return "ffmpeg"
end

-- 確保錄音資料夾存在
local function ensureRecordingDir()
  local dir = config.recordingDir
  if not hs.fs.attributes(dir) then
    hs.fs.mkdir(dir)
  end
  return dir
end

-- 產生時間戳檔名
local function generateRecordingFilename()
  local timestamp = os.date("%Y-%m-%d_%H-%M-%S")
  return config.recordingDir .. "/" .. timestamp .. ".m4a"
end

-- 取得 jq 路徑
local function getJqPath()
  -- 系統內建（macOS）
  if hs.fs.attributes("/usr/bin/jq") then
    return "/usr/bin/jq"
  end
  -- Apple Silicon Homebrew
  if hs.fs.attributes("/opt/homebrew/bin/jq") then
    return "/opt/homebrew/bin/jq"
  end
  -- Intel Mac Homebrew
  if hs.fs.attributes("/usr/local/bin/jq") then
    return "/usr/local/bin/jq"
  end
  -- 嘗試 PATH
  return "jq"
end

-- 取得 opencc 路徑（簡繁轉換）
local function getOpenccPath()
  -- Apple Silicon Homebrew
  if hs.fs.attributes("/opt/homebrew/bin/opencc") then
    return "/opt/homebrew/bin/opencc"
  end
  -- Intel Mac Homebrew
  if hs.fs.attributes("/usr/local/bin/opencc") then
    return "/usr/local/bin/opencc"
  end
  -- 嘗試 PATH
  return nil
end

-- 簡體轉繁體
local function convertToTraditional(text, callback)
  local openccPath = getOpenccPath()
  if not openccPath then
    -- 沒有 opencc，直接返回原文
    callback(text)
    return
  end

  -- 使用 opencc 轉換 s2t = 簡體到繁體
  local cmd = string.format("echo '%s' | %s -c s2t", text:gsub("'", "'\\''"), openccPath)
  local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    if exitCode == 0 and stdout then
      callback(stdout:gsub("^%s*(.-)%s*$", "%1"))  -- trim
    else
      callback(text)  -- 失敗時返回原文
    end
  end, {"-c", cmd})
  task:start()
end

-- 格式化時間
local function formatDuration(seconds)
  if seconds < 60 then
    return string.format("%.1f 秒", seconds)
  else
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d 分 %.1f 秒", mins, secs)
  end
end

-- ========================================
-- 歷史紀錄管理（SRP: 獨立負責歷史讀寫）
-- ========================================

-- 載入歷史紀錄（DRY: 統一讀取入口）
local function loadHistory()
  local file = io.open(config.historyFile, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return {}
  end
  local history = hs.json.decode(content)
  return history or {}
end

-- 儲存歷史紀錄（DRY: 統一寫入入口）
local function saveHistory(history)
  ensureRecordingDir()
  local content = hs.json.encode(history, true)
  local file = io.open(config.historyFile, "w")
  if file then
    file:write(content)
    file:close()
  end
end

-- 新增一筆歷史紀錄（KISS: 簡單的 FIFO 佇列）
local function addToHistory(text, filePath)
  local history = loadHistory()
  local entry = {
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    text = text,
    filePath = filePath,
  }
  table.insert(history, 1, entry)
  while #history > config.maxHistory do
    table.remove(history)
  end
  saveHistory(history)
end

-- UTF-8 安全截斷文字
local function truncateText(text, maxChars)
  if not text then return "" end
  local len = utf8.len(text)
  if not len or len <= maxChars then
    return text
  end
  local bytePos = utf8.offset(text, maxChars + 1)
  if bytePos then
    return text:sub(1, bytePos - 1) .. "..."
  end
  return text
end

-- ========================================
-- 麥克風偵測
-- ========================================

-- 虛擬音訊裝置關鍵字（不應作為錄音麥克風）
local VIRTUAL_AUDIO_KEYWORDS = {
  "teams", "zoom", "virtual", "soundflower", "blackhole",
  "loopback", "aggregate", "obs", "discord", "webex"
}

-- 判斷裝置名稱是否為虛擬音訊裝置
local function isVirtualDevice(name)
  local lower = name:lower()
  for _, keyword in ipairs(VIRTUAL_AUDIO_KEYWORDS) do
    if lower:find(keyword, 1, true) then
      return true
    end
  end
  return false
end

-- 取得最佳麥克風的 avfoundation index
-- 策略：1) 系統預設輸入裝置（若非虛擬）2) 內建麥克風 3) 第一個非虛擬裝置 4) fallback :0
local function getBestMicIndex()
  local ffmpegPath = getFFmpegPath()

  -- 用 ffmpeg 列出 avfoundation 裝置
  local output, status = hs.execute(ffmpegPath .. " -f avfoundation -list_devices true -i '' 2>&1")
  if not output then
    print("[波特槌] 無法列出音訊裝置，使用預設 :0")
    return ":0"
  end

  -- 解析音訊輸入裝置（在 "AVFoundation audio devices:" 之後）
  local inAudioSection = false
  local audioDevices = {}  -- { {index=number, name=string}, ... }

  for line in output:gmatch("[^\n]+") do
    if line:find("AVFoundation audio devices:") then
      inAudioSection = true
    elseif inAudioSection then
      local index, name = line:match("%[(%d+)%]%s+(.+)")
      if index and name then
        table.insert(audioDevices, {index = tonumber(index), name = name})
      end
    end
  end

  if #audioDevices == 0 then
    print("[波特槌] 未偵測到音訊裝置，使用預設 :0")
    return ":0"
  end

  -- 列出偵測到的裝置
  print("[波特槌] 偵測到音訊裝置:")
  for _, dev in ipairs(audioDevices) do
    print(string.format("  [%d] %s%s", dev.index, dev.name,
      isVirtualDevice(dev.name) and " (虛擬裝置，跳過)" or ""))
  end

  -- 策略 1: 系統預設輸入裝置（若非虛擬）
  local defaultInput = hs.audiodevice.defaultInputDevice()
  if defaultInput then
    local defaultName = defaultInput:name()
    if not isVirtualDevice(defaultName) then
      for _, dev in ipairs(audioDevices) do
        if dev.name:find(defaultName, 1, true) then
          print("[波特槌] 使用系統預設麥克風: [" .. dev.index .. "] " .. dev.name)
          return ":" .. dev.index
        end
      end
    else
      print("[波特槌] 系統預設為虛擬裝置 (" .. defaultName .. ")，尋找替代")
    end
  end

  -- 策略 2: 尋找內建麥克風
  local builtinKeywords = {"built%-in", "macbook", "內建"}
  for _, dev in ipairs(audioDevices) do
    local lower = dev.name:lower()
    for _, kw in ipairs(builtinKeywords) do
      if lower:find(kw) then
        print("[波特槌] 使用內建麥克風: [" .. dev.index .. "] " .. dev.name)
        return ":" .. dev.index
      end
    end
  end

  -- 策略 3: 第一個非虛擬裝置
  for _, dev in ipairs(audioDevices) do
    if not isVirtualDevice(dev.name) then
      print("[波特槌] 使用第一個非虛擬裝置: [" .. dev.index .. "] " .. dev.name)
      return ":" .. dev.index
    end
  end

  -- 策略 4: fallback
  print("[波特槌] 所有裝置皆為虛擬，使用預設 :0")
  return ":0"
end

-- ========================================
-- 錄音功能
-- ========================================

-- 開始錄音
local function startRecording()
  local ffmpegPath = getFFmpegPath()

  -- 檢查 ffmpeg 是否存在
  if not hs.fs.attributes(ffmpegPath) and ffmpegPath ~= "ffmpeg" then
    hs.alert.show("需要 ffmpeg 才能錄音\n請執行: brew install ffmpeg", 3)
    return false
  end

  -- 確保錄音資料夾存在
  ensureRecordingDir()

  -- 產生錄音檔名
  state.currentRecordingFile = generateRecordingFilename()
  state.isRecording = true
  state.startTime = hs.timer.secondsSinceEpoch()

  -- 偵測最佳麥克風
  local micIndex = getBestMicIndex()

  -- 啟動 ffmpeg 錄音（即時壓縮 M4A/AAC）
  state.recordingTask = hs.task.new(ffmpegPath, nil, {
    "-y",                                    -- 覆寫既有檔案
    "-f", "avfoundation",                    -- macOS 音訊輸入
    "-i", micIndex,                          -- 智慧偵測麥克風
    "-acodec", "aac",                        -- AAC 編碼
    "-b:a", config.audioBitrate,             -- 位元率
    "-ar", tostring(config.sampleRate),      -- 取樣率
    "-ac", tostring(config.channels),        -- 聲道數
    state.currentRecordingFile               -- 輸出檔案
  })

  local success = state.recordingTask:start()

  if success then
    hs.alert.show("🎙️ 波特槌 v" .. VERSION .. " 正在傾聽\n(F5 停止，ESC 取消)", 2)
    return true
  else
    hs.alert.show("啟動錄音失敗", 2)
    state.isRecording = false
    state.currentRecordingFile = nil
    return false
  end
end

-- 停止錄音
local function stopRecording()
  if state.recordingTask then
    state.recordingTask:terminate()
    state.recordingTask = nil
  end

  local duration = 0
  if state.startTime then
    duration = hs.timer.secondsSinceEpoch() - state.startTime
  end

  state.isRecording = false
  state.startTime = nil

  -- 回傳錄音時長和檔案路徑
  local recordingFile = state.currentRecordingFile
  return duration, recordingFile
end

-- ========================================
-- API 呼叫
-- ========================================

-- 呼叫 NCHC Whisper API
local function transcribeWithNCHC(recordingFile, callback)
  local apiKey = getNchcApiKey()

  if not apiKey then
    callback(nil, "NCHC API Key 未設定")
    return
  end

  -- 使用 curl 呼叫 API
  local curlCmd = string.format([[
    curl -s -X POST "%s" \
      -H "Authorization: Bearer %s" \
      -H "Accept: application/json" \
      -F "file=@%s" \
      -F "model=%s" \
      -F "language=%s" \
      -F "response_format=json"
  ]], config.nchcApiUrl, apiKey, recordingFile, config.nchcModel, config.language)

  hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    if exitCode ~= 0 then
      callback(nil, "NCHC 連線失敗: " .. (stderr or ""))
      return
    end

    -- 檢查是否有錯誤回應
    if stdout:find('"status"%s*:%s*"error"') or stdout:find("Upstream Service Error") then
      callback(nil, "NCHC 服務異常: " .. stdout)
      return
    end

    -- 解析 JSON 回應
    local jqPath = getJqPath()
    local parseTask = hs.task.new("/bin/bash", function(_, jsonOut, _)
      local text = jsonOut:gsub("^%s*(.-)%s*$", "%1")  -- trim

      if text and text ~= "" and text ~= "null" then
        callback(text, nil)
      else
        callback(nil, "NCHC 無法解析回應: " .. stdout)
      end
    end, {"-c", "echo '" .. stdout:gsub("'", "'\\''") .. "' | " .. jqPath .. " -r '.text // empty'"})
    parseTask:start()

  end, {"-c", curlCmd})
  :start()
end

-- 呼叫 Gemini API（備案）
local function transcribeWithGemini(recordingFile, callback)
  local apiKey = getGeminiApiKey()

  if not apiKey then
    callback(nil, "Gemini API Key 未設定")
    return
  end

  local jqPath = getJqPath()

  -- Gemini 需要先上傳檔案，再呼叫 generateContent
  -- 使用 shell script 一次完成整個流程
  local geminiCmd = string.format([[
    set -e
    GEMINI_API_KEY="%s"
    AUDIO_PATH="%s"
    MIME_TYPE="audio/mp4"
    NUM_BYTES=$(wc -c < "${AUDIO_PATH}" | tr -d ' ')

    # Step 1: 初始化上傳
    curl -s "%s?key=${GEMINI_API_KEY}" \
      -D /tmp/gemini-upload-header.tmp \
      -H "X-Goog-Upload-Protocol: resumable" \
      -H "X-Goog-Upload-Command: start" \
      -H "X-Goog-Upload-Header-Content-Length: ${NUM_BYTES}" \
      -H "X-Goog-Upload-Header-Content-Type: ${MIME_TYPE}" \
      -H "Content-Type: application/json" \
      -d '{"file": {"display_name": "voice-recording"}}' > /dev/null

    upload_url=$(grep -i "x-goog-upload-url: " /tmp/gemini-upload-header.tmp | cut -d" " -f2 | tr -d "\r")

    if [ -z "$upload_url" ]; then
      echo '{"error": "無法取得上傳 URL"}'
      exit 1
    fi

    # Step 2: 上傳檔案
    curl -s "${upload_url}" \
      -H "Content-Length: ${NUM_BYTES}" \
      -H "X-Goog-Upload-Offset: 0" \
      -H "X-Goog-Upload-Command: upload, finalize" \
      --data-binary "@${AUDIO_PATH}" > /tmp/gemini-file-info.json

    file_uri=$(%s -r ".file.uri" /tmp/gemini-file-info.json)

    if [ -z "$file_uri" ] || [ "$file_uri" = "null" ]; then
      echo '{"error": "檔案上傳失敗"}'
      exit 1
    fi

    # Step 3: 呼叫 generateContent 進行轉錄
    curl -s "%s/models/%s:generateContent?key=${GEMINI_API_KEY}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d '{
        "contents": [{
          "parts":[
            {"text": "請將這段音訊轉錄成繁體中文文字，只輸出轉錄的文字內容，不要加任何說明"},
            {"file_data":{"mime_type": "audio/mp4", "file_uri": "'"${file_uri}"'"}}
          ]
        }],
        "generationConfig": {
          "maxOutputTokens": 65536,
          "thinkingConfig": {
            "thinkingLevel": "MINIMAL"
          }
        }
      }'
  ]], apiKey, recordingFile, config.geminiUploadUrl, jqPath, config.geminiApiUrl, config.geminiModel)

  hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    if exitCode ~= 0 then
      callback(nil, "Gemini 連線失敗: " .. (stderr or ""))
      return
    end

    -- 解析 Gemini 回應
    local parseTask = hs.task.new("/bin/bash", function(_, jsonOut, _)
      local text = jsonOut:gsub("^%s*(.-)%s*$", "%1")  -- trim

      if text and text ~= "" and text ~= "null" then
        callback(text, nil)
      else
        callback(nil, "Gemini 無法解析回應: " .. stdout)
      end
    end, {"-c", "echo '" .. stdout:gsub("'", "'\\''") .. "' | " .. jqPath .. " -r '.candidates[0].content.parts[0].text // empty'"})
    parseTask:start()

  end, {"-c", geminiCmd})
  :start()
end

-- 轉錄動畫控制
local function startTranscribeAnimation()
  state.transcribeEmojiIndex = 1
  -- 先顯示第一個
  hs.alert.show(transcribeEmojis[1] .. " 波特人已經聽到囉，正在幫忙寫出來...", 1.5)

  -- 每秒更換 emoji
  state.transcribeTimer = hs.timer.doEvery(1, function()
    state.transcribeEmojiIndex = (state.transcribeEmojiIndex % #transcribeEmojis) + 1
    hs.alert.show(transcribeEmojis[state.transcribeEmojiIndex] .. " 波特人已經聽到囉，正在幫忙寫出來...", 1.5)
  end)
end

local function stopTranscribeAnimation()
  if state.transcribeTimer then
    state.transcribeTimer:stop()
    state.transcribeTimer = nil
  end
end

-- 主要轉錄函數（自動 Failover：Gemini 優先，NCHC 備用）
local function transcribe(recordingFile, callback)
  -- 檢查檔案是否存在
  if not recordingFile or not hs.fs.attributes(recordingFile) then
    hs.alert.show("找不到錄音檔", 2)
    callback(nil, "找不到錄音檔案")
    return
  end

  -- 啟動轉錄動畫
  startTranscribeAnimation()

  -- 先嘗試 Gemini API（失敗會自動 retry 一次，再失敗才切 NCHC）
  local function onGeminiResult(text, err, isRetry)
    if text then
      -- Gemini 成功
      stopTranscribeAnimation()
      if not config.keepSuccessfulRecordings then
        os.remove(recordingFile)
      end
      convertToTraditional(text, function(traditionalText)
        callback(traditionalText, nil)
      end)
    elseif not isRetry then
      -- Gemini 第一次失敗，retry 一次
      print("[波特槌] Gemini 第一次失敗: " .. (err or "未知錯誤") .. "，重試一次...")
      hs.alert.show("⚠️ Gemini 暫時故障，重試中...", 1.5)
      hs.timer.doAfter(1, function()
        transcribeWithGemini(recordingFile, function(retryText, retryErr)
          onGeminiResult(retryText, retryErr, true)
        end)
      end)
    else
      -- Gemini retry 也失敗，切換 NCHC 備案
      print("[波特槌] Gemini 重試也失敗: " .. (err or "未知錯誤") .. "，切換到 NCHC")
      hs.alert.show("⚠️ Gemini 故障，切換 NCHC...", 1.5)

      transcribeWithNCHC(recordingFile, function(nchcText, nchcErr)
        stopTranscribeAnimation()
        if nchcText then
          -- NCHC 成功
          if not config.keepSuccessfulRecordings then
            os.remove(recordingFile)
          end
          convertToTraditional(nchcText, function(traditionalText)
            callback(traditionalText, nil)
          end)
        else
          -- 全部都失敗
          hs.alert.show("❌ 轉錄失敗\n錄音已保留: " .. recordingFile:match("([^/]+)$"), 3)
          callback(nil, "Gemini（含重試）和 NCHC 都失敗")
        end
      end)
    end
  end

  transcribeWithGemini(recordingFile, function(text, err)
    onGeminiResult(text, err, false)
  end)
end

-- ========================================
-- 輸出結果
-- ========================================

-- 貼到游標位置
local function pasteText(text)
  if not text or text == "" then
    return
  end

  -- 使用剪貼簿 + Cmd+V 貼上
  local oldClipboard = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)

  hs.eventtap.keyStroke({"cmd"}, "v")

  -- 延遲恢復剪貼簿
  hs.timer.doAfter(0.5, function()
    if oldClipboard then
      hs.pasteboard.setContents(oldClipboard)
    end
  end)
end

-- ========================================
-- 歷史紀錄選單（ISP: 文字與檔案分離為獨立介面）
-- ========================================

-- 文字歷史選單 (F6)：選擇後複製到剪貼簿
local textChooser = hs.chooser.new(function(choice)
  if not choice then return end
  hs.pasteboard.setContents(choice.fullText)
  hs.alert.show("✅ 已複製到剪貼簿", 1)
end)

textChooser:placeholderText("搜尋轉錄歷史...")
textChooser:searchSubText(true)

-- 檔案歷史選單 (F7)：選擇後在 Finder 顯示
local fileChooser = hs.chooser.new(function(choice)
  if not choice then return end
  if choice.filePath and hs.fs.attributes(choice.filePath) then
    hs.task.new("/usr/bin/open", nil, {"-R", choice.filePath}):start()
  else
    hs.alert.show("❌ 檔案不存在", 2)
  end
end)

fileChooser:placeholderText("搜尋錄音檔案...")
fileChooser:searchSubText(true)

-- 顯示文字歷史（DRY: 共用 loadHistory）
local function showTextHistory()
  local history = loadHistory()
  local choices = {}
  for _, entry in ipairs(history) do
    table.insert(choices, {
      text = truncateText(entry.text, 80),
      subText = entry.timestamp,
      fullText = entry.text,
    })
  end
  if #choices == 0 then
    hs.alert.show("📋 尚無轉錄歷史", 1.5)
    return
  end
  textChooser:choices(choices)
  textChooser:show()
end

-- 顯示檔案歷史（DRY: 共用 loadHistory）
local function showFileHistory()
  local history = loadHistory()
  local choices = {}
  for _, entry in ipairs(history) do
    if entry.filePath then
      local filename = entry.filePath:match("([^/]+)$") or entry.filePath
      local exists = hs.fs.attributes(entry.filePath) and "✅" or "❌"
      local preview = truncateText(entry.text, 50)
      table.insert(choices, {
        text = exists .. " " .. filename,
        subText = entry.timestamp .. " | " .. preview,
        filePath = entry.filePath,
      })
    end
  end
  if #choices == 0 then
    hs.alert.show("🎵 尚無錄音檔案", 1.5)
    return
  end
  fileChooser:choices(choices)
  fileChooser:show()
end

-- ========================================
-- 主要流程
-- ========================================

local function toggleRecording()
  if not state.isRecording then
    -- 開始錄音
    startRecording()
  else
    -- 停止錄音並轉文字
    local duration, recordingFile = stopRecording()

    if duration < 0.5 then
      hs.alert.show("錄音時間太短", 1.5)
      if recordingFile then
        os.remove(recordingFile)
      end
      state.currentRecordingFile = nil
      return
    end

    hs.alert.show(string.format("錄了 %s，轉譯中...", formatDuration(duration)), 1.5)

    transcribe(recordingFile, function(text, err)
      if text then
        addToHistory(text, recordingFile)
        pasteText(text)
        hs.alert.show("✅ 完成！", 1)
      else
        hs.alert.show("轉譯失敗: " .. (err or "未知錯誤"), 3)
      end
      state.currentRecordingFile = nil
    end)
  end
end

-- ========================================
-- 快捷鍵綁定
-- ========================================

-- F5 開始/停止錄音
hs.hotkey.bind({}, config.hotkey, toggleRecording)

-- F6 文字歷史選單
hs.hotkey.bind({}, config.historyTextKey, showTextHistory)

-- F7 檔案歷史選單
hs.hotkey.bind({}, config.historyFileKey, showFileHistory)

-- ========================================
-- 自動更新
-- ========================================

-- 比較語意化版本號（回傳 1=a>b, -1=a<b, 0=a==b）
local function compareVersions(a, b)
  local function parseVersion(v)
    local major, minor, patch = v:match("^(%d+)%.(%d+)%.(%d+)$")
    return {tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0}
  end
  local va = parseVersion(a)
  local vb = parseVersion(b)
  for i = 1, 3 do
    if va[i] > vb[i] then return 1
    elseif va[i] < vb[i] then return -1
    end
  end
  return 0
end

-- 從腳本內容提取版本號
local function extractVersion(content)
  return content:match("波特槌 v(%d+%.%d+%.%d+)")
end

-- 檢查並套用更新
local function checkForUpdate()
  if state.isRecording then
    print("[波特槌] 錄音中，跳過更新檢查")
    return
  end

  print("[波特槌] 正在檢查更新...")

  hs.http.asyncGet(config.autoUpdate.githubRawUrl, nil, function(status, body, headers)
    if status ~= 200 or not body then
      print("[波特槌] 更新檢查失敗 (HTTP " .. tostring(status) .. ")")
      return
    end

    local remoteVersion = extractVersion(body)
    if not remoteVersion then
      print("[波特槌] 無法解析遠端版本號")
      return
    end

    print("[波特槌] 本地: v" .. VERSION .. " | 遠端: v" .. remoteVersion)

    if compareVersions(remoteVersion, VERSION) <= 0 then
      print("[波特槌] 已是最新版本")
      return
    end

    -- 有新版本，備份現有檔案
    print("[波特槌] 發現新版本 v" .. remoteVersion .. "，正在更新...")
    local backupPath = SCRIPT_PATH .. ".bak"
    local currentFile = io.open(SCRIPT_PATH, "r")
    if currentFile then
      local currentContent = currentFile:read("*a")
      currentFile:close()
      local backupFile = io.open(backupPath, "w")
      if backupFile then
        backupFile:write(currentContent)
        backupFile:close()
      end
    end

    -- 寫入新版本
    local newFile = io.open(SCRIPT_PATH, "w")
    if newFile then
      newFile:write(body)
      newFile:close()

      hs.alert.show("🔨 波特槌已更新 v" .. VERSION .. " → v" .. remoteVersion .. "\n自動重新載入中...", 3)
      print("[波特槌] 更新成功：v" .. VERSION .. " → v" .. remoteVersion)

      -- 延遲重新載入（讓使用者看到通知）
      hs.timer.doAfter(2, function()
        hs.reload()
      end)
    else
      print("[波特槌] 更新寫入失敗")
      hs.alert.show("⚠️ 波特槌更新寫入失敗", 3)
    end
  end)
end

-- 啟動自動更新計時器
local autoUpdateTimer = nil

local function startAutoUpdate()
  if not config.autoUpdate.enabled then
    print("[波特槌] 自動更新已停用")
    return
  end

  -- 啟動後延遲檢查
  hs.timer.doAfter(config.autoUpdate.startupDelay, checkForUpdate)

  -- 定期檢查
  autoUpdateTimer = hs.timer.doEvery(config.autoUpdate.checkInterval, checkForUpdate)
end

-- ========================================
-- 初始化
-- ========================================

hs.alert.show("🔨 波特槌 v" .. VERSION .. " 已啟動\n🎤 F5 語音輸入 | F6 文字歷史 | F7 檔案歷史", 3)

-- 檢查依賴
local function checkDependencies()
  local issues = {}
  local warnings = {}

  if not getNchcApiKey() then
    table.insert(issues, "NCHC_GENAI_API_KEY 未設定")
  end

  if not getGeminiApiKey() then
    table.insert(warnings, "GEMINI_API_KEY 未設定（備案不可用）")
  end

  local ffmpegPath = getFFmpegPath()
  if ffmpegPath == "ffmpeg" then
    table.insert(issues, "ffmpeg 未安裝 (brew install ffmpeg)")
  end

  if not hs.fs.attributes("/opt/homebrew/bin/jq") and not hs.fs.attributes("/usr/local/bin/jq") and not hs.fs.attributes("/usr/bin/jq") then
    table.insert(issues, "jq 未安裝 (brew install jq)")
  end

  if #issues > 0 then
    hs.timer.doAfter(2.5, function()
      hs.alert.show("❌ 缺少依賴：\n" .. table.concat(issues, "\n"), 5)
    end)
  elseif #warnings > 0 then
    hs.timer.doAfter(2.5, function()
      hs.alert.show("⚠️ 警告：\n" .. table.concat(warnings, "\n"), 3)
    end)
  end
end

checkDependencies()

-- 啟動自動更新
startAutoUpdate()

print("[🔨 波特槌 v" .. VERSION .. "] 模組已載入（Gemini 主要，NCHC 備案｜F6 文字歷史｜F7 檔案歷史｜自動更新）")
