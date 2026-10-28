"""One-shot live smoke test against the running game (read-only)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bpb_mcp.api import GameAPI
from bpb_mcp.bridge import GameNotRunning


def main() -> int:
    api = GameAPI()
    try:
        st = api.state()
    except GameNotRunning as exc:
        print("Game bridge not reachable: %s" % exc)
        print("Start Backpack Battles and run: python -m bpb_mcp.cli install")
        return 2

    hp = st.get("hp") or {}
    print("state=%s round=%s tries=%s gold=%s class=%s hp=%s inventory_available=%s" % (
        st["state"], st["round"], st["tries"], st["gold"],
        st["class"]["name_localized"], hp, st.get("inventory_available", True)))
    print("shop (%d, reroll=%d):" % (len(st.get("shop", {}).get("items", [])),
                                     st.get("shop", {}).get("reroll_cost", 0)))
    for it in st.get("shop", {}).get("items", []):
        print("  [%d] %-22s %s  %dG  %s  id=%s" % (
            it["slot"], it["name_localized"], it["name"], it["price"],
            "sale" if it.get("on_sale") else "", it["id"]))
    backpack = st.get("backpack") or {"width": 0, "height": 0, "bags": [], "items": []}
    print("backpack %dx%d:" % (backpack["width"], backpack["height"]))
    for bag in backpack.get("bags", []):
        print("  bag %-16s top_left=%s cells=%d" % (bag["name_localized"], bag["top_left"], len(bag["cells"])))
    for it in backpack.get("items", []):
        print("  item %-16s top_left=%s cells=%s rot=%s id=%s" % (
            it["name_localized"], it.get("top_left"), it.get("cells"), it["rotation"], it["id"]))
    print("storage: %s" % [x["name_localized"] for x in st.get("storage", [])])
    print("can_start_battle=%s can_skip_result=%s" % (st["can_start_battle"], st["can_skip_result"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
