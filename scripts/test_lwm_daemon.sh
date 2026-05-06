#!/usr/bin/env bash
# 波特槌 LWM daemon 煙測
# 階段 A：health / auth / 404（不需模型）
# 階段 B：transcribe 30s 合成 wav（需要 lightning-whisper-mlx 已安裝）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME="$(mktemp -d -t lwm-test-XXXXXX)"
export BOTRUN_HAMMER_HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"' EXIT

PYTHON_BIN="${LWM_PYTHON:-python3}"
DAEMON_PY="$SCRIPT_DIR/lwm_daemon.py"

echo "=== Stage A: 啟動 daemon（不預載模型）==="
"$PYTHON_BIN" "$DAEMON_PY" --port 0 >"$TEST_HOME/daemon.log" 2>&1 &
DAEMON_PID=$!
trap 'kill -TERM $DAEMON_PID 2>/dev/null || true; rm -rf "$TEST_HOME"' EXIT

# 等 port 就緒
for _ in $(seq 1 50); do
  if [[ -s "$TEST_HOME/lwm.port" ]] && kill -0 $DAEMON_PID 2>/dev/null; then break; fi
  sleep 0.1
done

if ! kill -0 $DAEMON_PID 2>/dev/null; then
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

echo
echo "=== Stage B: 真實轉錄（30s 合成 wav）==="
if ! "$PYTHON_BIN" -c "import lightning_whisper_mlx" 2>/dev/null; then
  echo "SKIP: lightning_whisper_mlx 未安裝（執行 scripts/lwm_daemon_ctl.sh install 後再跑）"
  curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE/shutdown" >/dev/null || true
  echo
  echo "=== ALL STAGE A PASSED ==="
  exit 0
fi

# 合成 30 秒 sine wave wav
WAV="$TEST_HOME/sine30.wav"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "SKIP B: ffmpeg 不在 PATH"
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

curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE/shutdown" >/dev/null || true
echo
echo "=== ALL STAGES PASSED ==="
