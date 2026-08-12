#!/usr/bin/env bash
# 波特槌 v1.12.0 補轉未完成錄音 — BDD E2E 驗收
#
# 對應 docs/2026-08-12_203824_v1.12.0-補轉未完成錄音-DAG.md 的場景 S1–S7
#   S1 失敗的錄音可一鍵補轉（含「文字進剪貼簿」與「不得自動貼上」）
#   S2 沒有待補轉時不打擾
#   S3 pending 不會被 FIFO 擠掉
#   S4 音檔已刪除的失敗紀錄不列入補轉
#   S5 批次補轉逐筆序列執行
#   S6 轉錄成功後在對的時機提醒（靜態檢查；需真人 F5 才看得到彈窗）
#   S7 已完成的錄音右鍵可重轉（靜態檢查；chooser 右鍵無法由 CLI 驅動）
#
# ⚠️ 這是真的 E2E：會真的送去轉錄（預設雲端 Gemini，需 ADC 已登入）。
#    測試會備份並還原 history.json，測試音檔用 macOS say 合成。
# ⚠️ S5 的批次補轉依設計會把「本機既有的待補轉錄音」也一起轉掉，
#    但結束時 history.json 會被還原 → 那些成果不會留下。
#    若你本機真的有想救回的錄音，請在測試「之後」按 F6 →「🔁 補轉」跑一次真的。
#
# 用法：bash scripts/test_retranscribe.sh

set -uo pipefail

LUA_FILE="${LUA_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hammerspoon/botrun-hammer.lua}"
HISTORY="$HOME/Library/Application Support/botrun-hammer/recordings/history.json"
WORK="$(mktemp -d -t botrun-retrans-XXXXXX)"
BACKUP="$WORK/history.backup.json"
PASS=0; FAIL=0

FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"; [ -x "$FFMPEG" ] || FFMPEG=/usr/local/bin/ffmpeg

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ·  $1"; }

# ⚠️ 地雷：Hammerspoon 首次用到某個 extension 時，會把「-- Loading extension: json」
#    這種行印進 stdout，混進取值結果（$BASE 會變成兩行）導致後面所有比較全錯。
#    一律濾掉這類行，取值才可靠。
hsc() { hs -c "$1" 2>/dev/null | grep -v '^-- Loading extension:'; }

