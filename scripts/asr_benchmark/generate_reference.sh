#!/usr/bin/env bash
# 用 macOS `say` 合成繁中 25s 基準音檔
# 為何用合成：ground truth 100% 確定，未來換引擎跑同一份就有答案
# Why not 人聲：人聲一次性、不可重現；CI 跑不動
set -euo pipefail
cd "$(dirname "$0")"

VOICE="${VOICE:-Meijia}"  # macOS 內建台灣繁中女聲；若無 fallback Sinji
RATE="${RATE:-180}"        # 字/分鐘；180 ≈ 自然語速，控制總長 ~25s
TXT="reference_zh_25s.txt"
AIFF="reference_zh_25s.aiff"
WAV="reference_zh_25s.wav"

# 若 Meijia 不存在，列出可用中文聲音給使用者選
if ! say -v '?' 2>/dev/null | grep -qi "^$VOICE "; then
  echo "[WARN] 找不到語音 '$VOICE'，可用繁中聲音："
  say -v '?' | grep -iE "zh_TW|zh-TW|Meijia|Sinji" || say -v '?' | grep -i zh
  VOICE=$(say -v '?' | grep -iE "zh_TW|zh-TW" | head -1 | awk '{print $1}')
  echo "[INFO] fallback to: $VOICE"
fi

echo "[INFO] 合成中... voice=$VOICE rate=$RATE"
say -v "$VOICE" -r "$RATE" -f "$TXT" -o "$AIFF"

# 轉 16kHz mono wav（whisper / mlx-vlm 都吃）
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
[ -x "$FFMPEG" ] || FFMPEG=/usr/local/bin/ffmpeg
"$FFMPEG" -y -i "$AIFF" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV" 2>&1 | tail -3
rm -f "$AIFF"

DURATION=$("$FFMPEG" -i "$WAV" 2>&1 | grep -oE "Duration: [0-9:.]+" | head -1)
echo "[OK] $WAV $DURATION"
echo "[INFO] 若長度 > 30s 或 < 20s，調整 RATE 環境變數重跑（目前 RATE=$RATE）"
