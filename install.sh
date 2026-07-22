#!/bin/bash
#
# 波特槌 安裝腳本
# Mac 語音轉文字工具（F5 快捷鍵）
#
# 使用方式：
#   curl -fsSL https://raw.githubusercontent.com/botrun/botrun-hammer/main/install.sh | bash
#   或
#   ./install.sh
#

set -e

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 路徑
HAMMERSPOON_DIR="$HOME/.hammerspoon"
BOTRUN_DIR="$HOME/.botrun-hammer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"

echo ""
echo -e "${BOLD}🎤 波特槌 安裝程式${NC}"
echo -e "${CYAN}   Mac 語音轉文字工具（F5 快捷鍵）${NC}"
echo ""

# ========================================
# 檢查系統
# ========================================

# 檢查是否為 macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}❌ 此工具僅支援 macOS${NC}"
    exit 1
fi

# ========================================
# 檢查/安裝 Homebrew
# ========================================

echo "🔍 檢查 Homebrew..."
if ! command -v brew &> /dev/null; then
    echo -e "${YELLOW}⚠️ Homebrew 未安裝${NC}"
    echo "正在安裝 Homebrew..."
    # 重點修正：隔離 stdin，避免 curl|bash 模式下被吃掉
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/null

    # 設定 PATH（Apple Silicon）
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
echo -e "${GREEN}✅ Homebrew 已安裝${NC}"

# ========================================
# 檢查/安裝 Hammerspoon
# ========================================

echo "🔍 檢查 Hammerspoon..."
if [[ ! -d "/Applications/Hammerspoon.app" && ! -d "$HOME/Applications/Hammerspoon.app" ]]; then
    echo "⚠️ Hammerspoon 未安裝，正在安裝..."
    brew install --cask hammerspoon < /dev/null
    NEED_ACCESSIBILITY=1
fi
echo -e "${GREEN}✅ Hammerspoon 已安裝${NC}"

# ========================================
# 檢查/安裝依賴工具
# ========================================

echo "🔍 檢查 ffmpeg（音訊處理工具）..."
if ! command -v ffmpeg &> /dev/null; then
    echo "⚠️ ffmpeg 未安裝，正在安裝..."
    brew install ffmpeg < /dev/null
fi
echo -e "${GREEN}✅ ffmpeg 已安裝${NC}"

echo "🔍 檢查 jq（JSON 解析）..."
if ! command -v jq &> /dev/null; then
    echo "⚠️ jq 未安裝，正在安裝..."
    brew install jq < /dev/null
fi
echo -e "${GREEN}✅ jq 已安裝${NC}"

echo "🔍 檢查 gcloud（Google Cloud SDK，語音轉文字認證用）..."
if [[ ! -x /opt/homebrew/bin/gcloud && ! -x /usr/local/bin/gcloud && ! -x /usr/bin/gcloud && ! -x "$HOME/google-cloud-sdk/bin/gcloud" ]]; then
    echo "⚠️ gcloud 未安裝，正在安裝（約 1-2 分鐘）..."
    brew install --cask gcloud-cli < /dev/null || brew install --cask google-cloud-sdk < /dev/null || true
fi
echo -e "${GREEN}✅ gcloud 檢查完成${NC}"

echo "🔍 檢查 opencc（簡繁轉換，可選）..."
if ! command -v opencc &> /dev/null; then
    echo "⚠️ opencc 未安裝，正在安裝..."
    brew install opencc < /dev/null
fi
echo -e "${GREEN}✅ opencc 已安裝${NC}"

# ========================================
# 建立設定目錄
# ========================================

echo ""
echo "📁 建立設定目錄..."
mkdir -p "$BOTRUN_DIR"
mkdir -p "$HAMMERSPOON_DIR"

# ========================================
# 部署 Lua 腳本
# ========================================

echo "📝 部署 Lua 腳本..."

# 判斷來源：本地安裝 or curl 安裝
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/hammerspoon/botrun-hammer.lua" ]]; then
    # 本地安裝
    cp "$SCRIPT_DIR/hammerspoon/botrun-hammer.lua" "$HAMMERSPOON_DIR/botrun-hammer.lua"
else
    # curl 安裝，下載 Lua 腳本
    curl -fsSL "https://raw.githubusercontent.com/botrun/botrun-hammer/main/hammerspoon/botrun-hammer.lua" \
        -o "$HAMMERSPOON_DIR/botrun-hammer.lua"
