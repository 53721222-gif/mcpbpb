"""High-level API for Backpack Battles over the in-game bridge."""
from __future__ import annotations

import time
from typing import Any, Callable, Dict, Optional

from .bridge import Bridge, BridgeError, GameNotRunning


class GameAPI:
    def __init__(self, bridge: Optional[Bridge] = None) -> None:
        self.bridge = bridge or Bridge()

    # ------------------------------------------------------------------- state
    def state(self) -> Dict[str, Any]:
        result = self.bridge.api("get_state", {})
        return result["state"]

    def phase(self) -> Dict[str, Any]:
        """Lightweight state safe to call during combat."""
        return self.bridge.api("get_phase", {})

    def backpack(self) -> Dict[str, Any]:
        return self.bridge.api("get_backpack", {})

    def star_slots(self, item_id: Optional[int] = None) -> Dict[str, Any]:
        args: Dict[str, Any] = {}
        if item_id is not None:
            args["item_id"] = int(item_id)
        return self.bridge.api("get_star_slots", args)

    def stamina(self) -> Dict[str, Any]:
        return self.bridge.api("get_stamina", {})

    def recipes(self, item_id: Optional[int] = None) -> Dict[str, Any]:
        args: Dict[str, Any] = {}
        if item_id is not None:
            args["item_id"] = int(item_id)
        return self.bridge.api("get_recipes", args)

    def ping(self) -> Dict[str, Any]:
        return self.bridge.ping()

    def health(self) -> Dict[str, Any]:
        try:
            pong = self.ping()
            ph = self.phase()
            return {
                "ok": True,
                "bridge": pong,
                "game_state": ph.get("state"),
                "round": ph.get("round"),
                "gold": ph.get("gold"),
                "wins": ph.get("wins"),
                "total_wins": ph.get("total_wins"),
                "survival": ph.get("survival"),
                "version": ph.get("version"),
            }
        except BridgeError as exc:
            return {"ok": False, "error": exc.payload}

    # ----------------------------------------------------------------- actions
    def buy_item(self, slot: Optional[int] = None, item_id: Optional[int] = None) -> Dict[str, Any]:
        args: Dict[str, Any] = {}
        if slot is not None:
            args["slot"] = int(slot)
        if item_id is not None:
            args["item_id"] = int(item_id)
        return self.bridge.api("buy_item", args)

    def refresh_shop(self) -> Dict[str, Any]:
        return self.bridge.api("reroll_shop", {})

    def set_edit_mode(self, mode: str = "default") -> Dict[str, Any]:
        return self.bridge.api("set_edit_mode", {"mode": mode})

    def edit_items(self) -> Dict[str, Any]:
        return self.set_edit_mode("items")

    def edit_bags(self) -> Dict[str, Any]:
        return self.set_edit_mode("bags")

    def edit_all(self) -> Dict[str, Any]:
        return self.set_edit_mode("all")

    def open_backpack_edit(self) -> Dict[str, Any]:
        return self.set_edit_mode("bags")

    def open_item_edit(self, item_id: Optional[int] = None) -> Dict[str, Any]:
        result = self.set_edit_mode("items")
        if item_id is not None:
            try:
                focus = self.bridge.api("focus_item", {"item_id": int(item_id)})
                result["focus"] = focus
            except BridgeError as exc:
                result["focus"] = exc.payload
        return result

    def place_item(self, item_id: int, x: int, y: int) -> Dict[str, Any]:
        return self.bridge.api("place_item", {"item_id": int(item_id), "x": int(x), "y": int(y)})

    def place_bag(self, item_id: int, x: int, y: int) -> Dict[str, Any]:
        return self.bridge.api("place_bag", {"item_id": int(item_id), "x": int(x), "y": int(y)})

    def store_item(self, item_id: int) -> Dict[str, Any]:
        return self.bridge.api("store_item", {"item_id": int(item_id)})

    def sell_item(self, item_id: int) -> Dict[str, Any]:
        return self.bridge.api("sell_item", {"item_id": int(item_id)})

    def reserve_item(self, slot: Optional[int] = None, item_id: Optional[int] = None,
                     reserved: bool = True) -> Dict[str, Any]:
        args: Dict[str, Any] = {"reserved": bool(reserved)}
        if slot is not None:
            args["slot"] = int(slot)
        if item_id is not None:
            args["item_id"] = int(item_id)
        return self.bridge.api("reserve_shop_item", args)

    def rotate_item(self, item_id: int, direction: str = "right") -> Dict[str, Any]:
        return self.bridge.api("rotate_item", {"item_id": int(item_id), "direction": direction})

    def rotate_bag(self, item_id: int, direction: str = "right") -> Dict[str, Any]:
        return self.bridge.api("rotate_bag", {"item_id": int(item_id), "direction": direction})

    def start_battle(self) -> Dict[str, Any]:
        result = self.bridge.api("start_battle", {})
        deadline = time.time() + 5.0
        while time.time() < deadline:
            ph = self.phase()
            if ph.get("state") == "combat":
                if isinstance(result, dict):
                    result = dict(result)
                    result["state"] = "combat"
                    result["round"] = ph.get("round", result.get("round"))
                return result
            time.sleep(0.2)
        return result

    def skip_result(self) -> Dict[str, Any]:
        return self.bridge.api("skip_result", {})

    def enter_survival(self) -> Dict[str, Any]:
        return self.bridge.api("enter_survival", {})

    def stop_here(self) -> Dict[str, Any]:
        return self.bridge.api("stop_here", {})

    def choose_survival(self, choice: str = "survival") -> Dict[str, Any]:
        return self.bridge.api("choose_survival", {"choice": choice})

    def start_run(self, mode: str = "unranked", force_new: bool = False) -> Dict[str, Any]:
        return self._title_retry("start_run", {"mode": mode, "force_new": bool(force_new)})

    def set_loadout(self, loadout: int = 0) -> Dict[str, Any]:
        return self.bridge.api("set_loadout", {"loadout": int(loadout)})

    def set_class(self, class_id: int = 0, loadout: int = 0) -> Dict[str, Any]:
        return self.bridge.api("set_class", {"class": int(class_id), "loadout": int(loadout)})

    def continue_run(self) -> Dict[str, Any]:
        return self._title_retry("continue_run", {})

    def _title_retry(self, fn: str, args: Dict[str, Any], attempts: int = 12, delay: float = 0.5) -> Dict[str, Any]:
        """Retry while the title screen / class resources are still loading."""
        last: Dict[str, Any] = {"ok": False, "error": "title_not_ready"}
        for _ in range(attempts):
            last = self.bridge.api(fn, args)
            if last.get("error") != "title_not_ready":
                return last
            time.sleep(delay)
        return last

    # ------------------------------------------------------------------- waits
    def wait_until(
        self,
        predicate: Callable[[Dict[str, Any]], bool],
        timeout: float = 30.0,
        interval: float = 0.5,
    ) -> Dict[str, Any]:
        deadline = time.time() + timeout
        last: Optional[Dict[str, Any]] = None
        while time.time() < deadline:
            last = self.state()
            if predicate(last):
                return last
            time.sleep(interval)
        return last or self.state()

    def wait_for_shop_or_title(self, timeout: float = 20.0) -> Dict[str, Any]:
        deadline = time.time() + timeout
        last: Optional[Dict[str, Any]] = None
        while time.time() < deadline:
            last = self.phase()
            if last.get("state") in ("shop", "title"):
                return self.state()
            time.sleep(0.5)
        return last or self.phase()

    def wait_for_shop(self, timeout: float = 20.0, ready: bool = True) -> Dict[str, Any]:
        deadline = time.time() + timeout
        last: Optional[Dict[str, Any]] = None
        while time.time() < deadline:
            last = self.phase()
            if last.get("state") == "shop":
                st = self.state()
                if not ready:
                    return st
                # The shop scene can still be animating for ~1-2s after the
                # state flips; wait (briefly) until the battle button is ready.
                ready_deadline = time.time() + 4.0
                while time.time() < ready_deadline:
                    if st.get("can_start_battle"):
                        return st
                    time.sleep(0.4)
                    st = self.state()
                return st
            time.sleep(0.5)
        return last or self.phase()

    def wait_for_result(self, timeout: float = 90.0, auto_skip: bool = True) -> Dict[str, Any]:
        """Wait for the post-combat result screen, optionally skip it.

        Uses the lightweight phase endpoint while in combat so the game
        inventory is never touched during a running battle.
        """
        deadline = time.time() + timeout
        started_at = time.time()
        saw_combat = False
        while time.time() < deadline:
            ph = self.phase()
            state = ph.get("state")
            if state == "title":
                return {"ok": True, "result": "run_over", "state": ph}
            if state == "shop":
                if saw_combat or time.time() - started_at > 4.0:
                    return {"ok": True, "result": "already_shop", "state": self.state()}
                time.sleep(0.4)
                continue
            surv = ph.get("survival") or {}
            if surv.get("prompt_visible"):
                return {"ok": False, "error": "survival_choice_required",
                        "state": self.state()}
            if state == "combat":
                saw_combat = True
                if ph.get("can_skip_result"):
                    if auto_skip:
                        skip = self.skip_result()
                        if not skip.get("ok"):
                            return {"ok": False, "error": "skip_failed", "detail": skip, "state": ph}
                        st = self.wait_for_shop_or_title(timeout=20.0)
                        if st.get("state") == "title":
                            return {"ok": True, "result": "run_over", "state": st}
                        st = self.wait_for_shop(timeout=5.0, ready=True)
                        return {"ok": True, "result": "skipped", "state": st}
                    return {"ok": True, "result": "ready", "state": self.state()}
            elif saw_combat:
                return {"ok": True, "result": "auto_returned", "state": self.state()}
            time.sleep(0.6)
        return {"ok": False, "error": "timeout", "state": self.phase()}
