#!/usr/bin/env bash
# 波特槌 — mlx-whisper daemon 控制腳本
#
# 用法：
#   lwm_daemon_ctl.sh start    # 背景啟動（若已在跑則不重複起）
#   lwm_daemon_ctl.sh stop     # 停止
#   lwm_daemon_ctl.sh restart
#   lwm_daemon_ctl.sh status   # 0=running 1=down
#   lwm_daemon_ctl.sh ensure   # 沒在跑就啟動（給 lua 呼叫）
#   lwm_daemon_ctl.sh install  # pip install mlx-whisper

set -euo pipefail

CONFIG_DIR="${BOTRUN_HAMMER_HOME:-$HOME/.botrun-hammer}"
PID_FILE="$CONFIG_DIR/lwm.pid"
PORT_FILE="$CONFIG_DIR/lwm.port"
TOKEN_FILE="$CONFIG_DIR/lwm.token"
LOG_FILE="$CONFIG_DIR/lwm.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_PY="$SCRIPT_DIR/lwm_daemon.py"

# v1.7.5: 用獨立 venv 避開 PEP 668（Homebrew Python externally-managed）
# v1.8.0: 改用 uv 自管 standalone Python，避開 brew Python 升版打爆 venv
VENV_DIR="$CONFIG_DIR/venv"
VENV_PY="$VENV_DIR/bin/python"

# v1.8.0: 不再用 system python 偵測 — uv venv 直接用 uv-managed standalone interpreter，
# 完全避開 v1.7.16 那個「找到 uv shim 建 venv 後 base_prefix=/install 導致 pip 崩」的雷
# （ChialoLee 2026-05-07 18:32 在另一台機器踩到的真實 case，就是 v1.8.0 想根治的問題）

# v1.11.2: 機器原生架構（arm64 / x86_64）——
# 地雷：anaconda 等會把「x86_64 版 uv」塞在 PATH 最前面，Apple Silicon 上
# 用它建 venv 會得到 x86_64 Python → mlx 只出 arm64 wheel → 安裝必炸。
# 因此 uv 一律挑「架構跟機器一致」的那顆，而不是 PATH 上第一顆。
NATIVE_ARCH="$(uname -m)"

# 檢查某執行檔的架構是否符合機器原生架構
is_native_binary() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  file "$bin" 2>/dev/null | grep -q "$NATIVE_ARCH"
}

# 挑 uv：掃常見安裝位置＋PATH，優先取原生架構那顆；找不到原生的才退而求其次
UV_BIN=""
pick_uv() {
  local candidates=(
    "/opt/homebrew/bin/uv"
    "/usr/local/bin/uv"
    "$HOME/.local/bin/uv"
    "$HOME/.cargo/bin/uv"
  )
  local from_path
  from_path="$(command -v uv 2>/dev/null || true)"
  [[ -n "$from_path" ]] && candidates+=("$from_path")

  local c
  for c in "${candidates[@]}"; do
    if is_native_binary "$c"; then UV_BIN="$c"; return 0; fi
  done
  # 沒有原生架構的 uv：退回任何一顆可執行的（至少 Intel 機器仍可動）
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then UV_BIN="$c"; return 0; fi
  done
  return 1
}

# 安裝 uv（沒裝就裝；astral 官方安裝器一定裝原生架構版；KISS，無 brew/pip 介入）
ensure_uv_installed() {
  if pick_uv && is_native_binary "$UV_BIN"; then return 0; fi
  echo "[uv] 未安裝原生架構版（${NATIVE_ARCH}），自 astral.sh 下載中..."
  if curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
    pick_uv
    return $?
  fi
  # 下載失敗但至少有非原生 uv 可用
  pick_uv
}

# 偵測既有 venv 是否為 uv 管理（symlink 指向 ~/.local/share/uv/python/...）
is_uv_managed_venv() {
  # uv venv: bin/python 為絕對 symlink，指向 ~/.local/share/uv/python/cpython-X.Y.Z-.../bin/pythonX.Y
  local link
  link=$(readlink "$VENV_DIR/bin/python" 2>/dev/null || echo "")
  [[ "$link" == *"/uv/python/"* ]] || [[ "$link" == *"share/uv/"* ]]
}