fi

echo -e "${GREEN}✅ Lua 腳本已部署${NC}"

# ========================================
# v1.7.0: 部署本機 STT daemon scripts (mlx-whisper)
# ========================================

echo "📝 部署本機 STT daemon 腳本（mlx-whisper）..."
LWM_SCRIPT_DIR="$BOTRUN_DIR/scripts"
mkdir -p "$LWM_SCRIPT_DIR"

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/lwm_daemon.py" ]]; then
    cp "$SCRIPT_DIR/scripts/lwm_daemon.py" "$LWM_SCRIPT_DIR/lwm_daemon.py"
    cp "$SCRIPT_DIR/scripts/lwm_daemon_ctl.sh" "$LWM_SCRIPT_DIR/lwm_daemon_ctl.sh"
else
    curl -fsSL "https://raw.githubusercontent.com/botrun/botrun-hammer/main/scripts/lwm_daemon.py" \
        -o "$LWM_SCRIPT_DIR/lwm_daemon.py" || true
    curl -fsSL "https://raw.githubusercontent.com/botrun/botrun-hammer/main/scripts/lwm_daemon_ctl.sh" \
        -o "$LWM_SCRIPT_DIR/lwm_daemon_ctl.sh" || true
fi
chmod +x "$LWM_SCRIPT_DIR/lwm_daemon.py" "$LWM_SCRIPT_DIR/lwm_daemon_ctl.sh" 2>/dev/null || true

# v1.8.0: 預先確保 uv 可用（同事不需要懂 python3/venv/PEP 668/brew python）
# uv 自管 standalone Python 3.12 → brew 升版完全不影響 venv
echo "🔍 檢查 uv（Python 環境管理工具）..."
if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    echo "⚠️  uv 未安裝，自 astral.sh 下載中（< 5 秒）..."
    curl -LsSf https://astral.sh/uv/install.sh | sh < /dev/null
fi
if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
if command -v uv >/dev/null 2>&1; then
    echo -e "${GREEN}✅ uv 已就緒（$(uv --version)）${NC}"
    echo "   首次切換到本機引擎時，選單會自動執行 uv pip install mlx-whisper"
else
    echo -e "${YELLOW}⚠️  uv 安裝失敗（網路問題？），本機引擎不可用（雲端 Gemini 仍正常運作）${NC}"
    echo "   手動安裝：curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# ========================================
# 清除舊版腳本（如果存在）
# ========================================

for OLD_SCRIPT in "$HAMMERSPOON_DIR/nchc-whisper.lua" "$HAMMERSPOON_DIR/botrun-whisper.lua"; do
    if [[ -f "$OLD_SCRIPT" ]]; then
        echo "🧹 清除舊版 $(basename "$OLD_SCRIPT")..."
        rm -f "$OLD_SCRIPT"
        echo -e "${GREEN}✅ 已移除 $(basename "$OLD_SCRIPT")${NC}"
    fi
done

# 從 init.lua 移除舊的 require 引用
if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    for OLD_REQ in "nchc-whisper" "botrun-whisper"; do
        if grep -q "require(\"$OLD_REQ\")" "$HAMMERSPOON_DIR/init.lua"; then
            echo "🧹 從 init.lua 移除舊的 $OLD_REQ 引用..."
            sed -i '' "/require(\"$OLD_REQ\")/d" "$HAMMERSPOON_DIR/init.lua"
            sed -i '' "/-- .*$OLD_REQ/d" "$HAMMERSPOON_DIR/init.lua"
            echo -e "${GREEN}✅ 已清除舊版引用${NC}"
        fi
    done
fi

# ========================================
# 更新 init.lua
# ========================================

echo "📝 更新 Hammerspoon 設定..."

INIT_FILE="$HAMMERSPOON_DIR/init.lua"
REQUIRE_LINE='require("botrun-hammer")'
COMMENT_LINE='-- 波特槌 語音轉文字 (F5)'

if [[ -f "$INIT_FILE" ]]; then
    if grep -q "$REQUIRE_LINE" "$INIT_FILE"; then
        echo -e "${GREEN}✅ init.lua 已包含 波特槌${NC}"
    else
        echo "" >> "$INIT_FILE"
        echo "$COMMENT_LINE" >> "$INIT_FILE"
        echo "$REQUIRE_LINE" >> "$INIT_FILE"
        echo -e "${GREEN}✅ 已更新 init.lua${NC}"
    fi
