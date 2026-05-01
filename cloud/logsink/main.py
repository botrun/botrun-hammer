"""botrun-hammer logsink — 收 client 端 heartbeat / error 事件寫進 Cloud Logging。

部署在 botrun-c project。客戶端用 Bearer token 認證；token 從 Secret Manager 注入到
LOG_TOKEN 環境變數。

POST /log
  Headers: Authorization: Bearer <token>
  Body: JSON object，建議欄位：
    {
      "event": "heartbeat" | "start" | "stop" | "exit" | "error" | ...,
      "version": "1.6.8",
      "hostname": "<machine identifier>",
      "elapsed_s": 1234.5,
      "file_size": 8388608,
      ...任何結構化欄位
    }
  Response: 204 No Content（成功）/ 401 / 400

GET /healthz → 200 ok

設計原則：
  - 永不回傳大 body（client 跑在 hs.task curl 不關心 body）
  - severity 從 body.severity 取（INFO/WARNING/ERROR），預設 INFO
  - logName 固定 botrun-hammer，labels 帶 hostname/version/event 方便 filter
  - 只接受 application/json + 大小 < 64KB
"""
from __future__ import annotations

import os
import logging as stdlogging
from flask import Flask, request

from google.cloud import logging as cloud_logging

stdlogging.basicConfig(level=stdlogging.INFO)
log = stdlogging.getLogger("logsink")

LOG_TOKEN = os.environ.get("LOG_TOKEN", "")
if not LOG_TOKEN:
    log.warning("LOG_TOKEN 未設定 — 服務會拒絕所有請求")

MAX_BODY_BYTES = 64 * 1024
LOGGER_NAME = "botrun-hammer"
ALLOWED_SEVERITY = {"DEFAULT", "DEBUG", "INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL"}

_client = cloud_logging.Client()
_logger = _client.logger(LOGGER_NAME)

app = Flask(__name__)


@app.route("/healthz", methods=["GET"])
@app.route("/", methods=["GET"])
def healthz():
    return ("ok", 200, {"Content-Type": "text/plain"})


@app.route("/log", methods=["POST"])
def ingest():
    if not LOG_TOKEN:
        return ("LOG_TOKEN 未設定", 503, {"Content-Type": "text/plain"})

    auth = request.headers.get("Authorization", "")
    expected = f"Bearer {LOG_TOKEN}"
    if auth != expected:
        return ("unauthorized", 401, {"Content-Type": "text/plain"})

    if request.content_length and request.content_length > MAX_BODY_BYTES:
        return ("payload too large", 413, {"Content-Type": "text/plain"})

    try:
        data = request.get_json(silent=False, force=True)
    except Exception as exc:
        log.info("bad json: %s", exc)
        return ("bad json", 400, {"Content-Type": "text/plain"})

    if not isinstance(data, dict):
        return ("body must be JSON object", 400, {"Content-Type": "text/plain"})

    severity = str(data.pop("severity", "INFO")).upper()
    if severity not in ALLOWED_SEVERITY:
        severity = "INFO"

    labels = {
        "hostname": str(data.get("hostname", "unknown"))[:128],
        "computer_name": str(data.get("computer_name", "unknown"))[:128],
        "machine_id": str(data.get("machine_id", "unknown"))[:64],
        "os_user": str(data.get("os_user", "unknown"))[:64],
        "version": str(data.get("version", "unknown"))[:32],
        "event": str(data.get("event", "unknown"))[:64],
    }

    try:
        _logger.log_struct(data, severity=severity, labels=labels)
    except Exception as exc:
        log.exception("cloud logging write failed")
        return ("logging backend error", 502, {"Content-Type": "text/plain"})

    return ("", 204)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