cleanup() {
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$HISTORY"
    echo "[cleanup] history.json 已還原"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 前置：環境檢查 ==="
command -v hs >/dev/null || { echo "FAIL: 找不到 hs CLI（Hammerspoon → Enable command line tool）"; exit 1; }
VER=$(hsc 'print(_G.botrunHammer and "has-api" or "no-api")')
[ "$VER" = "has-api" ] || { echo "FAIL: Hammerspoon 未載入波特槌，或版本過舊（缺 _G.botrunHammer）"; exit 1; }
HAS_PENDING_API=$(hsc 'print(_G.botrunHammer.pendingCount and "yes" or "no")')
[ "$HAS_PENDING_API" = "yes" ] || { echo "FAIL: 目前載入的是舊版（無 pendingCount）——請先部署 v1.12.0 再測"; exit 1; }
BUSY=$(hsc 'print(tostring(botrunHammerIsBusy()))')
[ "$BUSY" = "false" ] || { echo "FAIL: 正在錄音／轉錄中，請結束後再測"; exit 1; }
info "hs CLI OK、波特槌 v1.12.0 API 就緒"

cp "$HISTORY" "$BACKUP" 2>/dev/null && info "history.json 已備份到 $BACKUP"

echo
echo "=== 前置：合成測試音檔（ground truth 可重現）==="
VOICE="Meijia"
say -v '?' 2>/dev/null | grep -qi "^$VOICE " || VOICE=$(say -v '?' | grep -iE "zh_TW|zh-TW" | head -1 | awk '{print $1}')
mk_audio() {  # $1=輸出路徑 $2=念的字
  say -v "$VOICE" -o "$WORK/tmp.aiff" "$2"
  "$FFMPEG" -y -loglevel error -i "$WORK/tmp.aiff" -c:a aac -b:a 64k "$1"
  rm -f "$WORK/tmp.aiff"
}
AUDIO_A="$WORK/retrans_a.m4a"
AUDIO_B="$WORK/retrans_b.m4a"
mk_audio "$AUDIO_A" "波特槌補轉測試第一段錄音"
mk_audio "$AUDIO_B" "波特槌補轉測試第二段錄音"
[ -s "$AUDIO_A" ] && [ -s "$AUDIO_B" ] && info "測試音檔完成（voice=${VOICE}）" || { echo "FAIL: 音檔合成失敗"; exit 1; }

BASE=$(hsc 'print(_G.botrunHammer.pendingCount())')
info "測試開始前既有 pending 數 = $BASE"

echo
echo "=== S4: 音檔已刪除的失敗紀錄不列入補轉 ==="
hsc "_G.botrunHammer.addHistory(nil, '$WORK/ghost-not-exist.m4a', 'failed')" >/dev/null
N=$(hsc 'print(_G.botrunHammer.pendingCount())')
if [ "$N" = "$BASE" ]; then ok "音檔不存在的 failed 紀錄未被列入（$N == ${BASE}）"
else bad "不該列入卻列入了（$N != ${BASE}）"; fi

echo
echo "=== S1: 失敗的錄音可一鍵補轉 ==="
hsc "_G.botrunHammer.addHistory(nil, '$AUDIO_A', 'failed')" >/dev/null
N=$(hsc 'print(_G.botrunHammer.pendingCount())')
if [ "$N" = "$((BASE+1))" ]; then ok "failed + 音檔存在 → 被列為待補轉（${N}）"
else bad "pending 數不對（期望 $((BASE+1))，實得 ${N}）"; fi

# 「不得自動貼上」的動態判別：
#   pasteText() 會在貼上後 0.5 秒把剪貼簿「還原成舊值」；
#   補轉只 setContents 不還原。所以先塞哨兵值，補轉後剪貼簿若變回哨兵 = 走了貼上路徑。
SENTINEL="SENTINEL-DO-NOT-PASTE-$$"
hsc "hs.pasteboard.setContents('$SENTINEL')" >/dev/null

hsc "print(_G.botrunHammer.retranscribe('$AUDIO_A'))" >/dev/null
info "已觸發補轉，等待完成（最多 120 秒）…"
for _ in $(seq 1 120); do
  sleep 1
  [ "$(hsc 'print(tostring(botrunHammerIsTranscribing()))')" = "false" ] && break
done
sleep 2  # 讓 pasteText 的 0.5 秒還原（若真的被呼叫）有機會發生

ST=$(hsc "print(_G.botrunHammer.historyStatusOf('$AUDIO_A'))")
STATUS=$(echo "$ST" | cut -f1); LEN=$(echo "$ST" | cut -f2)
if [ "$STATUS" = "done" ]; then ok "history 狀態 failed → done"
else bad "history 狀態應為 done，實得 '$STATUS'"; fi
if [ "${LEN:-0}" -gt 0 ]; then ok "轉錄文字非空（$LEN bytes）"
else bad "轉錄文字為空"; fi

CLIP=$(hsc 'print(hs.pasteboard.getContents())')
if [ "$CLIP" = "$SENTINEL" ]; then
  bad "剪貼簿被還原成哨兵值 → 補轉走了自動貼上路徑（違反鐵律）"
elif [ -n "$CLIP" ] && [ "$CLIP" != "nil" ]; then
  ok "文字已放進剪貼簿且未被還原 → 未自動貼上（clip=「$(echo "$CLIP" | head -c 30)…」）"
else
  bad "剪貼簿是空的，補轉沒有把文字交出來"
fi

N=$(hsc 'print(_G.botrunHammer.pendingCount())')
if [ "$N" = "$BASE" ]; then ok "補轉成功後該筆離開待補轉清單（${N}）"
else bad "補轉後 pending 應回到 ${BASE}，實得 $N"; fi

echo
echo "=== S5: 批次補轉逐筆序列執行 ==="
hsc "_G.botrunHammer.addHistory(nil, '$AUDIO_A', 'cancelled')" >/dev/null
hsc "_G.botrunHammer.addHistory(nil, '$AUDIO_B', 'failed')" >/dev/null
N=$(hsc 'print(_G.botrunHammer.pendingCount())')
if [ "$N" = "$((BASE+2))" ]; then ok "造出 2 筆待補轉（${N}）"
else bad "應為 $((BASE+2))，實得 $N"; fi

hsc 'print(_G.botrunHammer.retranscribeAll())' >/dev/null
CONCURRENT_VIOLATION=0
for _ in $(seq 1 400); do
  sleep 1
  # 序列性檢查：任何一刻最多只能有一筆處於 transcribing
  ING=$(hsc 'local n=0 for _,e in ipairs(hs.json.decode(io.open(botrunHammerHistoryFile()):read("*a")) or {}) do if e.status=="transcribing" then n=n+1 end end print(n)')
  [ "${ING:-0}" -gt 1 ] && CONCURRENT_VIOLATION=1
  [ "$(hsc 'print(tostring(_G.botrunHammer.isRetranscribing()))')" = "false" ] && break
done
sleep 2
[ "$CONCURRENT_VIOLATION" = "0" ] && ok "全程未出現 2 筆同時轉錄（序列執行）" || bad "偵測到同時 >1 筆轉錄中"

SA=$(hsc "print(_G.botrunHammer.historyStatusOf('$AUDIO_A'))" | cut -f1)
SB=$(hsc "print(_G.botrunHammer.historyStatusOf('$AUDIO_B'))" | cut -f1)
if [ "$SA" = "done" ] && [ "$SB" = "done" ]; then ok "兩筆皆補轉完成（A=$SA B=${SB}）"
else bad "批次補轉未完成（A=$SA B=${SB}）"; fi

echo
echo "=== S2: 沒有待補轉時不打擾 ==="
# 注意：retranscribeAll 依設計會清掉「全部」待補轉（含測試前既有的 $BASE 筆），
# 所以這裡的期望值是 0，不是 $BASE——批次跑完還剩東西才是 bug。
N=$(hsc 'print(_G.botrunHammer.pendingCount())')
if [ "$N" = "0" ]; then ok "批次補轉後 pending = 0 → F6 選單不會出現補轉列（零狀態不打擾）"
else bad "批次補轉後 pending 應為 0，實得 ${N}"; fi
grep -q 'if pendingCount > 0 then' "$LUA_FILE" && ok "靜態：補轉列只在 pendingCount > 0 時插入" || bad "靜態：找不到零狀態守衛"

echo
echo "=== S3: pending 不會被 FIFO 擠掉 ==="
hsc "_G.botrunHammer.addHistory(nil, '$AUDIO_B', 'failed')" >/dev/null
for i in $(seq 1 32); do
  hsc "_G.botrunHammer.addHistory('填充$i', '$WORK/filler-$i.m4a', 'done')" >/dev/null
done
ST=$(hsc "print(_G.botrunHammer.historyStatusOf('$AUDIO_B'))" | cut -f1)
if [ "$ST" = "failed" ]; then ok "灌入 32 筆新紀錄後，待補轉那筆仍在歷史中（未被 FIFO 沖掉）"
else bad "待補轉紀錄被擠掉了（status=${ST}）"; fi
N=$(hsc 'print(_G.botrunHammer.pendingCount())')
[ "${N:-0}" -ge 1 ] && ok "它仍可被補轉（pending=${N}）" || bad "它已不在待補轉清單"

echo
echo "=== S8: 批次一定會結束，不會把補轉功能鎖死 ==="
# 背景：實測發現非同步回呼偶爾會遺失，若沒有監督者，running 會永遠卡 true，
# 之後按 F6 只會看到「進行中…」，補轉功能從此按不動（比少轉一筆嚴重得多）。
R=$(hsc 'print(tostring(_G.botrunHammer.isRetranscribing()))')
if [ "$R" = "false" ]; then ok "批次結束後已釋放鎖（isRetranscribing=false）"
else bad "批次結束後 running 仍為 true → 補轉功能被鎖死"; fi
hsc "_G.botrunHammer.addHistory(nil, '$AUDIO_A', 'failed')" >/dev/null
hsc 'print(_G.botrunHammer.retranscribeAll())' >/dev/null
sleep 1
R2=$(hsc 'print(tostring(_G.botrunHammer.isRetranscribing()))')
if [ "$R2" = "true" ]; then ok "可以再次啟動新的批次（未被前一輪鎖住）"
else bad "新批次啟動失敗（可能被舊狀態擋住）"; fi
for _ in $(seq 1 120); do
  sleep 1
  [ "$(hsc 'print(tostring(_G.botrunHammer.isRetranscribing()))')" = "false" ] && break
done
[ "$(hsc 'print(tostring(_G.botrunHammer.isRetranscribing()))')" = "false" ] \
  && ok "第二輪批次也正常結束" || bad "第二輪批次卡住未結束"
grep -q 'retranscribeState.supervisor = hs.timer.doEvery' "$LUA_FILE" \
  && ok "靜態：批次監督者已就位（回呼失聯時強制推進）" || bad "靜態：找不到批次監督者"

echo
echo "=== S6/S7: 靜態檢查（UI 互動需真人操作）==="
grep -q '還有 %d 筆錄音沒轉成功' "$LUA_FILE" && ok "S6 靜態：轉錄成功後會提醒尚有待補轉" || bad "S6 靜態：找不到成功後提醒"
grep -q 'rightClickCallback' "$LUA_FILE" && ok "S7 靜態：chooser 已綁右鍵重轉（Process Again）" || bad "S7 靜態：未綁右鍵"
grep -A2 'hs.pasteboard.setContents(text)   -- ⚠️ 只複製' "$LUA_FILE" | grep -q 'pasteText' && bad "補轉路徑出現 pasteText（違反鐵律）" || ok "靜態：補轉路徑不含 pasteText"

echo
echo "================================"
echo "  通過 $PASS 項，失敗 $FAIL 項"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