else
    cat > "$INIT_FILE" << EOF
$COMMENT_LINE
$REQUIRE_LINE

-- 設定開機自動啟動
hs.autoLaunch(true)
EOF
    echo -e "${GREEN}✅ 已建立 init.lua${NC}"
fi

# ========================================
# 設定 Google Cloud ADC 認證（v1.10.0：永久移除 GEMINI_API_KEY）
# 公司已停用 Gemini API key（曾遭盜用），雲端轉錄一律走 ADC
# ========================================

ENV_FILE="$BOTRUN_DIR/.env"

echo ""
echo -e "${BOLD}🔑 設定 Google Cloud 認證（ADC）${NC}"
echo ""

# 初始化 .env 檔案（如果不存在）
if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

# 升級路徑：把舊版留下的 API key 清乾淨（不再使用，留著只是外洩風險）
if grep -q "^GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null; then
    sed -i '' '/^GEMINI_API_KEY/d' "$ENV_FILE"
    echo -e "${YELLOW}🧹 已移除 .env 內舊版 GEMINI_API_KEY（v1.10.0 起改用 ADC）${NC}"
    echo -e "${YELLOW}   若該 key 曾外流，建議到 Google Cloud Console 撤銷它${NC}"
fi

# 1) gcloud 是否安裝
GCLOUD_BIN=""
for p in /opt/homebrew/bin/gcloud /usr/local/bin/gcloud /usr/bin/gcloud "$HOME/google-cloud-sdk/bin/gcloud"; do
    [[ -x "$p" ]] && GCLOUD_BIN="$p" && break
done

if [[ -z "$GCLOUD_BIN" ]]; then
    echo -e "${RED}❌ 找不到 gcloud（Google Cloud SDK）${NC}"
    echo ""
    echo -e "   請執行安裝："
    echo -e "   ${BOLD}brew install --cask gcloud-cli${NC}"
    echo ""
    echo -e "   安裝後再執行："
    echo -e "   ${BOLD}gcloud auth application-default login${NC}"
    echo ""
else
    printf "%b✅ gcloud 已安裝: %s%b\n" "$GREEN" "$GCLOUD_BIN" "$NC"

    # 2) ADC 是否已登入（實際取一次 token 才算數）
    if "$GCLOUD_BIN" auth application-default print-access-token >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Google Cloud ADC 已登入${NC}"
    else
        echo -e "${YELLOW}⚠️ 尚未登入 Google Cloud ADC，語音轉文字無法使用${NC}"
        echo ""
        if [[ -t 0 ]]; then
            echo -e "   現在登入？瀏覽器會開啟 Google 授權頁面"
            read -p "   按 Enter 開始登入，或輸入 s 跳過： " ADC_CHOICE < /dev/tty
            if [[ "$ADC_CHOICE" != "s" && "$ADC_CHOICE" != "S" ]]; then
                "$GCLOUD_BIN" auth application-default login < /dev/tty || true
                if "$GCLOUD_BIN" auth application-default print-access-token >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ ADC 登入成功${NC}"
                else
                    echo -e "${RED}❌ ADC 仍未登入，之後請手動執行：${NC}"
                    echo -e "   ${BOLD}gcloud auth application-default login${NC}"
                fi
            else
                echo -e "${YELLOW}   已跳過。之後請手動執行：${NC}"
                echo -e "   ${BOLD}gcloud auth application-default login${NC}"
            fi
        else
            echo -e "   ${BOLD}gcloud auth application-default login${NC}"
        fi
    fi
fi

# 3) Vertex 專案（需有 aiplatform.endpoints.predict 權限）
if ! grep -q "^VERTEX_PROJECT=" "$ENV_FILE" 2>/dev/null; then
    echo "VERTEX_PROJECT=botrun-hammer" >> "$ENV_FILE"
fi
if ! grep -q "^VERTEX_LOCATION=" "$ENV_FILE" 2>/dev/null; then
    echo "VERTEX_LOCATION=global" >> "$ENV_FILE"
fi
# 升級路徑：舊版預設專案（botrun-chat）自動改為本案專屬專案
if grep -q "^VERTEX_PROJECT=botrun-chat$" "$ENV_FILE" 2>/dev/null; then
    sed -i '' 's|^VERTEX_PROJECT=botrun-chat$|VERTEX_PROJECT=botrun-hammer|' "$ENV_FILE"
    echo -e "${YELLOW}🔁 VERTEX_PROJECT 已更新為本案專屬專案 botrun-hammer${NC}"
