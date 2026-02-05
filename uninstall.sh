#!/bin/bash
#
# Botrun Whisper 解除安裝腳本
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

HAMMERSPOON_DIR="$HOME/.hammerspoon"
BOTRUN_DIR="$HOME/.botrun-hammer"

echo ""
echo -e "${BOLD}🗑️ Botrun Whisper 解除安裝${NC}"
echo ""

# 移除 Lua 腳本
if [[ -f "$HAMMERSPOON_DIR/botrun-whisper.lua" ]]; then
    rm "$HAMMERSPOON_DIR/botrun-whisper.lua"
    echo -e "${GREEN}✅ 已移除 Lua 腳本${NC}"
fi

# 從 init.lua 移除載入指令
if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    # 建立備份
    cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.bak"

    # 移除相關行
    sed -i '' '/botrun-whisper/d' "$HAMMERSPOON_DIR/init.lua"
    sed -i '' '/Botrun Whisper/d' "$HAMMERSPOON_DIR/init.lua"

    echo -e "${GREEN}✅ 已更新 init.lua（備份：init.lua.bak）${NC}"
fi

# 詢問是否移除設定目錄
echo ""
if [[ -t 0 ]]; then
    # 互動模式：詢問
    read -p "是否移除設定目錄 $BOTRUN_DIR？(y/N) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$BOTRUN_DIR"
        echo -e "${GREEN}✅ 已移除設定目錄${NC}"
    else
        echo -e "${YELLOW}⚠️ 保留設定目錄（包含 API Key）${NC}"
    fi
else
    # 非互動模式：保留設定目錄
    echo -e "${YELLOW}⚠️ 非互動模式，保留設定目錄（包含 API Key）${NC}"
fi

# 重新載入 Hammerspoon（加 timeout 避免卡住）
if pgrep -x "Hammerspoon" > /dev/null; then
    if command -v hs &> /dev/null; then
        timeout 5 hs -c "hs.reload()" 2>/dev/null || true
    else
        timeout 5 osascript -e 'tell application "Hammerspoon" to reload config' 2>/dev/null || true
    fi
fi

echo ""
echo -e "${GREEN}✅ Botrun Whisper 已解除安裝${NC}"
echo ""
echo -e "${YELLOW}💡 提示：${NC}"
echo "   • Hammerspoon 本體未移除（brew uninstall --cask hammerspoon）"
echo "   • sox、jq、opencc 等工具未移除"
echo ""
