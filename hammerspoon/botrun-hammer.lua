--[[
  🔨 波特槌 v1.10.2 - Mac 語音轉文字

  由 Vertex AI Gemini（gcloud ADC 認證）驅動的語音輸入助手

  功能：
  - F5 開始/停止錄音
  - 自動呼叫 Gemini API 轉錄
  - 轉錄文字貼到游標位置
  - 再按 F5 停止錄音
  - 轉錄中按 ESC 或 F5 可取消轉錄（錄音檔保留）
  - F6 統一選單：引擎切換 + 文字歷史 + 錄音檔案（v1.7.15 起合併原 F6/F7/F8）
  - 自動更新：啟動時及每 4 小時檢查 GitHub 最新版本

  安裝：
  - ./install.sh

  需求：
  - Hammerspoon
  - ffmpeg (brew install ffmpeg)
  - jq (brew install jq)
  - gcloud CLI + ADC 登入（gcloud auth application-default login）
    ※ v1.10.0 起永久移除 GEMINI_API_KEY，雲端轉錄一律走 ADC
]]--

-- 版本號（所有版本顯示共用此常數）
local VERSION = "1.10.2"

-- 開機自動啟動 Hammerspoon（v1.7.11）
pcall(function() hs.autoLaunch(true) end)

-- 目前腳本檔案路徑（用於自動更新）
local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$")
  or (os.getenv("HOME") .. "/.hammerspoon/botrun-hammer.lua")

-- ========================================
-- 設定
-- ========================================