fi

printf "%b   Vertex 專案: %s (可編輯 %s 更換)%b\n" "$CYAN" "$(grep '^VERTEX_PROJECT=' "$ENV_FILE" | cut -d= -f2)" "$ENV_FILE" "$NC"

# 4) 連線實測：真的打一次 Vertex AI，確認這台機器現在就能轉錄
if [[ -n "${GCLOUD_BIN:-}" ]]; then
    VP=$(grep '^VERTEX_PROJECT=' "$ENV_FILE" | cut -d= -f2)
    VL=$(grep '^VERTEX_LOCATION=' "$ENV_FILE" | cut -d= -f2)
    ADC_TOKEN=$("$GCLOUD_BIN" auth application-default print-access-token 2>/dev/null || true)
    if [[ -n "$ADC_TOKEN" ]]; then
        echo ""
        printf "🔍 實測 Vertex AI 連線: %s / %s ...\n" "$VP" "$VL"
        # ⚠️ 絕不可加 x-goog-user-project header（會被擋成 HTML 404）
        VTEST_CODE=$(curl -s -o /tmp/botrun-hammer-vertex-test.json -w '%{http_code}' \
            -X POST "https://aiplatform.googleapis.com/v1/projects/$VP/locations/$VL/publishers/google/models/gemini-3.5-flash:generateContent" \
            -H "Authorization: Bearer $ADC_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"contents":[{"role":"user","parts":[{"text":"ok"}]}],"generationConfig":{"maxOutputTokens":8}}' || echo "000")
        MY_ACCOUNT=$("$GCLOUD_BIN" config get-value account 2>/dev/null)
        if [[ "$VTEST_CODE" == "200" ]]; then
            echo -e "${GREEN}✅ Vertex AI 連線正常，語音轉文字可以直接使用${NC}"
        elif [[ "$VTEST_CODE" == "403" ]]; then
            if [[ "$MY_ACCOUNT" == *"@cameo.tw" ]]; then
                echo -e "${RED}❌ 帳號 $MY_ACCOUNT 目前無法使用 $VP${NC}"
                echo ""
                echo -e "   @cameo.tw 網域理論上已全網域授權，請把這行貼給波特槌管理者："
                echo ""
                printf "   %b波特槌 403：%s / 專案 %s%b\n" "$BOLD" "$MY_ACCOUNT" "$VP" "$NC"
            else
                echo -e "${RED}❌ 你目前登入的是個人帳號：$MY_ACCOUNT${NC}"
                echo ""
                echo -e "   波特槌已對 ${BOLD}@cameo.tw${NC} 全網域開放，請改用公司帳號重新登入："
                echo ""
                printf "   %bgcloud auth application-default login%b\n" "$BOLD" "$NC"
                echo ""
                echo -e "   （瀏覽器出現選帳號畫面時，選你的 ${BOLD}@cameo.tw${NC} 帳號）"
                echo ""
                echo -e "   若你不是 @cameo.tw 成員，請把這行貼給管理者請他開通："
                printf "   %b請幫我開通波特槌語音轉文字：%s%b\n" "$BOLD" "$MY_ACCOUNT" "$NC"
            fi
            echo ""
            echo -e "   處理後不用重裝，直接按 F5 就會通。"
        else
            echo -e "${YELLOW}⚠️ Vertex AI 連線測試回應 HTTP $VTEST_CODE${NC}"
            echo -e "   詳情：/tmp/botrun-hammer-vertex-test.json"
            echo -e "   多半是尚未登入 ADC，請執行：${BOLD}gcloud auth application-default login${NC}"
        fi
        rm -f /tmp/botrun-hammer-vertex-test.json
    fi
fi

# 移除舊版 NCHC key（如果存在）
if grep -q "NCHC_GENAI_API_KEY" "$ENV_FILE" 2>/dev/null; then
    sed -i '' '/^NCHC_GENAI_API_KEY/d' "$ENV_FILE"
fi

# ========================================
# 雲端日誌（v1.6.8+）— 自動把錄音事件送到 Cloud Logging
# 開發者用來自動抓使用者故障原因，使用者免任何操作
# 機敏邊界：只送 metadata（檔名 basename / 大小 / 時間 / pid / stderr 末段），不送錄音內容
# ========================================
DEFAULT_LOG_URL="https://botrun-hammer-logsink-257949799705.asia-east1.run.app/log"
DEFAULT_LOG_TOKEN="ed545bd2d6120b5084cc59f658e91f5cb2907b19b45a38078bd303041afc09c1"

# 升級時若 .env 已有，保留；沒有則寫入預設
if ! grep -q "^BOTRUN_HAMMER_LOG_URL=" "$ENV_FILE" 2>/dev/null; then
    echo "BOTRUN_HAMMER_LOG_URL=$DEFAULT_LOG_URL" >> "$ENV_FILE"
fi
if ! grep -q "^BOTRUN_HAMMER_LOG_TOKEN=" "$ENV_FILE" 2>/dev/null; then
    echo "BOTRUN_HAMMER_LOG_TOKEN=$DEFAULT_LOG_TOKEN" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"

# ========================================
# 啟動 Hammerspoon
# ========================================

echo ""
echo "🚀 啟動 Hammerspoon..."

# 如果已經在執行，重新載入設定
if pgrep -x "Hammerspoon" > /dev/null; then
    if command -v hs &> /dev/null; then
        hs -c "hs.reload()" 2>/dev/null &
    else
        osascript -e 'tell application "Hammerspoon" to reload config' 2>/dev/null &
    fi
    # 等最多 3 秒，不阻塞
    sleep 1
    echo -e "${GREEN}✅ Hammerspoon 已重新載入${NC}"
else
    open -a Hammerspoon
    echo -e "${GREEN}✅ Hammerspoon 已啟動${NC}"
fi

# ========================================
# 完成
# ========================================

# ========================================
# Accessibility 權限引導
# ========================================

if [[ "${NEED_ACCESSIBILITY:-}" == "1" ]]; then
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  重要：需要授權「輔助使用」權限${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "   Hammerspoon 需要「輔助使用」權限才能："
    echo -e "   • 偵測 F5/F6/F7 快捷鍵"
    echo -e "   • 轉錄完成後自動貼上文字"
    echo ""
    echo -e "${BOLD}   請在彈出的設定視窗中：${NC}"
    echo -e "   1. 找到 ${BOLD}Hammerspoon${NC}"
    echo -e "   2. ${BOLD}打開開關${NC}（切換為藍色）"
    echo ""
    echo -e "${CYAN}   正在開啟系統設定...${NC}"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    echo ""
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ 波特槌 安裝完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}使用方式：${NC}"
echo "  🎤 F5      開始/停止錄音並轉文字"
echo "  📋 F6      瀏覽轉錄文字歷史"
echo "  🎵 F7      瀏覽錄音檔案歷史"
echo ""
echo -e "${CYAN}轉錄結果會自動貼到游標位置${NC}"
echo ""
echo -e "${YELLOW}💡 提示：${NC}"
echo "   • 開機會自動啟動 Hammerspoon（選單列 🔨 圖示）"
echo "   • 首次使用需授權 Accessibility 權限"
echo ""
echo -e "${BOLD}📋 認證狀態（Google Cloud ADC）：${NC}"
echo ""
if [[ -n "${GCLOUD_BIN:-}" ]] && "$GCLOUD_BIN" auth application-default print-access-token >/dev/null 2>&1; then
    ADC_ACCOUNT=$("$GCLOUD_BIN" config get-value account 2>/dev/null)
    printf "   %b✅ ADC 已登入: %s%b\n" "$GREEN" "$ADC_ACCOUNT" "$NC"
    echo -e "   Vertex 專案：${CYAN}$(grep '^VERTEX_PROJECT=' "$ENV_FILE" | cut -d= -f2)${NC}"
    echo -e "   設定檔：${CYAN}$ENV_FILE${NC}"
else
    echo -e "   ${RED}❌ 尚未登入 Google Cloud，語音轉文字無法使用！${NC}"
    echo ""
    echo -e "   請執行以下指令："
    echo ""
    echo -e "   ${BOLD}gcloud auth application-default login${NC}"
    echo ""
    echo -e "   若還沒裝 gcloud：${BOLD}brew install --cask gcloud-cli${NC}"
    echo -e "   若出現 403 權限不足：請管理者把你加入最小權限角色"
    echo -e "   ${BOLD}projects/botrun-hammer/roles/botrunHammerPredict${NC}，"
    echo -e "   或改設定 ${BOLD}VERTEX_PROJECT${NC} 為你有權限的專案（$ENV_FILE）"
fi
echo ""
