"""Offline tests: override.cfg merging and MCP protocol framing/dispatch."""
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bpb_mcp.installer import _merge_override, _remove_override
from bpb_mcp.server import McpServer, TOOLS


class FakeAPI:
    def state(self):
        return {
            "state": "shop",
            "round": 1,
            "gold": 10,
            "class": {"id": 0, "name": "Ranger"},
            "backpack": {"width": 9, "height": 7, "bags": [], "items": [], "grid": []},
            "shop": {"items": [], "reroll_cost": 1, "rerolls": 0, "items_bought": 0},
            "storage": [],
        }

    def health(self):
        return {"ok": True, "game_state": "shop"}

    def phase(self):
        return {"ok": True, "state": "shop", "round": 1, "tries": 5, "gold": 10,
                "can_skip_result": False, "last_result": None}

    def buy_item(self, slot=None, item_id=None):
        return {"ok": True, "slot": slot, "item_id": item_id}

    def refresh_shop(self):
        return {"ok": True, "cost": 1}

    def sell_item(self, item_id):
        return {"ok": True, "sold": True, "item_id": item_id, "gold_gained": 2}

    def set_fusion_lock(self, item_id, locked=True):
        return {"ok": True, "item_id": item_id, "fusion_locked": bool(locked),
                "previous_fusion_locked": not bool(locked), "changed": True}

    def socket_gem(self, host_id, gem_id, socket_index=0):
        return {"ok": True, "host_id": host_id, "gem_id": gem_id,
                "socket_index": socket_index, "socketed": True}

    def unsocket_gem(self, host_id, socket_index=0):
        return {"ok": True, "host_id": host_id, "socket_index": socket_index,
                "unsocketed": True}

    def set_edit_mode(self, mode="default"):
        return {"ok": True, "mode": mode}

    def edit_items(self):
        return self.set_edit_mode("items")

    def edit_bags(self):
        return self.set_edit_mode("bags")

    def edit_all(self):
        return self.set_edit_mode("all")

    def set_class(self, class_id=0, loadout=0):
        return {"ok": True, "class": class_id, "loadout": loadout}

    def set_loadout(self, loadout=0):
        return {"ok": True, "loadout": loadout}

    def enter_survival(self):
        return {"ok": True, "choice": "survival"}

    def stop_here(self):
        return {"ok": True, "choice": "stop"}

    def choose_survival(self, choice="survival"):
        return {"ok": True, "choice": choice}

    def start_battle(self):
        return {"ok": True, "state": "combat"}

    def skip_result(self):
        return {"ok": True}


class TestOverrideMerge(unittest.TestCase):
    def test_empty(self):
        text = _merge_override("")
        self.assertIn("[autoload]", text)
        self.assertIn('McpBridge="*user://mcp/McpBridge.gd"', text)

    def test_preserves_other_sections(self):
        existing = "[application]\nconfig/name=\"X\"\n\n[autoload]\nOther=\"*res://Other.gd\"\n"
        text = _merge_override(existing)
        self.assertIn("[application]", text)
        self.assertIn('Other="*res://Other.gd"', text)
        self.assertIn('McpBridge="*user://mcp/McpBridge.gd"', text)
        self.assertEqual(text.count("McpBridge="), 1)

    def test_idempotent(self):
        once = _merge_override("")
        twice = _merge_override(once)
        self.assertEqual(once.count("McpBridge="), 1)
        self.assertEqual(twice.count("McpBridge="), 1)

    def test_remove(self):
        existing = '[autoload]\nOther="*res://Other.gd"\nMcpBridge="*user://mcp/McpBridge.gd"\n'
        text = _remove_override(existing)
        self.assertNotIn("McpBridge=", text)
        self.assertIn("Other=", text)


class TestMcpProtocol(unittest.TestCase):
    def _run(self, messages):
        inp = io.BytesIO()
        for msg in messages:
            inp.write((json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8"))
        inp.seek(0)
        out = io.BytesIO()
        server = McpServer(api=FakeAPI(), stdin=inp, stdout=out)
        server.run()
        return [json.loads(line) for line in out.getvalue().decode("utf-8").splitlines()]

    def test_initialize_and_list(self):
        responses = self._run([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                        "clientInfo": {"name": "test", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        ])
        self.assertEqual(len(responses), 2)
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "backpack-battles-mcp")
        names = [t["name"] for t in responses[1]["result"]["tools"]]
        for expected in ("bpb_get_state", "bpb_get_phase", "bpb_buy_item",
                         "bpb_sell_item", "bpb_place_item", "bpb_start_battle",
                         "bpb_set_fusion_lock", "bpb_socket_gem", "bpb_unsocket_gem",
                         "bpb_set_class", "bpb_set_loadout",
                         "bpb_edit_items", "bpb_edit_bags", "bpb_edit_all",
                         "bpb_enter_survival", "bpb_stop_here", "bpb_choose_survival"):
            self.assertIn(expected, names)
        self.assertEqual(len(names), len(TOOLS))

    def test_call_state(self):
        responses = self._run([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "bpb_get_state", "arguments": {}}},
        ])
        result = responses[0]["result"]
        self.assertFalse(result["isError"])
        self.assertEqual(result["content"][0]["type"], "text")
        self.assertEqual(result["structuredContent"]["state"], "shop")
        self.assertEqual(result["structuredContent"]["round"], 1)

    def test_call_phase_and_sell(self):
        responses = self._run([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "bpb_get_phase", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "bpb_sell_item", "arguments": {"item_id": 7}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "bpb_set_class", "arguments": {"class_id": 2, "loadout": 0}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": {"name": "bpb_edit_all", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
             "params": {"name": "bpb_set_fusion_lock",
                        "arguments": {"item_id": 7, "locked": True}}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
             "params": {"name": "bpb_socket_gem",
                        "arguments": {"host_id": 1, "gem_id": 2, "socket_index": 0}}},
        ])
        self.assertEqual(responses[0]["result"]["structuredContent"]["state"], "shop")
        self.assertTrue(responses[1]["result"]["structuredContent"]["sold"])
        self.assertEqual(responses[2]["result"]["structuredContent"]["class"], 2)
        self.assertEqual(responses[3]["result"]["structuredContent"]["mode"], "all")
        self.assertTrue(responses[4]["result"]["structuredContent"]["fusion_locked"])
        self.assertTrue(responses[5]["result"]["structuredContent"]["socketed"])

    def test_unknown_tool_is_error(self):
        responses = self._run([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "nope", "arguments": {}}},
        ])
        self.assertTrue(responses[0]["result"]["isError"])

    def test_unknown_method(self):
        responses = self._run([
            {"jsonrpc": "2.0", "id": 1, "method": "nope", "params": {}},
        ])
        self.assertEqual(responses[0]["error"]["code"], -32601)


if __name__ == "__main__":
    unittest.main()
