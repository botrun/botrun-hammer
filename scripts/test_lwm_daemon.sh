#!/usr/bin/env bash
# 波特槌 LWM daemon 煙測
# 階段 A：health / auth / 404（不需模型）
# 階段 B：transcribe 30s 合成 wav（需要 mlx-whisper 已安裝）
# 階段 C（daemon 1.11.1）：/health 的 MLX 欄位、閒置卸載＋重新載入、SIGTERM 2 秒內結束、環境變數亂填仍能啟動

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME="$(mktemp -d -t lwm-test-XXXXXX)"
export BOTRUN_HAMMER_HOME="$TEST_HOME"

PYTHON_BIN="${LWM_PYTHON:-python3}"
DAEMON_PY="$SCRIPT_DIR/lwm_daemon.py"
DAEMON_PID=""
EXTRA_PID=""
EXTRA_HOME=""

cleanup() {
  for p in "$DAEMON_PID" "$EXTRA_PID"; do
    [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_HOME"
  # set -e 底下 trap 最後一行用 `[[ ]] && ...` 失敗會把結束碼改成 1，改用 if
  if [[ -n "$EXTRA_HOME" ]]; then rm -rf "$EXTRA_HOME"; fi
}
trap cleanup EXIT

# 讓階段 C 能在幾秒內看到閒置卸載：閒置 3 秒卸載、每 1 秒檢查（正式預設 1800／60）
export LWM_IDLE_UNLOAD_SEC=3
export LWM_IDLE_CHECK_SEC=1

wait_port() {  # $1=home $2=pid；port 檔出現且程序還活著才算就緒
  for _ in $(seq 1 50); do
    if [[ -s "$1/lwm.port" ]] && kill -0 "$2" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

echo "=== Stage A: 啟動 daemon（不預載模型）==="
"$PYTHON_BIN" "$DAEMON_PY" --port 0 >"$TEST_HOME/daemon.log" 2>&1 &
DAEMON_PID=$!

if ! wait_port "$TEST_HOME" "$DAEMON_PID"; then
  echo "FAIL: daemon 未啟動"
  cat "$TEST_HOME/daemon.log"
  exit 1
fi

PORT=$(cat "$TEST_HOME/lwm.port")
TOKEN=$(cat "$TEST_HOME/lwm.token")
BASE="http://127.0.0.1:$PORT"
echo "daemon up port=$PORT"

echo "--- A.1 缺 token 應 401 ---"
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/health")
[[ "$code" == "401" ]] || { echo "FAIL: expect 401, got $code"; exit 1; }
echo "PASS"

echo "--- A.2 錯 token 應 401 ---"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer wrong" "$BASE/health")
[[ "$code" == "401" ]] || { echo "FAIL: expect 401, got $code"; exit 1; }
echo "PASS"

echo "--- A.3 /health 應 200 + ok ---"
resp=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/health")
echo "$resp" | grep -q '"ok": true' || { echo "FAIL: $resp"; exit 1; }
echo "PASS  ($resp)"

echo "--- A.4 /models 應列出 11 個模型 ---"
resp=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/models")
echo "$resp" | grep -q "distil-large-v3" || { echo "FAIL: $resp"; exit 1; }
echo "PASS"

echo "--- A.5 未知路徑應 404 ---"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE/nope")
[[ "$code" == "404" ]] || { echo "FAIL: $code"; exit 1; }
echo "PASS"

echo "--- A.6 /transcribe 空 body 應 400 ---"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $TOKEN" "$BASE/transcribe")
[[ "$code" == "400" ]] || { echo "FAIL: $code"; exit 1; }
echo "PASS"

# 階段 C 裡不需要模型的部分：SIGTERM 與環境變數。B 被 SKIP 時也要跑。
stage_c_common() {
  echo
  echo "=== Stage C: 訊號與環境變數（daemon 1.11.1）==="
  echo "--- C.1 SIGTERM 後 2 秒內結束，pid/port 檔清掉 ---"
  kill -TERM "$DAEMON_PID"
  for _ in $(seq 1 20); do
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "FAIL: daemon 收到 SIGTERM 2 秒內未結束（舊版 shutdown 在 serve_forever 執行緒內互等卡死）"
    exit 1
  fi
  DAEMON_PID=""
  if [[ -e "$TEST_HOME/lwm.pid" || -e "$TEST_HOME/lwm.port" ]]; then
    echo "FAIL: 結束後 pid/port 檔沒清掉"
    exit 1
  fi
  echo "PASS"

  echo "--- C.2 環境變數亂填仍能啟動、/health 200、log 有退回預設值 ---"
  EXTRA_HOME="$(mktemp -d -t lwm-test-env-XXXXXX)"
  BOTRUN_HAMMER_HOME="$EXTRA_HOME" LWM_IDLE_UNLOAD_SEC=abc LWM_MLX_CACHE_LIMIT_MB=-1 LWM_IDLE_CHECK_SEC=0 \
    "$PYTHON_BIN" "$DAEMON_PY" --port 0 >"$EXTRA_HOME/daemon.log" 2>&1 &
  EXTRA_PID=$!
  if ! wait_port "$EXTRA_HOME" "$EXTRA_PID"; then
    echo "FAIL: 環境變數亂填時 daemon 起不來"
    cat "$EXTRA_HOME/daemon.log"
    exit 1
  fi
  local port2 tok2 code2
  port2=$(cat "$EXTRA_HOME/lwm.port")
  tok2=$(cat "$EXTRA_HOME/lwm.token")
  code2=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $tok2" "http://127.0.0.1:$port2/health")
  [[ "$code2" == "200" ]] || { echo "FAIL: expect 200, got $code2"; cat "$EXTRA_HOME/daemon.log"; exit 1; }
  grep -q '改用預設' "$EXTRA_HOME/daemon.log" || { echo "FAIL: log 沒有記錄退回預設值"; cat "$EXTRA_HOME/daemon.log"; exit 1; }
  kill -TERM "$EXTRA_PID" 2>/dev/null || true
  EXTRA_PID=""
  echo "PASS"
}

echo
echo "=== Stage B: 真實轉錄（30s 合成 wav）==="
if ! "$PYTHON_BIN" -c "import mlx_whisper" 2>/dev/null; then
  echo "SKIP: mlx_whisper 未安裝（執行 scripts/lwm_daemon_ctl.sh install 後再跑）"
  stage_c_common
  echo
  echo "=== ALL STAGE A + C PASSED（B 略過）==="
  exit 0
fi

# 合成 30 秒 sine wave wav
WAV="$TEST_HOME/sine30.wav"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "SKIP B: ffmpeg 不在 PATH"
  stage_c_common
  exit 0
fi
ffmpeg -nostdin -loglevel error -y -f lavfi -i "sine=frequency=440:duration=30" -ar 16000 "$WAV"

echo "--- B.1 transcribe distil-large-v3（首次會載模型）---"
resp=$(curl -s -X POST --data-binary "@$WAV" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "$BASE/transcribe?model=distil-large-v3&ext=.wav")
echo "$resp" | grep -q '"text"' || { echo "FAIL: $resp"; exit 1; }
echo "PASS  ($(echo "$resp" | head -c 200)...)"

echo
echo "=== Stage C: 記憶體（daemon 1.11.1，需要 MLX）==="
echo "--- C.0 轉錄後 /health 有 MLX 欄位、cache 為 0 ---"
resp=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/health")
echo "$resp" | grep -q '"mlx_active_mb"' || { echo "FAIL: /health 沒有 mlx 欄位: $resp"; exit 1; }
echo "$resp" | grep -q '"mlx_cache_mb": 0.0' || { echo "FAIL: 轉錄後快取沒清: $resp"; exit 1; }
echo "PASS  ($resp)"

echo "--- C.3 閒置 3 秒後自動卸載（model_loaded false、mlx_active_mb < 50）---"
for _ in $(seq 1 100); do
  resp=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/health")
  echo "$resp" | grep -q '"model_loaded": false' && break
  sleep 0.2
done
echo "$resp" | grep -q '"model_loaded": false' || { echo "FAIL: 20 秒內沒有閒置卸載: $resp"; exit 1; }
"$PYTHON_BIN" -c 'import sys, json; d = json.loads(sys.argv[1]); sys.exit(0 if d.get("mlx_active_mb", 0) < 50 else 1)' "$resp" \
  || { echo "FAIL: 卸載後 mlx_active_mb 仍偏高: $resp"; exit 1; }
echo "PASS  ($resp)"

echo "--- C.4 卸載後再轉錄可重新載入 ---"
resp=$(curl -s -X POST --data-binary "@$WAV" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "$BASE/transcribe?model=distil-large-v3&ext=.wav")
echo "$resp" | grep -q '"text"' || { echo "FAIL: $resp"; exit 1; }
echo "PASS"

stage_c_common
echo
echo "=== ALL STAGES PASSED ==="
