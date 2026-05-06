#!/usr/bin/env bash
# 波特槌 — lightning-whisper-mlx daemon 控制腳本
#
# 用法：
#   lwm_daemon_ctl.sh start    # 背景啟動（若已在跑則不重複起）
#   lwm_daemon_ctl.sh stop     # 停止
#   lwm_daemon_ctl.sh restart
#   lwm_daemon_ctl.sh status   # 0=running 1=down
#   lwm_daemon_ctl.sh ensure   # 沒在跑就啟動（給 lua 呼叫）
#   lwm_daemon_ctl.sh install  # pip install lightning-whisper-mlx

set -euo pipefail

CONFIG_DIR="${BOTRUN_HAMMER_HOME:-$HOME/.botrun-hammer}"
PID_FILE="$CONFIG_DIR/lwm.pid"
PORT_FILE="$CONFIG_DIR/lwm.port"
TOKEN_FILE="$CONFIG_DIR/lwm.token"
LOG_FILE="$CONFIG_DIR/lwm.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_PY="$SCRIPT_DIR/lwm_daemon.py"

# v1.7.5: 用獨立 venv 避開 PEP 668（Homebrew Python externally-managed）
VENV_DIR="$CONFIG_DIR/venv"
VENV_PY="$VENV_DIR/bin/python"

# 系統 Python：建 venv 用；不直接拿來跑 daemon
SYSTEM_PYTHON="${LWM_PYTHON:-}"
if [[ -z "$SYSTEM_PYTHON" ]]; then
  for cand in python3.12 python3.11 python3.10 python3; do
    if command -v "$cand" >/dev/null 2>&1; then
      SYSTEM_PYTHON="$cand"; break
    fi
  done
fi

# 給 daemon 用的 python：venv 優先，fallback 系統
if [[ -x "$VENV_PY" ]]; then
  PYTHON_BIN="$VENV_PY"
else
  PYTHON_BIN="$SYSTEM_PYTHON"
fi

mkdir -p "$CONFIG_DIR"

is_running() {
  if [[ ! -s "$PID_FILE" ]]; then return 1; fi
  local pid
  pid=$(cat "$PID_FILE")
  if [[ -z "$pid" ]]; then return 1; fi
  if kill -0 "$pid" 2>/dev/null; then return 0; else return 1; fi
}

cmd_status() {
  if is_running; then
    local port
    port=$(cat "$PORT_FILE" 2>/dev/null || echo "?")
    echo "running pid=$(cat "$PID_FILE") port=$port"
    return 0
  fi
  echo "down"
  return 1
}

cmd_start() {
  if is_running; then
    echo "already running"
    cmd_status
    return 0
  fi
  if [[ -z "$PYTHON_BIN" ]]; then
    echo "ERROR: python3 not found. Install Python 3.10+." >&2
    return 2
  fi
  if [[ ! -x "$VENV_PY" ]]; then
    echo "ERROR: venv not yet created. Run: $0 install" >&2
    return 6
  fi
  if ! "$PYTHON_BIN" -c "import mlx_whisper" 2>/dev/null; then
    echo "ERROR: mlx_whisper not installed in venv. Run: $0 install" >&2
    return 3
  fi
  echo "starting daemon (python=$PYTHON_BIN)..."
  # v1.7.6: Hammerspoon spawn 的 daemon 預設 PATH 不含 /opt/homebrew/bin，
  # 但 lightning-whisper-mlx 內部會 subprocess 呼叫 ffmpeg —— 補進去
  export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$PATH"
  nohup "$PYTHON_BIN" "$DAEMON_PY" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  # 等 PORT_FILE 出現（最多 5 秒）
  for _ in $(seq 1 50); do
    if [[ -s "$PORT_FILE" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "started pid=$pid port=$(cat "$PORT_FILE")"
      return 0
    fi
    sleep 0.1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: daemon failed to start. tail $LOG_FILE" >&2
    tail -20 "$LOG_FILE" >&2 || true
    return 4
  fi
  echo "started pid=$pid (port file pending)"
}

cmd_stop() {
  if ! is_running; then
    echo "not running"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  echo "stopping pid=$pid..."
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE" "$PORT_FILE"
      echo "stopped"
      return 0
    fi
    sleep 0.1
  done
  echo "WARN: TERM timeout, sending KILL"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_FILE" "$PORT_FILE"
}

cmd_ensure() {
  if is_running; then
    return 0
  fi
  cmd_start
}

cmd_install() {
  if [[ -z "$SYSTEM_PYTHON" ]]; then
    echo "ERROR: python3 not found. Install with: brew install python@3.12" >&2
    return 2
  fi
  # v1.7.5: 用 venv 安裝避開 PEP 668（Homebrew Python externally-managed-environment）
  if [[ ! -x "$VENV_PY" ]]; then
    echo "[1/3] 建立 venv: $VENV_DIR (使用 $SYSTEM_PYTHON)..."
    "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
  else
    echo "[1/3] venv 已存在: $VENV_DIR"
  fi
  if [[ ! -x "$VENV_PY" ]]; then
    echo "ERROR: venv 建立失敗" >&2
    return 5
  fi
  echo "[2/3] 升級 pip..."
  "$VENV_PY" -m pip install --upgrade pip wheel setuptools 2>&1 | grep -E "^(Collecting|Downloading|Installing|Successfully|ERROR)" || true
  echo "[3/3] Collecting mlx-whisper（含 mlx + transformers，約 1GB，1-3 分鐘）..."
  "$VENV_PY" -m pip install mlx-whisper
  echo "驗證: $VENV_PY -c 'import mlx_whisper'"
  "$VENV_PY" -c "import mlx_whisper; print('Successfully installed and importable')"
}

cmd_token() {
  if [[ -s "$TOKEN_FILE" ]]; then
    cat "$TOKEN_FILE"
  else
    echo "ERROR: token not yet generated; run start first" >&2
    return 1
  fi
}

cmd_port() {
  if [[ -s "$PORT_FILE" ]]; then
    cat "$PORT_FILE"
  else
    echo "ERROR: port file missing; daemon not running?" >&2
    return 1
  fi
}

main() {
  local cmd="${1:-status}"
  case "$cmd" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status)  cmd_status ;;
    ensure)  cmd_ensure ;;
    install) cmd_install ;;
    token)   cmd_token ;;
    port)    cmd_port ;;
    *)
      echo "usage: $0 {start|stop|restart|status|ensure|install|token|port}" >&2
      return 2
      ;;
  esac
}

main "$@"
