--[[
  🔨 波特槌 v1.6.6 - Mac 語音轉文字

  由 Gemini API 驅動的語音輸入助手

  功能：
  - F5 開始/停止錄音
  - 自動呼叫 Gemini API 轉錄
  - 轉錄文字貼到游標位置
  - 再按 F5 停止錄音
  - 轉錄中按 ESC 或 F5 可取消轉錄（錄音檔保留）
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
]]--

-- 版本號（所有版本顯示共用此常數）
local VERSION = "1.6.6"

-- 目前腳本檔案路徑（用於自動更新）
local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$")
  or (os.getenv("HOME") .. "/.hammerspoon/botrun-hammer.lua")

-- ========================================
-- 設定
-- ========================================

local config = {
  language = "zh",

  -- Gemini API
  geminiApiUrl = "https://generativelanguage.googleapis.com/v1beta",
  geminiModel = "gemini-3-flash-preview",
  geminiUploadUrl = "https://generativelanguage.googleapis.com/upload/v1beta/files",

  -- 錄音設定
  -- v1.6.6: 改用 Application Support 避開 iCloud Drive Documents 同步干擾（否則長錄音可能被搬離本地）
  recordingDir = os.getenv("HOME") .. "/Library/Application Support/botrun-hammer/recordings",
  legacyRecordingDir = os.getenv("HOME") .. "/Documents/botrun-hammer-recordings",  -- 舊路徑（用於 migration）
  sampleRate = 16000,
  channels = 1,
  audioBitrate = "64k",  -- AAC 位元率
  fragDurationUs = 1000000,  -- fMP4 fragment 長度（微秒）；1 秒一顆 moof，斷電最多只遺失 1 秒

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
  historyFile = os.getenv("HOME") .. "/Library/Application Support/botrun-hammer/recordings/history.json",
  maxHistory = 30,

  -- 自動更新
  autoUpdate = {
    enabled = true,
    githubRawUrl = "https://raw.githubusercontent.com/botrun/botrun-hammer/main/hammerspoon/botrun-hammer.lua",
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
  currentStderrLog = nil,      -- 目前錄音的 ffmpeg stderr 日誌檔
  transcribeTimer = nil,       -- 轉錄動畫 timer
  transcribeEmojiIndex = 1,    -- 目前 emoji 索引
  isTranscribing = false,      -- 是否正在轉錄
  transcribeTask = nil,        -- 轉錄 hs.task（可中斷）
  transcribeFile = nil,        -- 正在轉錄的檔案路徑
  cancelHotkey = nil,          -- ESC 取消熱鍵（轉錄時綁定）
  caffeinateDisplay = false,   -- 錄音期間防顯示器睡眠旗標
  caffeinateSystem = false,    -- 錄音期間防系統睡眠旗標
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
    os.getenv("HOME") .. "/.botrun-hammer/.env",
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

-- Shell 安全引號（單引號包裹，內含單引號做轉義）
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 確保錄音資料夾存在（mkdir -p 支援多層）
local function ensureRecordingDir()
  local dir = config.recordingDir
  if not hs.fs.attributes(dir) then
    hs.execute("mkdir -p " .. shellQuote(dir))
  end
  return dir
end

-- 一次性遷移：把舊 Documents/botrun-hammer-recordings 搬到新的 Application Support 路徑
-- 原因：Documents 會被 iCloud Drive 同步吃掉，長錄音可能被搬離本地造成檔案「消失」
local function migrateLegacyRecordings()
  local legacy = config.legacyRecordingDir
  if not legacy or not hs.fs.attributes(legacy) then
    return
  end
  ensureRecordingDir()
  -- 把舊資料夾內所有檔案搬到新資料夾（含 .m4a 與 history.json）
  local cmd = string.format(
    "mv -n %s/* %s/ 2>/dev/null; rmdir %s 2>/dev/null",
    shellQuote(legacy), shellQuote(config.recordingDir), shellQuote(legacy)
  )
  hs.execute(cmd)
  print("[波特槌] 已將舊錄音從 Documents 遷移至 Application Support")
end

-- 產生時間戳檔名
local function generateRecordingFilename()
  local timestamp = os.date("%Y-%m-%d_%H-%M-%S")
  return config.recordingDir .. "/" .. timestamp .. ".m4a"
end

-- 讀取日誌末段（用於錯誤回報）
local function readLogTail(path, maxBytes)
  if not path then return "(無日誌路徑)" end
  local f = io.open(path, "r")
  if not f then return "(日誌讀取失敗: " .. path .. ")" end
  local content = f:read("*a") or ""
  f:close()
  if content == "" then return "(日誌為空)" end
  maxBytes = maxBytes or 800
  if #content > maxBytes then
    content = "...\n" .. content:sub(-maxBytes)
  end
  return content
end

-- 持久顯示錯誤通知（不會閃一下就消失）
local function showPersistentError(title, body)
  -- 長時間 alert
  hs.alert.show(title .. "\n" .. body, 15)
  -- 永久通知（需要使用者手動點擊才消失）
  hs.notify.new({
    title = title,
    informativeText = body,
    withdrawAfter = 0,
    hasActionButton = true,
    actionButtonTitle = "知道了",
    soundName = hs.notify.defaultNotificationSound,
  }):send()
  -- 同時印到 Hammerspoon console，F1 或 hs.console 可回查
  print("[波特槌][ERROR] " .. title .. " | " .. body)
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
-- status: "transcribing" | "done" | "failed" | "cancelled"（向下相容：無 status 視為 done）
local function addToHistory(text, filePath, status)
  local history = loadHistory()
  local entry = {
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    text = text,
    filePath = filePath,
    status = status or "done",
  }
  table.insert(history, 1, entry)
  while #history > config.maxHistory do
    table.remove(history)
  end
  saveHistory(history)
end

-- 根據檔案路徑更新歷史紀錄（轉錄完成後回寫文字與狀態）
local function updateHistoryEntry(filePath, text, status)
  local history = loadHistory()
  for _, entry in ipairs(history) do
    if entry.filePath == filePath then
      entry.text = text
      entry.status = status
      saveHistory(history)
      return true
    end
  end
  return false
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
--
-- v1.6.6 長錄音穩定性改造（目標：支援 5 小時不遺失）
-- 根本原因修正：
--   (1) hs.task 預設以 pipe 捕獲 stdout/stderr，macOS pipe buffer 僅 ~64KB。
--       ffmpeg 每秒一行進度輸出，~10 分鐘後 pipe 塞滿、ffmpeg 阻塞在 write()，
--       錄音完全停擺 → 這就是「閃一下就不見」的主凶。
--       對策：用 bash 包裝，-loglevel warning 降量，stderr 導向「日誌檔」(不是 /dev/null，
--       便於事後回報錯誤)，stdin 從 /dev/null 讀，徹底與 hs.task 的 pipe 脫鉤。
--   (2) MP4/M4A 需要 moov atom 才能播放，SIGTERM 若沒 flush 會留下廢檔。
--       對策：-movflags +frag_keyframe+empty_moov+default_base_moof + -frag_duration 1s，
--       每秒寫一顆 moof fragment；moov atom 一開始就寫在檔頭，檔案隨時 kill 都可播，
--       最多只會遺失最後 1 秒。
--   (3) Documents 會被 iCloud Drive 同步，長錄音可能被搬離本地。
--       對策：config.recordingDir 改到 ~/Library/Application Support/botrun-hammer/recordings。
--   (4) 系統睡眠會斷錄音。對策：hs.caffeinate.set 禁止 system/display idle。
--   (5) 沒 -nostdin ffmpeg 會讀 stdin 可能意外退出。對策：加 -nostdin 並 < /dev/null。
local function startRecording()
  local ffmpegPath = getFFmpegPath()

  -- 檢查 ffmpeg 是否存在
  if not hs.fs.attributes(ffmpegPath) and ffmpegPath ~= "ffmpeg" then
    showPersistentError("❌ 需要 ffmpeg 才能錄音", "請執行: brew install ffmpeg")
    return false
  end

  -- 確保錄音資料夾存在
  ensureRecordingDir()

  -- 產生錄音檔名與日誌檔名
  state.currentRecordingFile = generateRecordingFilename()
  state.currentStderrLog = state.currentRecordingFile:gsub("%.m4a$", ".log")
  state.isRecording = true
  state.startTime = hs.timer.secondsSinceEpoch()

  -- 偵測最佳麥克風
  local micIndex = getBestMicIndex()

  -- 組 bash 命令：exec ffmpeg 讓 PID 替換，SIGTERM 直達 ffmpeg；
  -- stdin 從 /dev/null 讀避免任何誤觸；stderr 導向 per-recording log 檔避免 pipe 塞爆
  local ffmpegCmd = string.format(
    "exec %s -nostdin -hide_banner -loglevel warning -y "
    .. "-f avfoundation -i %s "
    .. "-acodec aac -b:a %s -ar %d -ac %d "
    .. "-movflags +frag_keyframe+empty_moov+default_base_moof "
    .. "-frag_duration %d "
    .. "%s < /dev/null 2> %s",
    shellQuote(ffmpegPath),
    shellQuote(micIndex),
    config.audioBitrate,
    config.sampleRate,
    config.channels,
    config.fragDurationUs,
    shellQuote(state.currentRecordingFile),
    shellQuote(state.currentStderrLog)
  )

  print("[波特槌] 錄音命令: " .. ffmpegCmd)

  -- exit callback：偵測「非預期退出」（state.isRecording 還是 true 表示使用者沒按停止）
  local recordingFileAtStart = state.currentRecordingFile
  local stderrLogAtStart = state.currentStderrLog
  local exitCb = function(exitCode, stdout, stderr)
    -- 正常停止會先把 state.isRecording 設成 false，才 terminate，所以這裡只處理非預期
    if state.isRecording and state.currentRecordingFile == recordingFileAtStart then
      state.isRecording = false
      state.recordingTask = nil
      -- 釋放 caffeinate
      if state.caffeinateSystem then hs.caffeinate.set("systemIdle", false, true); state.caffeinateSystem = false end
      if state.caffeinateDisplay then hs.caffeinate.set("displayIdle", false, true); state.caffeinateDisplay = false end
      -- 讀日誌末段給使用者看
      local tail = readLogTail(stderrLogAtStart, 800)
      local fileAttrs = hs.fs.attributes(recordingFileAtStart)
      local fileSize = fileAttrs and fileAttrs.size or 0
      local body = string.format(
        "ffmpeg 非預期退出 exit=%s\n檔案: %s\n大小: %d bytes\n\n日誌末段:\n%s",
        tostring(exitCode or -1),
        recordingFileAtStart,
        fileSize,
        tail
      )
      showPersistentError("❌ 錄音中斷！", body)
      -- 寫入歷史讓 F7 找得到壞檔（fragmented MP4 通常仍可播放）
      addToHistory(nil, recordingFileAtStart, "failed")
    end
  end

  state.recordingTask = hs.task.new("/bin/bash", exitCb, {"-c", ffmpegCmd})

  local success = state.recordingTask:start()

  if success then
    -- 防止系統/顯示器睡眠（5 小時長錄音必備）
    hs.caffeinate.set("systemIdle", true, true)
    hs.caffeinate.set("displayIdle", true, true)
    state.caffeinateSystem = true
    state.caffeinateDisplay = true
    hs.alert.show("🎙️ 波特槌 v" .. VERSION .. " 正在傾聽\n(再按 F5 停止)", 2)
    return true
  else
    showPersistentError("❌ 啟動錄音失敗", "hs.task:start() 回傳 false，請檢查 Hammerspoon console")
    state.isRecording = false
    state.currentRecordingFile = nil
    state.currentStderrLog = nil
    return false
  end
end

-- 停止錄音
local function stopRecording()
  -- 先清旗標，避免 exit callback 誤判為「非預期退出」
  state.isRecording = false

  if state.recordingTask then
    state.recordingTask:terminate()
    state.recordingTask = nil
  end

  -- 釋放 caffeinate
  if state.caffeinateSystem then
    hs.caffeinate.set("systemIdle", false, true)
    state.caffeinateSystem = false
  end
  if state.caffeinateDisplay then
    hs.caffeinate.set("displayIdle", false, true)
    state.caffeinateDisplay = false
  end

  local duration = 0
  if state.startTime then
    duration = hs.timer.secondsSinceEpoch() - state.startTime
  end

  state.startTime = nil

  local recordingFile = state.currentRecordingFile
  local stderrLog = state.currentStderrLog

  -- 驗證檔案是否真的寫出且非空
  if recordingFile then
    local attrs = hs.fs.attributes(recordingFile)
    if not attrs or attrs.size == 0 then
      local tail = readLogTail(stderrLog, 800)
      showPersistentError(
        "❌ 錄音檔遺失或為 0 bytes",
        string.format("檔案: %s\n\n日誌末段:\n%s", recordingFile, tail)
      )
    else
      print(string.format("[波特槌] 錄音檔大小: %d bytes, 時長: %.1f 秒", attrs.size, duration))
    end
  end

  return duration, recordingFile
end

-- ========================================
-- API 呼叫
-- ========================================


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

  local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
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
  state.transcribeTask = task
  task:start()
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

-- 解除 ESC 取消熱鍵
local function unbindCancelHotkey()
  if state.cancelHotkey then
    state.cancelHotkey:delete()
    state.cancelHotkey = nil
  end
end

-- 取消轉錄
local function cancelTranscription()
  if not state.isTranscribing then return end

  print("[波特槌] 使用者取消轉錄")

  -- 終止轉錄任務
  if state.transcribeTask then
    state.transcribeTask:terminate()
    state.transcribeTask = nil
  end

  -- 停止動畫
  stopTranscribeAnimation()

  -- 更新歷史紀錄為 cancelled（錄音檔保留）
  if state.transcribeFile then
    updateHistoryEntry(state.transcribeFile, nil, "cancelled")
    local filename = state.transcribeFile:match("([^/]+)$")
    hs.alert.show("🚫 已取消轉錄\n錄音已保留: " .. filename, 2.5)
  else
    hs.alert.show("🚫 已取消轉錄", 2)
  end

  -- 清除狀態
  state.isTranscribing = false
  state.transcribeFile = nil
  state.currentRecordingFile = nil
  unbindCancelHotkey()
end

-- 綁定 ESC 為轉錄取消鍵（僅轉錄中有效）
local function bindCancelHotkey()
  unbindCancelHotkey()  -- 確保不重複綁定
  state.cancelHotkey = hs.hotkey.bind({}, "escape", cancelTranscription)
end

-- 主要轉錄函數（Gemini API）
local function transcribe(recordingFile, callback)
  -- 檢查檔案是否存在
  if not recordingFile or not hs.fs.attributes(recordingFile) then
    hs.alert.show("找不到錄音檔", 2)
    callback(nil, "找不到錄音檔案")
    return
  end

  -- 設定轉錄狀態
  state.isTranscribing = true
  state.transcribeFile = recordingFile
  bindCancelHotkey()

  -- 啟動轉錄動畫
  startTranscribeAnimation()

  -- 轉錄結束清理（成功/失敗都需要）
  local function finishTranscription()
    state.isTranscribing = false
    state.transcribeFile = nil
    state.transcribeTask = nil
    unbindCancelHotkey()
  end

  local function onGeminiResult(text, err, isRetry)
    -- 已被取消，忽略回調
    if not state.isTranscribing then return end

    if text then
      stopTranscribeAnimation()
      finishTranscription()
      if not config.keepSuccessfulRecordings then
        os.remove(recordingFile)
      end
      convertToTraditional(text, function(traditionalText)
        callback(traditionalText, nil)
      end)
    elseif not isRetry then
      -- 第一次失敗，retry 一次
      print("[波特槌] Gemini 第一次失敗: " .. (err or "未知錯誤") .. "，重試一次...")
      hs.alert.show("⚠️ Gemini 暫時故障，重試中...", 1.5)
      hs.timer.doAfter(1, function()
        if not state.isTranscribing then return end  -- 已取消則不重試
        transcribeWithGemini(recordingFile, function(retryText, retryErr)
          onGeminiResult(retryText, retryErr, true)
        end)
      end)
    else
      -- 重試也失敗
      stopTranscribeAnimation()
      finishTranscription()
      hs.alert.show("❌ 轉錄失敗\n錄音已保留: " .. recordingFile:match("([^/]+)$"), 3)
      callback(nil, "Gemini 轉錄失敗（含重試）")
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
      local statusIcon = (entry.status == "failed" and "⚠️")
        or (entry.status == "cancelled" and "🚫")
        or (entry.status == "transcribing" and "⏳")
        or (hs.fs.attributes(entry.filePath) and "✅" or "❌")
      local preview = truncateText(entry.text, 50)
      table.insert(choices, {
        text = statusIcon .. " " .. filename,
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
  if state.isTranscribing then
    -- 轉錄中按 F5 = 取消轉錄
    cancelTranscription()
    return
  end

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

    -- 離線優先：先存歷史紀錄，確保錄音檔不會遺失
    addToHistory(nil, recordingFile, "transcribing")

    transcribe(recordingFile, function(text, err)
      if text then
        updateHistoryEntry(recordingFile, text, "done")
        pasteText(text)
        hs.alert.show("✅ 完成！", 1)
      else
        updateHistoryEntry(recordingFile, nil, "failed")
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

-- 一次性遷移：Documents → Application Support（避開 iCloud 同步）
migrateLegacyRecordings()
-- 確保新資料夾存在
ensureRecordingDir()

hs.alert.show("🔨 波特槌 v" .. VERSION .. " 已啟動\n🎤 F5 語音輸入 | F6 文字歷史 | F7 檔案歷史\n⎋ ESC 取消轉錄", 3)

-- 檢查 Accessibility 權限
local function checkAccessibility()
  if not hs.accessibilityState() then
    hs.timer.doAfter(1, function()
      hs.alert.show("⚠️ 波特槌需要「輔助使用」權限\n請在系統設定中開啟 Hammerspoon 的權限", 5)
      hs.timer.doAfter(2, function()
        hs.execute("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
      end)
    end)
    return false
  end
  return true
end

checkAccessibility()

-- 檢查依賴
local function checkDependencies()
  local issues = {}
  local warnings = {}

  if not getGeminiApiKey() then
    table.insert(issues, "GEMINI_API_KEY 未設定，請編輯 ~/.botrun-hammer/.env")
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

print("[🔨 波特槌 v" .. VERSION .. "] 模組已載入（Gemini API｜F6 文字歷史｜F7 檔案歷史｜自動更新）")