local config = {
  language = "zh",

  -- Vertex AI（v1.10.0：全面改用 gcloud ADC，永久移除 API key）
  -- 公司已停用 Gemini API key（曾遭盜用），雲端轉錄一律走 Application Default Credentials
  geminiModel = "gemini-3.5-flash",
  vertex = {
    host = "https://aiplatform.googleapis.com",
    -- ⚠️ location 只有 global / us / asia-southeast1 有這顆模型，其餘回 404
    location = "global",
    -- 預設專案（可用 .env 的 VERTEX_PROJECT 覆寫）；需有 roles/aiplatform.user
    -- v1.10.1：全面改用專屬 GCP 專案 botrun-hammer
    -- https://console.cloud.google.com/welcome?project=botrun-hammer
    defaultProject = "botrun-hammer",
    -- inline base64 請求上限約 20MB，留安全邊際
    maxUploadBytes = 15 * 1024 * 1024,
    -- access token 快取秒數（實際有效期 1 小時，提早換發）
    tokenTtl = 50 * 60,
    gcloudPaths = {
      "/opt/homebrew/bin/gcloud",
      "/usr/local/bin/gcloud",
      "/usr/bin/gcloud",
      os.getenv("HOME") .. "/google-cloud-sdk/bin/gcloud",
    },
  },

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
  historyTextKey = "F6",  -- v1.7.15: 統一選單入口（合併原 F6/F7/F8）

  -- 歷史紀錄
  historyFile = os.getenv("HOME") .. "/Library/Application Support/botrun-hammer/recordings/history.json",
  maxHistory = 30,

  -- v1.7.0: 本機 STT 引擎（mlx-whisper daemon）
  lwm = {
    ctlScript = os.getenv("HOME") .. "/.botrun-hammer/scripts/lwm_daemon_ctl.sh",
    portFile  = os.getenv("HOME") .. "/.botrun-hammer/lwm.port",
    tokenFile = os.getenv("HOME") .. "/.botrun-hammer/lwm.token",
    -- v1.8.1: 預設改為 large-v3（精準模式，full 32 層 decoder）；turbo 列為次選
    -- 理由：差距 ~0.2% WER 雖小，但對繁中專有名詞/口齒不清/吵雜環境，full v3 較穩
    defaultModel = "large-v3",
    -- v1.7.6: mlx 0.31.2 的 4bit 路徑壞掉
    -- (QuantizedLinear.quantize_module 不存在)，預設 none 直到上游修復
    defaultQuant = "none",
    -- v1.9.0: 多引擎並陳：精準 / 快速 / Gemma 4 實驗
    menuModels = {
      { key = "large-v3",        label = "💻 本機 large-v3 (繁中・精準)" },
      { key = "large-v3-turbo",  label = "💻 本機 large-v3-turbo (繁中・快速)" },
      { key = "gemma-4-e4b",     label = "🧪 本機 Gemma-4-E4B (實驗・≤30s)" },
    },
    -- 健康檢查 / 自動重啟參數
    healthCheckInterval = 60,    -- 秒，每 N 秒打 /health
    healthCheckTimeout = 4,      -- 秒，N 秒沒回視為卡死
    autoRestartEnabled = true,
  },

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
  heartbeatTimer = nil,        -- 錄音期間每 30 秒心跳 logger（v1.6.7+）
  heartbeatTickCount = 0,      -- 心跳次數（用於指數測試比對）
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

-- ========================================
-- gcloud ADC（v1.10.0：雲端轉錄唯一認證方式，API key 已永久移除）
-- ========================================

-- 找 gcloud 執行檔（hs.task 的 PATH 不含 Homebrew，必須用絕對路徑）
local function getGcloudPath()
  for _, p in ipairs(config.vertex.gcloudPaths) do
    if hs.fs.attributes(p) then return p end
  end
  return nil
end

-- Vertex 專案（.env 的 VERTEX_PROJECT 優先，否則用預設）
local function getVertexProject()
  local p = getEnvKey("VERTEX_PROJECT")
  -- v1.10.1 migrate：botrun-chat 是 v1.10.0 的暫用預設，一律改指本案專屬專案
  -- （自動更新只換 lua 不重跑 install.sh，所以這裡也要接住）
  if p == "botrun-chat" then p = nil end
  if p and p ~= "" then return p end
  return config.vertex.defaultProject
end

local function getVertexLocation()
  local l = getEnvKey("VERTEX_LOCATION")
  if l and l ~= "" then return l end
  return config.vertex.location
end

-- ADC 狀態檢查（同步、輕量：只看憑證檔存在與否，不打網路）
local function adcCredentialsExist()
  local p = os.getenv("HOME") .. "/.config/gcloud/application_default_credentials.json"
  return hs.fs.attributes(p) ~= nil
end

-- 引導使用者登入 ADC：指令複製進剪貼簿 + 開 Terminal，讓使用者直接貼上執行
local function guideAdcLogin(reasonText)
  local cmd = "gcloud auth application-default login"
  hs.pasteboard.setContents(cmd)
  hs.alert.show(
    "🔑 " .. (reasonText or "需要 Google Cloud 授權") ..
    "\n\n已複製指令到剪貼簿，請在終端機貼上執行：\n" .. cmd ..
    "\n\n登入後回來按 F5 即可繼續",
    8
  )
  hs.timer.doAfter(1, function()
    -- 注意：此處不能用 shellQuote（宣告在本函式之後，Lua local 尚未可見）
    hs.execute("open -a Terminal \"" .. os.getenv("HOME") .. "\"")
  end)
end

-- 引導安裝 gcloud
local function guideGcloudInstall()
  local cmd = "brew install --cask gcloud-cli"
  hs.pasteboard.setContents(cmd)
  hs.alert.show(
    "🔧 找不到 gcloud（Google Cloud SDK）" ..
    "\n\n已複製安裝指令到剪貼簿：\n" .. cmd ..
    "\n裝好後執行：gcloud auth application-default login",
    8
  )
end

-- 引導權限不足（403）：夥伴第一次使用最常見的狀況
-- 直接把「要貼給管理者的那句話」放進剪貼簿，含自己的 Google 帳號
local function guideVertexPermission(project)
  local account = ""
  local gcloudPath = getGcloudPath()
  if gcloudPath then
    local out = hs.execute("\"" .. gcloudPath .. "\" config get-value account 2>/dev/null")
    account = (out or ""):gsub("%s+$", "")
  end
  if account == "" then account = "（你的 Google 帳號）" end

  local isCameo = account:match("@cameo%.tw$") ~= nil
  if isCameo then
    hs.pasteboard.setContents("波特槌 403：" .. account .. " / 專案 " .. tostring(project))
    hs.alert.show(
      "🚫 帳號 " .. account .. " 目前無法使用「" .. tostring(project) .. "」" ..
      "\n\n@cameo.tw 應已全網域授權，請把剪貼簿內容貼給管理者",
      10
    )
  else
    hs.pasteboard.setContents("gcloud auth application-default login")
    hs.alert.show(
      "🚫 你登入的是個人帳號：" .. account ..
      "\n\n波特槌已對 @cameo.tw 全網域開放" ..
      "\n請用公司帳號重新登入（指令已複製到剪貼簿）：" ..
      "\ngcloud auth application-default login" ..
      "\n\n選帳號時請選你的 @cameo.tw 帳號，之後按 F5 即可",
      12
    )
    hs.timer.doAfter(1, function()
      hs.execute("open -a Terminal \"" .. os.getenv("HOME") .. "\"")
    end)
  end
end

-- ========================================
-- 雲端日誌（v1.6.8+）— 自動把錄音事件送到 Cloud Logging
-- ========================================
-- 設計：async fire-and-forget，永遠不阻擋錄音；失敗靜默（避免拖累體驗）
-- BOTRUN_HAMMER_LOG_URL / BOTRUN_HAMMER_LOG_TOKEN 在 install.sh 寫進 .env，使用者免設
-- 機敏邊界：只送 metadata（檔名 basename / 大小 / 時間 / pid / stderr 末段），不送錄音內容/轉錄文字

local cloudLogConfig = {
  url = nil,
  token = nil,
  hostname = nil,        -- 短 hostname（hostname -s）
  computer_name = nil,   -- 使用者設定的電腦名稱（scutil ComputerName）
  machine_id = nil,      -- 持久化機器 UUID（first-run 生成，存 ~/.botrun-hammer/machine-id）
  os_user = nil,         -- 登入帳號
  loaded = false,
}

-- 讀第一行 trim
local function shellOneLine(cmd)
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return "" end
  local s = h:read("*a") or ""
  h:close()
  return (s:gsub("[\r\n]+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function loadCloudLogConfig()
  if cloudLogConfig.loaded then return end
  cloudLogConfig.loaded = true
  cloudLogConfig.url = getEnvKey("BOTRUN_HAMMER_LOG_URL")
  cloudLogConfig.token = getEnvKey("BOTRUN_HAMMER_LOG_TOKEN")

  -- 短主機名（"Mac"、"bohachu-mbp" 之類）
  local h = shellOneLine("hostname -s")
  if h == "" then h = "unknown" end
  cloudLogConfig.hostname = h

  -- 使用者命名的電腦名稱，例如「Bowen 的 MacBook Pro」
  cloudLogConfig.computer_name = shellOneLine("scutil --get ComputerName") or ""
  if cloudLogConfig.computer_name == "" then
    cloudLogConfig.computer_name = cloudLogConfig.hostname
  end

  -- 持久化 machine_id：first-run 生成 UUID 存到 ~/.botrun-hammer/machine-id
  local idFile = os.getenv("HOME") .. "/.botrun-hammer/machine-id"
  local fid = io.open(idFile, "r")
  if fid then
    local content = fid:read("*a") or ""
    fid:close()
    cloudLogConfig.machine_id = (content:gsub("[\r\n]+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
  end
  if not cloudLogConfig.machine_id or cloudLogConfig.machine_id == "" then
    -- 生 8 位 hex（足夠去重，又不會太長）
    local newId = shellOneLine("/usr/bin/uuidgen | tr 'A-Z' 'a-z' | cut -c1-8")
    if newId == "" then newId = string.format("%08x", os.time() % 0xffffffff) end
    cloudLogConfig.machine_id = newId
    -- 確保資料夾存在
    os.execute("mkdir -p " .. os.getenv("HOME") .. "/.botrun-hammer")
    local fout = io.open(idFile, "w")
    if fout then fout:write(newId); fout:close() end
  end

  cloudLogConfig.os_user = os.getenv("USER") or "unknown"

  if cloudLogConfig.url and cloudLogConfig.token then
    print(string.format(
      "[波特槌][cloudlog] 雲端日誌啟用 host=%s computer=%s machine_id=%s user=%s",
      cloudLogConfig.hostname, cloudLogConfig.computer_name,
      cloudLogConfig.machine_id, cloudLogConfig.os_user
    ))
  else
    print("[波特槌][cloudlog] 未設定（缺 BOTRUN_HAMMER_LOG_URL 或 BOTRUN_HAMMER_LOG_TOKEN）")
  end
end

-- 把任意 lua table 轉成最小 JSON（只支援 string/number/bool/nil/table，足夠我們用）
local function jsonEncode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return tostring(v)
  end
  if t == "string" then
    local s = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    -- 控制字元清掉
    s = s:gsub("[%c]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return '"' .. s .. '"'
  end
  if t == "table" then
    -- array vs object
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    local arrN = #v
    if arrN == n and arrN > 0 then
      local parts = {}
      for i = 1, arrN do parts[#parts+1] = jsonEncode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, vv in pairs(v) do
        parts[#parts+1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(vv)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return '"' .. tostring(v) .. '"'
end

-- 送一筆事件到雲端（async，永不阻擋）
-- event 是字串如 "heartbeat" / "start" / "stop" / "exit" / "error"
-- fields 是 table，會合併進 payload
local function cloudLog(event, fields, severity)
  loadCloudLogConfig()
  if not cloudLogConfig.url or not cloudLogConfig.token then return end

  local payload = {
    event = event,
    severity = severity or "INFO",
    version = VERSION,
    hostname = cloudLogConfig.hostname,
    computer_name = cloudLogConfig.computer_name,
    machine_id = cloudLogConfig.machine_id,
    os_user = cloudLogConfig.os_user,
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if fields then
    for k, v in pairs(fields) do payload[k] = v end
  end

  local body = jsonEncode(payload)
  -- 用 hs.task 跑 curl async，stdin 餵 body 避免 cmdline 過長/特殊字元
  -- 寫入 tmpfile 比 echo|pipe 更穩
  local tmpFile = string.format("/tmp/botrun-hammer-clog-%d-%d.json",
    hs.timer.absoluteTime(), math.random(0, 999999))
  local f = io.open(tmpFile, "w")
  if not f then return end
  f:write(body)
  f:close()

  local cmd = string.format(
    "exec /usr/bin/curl -sS --max-time 5 -X POST %s "
    .. "-H 'Authorization: Bearer %s' "
    .. "-H 'Content-Type: application/json' "
    .. "--data-binary @%s -o /dev/null; rm -f %s",
    cloudLogConfig.url, cloudLogConfig.token, tmpFile, tmpFile
  )
  local task = hs.task.new("/bin/bash", function(_) end, {"-c", cmd})
  if task then task:start() end
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
  -- 雲端日誌：使用者看到的所有錯誤都送一份上去
  cloudLog("error", { title = title, body = body }, "ERROR")
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
-- 心跳 logger（v1.6.7+）：錄音期間每 30 秒寫一行到 Hammerspoon console
-- 目的：長錄音失敗時，從 console 拉時間軸；最後一個心跳 = 故障時刻
local function heartbeatTick()
  if not state.isRecording then return end
  state.heartbeatTickCount = (state.heartbeatTickCount or 0) + 1
  local elapsed = state.startTime and (hs.timer.secondsSinceEpoch() - state.startTime) or 0
  local recFile = state.currentRecordingFile
  local logFile = state.currentStderrLog
  local recAttrs = recFile and hs.fs.attributes(recFile) or nil
  local logAttrs = logFile and hs.fs.attributes(logFile) or nil
  local recSize = recAttrs and recAttrs.size or 0
  local logSize = logAttrs and logAttrs.size or 0
  -- 用 statvfs 風格抓剩餘空間（df -k 一行）
  local diskFreeKB = -1
  if recFile then
    local dir = recFile:match("(.*)/") or "/"
    local h = io.popen(string.format("df -k %q | tail -1 | awk '{print $4}'", dir))
    if h then
      local s = h:read("*a")
      h:close()
      diskFreeKB = tonumber((s or ""):match("(%d+)")) or -1
    end
  end
  local taskAlive = state.recordingTask and state.recordingTask:isRunning() or false
  local pid = state.recordingTask and state.recordingTask:pid() or -1
  print(string.format(
    "[波特槌][heartbeat] tick=%d elapsed=%.1fs file_size=%d log_size=%d disk_free_kb=%d task_running=%s pid=%s",
    state.heartbeatTickCount, elapsed, recSize, logSize, diskFreeKB,
    tostring(taskAlive), tostring(pid)
  ))
  cloudLog("heartbeat", {
    tick = state.heartbeatTickCount,
    elapsed_s = elapsed,
    file_size = recSize,
    log_size = logSize,
    disk_free_kb = diskFreeKB,
    task_running = taskAlive,
    pid = pid,
    file_basename = recFile and (recFile:match("([^/]+)$") or "") or "",
  })
  -- 第一次（30 秒）和每 10 次（5 分鐘）多附帶一行 alert，方便桌面看
  if state.heartbeatTickCount == 1 or state.heartbeatTickCount % 10 == 0 then
    print(string.format(
      "[波特槌][heartbeat] 已錄 %.1f 分鐘，檔案 %.2f MB",
      elapsed / 60, recSize / 1024 / 1024
    ))
  end
end

local function startHeartbeat()
  state.heartbeatTickCount = 0
  if state.heartbeatTimer then state.heartbeatTimer:stop() end
  state.heartbeatTimer = hs.timer.doEvery(30, heartbeatTick)
  print("[波特槌][heartbeat] timer 啟動（每 30 秒一拍）")
end

local function stopHeartbeat()
  if state.heartbeatTimer then
    state.heartbeatTimer:stop()
    state.heartbeatTimer = nil
    print(string.format("[波特槌][heartbeat] timer 停止，總共 %d 拍", state.heartbeatTickCount or 0))
  end
end

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
      stopHeartbeat()
      print(string.format("[波特槌][exit] ffmpeg 非預期退出 exit=%s file=%s", tostring(exitCode or -1), recordingFileAtStart))
      local _tail = readLogTail(stderrLogAtStart, 800)
      local _attrs = hs.fs.attributes(recordingFileAtStart)
      cloudLog("exit_unexpected", {
        exit_code = tostring(exitCode or -1),
        file_basename = recordingFileAtStart:match("([^/]+)$") or "",
        file_size = _attrs and _attrs.size or 0,
        stderr_tail = _tail,
      }, "ERROR")
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
    startHeartbeat()
    print(string.format(
      "[波特槌][start] file=%s log=%s pid=%s",
      tostring(state.currentRecordingFile), tostring(state.currentStderrLog),
      tostring(state.recordingTask and state.recordingTask:pid() or -1)
    ))
    cloudLog("start", {
      file_basename = state.currentRecordingFile and (state.currentRecordingFile:match("([^/]+)$") or "") or "",
      pid = state.recordingTask and state.recordingTask:pid() or -1,
    })
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
  stopHeartbeat()
  local _stopElapsed = state.startTime and (hs.timer.secondsSinceEpoch() - state.startTime) or 0
  print(string.format("[波特槌][stop] 使用者停止錄音 elapsed=%.1fs file=%s",
    _stopElapsed, tostring(state.currentRecordingFile)))
  cloudLog("stop", {
    elapsed_s = _stopElapsed,
    file_basename = state.currentRecordingFile and (state.currentRecordingFile:match("([^/]+)$") or "") or "",
    tick_count = state.heartbeatTickCount or 0,
  })

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
      -- recording_finalized 延遲 3 秒發，給 ffmpeg 真正 flush + moov 寫完的時間
      -- 否則 attrs.size 只會看到 moov header（28 bytes 之類）誤報
      local _capturedFile = recordingFile
      local _capturedDuration = duration
      hs.timer.doAfter(3, function()
        local finalAttrs = hs.fs.attributes(_capturedFile)
        cloudLog("recording_finalized", {
          file_basename = _capturedFile:match("([^/]+)$") or "",
          file_size = finalAttrs and finalAttrs.size or 0,
          duration_s = _capturedDuration,
        })
      end)
    end
  end

  return duration, recordingFile
end

-- ========================================
-- API 呼叫
-- ========================================


-- 呼叫 Gemini API（備案）
-- 呼叫 Vertex AI Gemini 轉錄（v1.10.0：gcloud ADC，無 API key）
-- 流程：ADC token → ffmpeg 轉 opus（壓縮至 inline 可承載）→ base64 inline → generateContent
-- shell exit code 契約（給 Lua 端做「清晰引導」）：
--   90 = ADC 未登入 / token 取不到；91 = 音檔過大；92 = 403 權限不足
--   93 = ffmpeg 轉檔失敗；94 = 其他 HTTP 錯誤
local function transcribeWithGemini(recordingFile, callback)
  local gcloudPath = getGcloudPath()
  local basename = recordingFile and (recordingFile:match("([^/]+)$") or "") or ""

  if not gcloudPath then
    cloudLog("transcribe_failed", { file_basename = basename, reason = "gcloud_missing" }, "ERROR")
    guideGcloudInstall()
    callback(nil, "gcloud 未安裝")
    return
  end

  if not adcCredentialsExist() then
    cloudLog("transcribe_failed", { file_basename = basename, reason = "adc_not_logged_in" }, "ERROR")
    guideAdcLogin("尚未登入 Google Cloud ADC")
    callback(nil, "ADC 未登入")
    return
  end

  local project = getVertexProject()
  local location = getVertexLocation()
  local jqPath = getJqPath()
  local ffmpegPath = getFFmpegPath()
  local _attrs = hs.fs.attributes(recordingFile)
  local _fileSize = _attrs and _attrs.size or 0
  local _txStartEpoch = hs.timer.secondsSinceEpoch()
  cloudLog("transcribe_request_start", {
    file_basename = basename,
    file_size = _fileSize,
    model = config.geminiModel,
    auth = "adc",
    vertex_project = project,
    vertex_location = location,
  })

  local vertexCmd = string.format([[
    set -uo pipefail
    GCLOUD=%s
    FFMPEG=%s
    JQ=%s
    AUDIO=%s
    PROJECT=%s
    LOCATION=%s
    MODEL=%s
    HOST=%s
    MAXB=%d

    TOKEN=$("$GCLOUD" auth application-default print-access-token 2>/tmp/botrun-adc-err.txt)
    if [ -z "$TOKEN" ]; then
      cat /tmp/botrun-adc-err.txt >&2
      exit 90
    fi

    TMPDIR_BRH=$(mktemp -d -t botrun-vertex)
    trap 'rm -rf "$TMPDIR_BRH"' EXIT
    OPUS="$TMPDIR_BRH/audio.opus"

    # 壓成 16k 單聲道 opus 24kbps（約 3KB/s，大幅降低 inline 體積）
    "$FFMPEG" -y -loglevel error -i "$AUDIO" -vn -ac 1 -ar 16000 -c:a libopus -b:a 24k "$OPUS" || exit 93

    SZ=$(wc -c < "$OPUS" | tr -d ' ')
    if [ "$SZ" -gt "$MAXB" ]; then
      echo "audio too large: ${SZ} bytes" >&2
      exit 91
    fi

    base64 -i "$OPUS" | tr -d '\n' > "$TMPDIR_BRH/b64.txt"

    "$JQ" -n --rawfile d "$TMPDIR_BRH/b64.txt" \
      '{contents:[{role:"user",parts:[
         {inlineData:{mimeType:"audio/ogg",data:$d}},
         {text:"請將這段音訊轉錄成繁體中文（臺灣用語）文字，只輸出轉錄的文字內容，不要加任何說明"}
       ]}],
       generationConfig:{maxOutputTokens:65536,thinkingConfig:{thinkingLevel:"low"}}}' \
      > "$TMPDIR_BRH/req.json"

    # ⚠️ 絕對不要加 x-goog-user-project header：會被擋成 HTML 404，極難查
    CODE=$(curl -s -o "$TMPDIR_BRH/resp.json" -w '%%{http_code}' \
      -X POST "$HOST/v1/projects/$PROJECT/locations/$LOCATION/publishers/google/models/$MODEL:generateContent" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d @"$TMPDIR_BRH/req.json")

    if [ "$CODE" = "200" ]; then
      cat "$TMPDIR_BRH/resp.json"
      exit 0
    fi

    tail -c 800 "$TMPDIR_BRH/resp.json" >&2
    case "$CODE" in
      401) exit 90 ;;
      403) exit 92 ;;
      *)   exit 94 ;;
    esac
  ]],
    shellQuote(gcloudPath), shellQuote(ffmpegPath), shellQuote(jqPath),
    shellQuote(recordingFile), shellQuote(project), shellQuote(location),
    shellQuote(config.geminiModel), shellQuote(config.vertex.host),
    config.vertex.maxUploadBytes)

  local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    local _latency = hs.timer.secondsSinceEpoch() - _txStartEpoch
    local _stdoutLen = stdout and #stdout or 0
    local _stderrLen = stderr and #stderr or 0

    -- 認證/權限類錯誤：不重試，直接引導使用者處理
    if exitCode == 90 or exitCode == 92 then
      local reason = (exitCode == 90) and "adc_token_failed" or "vertex_permission_denied"
      cloudLog("transcribe_failed", {
        file_basename = basename, file_size = _fileSize, reason = reason,
        latency_s = _latency, vertex_project = project,
        stderr_tail = (stderr or ""):sub(-800),
      }, "ERROR")
      if exitCode == 90 then
        guideAdcLogin("Google Cloud 憑證已過期或無效")
      else
        guideVertexPermission(project)
      end
      callback(nil, (exitCode == 90) and "ADC 憑證失效" or "Vertex 權限不足")
      return
    end

    if exitCode ~= 0 then
      local reasonMap = {
        [91] = "audio_too_large",
        [93] = "ffmpeg_convert_failed",
        [94] = "vertex_http_error",
      }
      cloudLog("transcribe_failed", {
        file_basename = basename, file_size = _fileSize,
        reason = reasonMap[exitCode] or "shell_nonzero_exit",
        exit_code = exitCode, latency_s = _latency,
        stderr_tail = (stderr or ""):sub(-800),
        stdout_tail = (stdout or ""):sub(-400),
      }, "ERROR")
      if exitCode == 91 then
        hs.alert.show("⚠️ 錄音太長，超過雲端單次上限\n請改用 F6 選單的本機引擎轉錄", 5)
        callback(nil, "錄音過長，雲端單次無法處理")
      else
        callback(nil, "Vertex AI 連線失敗: " .. (stderr or ""))
      end
      return
    end

    cloudLog("transcribe_request_done", {
      file_basename = basename,
      latency_s = _latency,
      stdout_bytes = _stdoutLen,
      stderr_bytes = _stderrLen,
    })

    -- 解析回應
    local parseTask = hs.task.new("/bin/bash", function(_, jsonOut, _)
      local text = jsonOut:gsub("^%s*(.-)%s*$", "%1")  -- trim

      if text and text ~= "" and text ~= "null" then
        cloudLog("transcribe_success", {
          file_basename = basename,
          file_size = _fileSize,
          latency_s = _latency,
          text_length = #text,
          -- 注意：text 內容不送雲端（隱私）
        })
        callback(text, nil)
      else
        cloudLog("transcribe_failed", {
          file_basename = basename,
          file_size = _fileSize,
          reason = "empty_or_null_text",
          latency_s = _latency,
          api_response_tail = (stdout or ""):sub(-1200),
        }, "ERROR")
        callback(nil, "Vertex AI 無法解析回應: " .. stdout)
      end
    end, {"-c", "echo '" .. stdout:gsub("'", "'\\''") .. "' | " .. jqPath .. " -r '.candidates[0].content.parts[0].text // empty'"})
    parseTask:start()

  end, {"-c", vertexCmd})
  state.transcribeTask = task
  task:start()
end

-- ========================================
-- v1.7.0: 本機 STT — mlx-whisper daemon
-- ========================================

local function lwmLog(msg)
  print("[LWM-DEBUG " .. os.date("%H:%M:%S") .. "] " .. tostring(msg))
end

-- 讀小檔輔助（trim 換行）
local function readSmallFile(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local content = fh:read("*a") or ""
  fh:close()
  return (content:gsub("%s+$", ""))
end

-- ========================================
-- v1.7.4: 自動安裝 + 浮動進度條 UI
-- ========================================

local lwmProgress = {
  canvas = nil,
  totalSteps = 4,
  step = 0,
}

function lwmProgress:show()
  if self.canvas then return end
  local screen = hs.screen.mainScreen()
  local f = screen:frame()
  local W, H = 520, 96
  local x = f.x + (f.w - W) / 2
  local y = f.y + 80
  self.canvas = hs.canvas.new({ x = x, y = y, w = W, h = H })
  self.canvas[1] = {
    type = "rectangle", action = "fill",
    fillColor = { alpha = 0.92, red = 0.08, green = 0.09, blue = 0.13 },
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
  }
  self.canvas[2] = {
    type = "rectangle", action = "stroke",
    strokeColor = { alpha = 0.5, red = 0.4, green = 0.7, blue = 0.4 },
    strokeWidth = 1.5,
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
  }
  self.canvas[3] = {
    type = "text",
    text = "🔨 波特槌 — 自動安裝本機 STT 引擎",
    textSize = 14, textColor = { white = 1 },
    frame = { x = 20, y = 12, w = W - 40, h = 20 },
  }
  self.canvas[4] = {
    type = "text",
    text = "",
    textSize = 11, textColor = { white = 0.85 },
    frame = { x = 20, y = 36, w = W - 40, h = 18 },
  }
  self.canvas[5] = {
    type = "rectangle", action = "fill",
    fillColor = { white = 0.25 },
    frame = { x = 20, y = 64, w = W - 40, h = 14 },
    roundedRectRadii = { xRadius = 7, yRadius = 7 },
  }
  self.canvas[6] = {
    type = "rectangle", action = "fill",
    fillColor = { red = 0.3, green = 0.75, blue = 0.45 },
    frame = { x = 20, y = 64, w = 0, h = 14 },
    roundedRectRadii = { xRadius = 7, yRadius = 7 },
  }
  self.canvas:show()
  self.step = 0
end

function lwmProgress:update(step, label)
  if not self.canvas then return end
  self.step = step
  local pct = math.min(1.0, math.max(0, step / self.totalSteps))
  local barWidth = (520 - 40) * pct
  self.canvas[6].frame = { x = 20, y = 64, w = barWidth, h = 14 }
  self.canvas[4].text = string.format("[%d/%d] %s", step, self.totalSteps, label or "")
end

function lwmProgress:fail(msg)
  if not self.canvas then return end
  self.canvas[6].fillColor = { red = 0.85, green = 0.3, blue = 0.3 }
  self.canvas[6].frame = { x = 20, y = 64, w = 520 - 40, h = 14 }
  self.canvas[4].text = "❌ " .. (msg or "失敗")
  self.canvas[3].text = "🔨 波特槌 — 安裝失敗"
end

function lwmProgress:hide()
  if self.canvas then
    self.canvas:hide()
    self.canvas:delete()
    self.canvas = nil
  end
end

local function isLwmInstalled(callback)
  -- v1.7.5: 改用 venv 內 python 偵測
  local venvPy = os.getenv("HOME") .. "/.botrun-hammer/venv/bin/python"
  local probe = string.format(
    "test -x %q && %q -c 'import mlx_whisper' 2>/dev/null",
    venvPy, venvPy
  )
  local task = hs.task.new("/bin/bash", function(exitCode, _, _)
    callback(exitCode == 0)
  end, {"-c", probe})
  task:start()
end

local function parsePipLine(line)
  local pkg = line:match("^Collecting%s+([%w%-%._]+)")
  if pkg then return "下載: " .. pkg end
  pkg = line:match("^Downloading%s+([%w%-%._]+)")
  if pkg then return "下載: " .. pkg end
  pkg = line:match("Installing collected packages:%s*(.+)")
  if pkg then return "安裝: " .. pkg:sub(1, 60) end
  if line:match("Successfully installed") then return "驗證中…" end
  if line:match("^ERROR: ") then return "⚠️ " .. line:sub(1, 80) end
  return nil
end

local lwmInstalling = false

local function autoInstallLwm(onDone)
  if lwmInstalling then
    lwmLog("autoInstallLwm: 已在安裝中，忽略重複呼叫")
    if onDone then onDone(false) end
    return
  end
  isLwmInstalled(function(installed)
    if installed then
      lwmLog("LWM 已安裝，跳過 auto-install")
      if onDone then onDone(true) end
      return
    end
    lwmInstalling = true
    lwmLog("autoInstallLwm: 啟動 pip install 流程")
    lwmProgress:show()
    lwmProgress:update(1, "偵測 Python 環境…")

    if not hs.fs.attributes(config.lwm.ctlScript) then
      lwmProgress:fail("找不到 daemon 控制腳本（請等 self-heal 完成後再試）")
      hs.timer.doAfter(5, function() lwmProgress:hide(); lwmInstalling = false end)
      if onDone then onDone(false) end
      return
    end

    lwmProgress:update(2, "下載 mlx-whisper 與依賴（約 1GB）…")

    local installTask
    installTask = hs.task.new("/bin/bash",
      function(exitCode, stdout, stderr)
        lwmInstalling = false
        if exitCode == 0 then
          lwmProgress:update(4, "✅ 完成，可開始使用本機引擎")
          lwmLog("autoInstallLwm: 成功")
          hs.timer.doAfter(2.5, function() lwmProgress:hide() end)
          if onDone then onDone(true) end
        else
          local tail = (stderr or stdout or ""):sub(-150):gsub("\n", " ")
          lwmProgress:fail(tail)
          lwmLog("autoInstallLwm: 失敗 exit=" .. tostring(exitCode) .. " err_tail=" .. tail)
          hs.timer.doAfter(8, function() lwmProgress:hide() end)
          if onDone then onDone(false) end
        end
      end,
      function(task, stdoutChunk, stderrChunk)
        local data = (stdoutChunk or "") .. (stderrChunk or "")
        for line in data:gmatch("[^\r\n]+") do
          local label = parsePipLine(line)
          if label then
            local s = label:sub(1, 6) == "安裝:" and 3 or 2
            lwmProgress:update(s, label)
          end
        end
        return true
      end,
      { config.lwm.ctlScript, "install" }
    )
    installTask:start()
  end)
end

-- v1.9.0: Gemma 4 audio 需要 mlx-vlm（~2GB），lazy install — 只在使用者選 gemma-* 時才裝
local mlxVlmInstalling = false

local function isMlxVlmInstalled(callback)
  local venvPy = os.getenv("HOME") .. "/.botrun-hammer/venv/bin/python"
  hs.task.new("/bin/bash", function(ec, _, _)
    callback(ec == 0)
  end, {"-c", venvPy .. " -c 'import mlx_vlm' 2>/dev/null"}):start()
end

local function autoInstallMlxVlm(onDone)
  if mlxVlmInstalling then
    if onDone then onDone(false) end
    return
  end
  isMlxVlmInstalled(function(installed)
    if installed then
      if onDone then onDone(true) end
      return
    end
    mlxVlmInstalling = true
    lwmProgress:show()
    lwmProgress:update(1, "Gemma 4 需要 mlx-vlm，下載中（約 2GB）…")
    local venvPip = os.getenv("HOME") .. "/.botrun-hammer/venv/bin/pip"
    local installTask
    installTask = hs.task.new("/bin/bash",
      function(exitCode, stdout, stderr)
        mlxVlmInstalling = false
        if exitCode == 0 then
          lwmProgress:update(4, "✅ mlx-vlm 完成，準備載入 Gemma 4")
          hs.timer.doAfter(2, function() lwmProgress:hide() end)
          if onDone then onDone(true) end
        else
          local tail = (stderr or stdout or ""):sub(-150):gsub("\n", " ")
          lwmProgress:fail("mlx-vlm 安裝失敗：" .. tail)
          hs.timer.doAfter(8, function() lwmProgress:hide() end)
          if onDone then onDone(false) end
        end
      end,
      function(_task, stdoutChunk, stderrChunk)
        local data = (stdoutChunk or "") .. (stderrChunk or "")
        for line in data:gmatch("[^\r\n]+") do
          local label = parsePipLine(line)
          if label then lwmProgress:update(2, label) end
        end
        return true
      end,
      {"-c", venvPip .. " install --no-cache-dir mlx-vlm"}
    )
    installTask:start()
  end)
end

-- v1.7.3: 升級路徑自我修復
-- auto-update 只會拉這份 lua；daemon 腳本若缺（既有使用者升級到首次有 LWM 的版本），
-- 從 GitHub raw 抓回來。沿用 auto-update 的 hs.http 非同步機制，不阻塞啟動。
local LWM_RAW_BASE = "https://raw.githubusercontent.com/botrun/botrun-hammer/main/scripts"
local LWM_REQUIRED_FILES = {
  { name = "lwm_daemon.py",      mode = "0755" },
  { name = "lwm_daemon_ctl.sh",  mode = "0755" },
}

local function ensureLwmScriptsDeployed(onComplete)
  local scriptDir = os.getenv("HOME") .. "/.botrun-hammer/scripts"
  os.execute("mkdir -p '" .. scriptDir .. "'")

  local missing = {}
  for _, f in ipairs(LWM_REQUIRED_FILES) do
    local dest = scriptDir .. "/" .. f.name
    if not hs.fs.attributes(dest) then
      table.insert(missing, { name = f.name, dest = dest, mode = f.mode })
    end
  end

  if #missing == 0 then
    lwmLog("daemon scripts already deployed")
    if onComplete then onComplete(true) end
    return
  end

  lwmLog("self-heal: " .. #missing .. " daemon script(s) missing, fetching from GitHub raw...")
  local pending = #missing
  local allOk = true

  for _, f in ipairs(missing) do
    local url = LWM_RAW_BASE .. "/" .. f.name
    lwmLog("fetching " .. url)
    hs.http.asyncGet(url, nil, function(status, body, headers)
      if status == 200 and body and #body > 0 then
        local fh = io.open(f.dest, "w")
        if fh then
          fh:write(body)
          fh:close()
          os.execute("chmod " .. f.mode .. " '" .. f.dest .. "'")
          lwmLog("self-heal saved " .. f.name .. " (" .. #body .. " bytes)")
        else
          lwmLog("ERROR: cannot write " .. f.dest)
          allOk = false
        end
      else
        lwmLog("ERROR: GitHub fetch failed " .. f.name .. " status=" .. tostring(status))
        allOk = false
      end
      pending = pending - 1
      if pending == 0 and onComplete then onComplete(allOk) end
    end)
  end
end

-- 確保 daemon 在跑（同步：阻塞最多 ~5 秒等 port 就緒）
-- 回傳 true=就緒, false=失敗
local function ensureLwmDaemon()
  lwmLog("ensureLwmDaemon: ctlScript=" .. config.lwm.ctlScript)
  if not hs.fs.attributes(config.lwm.ctlScript) then
    lwmLog("FAIL: ctl script not found")
    return false, "lwm_ctl_missing"
  end
  if readSmallFile(config.lwm.portFile) then
    lwmLog("daemon already up, port=" .. tostring(readSmallFile(config.lwm.portFile)))
    return true
  end
  lwmLog("daemon down, starting via " .. config.lwm.ctlScript .. " ensure ...")
  local task = hs.task.new("/bin/bash", nil, {config.lwm.ctlScript, "ensure"})
  task:start()
  task:waitUntilExit()
  local exitCode = task:terminationStatus()
  lwmLog("ensure exit=" .. tostring(exitCode))
  if exitCode ~= 0 then
    return false, "ensure_nonzero(exit=" .. tostring(exitCode) .. ")"
  end
  local port = readSmallFile(config.lwm.portFile)
  if not port then
    lwmLog("FAIL: no port file after ensure")
    return false, "no_port_file"
  end
  lwmLog("daemon started, port=" .. port)
  return true
end

-- 呼叫本機 daemon 轉錄
local function transcribeWithLightningWhisperMLX(recordingFile, callback)
  lwmLog("transcribeWithLWM start: file=" .. tostring(recordingFile))
  local ok, ensureErr = ensureLwmDaemon()
  if not ok then
    cloudLog("transcribe_failed", {
      file_basename = recordingFile:match("([^/]+)$") or "",
      reason = "lwm_ensure_failed:" .. tostring(ensureErr),
      engine = "lwm",
    }, "ERROR")
    callback(nil, "本機引擎啟動失敗: " .. tostring(ensureErr))
    return
  end

  local port = readSmallFile(config.lwm.portFile)
  local token = readSmallFile(config.lwm.tokenFile)
  if not port or not token then
    callback(nil, "缺 port/token 檔")
    return
  end

  local model = hs.settings.get("botrun.lwm.model") or config.lwm.defaultModel
  local quant = hs.settings.get("botrun.lwm.quant") or config.lwm.defaultQuant
  lwmLog("port=" .. tostring(port) .. " model=" .. tostring(model) .. " quant=" .. tostring(quant) .. " token_len=" .. tostring(token and #token or 0))
  local _attrs = hs.fs.attributes(recordingFile)
  local _fileSize = _attrs and _attrs.size or 0
  local _txStartEpoch = hs.timer.secondsSinceEpoch()
  local ext = recordingFile:match("%.([^%./]+)$") or "m4a"

  cloudLog("transcribe_request_start", {
    file_basename = recordingFile:match("([^/]+)$") or "",
    file_size = _fileSize,
    engine = "lwm",
    lwm_model = model,
    lwm_quant = quant,
  })

  -- v1.7.7: 傳 language hint，預設繁中（沿用 config.language="zh"）
  local lang = config.language or "zh"
  local url = string.format("http://127.0.0.1:%s/transcribe?model=%s&quant=%s&ext=%s&lang=%s",
    port, model, quant, ext, lang)

  -- 用 curl --data-binary 上傳；同步用 hs.task fire-and-forget
  -- jq 路徑沿用既有 helper
  local jqPath = getJqPath()
  local cmd = string.format([[
    curl -sS -X POST --data-binary "@%s" \
      -H "Authorization: Bearer %s" \
      -H "Content-Type: application/octet-stream" \
      "%s"
  ]], recordingFile, token, url)

  lwmLog("curl cmd preview: POST " .. url)
  local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    local _latency = hs.timer.secondsSinceEpoch() - _txStartEpoch
    lwmLog("curl exit=" .. tostring(exitCode) .. " stdout_bytes=" .. (stdout and #stdout or 0) .. " stderr_bytes=" .. (stderr and #stderr or 0) .. " latency=" .. string.format("%.2f", _latency) .. "s")
    if stdout and #stdout > 0 then
      lwmLog("curl stdout head: " .. stdout:sub(1, 300))
    end
    if stderr and #stderr > 0 then
      lwmLog("curl stderr: " .. stderr:sub(1, 500))
    end
    if exitCode ~= 0 then
      cloudLog("transcribe_failed", {
        file_basename = recordingFile:match("([^/]+)$") or "",
        reason = "lwm_curl_nonzero",
        exit_code = exitCode,
        latency_s = _latency,
        stderr_tail = (stderr or ""):sub(-800),
        engine = "lwm",
      }, "ERROR")
      callback(nil, "本機 daemon 連線失敗: " .. (stderr or ""))
      return
    end

    -- 解析 JSON 取 .text
    local parseTask = hs.task.new("/bin/bash", function(_, jsonOut, jsonErr)
      local text = (jsonOut or ""):gsub("^%s*(.-)%s*$", "%1")
      lwmLog("jq parsed text_len=" .. tostring(#text) .. " jq_err=" .. tostring(jsonErr or ""):sub(1, 200))
      if text and text ~= "" and text ~= "null" then
        cloudLog("transcribe_success", {
          file_basename = recordingFile:match("([^/]+)$") or "",
          file_size = _fileSize,
          latency_s = _latency,
          text_length = #text,
          engine = "lwm",
          lwm_model = model,
          lwm_quant = quant,
        })
        callback(text, nil)
      else
        cloudLog("transcribe_failed", {
          file_basename = recordingFile:match("([^/]+)$") or "",
          reason = "lwm_empty_text",
          latency_s = _latency,
          api_response_tail = (stdout or ""):sub(-1200),
          engine = "lwm",
        }, "ERROR")
        callback(nil, "本機轉錄回傳空文字")
      end
    end, {"-c", "echo '" .. stdout:gsub("'", "'\\''") .. "' | " .. jqPath .. " -r '.text // empty'"})
    parseTask:start()
  end, {"-c", cmd})

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
  cloudLog("transcribe_cancelled", {
    file_basename = state.transcribeFile and (state.transcribeFile:match("([^/]+)$") or "") or "",
  }, "WARNING")

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
    cloudLog("transcribe_failed", {
      file_basename = recordingFile and (recordingFile:match("([^/]+)$") or "") or "(nil)",
      reason = "file_not_found",
    }, "ERROR")
    hs.alert.show("找不到錄音檔", 2)
    callback(nil, "找不到錄音檔案")
    return
  end

  -- v1.7.0: 依使用者選擇分流引擎（記憶於 hs.settings）
  local engine = hs.settings.get("botrun.engine") or "gemini"

  -- 設定轉錄狀態
  state.isTranscribing = true
  state.transcribeFile = recordingFile
  bindCancelHotkey()
  local _outerStartEpoch = hs.timer.secondsSinceEpoch()
  local _outerAttrs = hs.fs.attributes(recordingFile)
  cloudLog("transcribe_start", {
    file_basename = recordingFile:match("([^/]+)$") or "",
    file_size = _outerAttrs and _outerAttrs.size or 0,
    engine = engine,
    lwm_model = engine == "lwm" and (hs.settings.get("botrun.lwm.model") or config.lwm.defaultModel) or nil,
  })

  -- 啟動轉錄動畫
  startTranscribeAnimation()

  -- 轉錄結束清理（成功/失敗都需要）
  local function finishTranscription()
    state.isTranscribing = false
    state.transcribeFile = nil
    state.transcribeTask = nil
    unbindCancelHotkey()
  end

  local function onResult(text, err, isRetry)
    -- 已被取消，忽略回調
    if not state.isTranscribing then return end

    if text then
      stopTranscribeAnimation()
      finishTranscription()
      cloudLog("transcribe_done", {
        file_basename = recordingFile:match("([^/]+)$") or "",
        outer_latency_s = hs.timer.secondsSinceEpoch() - _outerStartEpoch,
        text_length = #text,
        is_retry = isRetry and true or false,
        engine = engine,
      })
      if not config.keepSuccessfulRecordings then
        os.remove(recordingFile)
      end
      convertToTraditional(text, function(traditionalText)
        callback(traditionalText, nil)
      end)
    elseif not isRetry and engine == "gemini" then
      -- Gemini：第一次失敗 retry 一次
      print("[波特槌] Gemini 第一次失敗: " .. (err or "未知錯誤") .. "，重試一次...")
      cloudLog("transcribe_retry", {
        file_basename = recordingFile:match("([^/]+)$") or "",
        first_error = err or "unknown",
        outer_elapsed_s = hs.timer.secondsSinceEpoch() - _outerStartEpoch,
        engine = engine,
      }, "WARNING")
      hs.alert.show("⚠️ Gemini 暫時故障，重試中...", 1.5)
      hs.timer.doAfter(1, function()
        if not state.isTranscribing then return end
        transcribeWithGemini(recordingFile, function(retryText, retryErr)
          onResult(retryText, retryErr, true)
        end)
      end)
    else
      -- lwm 不重試（daemon 失敗多半是模型/環境問題，retry 無意義）；或 gemini 二次也失敗
      stopTranscribeAnimation()
      finishTranscription()
      cloudLog("transcribe_final_failed", {
        file_basename = recordingFile:match("([^/]+)$") or "",
        last_error = err or "unknown",
        outer_latency_s = hs.timer.secondsSinceEpoch() - _outerStartEpoch,
        engine = engine,
      }, "ERROR")
      hs.alert.show("❌ 轉錄失敗\n錄音已保留: " .. recordingFile:match("([^/]+)$"), 3)
      callback(nil, (engine == "lwm" and "本機轉錄失敗" or "Gemini 轉錄失敗（含重試）"))
    end
  end

  -- 引擎分流（OCP：未來新增引擎只需加 elseif）
  print("[LWM-DEBUG " .. os.date("%H:%M:%S") .. "] dispatch engine=" .. tostring(engine))
  if engine == "lwm" then
    transcribeWithLightningWhisperMLX(recordingFile, function(text, err)
      onResult(text, err, false)
    end)
  else
    transcribeWithGemini(recordingFile, function(text, err)
      onResult(text, err, false)
    end)
  end
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

-- v1.6.8+：暴露給 hs CLI 用，讓 scripts/realtime_drive.sh 可以從外部驅動，不靠合成鍵盤事件
_G.botrunHammerToggle = toggleRecording
_G.botrunHammerIsRecording = function() return state.isRecording end
_G.botrunHammerIsTranscribing = function() return state.isTranscribing end
_G.botrunHammerIsBusy = function() return state.isRecording or state.isTranscribing end
_G.botrunHammerCurrentFile = function() return state.currentRecordingFile end
_G.botrunHammerTranscribeFile = function() return state.transcribeFile end
_G.botrunHammerHistoryFile = function() return config.historyFile end
-- v1.10.0：雲端（Vertex AI + ADC）轉錄除錯入口，供 `hs -c` 做 E2E 驗證
_G.botrunHammerTranscribeCloud = function(path, cb) transcribeWithGemini(path, cb) end
_G.botrunHammerAdcStatus = function()
  return {
    gcloud = getGcloudPath() or "NOT_FOUND",
    adc = adcCredentialsExist(),
    project = getVertexProject(),
    location = getVertexLocation(),
  }
end

-- v1.7.15: F6 統一選單（合併原 F6 文字歷史 + F7 檔案歷史 + F8 引擎切換）
-- 舊的 F7 / F8 hotkey 不再綁定，使用者只需記憶 F6

-- ========================================
-- v1.7.0: menubar 引擎切換選單（記憶最後一次）
-- ========================================

local function currentEngineSummary()
  local engine = hs.settings.get("botrun.engine") or "gemini"
  if engine == "lwm" then
    local model = hs.settings.get("botrun.lwm.model") or config.lwm.defaultModel
    return "🔨 lwm:" .. model
  end
  return "🔨 gemini"
end

local engineMenubar = nil

-- Forward declare（v1.7.10：setEngineLwm 會呼叫 lwmPreloadModel，但後者宣告在後面）
local lwmPreloadModel

local function setEngineGemini()
  hs.settings.set("botrun.engine", "gemini")
  hs.alert.show("✅ 已切換到 ☁️ Gemini (雲端)", 1.5)
  if engineMenubar then engineMenubar:setTitle(currentEngineSummary()) end
end

local function setEngineLwm(modelKey)
  hs.settings.set("botrun.engine", "lwm")
  hs.settings.set("botrun.lwm.model", modelKey)
  if not hs.settings.get("botrun.lwm.quant") then
    hs.settings.set("botrun.lwm.quant", config.lwm.defaultQuant)
  end
  if engineMenubar then engineMenubar:setTitle(currentEngineSummary()) end
  -- v1.9.0: Gemma 4 audio 有 30 秒上限，必須在 UI 警告
  local isGemma = modelKey:sub(1, 6) == "gemma-"
  if isGemma then
    hs.alert.show("⚠️ Gemma 4 實驗模式：音檔需 ≤30 秒\n超過會回 422，建議只用於短句測試", 5)
  end
  -- v1.7.4: 切換到本機 = 自動補齊環境（scripts → pip → daemon），全部 UI 化
  ensureLwmScriptsDeployed(function(scriptsOk)
    if not scriptsOk then
      hs.alert.show("⚠️ 無法部署 daemon 腳本（自我修復失敗，請檢查網路）", 4)
      return
    end
    autoInstallLwm(function(pipOk)
      if not pipOk then return end
      -- v1.9.0: Gemma 模型額外確保 mlx-vlm（lazy install）
      local function afterEnsureDeps()
        hs.alert.show("✅ 已切換到 💻 本機 " .. modelKey .. "\n背景預載 daemon + 模型...", 2)
        hs.task.new("/bin/bash", function(ec, _, _)
          if ec ~= 0 then return end
          lwmPreloadModel(modelKey)
        end, { config.lwm.ctlScript, "ensure" }):start()
        lwmStartHealthWatchdog()
      end
      if isGemma then
        autoInstallMlxVlm(function(vlmOk)
          if not vlmOk then
            hs.alert.show("⚠️ mlx-vlm 安裝失敗，無法使用 Gemma 4", 5)
            return
          end
          afterEnsureDeps()
        end)
      else
        afterEnsureDeps()
      end
    end)
  end)
end

-- v1.7.10: 預載模型 + 滾動 emoji 進度（首次會 HF download ~1.5GB）
function lwmPreloadModel(modelKey)
  local port = readSmallFile(config.lwm.portFile)
  local token = readSmallFile(config.lwm.tokenFile)
  if not port or not token then
    -- daemon 還沒就緒，0.5 秒後再試
    hs.timer.doAfter(0.5, function() lwmPreloadModel(modelKey) end)
    return
  end
  local emojis = {"🌐", "📥", "⏬", "📦", "🔧", "✨"}
  local i = 1
  local spinner = hs.timer.doEvery(1, function()
    i = (i % #emojis) + 1
    hs.alert.show(emojis[i] .. " 載入 " .. modelKey .. " 中...\n首次下載約 1.5–3GB", 1.2)
  end)
  hs.alert.show(emojis[1] .. " 載入 " .. modelKey .. " 中...\n首次下載約 1.5–3GB", 1.2)

  local cmd = string.format(
    "curl -s -m 600 -X POST -H 'Authorization: Bearer %s' 'http://127.0.0.1:%s/switch_model?model=%s'",
    token, port, modelKey
  )
  hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    spinner:stop()
    if exitCode == 0 and (stdout or ""):match('"ok": true') then
      local secs = (stdout or ""):match('"loaded_in_s":%s*([%d%.]+)') or "?"
      hs.alert.show("✅ " .. modelKey .. " 已就緒（載入 " .. secs .. "s）", 2)
    else
      -- v1.9.0: daemon 錯誤訊息在 stdout 的 JSON error 欄位（curl -s 時 stderr 空）
      local errMsg = (stdout or ""):match('"error":%s*"([^"]+)"')
      if not errMsg or errMsg == "" then errMsg = (stderr or ""):sub(1, 200) end
      if errMsg == "" then errMsg = "（無錯誤訊息，請看 ~/.botrun-hammer/lwm.log）" end
      -- 特例：mlx-vlm 未裝（Gemma 路徑），引導使用者跑 pip
      if errMsg:match("mlx%-vlm") then
        hs.alert.show("⚠️ " .. modelKey .. " 需要 mlx-vlm，請先跑：\n~/.botrun-hammer/venv/bin/pip install mlx-vlm", 8)
      else
        hs.alert.show("⚠️ 模型預載失敗：" .. errMsg:sub(1, 200), 5)
      end
    end
  end, {"-c", cmd}):start()
end

local function buildEngineMenu()
  local engine = hs.settings.get("botrun.engine") or "gemini"
  local currentModel = hs.settings.get("botrun.lwm.model") or config.lwm.defaultModel
  local items = {
    {
      title = "☁️ Gemini (雲端)",
      checked = engine == "gemini",
      fn = setEngineGemini,
    },
    { title = "-" },
  }
  for _, m in ipairs(config.lwm.menuModels) do
    table.insert(items, {
      title = m.label,
      checked = engine == "lwm" and currentModel == m.key,
      fn = function() setEngineLwm(m.key) end,
    })
  end
  -- v1.7.15: 合併文字歷史 / 錄音檔案進來，使用者只需記憶 F6
  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "📝 文字歷史…",
    fn = function() showTextHistory() end,
  })
  table.insert(items, {
    title = "🎵 錄音檔案…",
    fn = function() showFileHistory() end,
  })
  -- v1.7.14: 不再露出「重啟 daemon / 重新安裝 pip」——
  -- 這兩件事由 health watchdog（v1.7.9）+ 切換引擎 auto-install（v1.7.4）負責。
  -- 工程除錯仍可透過 `hs -c 'botrunHammer.restartDaemon()'` 等隱藏 API 觸發。
  table.insert(items, { title = "-" })
  table.insert(items, { title = "波特槌 v" .. VERSION, disabled = true })
  return items
end

-- v1.7.15: 隱藏 debug API（不出現在選單，但可從 hs CLI 呼叫）
_G.botrunHammer = _G.botrunHammer or {}
_G.botrunHammer.restartDaemon = function()
  hs.task.new("/bin/bash", function(code, _, stderr)
    print("[botrunHammer.restartDaemon] exit=" .. tostring(code) .. " stderr=" .. tostring(stderr or ""):sub(1, 200))
  end, {config.lwm.ctlScript, "restart"}):start()
  return "restarting…"
end
_G.botrunHammer.reinstallLwm = function()
  autoInstallLwm(function(ok)
    print("[botrunHammer.reinstallLwm] ok=" .. tostring(ok))
  end)
  return "installing…"
end

-- v1.7.15: 不常駐 menubar（避免上方 bar 干擾），F6 統一選單彈出；選完即關
engineMenubar = hs.menubar.new(false)
print("[LWM-DEBUG] engineMenubar created (hidden)? " .. tostring(engineMenubar ~= nil))
if engineMenubar then
  engineMenubar:setMenu(buildEngineMenu)
end

-- v1.7.15: F6 = 統一選單入口（合併原 F6/F7/F8）
hs.hotkey.bind({}, config.historyTextKey, function()
  if not engineMenubar then return end
  local pt = hs.mouse.absolutePosition()
  engineMenubar:popupMenu(pt)
end)

-- v1.7.9: Daemon health watchdog — 定期 /health，timeout 或失敗就 force restart
local lwmHealth = {
  timer = nil,
  consecutiveFails = 0,
  lastOk = nil,
  lastRestart = 0,
}

local function lwmHealthPing(onResult)
  local port = readSmallFile(config.lwm.portFile)
  local token = readSmallFile(config.lwm.tokenFile)
  if not port or not token then
    onResult(false, "no_port_or_token")
    return
  end
  local cmd = string.format(
    "curl -s -m %d -o /dev/null -w '%%{http_code}' -H 'Authorization: Bearer %s' http://127.0.0.1:%s/health",
    config.lwm.healthCheckTimeout, token, port
  )
  hs.task.new("/bin/bash", function(exitCode, stdout, _)
    if exitCode == 0 and (stdout or ""):match("^200") then
      onResult(true)
    else
      onResult(false, "http_status=" .. tostring(stdout) .. " curl_exit=" .. tostring(exitCode))
    end
  end, {"-c", cmd}):start()
end

local function lwmForceRestart(reason)
  local now = hs.timer.secondsSinceEpoch()
  -- 防止 restart loop：30 秒內最多一次
  if (now - lwmHealth.lastRestart) < 30 then
    lwmLog("watchdog: 跳過 restart（剛剛已重啟過）reason=" .. tostring(reason))
    return
  end
  lwmHealth.lastRestart = now
  lwmLog("watchdog: FORCE RESTART reason=" .. tostring(reason))
  hs.notify.new({title = "🔨 波特槌 watchdog", informativeText = "本機 daemon 卡住，自動重啟中..."}):send()
  hs.task.new("/bin/bash", function(code, stdout, stderr)
    if code == 0 then
      lwmLog("watchdog: restart success")
      lwmHealth.consecutiveFails = 0
    else
      lwmLog("watchdog: restart FAILED exit=" .. tostring(code) .. " stderr=" .. (stderr or ""):sub(1, 200))
    end
  end, {config.lwm.ctlScript, "restart"}):start()
end

local function lwmStartHealthWatchdog()
  if not config.lwm.autoRestartEnabled then return end
  if lwmHealth.timer then lwmHealth.timer:stop(); lwmHealth.timer = nil end
  lwmHealth.timer = hs.timer.doEvery(config.lwm.healthCheckInterval, function()
    -- 引擎不是 lwm 就不打（省資源；切回時會自動恢復）
    if (hs.settings.get("botrun.engine") or "gemini") ~= "lwm" then return end
    -- 轉錄中不打（避免干擾長轉錄）
    if state.isTranscribing then return end
    lwmHealthPing(function(ok, err)
      if ok then
        lwmHealth.consecutiveFails = 0
        lwmHealth.lastOk = hs.timer.secondsSinceEpoch()
      else
        lwmHealth.consecutiveFails = lwmHealth.consecutiveFails + 1
        lwmLog("watchdog ping fail #" .. lwmHealth.consecutiveFails .. " err=" .. tostring(err))
        -- 連續 2 次失敗才 restart（避免短暫網路 hiccup）
        if lwmHealth.consecutiveFails >= 2 then
          lwmForceRestart(err)
        end
      end
    end)
  end)
  lwmLog("health watchdog 啟動 interval=" .. config.lwm.healthCheckInterval .. "s")
end

-- 環境自檢（reload 時印一次，立刻看出哪邊缺）
print("[LWM-DEBUG] === 環境自檢 ===")
print("[LWM-DEBUG] ctlScript exists: " .. tostring(hs.fs.attributes(config.lwm.ctlScript) ~= nil) .. " (" .. config.lwm.ctlScript .. ")")
print("[LWM-DEBUG] portFile: " .. tostring(hs.fs.attributes(config.lwm.portFile) ~= nil) .. " (" .. config.lwm.portFile .. ")")
print("[LWM-DEBUG] tokenFile: " .. tostring(hs.fs.attributes(config.lwm.tokenFile) ~= nil) .. " (" .. config.lwm.tokenFile .. ")")
print("[LWM-DEBUG] saved engine: " .. tostring(hs.settings.get("botrun.engine")))
print("[LWM-DEBUG] saved model: " .. tostring(hs.settings.get("botrun.lwm.model")))
print("[LWM-DEBUG] saved quant: " .. tostring(hs.settings.get("botrun.lwm.quant")))

-- v1.7.3+1.7.4: 升級路徑完整自動化
-- 1. self-heal scripts（既有使用者 auto-update 後缺 daemon 腳本 → 從 GitHub raw 抓）
-- 2. 若 engine=lwm 且 LWM 未安裝 → 自動觸發 pip install + 浮動進度條 UI
ensureLwmScriptsDeployed(function(scriptsOk)
  print("[LWM-DEBUG] self-heal complete: ok=" .. tostring(scriptsOk))
  if not scriptsOk then return end
  local savedEngine = hs.settings.get("botrun.engine")
  -- v1.9.0: 預設雲端 Gemini，本地模型一律 lazy（不選不裝、不選不起 daemon）
  -- 只在 savedEngine == "lwm" 才繼續走確保流程
  if savedEngine ~= "lwm" then
    print("[LWM-DEBUG] engine=" .. tostring(savedEngine) .. "（非 lwm），跳過 daemon 預載")
    return
  end
  isLwmInstalled(function(installed)
    if installed then
      print("[LWM-DEBUG] engine=lwm 且 LWM 已安裝，起 daemon")
      hs.task.new("/bin/bash", nil, { config.lwm.ctlScript, "ensure" }):start()
      lwmStartHealthWatchdog()
    else
      print("[LWM-DEBUG] engine=lwm 但 LWM 未安裝，啟動自動安裝（含進度條）")
      autoInstallLwm(function(ok)
        if ok then
          hs.task.new("/bin/bash", nil, { config.lwm.ctlScript, "ensure" }):start()
          lwmStartHealthWatchdog()
        end
      end)
    end
  end)
end)

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

hs.alert.show("🔨 波特槌 v" .. VERSION .. " 已啟動\n🎤 F5 語音輸入 | F6 統一選單（引擎/歷史/檔案）\n⎋ ESC 取消轉錄", 3)

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

  -- v1.10.0：雲端轉錄改用 gcloud ADC（不再有 API key）
  if not getGcloudPath() then
    table.insert(issues, "gcloud 未安裝（brew install --cask gcloud-cli）")
  elseif not adcCredentialsExist() then
    table.insert(issues, "尚未登入 Google Cloud：gcloud auth application-default login")
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

print("[🔨 波特槌 v" .. VERSION .. "] 模組已載入（Gemini API｜F6 統一選單｜自動更新）")

-- v1.6.8+：啟動時送一次「load」事件，確認雲端日誌通路有打通
cloudLog("load", { script_path = SCRIPT_PATH })
