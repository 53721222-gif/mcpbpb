"""Backpack Battles MCP bridge client (TCP, newline-delimited JSON)."""
from __future__ import annotations

import json
import os
import re
import socket
import time
from typing import Any, Dict, Optional


class BridgeError(Exception):
    """The game bridge answered with ok=false."""

    def __init__(self, payload: Dict[str, Any]):
        self.payload = payload
        super().__init__(json.dumps(payload, ensure_ascii=False)[:800])


class GameNotRunning(BridgeError):
    """Could not connect to the in-game bridge."""

    def __init__(self, detail: str = ""):
        super().__init__({"ok": False, "error": "game_not_running", "detail": detail})


def _loads_tolerant(text: str) -> Any:
    # Godot's JSON.print may emit bare nan/inf in older builds; the bridge now
    # sanitizes them, but keep the client tolerant for forward compatibility.
    text = re.sub(r"(?<=[:,\[])\s*(-?inf(?:inity)?|nan)\s*(?=[,}\]])", "null", text, flags=re.I)
    return json.loads(text)


class Bridge:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 8765,
        timeout: float = 15.0,
        auto_reconnect: bool = True,
    ) -> None:
        self.host = host or os.environ.get("BPB_BRIDGE_HOST", "127.0.0.1")
        self.port = int(os.environ.get("BPB_BRIDGE_PORT", port))
        self.timeout = timeout
        self.auto_reconnect = auto_reconnect
        self._sock: Optional[socket.socket] = None
        self._file: Optional[Any] = None
        self._id = 0

    # ------------------------------------------------------------------ socket
    def connect(self, timeout: Optional[float] = None) -> None:
        self.close()
        try:
            sock = socket.create_connection((self.host, self.port), timeout=timeout or self.timeout)
        except OSError as exc:
            raise GameNotRunning("cannot connect to %s:%s (%s)" % (self.host, self.port, exc))
        sock.settimeout(timeout or self.timeout)
        self._sock = sock
        self._file = sock.makefile("rwb")

    def close(self) -> None:
        try:
            if self._file is not None:
                self._file.close()
        except Exception:
            pass
        try:
            if self._sock is not None:
                self._sock.close()
        except Exception:
            pass
        self._file = None
        self._sock = None

    def _ensure(self) -> None:
        if self._file is None:
            self.connect()

    # ---------------------------------------------------------------- requests
    def request(self, payload: Dict[str, Any], timeout: Optional[float] = None) -> Any:
        self._id += 1
        payload = dict(payload)
        payload.setdefault("id", self._id)
        line = json.dumps(payload, ensure_ascii=False) + "\n"
        last_error: Optional[Exception] = None
        attempts = 2 if self.auto_reconnect else 1
        for attempt in range(attempts):
            try:
                self._ensure()
                if timeout is not None and self._sock is not None:
                    self._sock.settimeout(timeout)
                assert self._file is not None
                self._file.write(line.encode("utf-8"))
                self._file.flush()
                raw = self._file.readline()
                if not raw:
                    raise OSError("bridge closed the connection")
                resp = _loads_tolerant(raw.decode("utf-8", "replace"))
                if not resp.get("ok"):
                    raise BridgeError(resp)
                return resp.get("result")
            except BridgeError:
                raise
            except (OSError, socket.timeout, ValueError) as exc:
                last_error = exc
                self.close()
                if attempt + 1 < attempts:
                    time.sleep(0.2)
        raise GameNotRunning("bridge request failed: %s" % (last_error,))

    # ------------------------------------------------------------------ helpers
    def ping(self) -> Dict[str, Any]:
        return self.request({"cmd": "ping"})

    def api(self, fn: str, args: Optional[Dict[str, Any]] = None) -> Any:
        return self.request({"cmd": "api", "fn": fn, "args": args or {}})

    def raw(self, cmd: str, **kwargs: Any) -> Any:
        payload = {"cmd": cmd}
        payload.update(kwargs)
        return self.request(payload)
