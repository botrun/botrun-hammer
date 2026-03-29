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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

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
    brew install --cask hammerspoon

    echo ""
    echo -e "${YELLOW}⚠️ 重要：首次使用需要授權 Accessibility 權限${NC}"
    echo "   1. 開啟「系統設定」→「隱私權與安全性」→「輔助使用」"
    echo "   2. 將 Hammerspoon 加入並打勾"
    echo ""
fi
echo -e "${GREEN}✅ Hammerspoon 已安裝${NC}"

# ========================================
# 檢查/安裝依賴工具
# ========================================

echo "🔍 檢查 ffmpeg（音訊處理工具）..."
if ! command -v ffmpeg &> /dev/null; then
    echo "⚠️ ffmpeg 未安裝，正在安裝..."
    brew install ffmpeg
fi
echo -e "${GREEN}✅ ffmpeg 已安裝${NC}"

echo "🔍 檢查 jq（JSON 解析）..."
if ! command -v jq &> /dev/null; then
    echo "⚠️ jq 未安裝，正在安裝..."
    brew install jq
fi
echo -e "${GREEN}✅ jq 已安裝${NC}"

echo "🔍 檢查 opencc（簡繁轉換，可選）..."
if ! command -v opencc &> /dev/null; then
    echo "⚠️ opencc 未安裝，正在安裝..."
    brew install opencc
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
if [[ -f "$SCRIPT_DIR/hammerspoon/botrun-hammer.lua" ]]; then
    # 本地安裝
    cp "$SCRIPT_DIR/hammerspoon/botrun-hammer.lua" "$HAMMERSPOON_DIR/botrun-hammer.lua"
else
    # curl 安裝，下載 Lua 腳本
    curl -fsSL "https://raw.githubusercontent.com/botrun/botrun-hammer/main/hammerspoon/botrun-hammer.lua" \
        -o "$HAMMERSPOON_DIR/botrun-hammer.lua"
fi

echo -e "${GREEN}✅ Lua 腳本已部署${NC}"

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
# 設定 API Key
# ========================================

ENV_FILE="$BOTRUN_DIR/.env"

echo ""
echo -e "${BOLD}🔑 設定 Gemini API Key${NC}"
echo ""

# 初始化 .env 檔案（如果不存在）
if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

if grep -q "GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null && ! grep -q "GEMINI_API_KEY=你的" "$ENV_FILE" 2>/dev/null; then
    echo -e "${GREEN}✅ Gemini API Key 已設定${NC}"
elif [[ -n "$GEMINI_API_KEY" ]]; then
    # 從環境變數讀取
    if grep -q "GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=$GEMINI_API_KEY|" "$ENV_FILE"
    else
        echo "GEMINI_API_KEY=$GEMINI_API_KEY" >> "$ENV_FILE"
    fi
    echo -e "${GREEN}✅ Gemini API Key 已從環境變數設定${NC}"
elif [[ -t 0 ]]; then
    echo ""
    echo "請輸入你的 Gemini API Key / Enter your Gemini API Key"
    echo -e "${CYAN}（免費申請 / Get free key: https://aistudio.google.com/apikey）${NC}"
    echo ""
    read -p "Gemini API Key: " GEMINI_KEY_INPUT

    if [[ -n "$GEMINI_KEY_INPUT" ]]; then
        if grep -q "GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null; then
            sed -i '' "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=$GEMINI_KEY_INPUT|" "$ENV_FILE"
        else
            echo "GEMINI_API_KEY=$GEMINI_KEY_INPUT" >> "$ENV_FILE"
        fi
        echo -e "${GREEN}✅ Gemini API Key 已儲存${NC}"
    else
        echo -e "${YELLOW}⚠️ 未設定 Gemini API Key，稍後請手動編輯：${NC}"
        echo -e "${YELLOW}   vi $ENV_FILE${NC}"
        if ! grep -q "GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null; then
            echo "GEMINI_API_KEY=你的Gemini_API_Key" >> "$ENV_FILE"
        fi
    fi
else
    echo -e "${YELLOW}⚠️ 非互動模式，跳過 API Key 設定${NC}"
    if ! grep -q "GEMINI_API_KEY" "$ENV_FILE" 2>/dev/null; then
        echo "GEMINI_API_KEY=你的Gemini_API_Key" >> "$ENV_FILE"
    fi
fi

# 移除舊版 NCHC key（如果存在）
if grep -q "NCHC_GENAI_API_KEY" "$ENV_FILE" 2>/dev/null; then
    sed -i '' '/^NCHC_GENAI_API_KEY/d' "$ENV_FILE"
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
echo -e "${BOLD}📋 API Key 設定檔位置：${NC}"
echo ""
echo -e "   ${CYAN}$ENV_FILE${NC}"
echo ""
echo -e "   內容格式："
echo -e "   ${GREEN}GEMINI_API_KEY=你的Key${NC}"
echo ""
echo -e "   免費申請：${CYAN}https://aistudio.google.com/apikey${NC}"
echo ""