# venv 的 Python 架構是否跟機器一致（x86_64 venv 在 Apple Silicon 上裝不了 mlx）
venv_arch_matches() {
  local real
  real="$(readlink -f "$VENV_PY" 2>/dev/null || echo "$VENV_PY")"
  is_native_binary "$real"
}

# Python 偵測（只用於 daemon 執行；建 venv 一律走 uv）
pick_uv || true
PYTHON_BIN="$VENV_PY"
[[ -x "$PYTHON_BIN" ]] || PYTHON_BIN=""

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
  if [[ ! -x "$VENV_PY" ]]; then
    echo "ERROR: venv not yet created. Run: $0 install" >&2
    return 6
  fi
  PYTHON_BIN="$VENV_PY"
  if ! "$PYTHON_BIN" -c "import mlx_whisper" 2>/dev/null; then
    echo "ERROR: mlx_whisper not installed in venv. Run: $0 install" >&2
    return 3
  fi
  echo "starting daemon (python=$PYTHON_BIN)..."
  # v1.7.6: Hammerspoon spawn 的 daemon 預設 PATH 不含 /opt/homebrew/bin，
  # 但 mlx-whisper 內部會 subprocess 呼叫 ffmpeg —— 補進去
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
  # v1.8.0: uv-first，標準 Python 3.12 standalone interpreter，避 brew 升版斷 venv
  if ! ensure_uv_installed; then
    echo "ERROR: uv 安裝失敗（網路問題？）。手動安裝: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    return 2
  fi
  echo "[1/4] uv: $UV_BIN ($("$UV_BIN" --version))"

  # 既有 venv 需重建的兩種情況：
  #   (a) 非 uv-managed（舊版 brew python 建的，brew 升版會斷）
  #   (b) v1.11.2: 架構不符（anaconda x86_64 uv 在 Apple Silicon 建出 x86_64 venv）
  if [[ -d "$VENV_DIR" ]] && { ! is_uv_managed_venv || ! venv_arch_matches; }; then
    local backup="${VENV_DIR}.bak-$(date +%Y%m%d%H%M%S)"
    echo "[migrate] 既有 venv 非 uv-managed 或架構非 ${NATIVE_ARCH}，備份至 $backup"
    mv "$VENV_DIR" "$backup"
  fi

  if [[ ! -x "$VENV_PY" ]]; then
    echo "[2/4] uv venv --python 3.12 $VENV_DIR..."
    "$UV_BIN" venv --python 3.12 "$VENV_DIR"
  else
    echo "[2/4] venv 已是 uv-managed: $VENV_DIR"
  fi
  if [[ ! -x "$VENV_PY" ]]; then
    echo "ERROR: venv 建立失敗" >&2
    return 5
  fi

  echo "[3/4] uv pip install mlx-whisper（含 mlx + torch，首次約 1 分鐘）..."
  "$UV_BIN" pip install --python "$VENV_PY" mlx-whisper

  echo "[4/4] 驗證 import..."
  "$VENV_PY" -c "import mlx_whisper; print('Successfully installed and importable')"
}

# v1.11.2: Breeze-ASR 全精度 backend 依賴（transformers + torch + accelerate，~3GB）
# 獨立指令：不強迫只用雲端/whisper 的使用者吃這包
cmd_install_breeze() {
  if ! ensure_uv_installed; then
    echo "ERROR: uv 不可用" >&2
    return 2
  fi
  if [[ ! -x "$VENV_PY" ]]; then
    echo "[breeze] venv 不存在，先跑基本安裝..."
    cmd_install
  fi
  echo "[breeze] uv pip install transformers torch accelerate..."
  "$UV_BIN" pip install --python "$VENV_PY" transformers torch accelerate
  "$VENV_PY" -c "import transformers, torch; print('breeze deps OK, torch', torch.__version__, 'mps:', torch.backends.mps.is_available())"
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
    install-breeze) cmd_install_breeze ;;
    token)   cmd_token ;;
    port)    cmd_port ;;
    *)
      echo "usage: $0 {start|stop|restart|status|ensure|install|token|port}" >&2
      return 2
      ;;
  esac
}

main "$@"
