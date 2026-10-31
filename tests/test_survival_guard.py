"""Offline regression: ten-win survival prompt must not be auto-skipped."""
from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from bpb_mcp.api import GameAPI


class FakeBridge:
    def __init__(self, just_started=False):
        self.skips = 0
        self.just_started = just_started
        self.calls = 0

    def api(self, fn, args=None):
        if fn == "get_phase":
            self.calls += 1
            if self.just_started and self.calls <= 2:
                return {"ok": True, "state": "combat", "round": 13, "wins": 10,
                        "current_run_wins": 10, "tries": 5, "can_skip_result": True,
                        "survival": {"prompt_visible": False, "can_start": False,
                                     "survival_mode": True, "just_started": True}}
            if self.just_started:
                return {"ok": True, "state": "shop", "round": 13, "wins": 10,
                        "current_run_wins": 10, "tries": 5, "can_skip_result": False,
                        "survival": {"prompt_visible": False, "can_start": False,
                                     "survival_mode": True, "just_started": False}}
            return {"ok": True, "state": "combat", "round": 13, "wins": 10,
                    "current_run_wins": 10, "tries": 4, "can_skip_result": True,
                    "survival": {"prompt_visible": False, "can_start": True,
                                 "survival_mode": False, "just_started": False}}
        if fn == "get_state":
            return {"state": "shop", "round": 13, "wins": 10, "tries": 5,
                    "survival": {"prompt_visible": False, "survival_mode": True}}
        if fn == "skip_result":
            self.skips += 1
            return {"ok": True}
        return {"ok": True}


class TestSurvivalGuard(unittest.TestCase):
    def test_wait_does_not_skip_ten_wins(self):
        bridge = FakeBridge()
        out = GameAPI(bridge=bridge).wait_for_result(timeout=4, auto_skip=True)
        self.assertFalse(out.get("ok"))
        self.assertEqual(out.get("error"), "survival_choice_required")
        self.assertEqual(bridge.skips, 0)

    def test_wait_handles_survival_transition(self):
        bridge = FakeBridge(just_started=True)
        out = GameAPI(bridge=bridge).wait_for_result(timeout=4, auto_skip=True)
        self.assertTrue(out.get("ok"))
        self.assertEqual(out.get("result"), "survival_started")
        self.assertEqual(bridge.skips, 0)


if __name__ == "__main__":
    unittest.main()
