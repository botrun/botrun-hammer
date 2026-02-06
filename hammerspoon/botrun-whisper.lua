--[[
  🔨 波特槌 v1.2.14 - Mac 語音轉文字

  由 NCHC Whisper API 驅動的語音輸入助手
  備案：Gemini API（NCHC 故障時自動切換）

  功能：
  - F5 開始/停止錄音
  - 自動呼叫 NCHC Whisper API
  - NCHC 失敗時自動切換 Gemini API
  - 轉錄文字貼到游標位置
  - ESC 取消錄音

  安裝：
  - ./install.sh

  需求：
  - Hammerspoon
  - ffmpeg (brew install ffmpeg)
  - jq (brew install jq)
  - NCHC_GENAI_API_KEY 環境變數
  - GEMINI_API_KEY 環境變數（備案用）
]]--

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
  cancelKey = "escape",
}

-- ========================================
-- 狀態
-- ========================================

local state = {
  isRecording = false,
  recordingTask = nil,
  startTime = nil,
  currentRecordingFile = nil,  -- 目前錄音檔案路徑
}

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

  -- 啟動 ffmpeg 錄音（即時壓縮 M4A/AAC）
  state.recordingTask = hs.task.new(ffmpegPath, nil, {
    "-y",                                    -- 覆寫既有檔案
    "-f", "avfoundation",                    -- macOS 音訊輸入
    "-i", ":0",                              -- 預設麥克風
    "-acodec", "aac",                        -- AAC 編碼
    "-b:a", config.audioBitrate,             -- 位元率
    "-ar", tostring(config.sampleRate),      -- 取樣率
    "-ac", tostring(config.channels),        -- 聲道數
    state.currentRecordingFile               -- 輸出檔案
  })

  local success = state.recordingTask:start()

  if success then
    hs.alert.show("🎙️ 波特槌 v1.2.14 正在傾聽\n(F5 停止，ESC 取消)", 2)
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

-- 取消錄音
local function cancelRecording()
  local _, recordingFile = stopRecording()

  -- 刪除錄音檔
  if recordingFile then
    os.remove(recordingFile)
  end
  state.currentRecordingFile = nil

  hs.alert.show("❌ 已取消錄音", 1.5)
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
          "thinkingConfig": {
            "thinkingBudget": 0
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

-- 主要轉錄函數（自動 Failover：Gemini 優先，NCHC 備用）
local function transcribe(recordingFile, callback)
  -- 檢查檔案是否存在
  if not recordingFile or not hs.fs.attributes(recordingFile) then
    hs.alert.show("找不到錄音檔", 2)
    callback(nil, "找不到錄音檔案")
    return
  end

  hs.alert.show("✨ Gemini 轉錄中...", 1)

  -- 先嘗試 Gemini API
  transcribeWithGemini(recordingFile, function(text, err)
    if text then
      -- Gemini 成功
      if not config.keepSuccessfulRecordings then
        os.remove(recordingFile)
      end
      convertToTraditional(text, function(traditionalText)
        callback(traditionalText, nil)
      end)
    else
      -- Gemini 失敗，嘗試 NCHC 備案
      print("[波特槌] Gemini 失敗: " .. (err or "未知錯誤") .. "，切換到 NCHC")
      hs.alert.show("⚠️ Gemini 故障，切換 NCHC...", 1.5)

      transcribeWithNCHC(recordingFile, function(nchcText, nchcErr)
        if nchcText then
          -- NCHC 成功
          if not config.keepSuccessfulRecordings then
            os.remove(recordingFile)
          end
          convertToTraditional(nchcText, function(traditionalText)
            callback(traditionalText, nil)
          end)
        else
          -- 兩個都失敗
          hs.alert.show("❌ 轉錄失敗\n錄音已保留: " .. recordingFile:match("([^/]+)$"), 3)
          callback(nil, "Gemini 和 NCHC 都失敗")
        end
      end)
    end
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

-- ESC 取消錄音（僅在錄音中有效）
hs.hotkey.bind({}, config.cancelKey, function()
  if state.isRecording then
    cancelRecording()
  else
    -- 不攔截 ESC，讓系統處理
    return false
  end
end)

-- ========================================
-- 初始化
-- ========================================

hs.alert.show("🔨 波特槌 v1.2.14 已啟動\n🎤 按 F5 開始語音輸入", 2)

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

print("[🔨 波特槌 v1.2.14] 模組已載入（含 Gemini 備案）")
