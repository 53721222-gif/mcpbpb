"""Optional local HTTP/JSON API for non-MCP clients.

Endpoints:
  GET  /health
  GET  /state
  GET  /tools
  POST /action   {"action": "buy_item", "args": {"slot": 1}}
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Tuple

from .api import GameAPI
from .bridge import BridgeError
from .server import TOOLS, McpServer


class _State:
    def __init__(self) -> None:
        self.api = GameAPI()
        self.lock = threading.Lock()


_STATE = _State()


def _dispatch(action: str, args: Dict[str, Any]) -> Tuple[int, Any]:
    name = action if action.startswith("bpb_") else "bpb_" + action
    try:
        with _STATE.lock:
            server = McpServer(api=_STATE.api)
            data = server.call_tool(name, args)
        status = 200
        if isinstance(data, dict) and data.get("ok") is False:
            status = 400
        return status, data
    except BridgeError as exc:
        return 400, {"ok": False, "error": "bridge_error", "detail": exc.payload}
    except Exception as exc:  # noqa: BLE001
        return 500, {"ok": False, "error": "server_error", "message": str(exc)}


class Handler(BaseHTTPRequestHandler):
    server_version = "BackpackBattlesHTTP/0.1"

    def _write(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/health"):
            try:
                with _STATE.lock:
                    data = _STATE.api.health()
                self._write(200 if data.get("ok") else 503, data)
            except Exception as exc:  # noqa: BLE001
                self._write(503, {"ok": False, "error": "game_not_running", "message": str(exc)})
            return
        if path == "/state":
            status, data = _dispatch("get_state", {})
            self._write(status, data)
            return
        if path == "/phase":
            status, data = _dispatch("get_phase", {})
            self._write(status, data)
            return
        if path == "/tools":
            self._write(200, {"ok": True, "tools": TOOLS})
            return
        self._write(404, {"ok": False, "error": "not_found", "path": path})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/")
        if path != "/action":
            self._write(404, {"ok": False, "error": "not_found", "path": path})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._write(400, {"ok": False, "error": "bad_request", "message": str(exc)})
            return
        action = payload.get("action")
        args = payload.get("args") or {}
        if not action:
            self._write(400, {"ok": False, "error": "missing_action"})
            return
        status, data = _dispatch(str(action), args)
        self._write(status, data)

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default
        return


def serve(host: str = "127.0.0.1", port: int = 8766) -> None:
    httpd = ThreadingHTTPServer((host, port), Handler)
    print("Backpack Battles HTTP API on http://%s:%d" % (host, port), flush=True)
    print("  GET  /state", flush=True)
    print("  GET  /phase", flush=True)
    print("  POST /action  {\"action\":\"buy_item\",\"args\":{\"slot\":1}}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    serve()
