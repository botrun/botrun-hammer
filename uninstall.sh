#!/bin/bash
#
# 波特槌 解除安裝腳本
#

set -e

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 路徑
HAMMERSPOON_DIR="$HOME/.hammerspoon"
BOTRUN_DIR="$HOME/.botrun-hammer"
RECORDINGS_DIR="$HOME/Documents/botrun-hammer-recordings"

echo ""
echo -e "${BOLD}🗑️  波特槌 解除安裝${NC}"
echo -e "${CYAN}   將移除波特槌語音轉文字工具${NC}"
echo ""

# ========================================
# 確認
# ========================================

if [[ -t 0 ]]; then
    echo -e "${YELLOW}⚠️  即將解除安裝 波特槌，此操作無法復原${NC}"
    echo ""
    read -p "確定要繼續嗎？(y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${CYAN}已取消解除安裝${NC}"
        echo ""
        exit 0
    fi
    echo ""
fi

# ========================================
# 移除 Lua 腳本
# ========================================

echo "📝 移除 Lua 腳本..."

for SCRIPT_NAME in "botrun-hammer.lua" "botrun-whisper.lua"; do
    if [[ -f "$HAMMERSPOON_DIR/$SCRIPT_NAME" ]]; then
        rm "$HAMMERSPOON_DIR/$SCRIPT_NAME"
        echo -e "${GREEN}✅ 已移除 $SCRIPT_NAME${NC}"
    fi
done

# 移除舊版腳本
if [[ -f "$HAMMERSPOON_DIR/nchc-whisper.lua" ]]; then
    rm "$HAMMERSPOON_DIR/nchc-whisper.lua"
    echo -e "${GREEN}✅ 已移除 nchc-whisper.lua（舊版）${NC}"
fi

# ========================================
# 從 init.lua 移除載入指令
# ========================================

echo "📝 更新 Hammerspoon 設定..."

if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    # 建立備份
    cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.bak"

    # 移除 botrun-hammer / botrun-whisper 相關行
    sed -i '' '/require("botrun-hammer")/d' "$HAMMERSPOON_DIR/init.lua"
    sed -i '' '/require("botrun-whisper")/d' "$HAMMERSPOON_DIR/init.lua"
    sed -i '' '/波特槌/d' "$HAMMERSPOON_DIR/init.lua"
    sed -i '' '/波特槌/d' "$HAMMERSPOON_DIR/init.lua"

    # 移除 nchc-whisper 相關行（舊版）
    sed -i '' '/require("nchc-whisper")/d' "$HAMMERSPOON_DIR/init.lua"
    sed -i '' '/NCHC Whisper/d' "$HAMMERSPOON_DIR/init.lua"

    echo -e "${GREEN}✅ 已更新 init.lua（備份：init.lua.bak）${NC}"
else
    echo -e "${CYAN}   init.lua 不存在，跳過${NC}"
fi

# ========================================
# 移除設定目錄
# ========================================

echo ""
if [[ -d "$BOTRUN_DIR" ]]; then
    if [[ -t 0 ]]; then
        read -p "是否移除設定目錄 $BOTRUN_DIR？（包含 API Key）(y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$BOTRUN_DIR"
            echo -e "${GREEN}✅ 已移除設定目錄${NC}"
        else
            echo -e "${YELLOW}⚠️  保留設定目錄${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  非互動模式，保留設定目錄 $BOTRUN_DIR${NC}"
    fi
else
    echo -e "${CYAN}   設定目錄不存在，跳過${NC}"
fi

# ========================================
# 移除錄音目錄
# ========================================

if [[ -d "$RECORDINGS_DIR" ]]; then
    if [[ -t 0 ]]; then
        read -p "是否移除錄音目錄 $RECORDINGS_DIR？(y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$RECORDINGS_DIR"
            echo -e "${GREEN}✅ 已移除錄音目錄${NC}"
        else
            echo -e "${YELLOW}⚠️  保留錄音目錄${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  非互動模式，保留錄音目錄 $RECORDINGS_DIR${NC}"
    fi
fi

# ========================================
# 重新載入 Hammerspoon
# ========================================

if pgrep -x "Hammerspoon" > /dev/null; then
    echo ""
    echo "🔄 重新載入 Hammerspoon..."
    if command -v hs &> /dev/null; then
        timeout 5 hs -c "hs.reload()" 2>/dev/null || true
    else
        timeout 5 osascript -e 'tell application "Hammerspoon" to reload config' 2>/dev/null || true
    fi
fi

# ========================================
# 完成
# ========================================

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ 波特槌 已解除安裝${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}💡 提示：${NC}"
echo "   • Hammerspoon 本體未移除（brew uninstall --cask hammerspoon）"
echo "   • ffmpeg、jq、opencc 等工具未移除"
echo ""
