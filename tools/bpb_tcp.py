"""Minimal client for the Backpack Battles in-game TCP bridge."""
import socket, json, time, re


class BridgeError(Exception):
    def __init__(self, payload):
        self.payload = payload
        super().__init__(json.dumps(payload, ensure_ascii=False)[:800])


def loads_tolerant(text):
    """Godot's JSON.print emits bare nan/inf, which is not valid JSON."""
    text = re.sub(r"(?<=[:,\[])\s*(-?inf(?:inity)?|nan)\s*(?=[,}\]])", "null", text, flags=re.I)
    return json.loads(text)


class Bridge:
    def __init__(self, host="127.0.0.1", port=8765, timeout=15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.file = self.sock.makefile("rwb")
        self._id = 0

    def request(self, cmd, **kw):
        self._id += 1
        payload = {"id": self._id, "cmd": cmd}
        payload.update(kw)
        self.file.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        self.file.flush()
        line = self.file.readline()
        if not line:
            raise BridgeError({"ok": False, "error": "connection_closed"})
        resp = loads_tolerant(line.decode("utf-8"))
        if not resp.get("ok"):
            raise BridgeError(resp)
        return resp.get("result")

    def run(self, source, **kw):
        """Execute `source` in the game. It must extend Reference and define run(ctx)."""
        return self.request("run", source=source, **kw)

    def close(self):
        try:
            self.file.close()
            self.sock.close()
        except Exception:
            pass


if __name__ == "__main__":
    b = Bridge()
    print("ping:", b.request("ping"))
    print("globals:", json.dumps(b.request("globals"), ensure_ascii=False, indent=2)[:2000])
    print("run:", b.run("extends Reference\nfunc run(ctx):\n\treturn {\"sum\": 1 + 2, \"scene\": str(ctx.scene)}\n"))
    b.close()
