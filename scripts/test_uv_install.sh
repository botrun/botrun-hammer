#!/usr/bin/env bash
# 波特槌 — uv venv E2E 驗證腳本（v1.8.0+）
#
# 目的：驗證在乾淨環境下，透過 uv 自管 Python 3.12 → 建 venv → 裝 mlx-whisper
#       → 啟 daemon → 真實轉錄 large-v3-turbo 全程綠燈，且**完全不動**
#       現有 ~/.botrun-hammer/venv 與正在跑的 daemon。
#
# 用法：
#   bash scripts/test_uv_install.sh
#
# 退出碼：0=PASS, 非 0=FAIL（會印明確錯誤訊息）

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d -t lwm-uv-e2e-XXXXXX)"
TEST_HOME="$(mktemp -d -t lwm-uv-home-XXXXXX)"
DPID=""

cleanup() {
  if [[ -n "$DPID" ]]; then kill -TERM "$DPID" 2>/dev/null || true; fi
  rm -rf "$TEST_DIR" "$TEST_HOME"
}
trap cleanup EXIT

echo "=== Step 1: uv 是否可用 ==="
if ! command -v uv >/dev/null 2>&1; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  else
    echo "[install] 安裝 uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
uv --version

echo ""
echo "=== Step 2: uv python install 3.12 ==="
uv python install 3.12 2>&1 | tail -3

echo ""
echo "=== Step 3: 建獨立 venv (不動 ~/.botrun-hammer/venv) ==="
uv venv --python 3.12 "$TEST_DIR/venv"
VENV_PY="$TEST_DIR/venv/bin/python"
"$VENV_PY" --version
LINK=$(readlink "$TEST_DIR/venv/bin/python" 2>/dev/null || echo "")
if [[ "$LINK" != *"/uv/python/"* ]] && [[ "$LINK" != *"share/uv/"* ]]; then
  echo "FAIL: venv python 未指向 uv 自管路徑（讀到: $LINK）" >&2
  exit 1
fi
echo "PASS  venv 為 uv-managed: $LINK"

echo ""
echo "=== Step 4: uv pip install mlx-whisper ==="
uv pip install --python "$VENV_PY" mlx-whisper 2>&1 | tail -5
"$VENV_PY" -c "import mlx_whisper; print('mlx_whisper import OK')"

echo ""
echo "=== Step 5: 啟 daemon (port 0 隨機，獨立 BOTRUN_HAMMER_HOME) ==="
export BOTRUN_HAMMER_HOME="$TEST_HOME"
"$VENV_PY" "$SCRIPT_DIR/lwm_daemon.py" --port 0 >"$TEST_HOME/daemon.log" 2>&1 &
DPID=$!
for _ in $(seq 1 50); do
  [[ -s "$TEST_HOME/lwm.port" ]] && kill -0 "$DPID" 2>/dev/null && break
  sleep 0.1
done
if ! kill -0 "$DPID" 2>/dev/null; then
  echo "FAIL: daemon 未啟動" >&2
  cat "$TEST_HOME/daemon.log" >&2
  exit 1
fi
PORT=$(cat "$TEST_HOME/lwm.port")
TOKEN=$(cat "$TEST_HOME/lwm.token")
echo "PASS  daemon up port=$PORT pid=$DPID"

echo ""
echo "=== Step 6: 健康檢查 ==="
RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")
echo "$RESP" | grep -q '"ok": true' || { echo "FAIL: $RESP" >&2; exit 1; }
echo "PASS  $RESP"

echo ""
echo "=== Step 7: 合成 5s 測試音檔 ==="
WAV="$TEST_HOME/test.wav"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "SKIP: ffmpeg 不可用（同事機器要 brew install ffmpeg）"
  exit 0
fi
ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 16000 -ac 1 "$WAV" -y 2>/dev/null
ls -lh "$WAV"

echo ""
echo "=== Step 8: 用 large-v3-turbo 轉錄 ==="
RESP=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  --data-binary @"$WAV" \
  "http://127.0.0.1:$PORT/transcribe?model=large-v3-turbo&lang=zh&ext=.wav")
echo "$RESP" | grep -q '"latency_ms"' || { echo "FAIL: $RESP" >&2; exit 1; }
echo "PASS  $RESP"

echo ""
echo "=================================="
echo "✅ uv E2E ALL PASSED — 同事可放心安裝"
echo "=================================="
