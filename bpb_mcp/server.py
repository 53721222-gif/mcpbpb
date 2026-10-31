"""MCP stdio server for Backpack Battles.

Implements the Model Context Protocol JSON-RPC framing directly (no external
dependencies), so it runs on a bare Python 3.8+ install.
"""
from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional, Tuple

from .api import GameAPI
from .bridge import BridgeError, GameNotRunning

SERVER_NAME = "backpack-battles-mcp"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2024-11-05"

INSTRUCTIONS = (
    "Backpack Battles 本地 MCP 工具。先用 bpb_get_state 读取当前状态，"
    "购买用 bpb_buy_item（物品会进入储物箱），再用 bpb_place_item 放到背包指定格子。"
    "bpb_start_battle 后调用 bpb_wait_for_result 等待并跳过结算，回到下一回合商店。"
    "标题界面可读 state.title，再用 bpb_set_class / bpb_set_loadout 选择职业与 loadout。"
    "出售背包物品用 bpb_sell_item。"
    "融合锁定用 bpb_set_fusion_lock（item_id + locked=true/false）：锁定后物品不会自动合成，"
    "解锁后恢复；state 的 item.fusion_locked 表示当前状态。"
    "宝石镶嵌用 bpb_socket_gem（host_id + gem_id + socket_index）和 bpb_unsocket_gem；"
    "宿主 state.sockets 给出空位与已镶宝石。"
    "购买后推荐编辑顺序：bpb_edit_items（物品可放包外）→ bpb_edit_bags（移包覆盖，物品固定）"
    "→ bpb_edit_all（规范化落格，不移走跨包物品）。"
    "10 胜提示时 state.survival.prompt_visible=true，必须用 bpb_enter_survival / bpb_stop_here "
    "明确选择；bpb_skip_result / bpb_wait_for_result 会返回 survival_choice_required。"
    "战斗期间 bpb_get_state 只返回摘要（inventory_available=false），不会触碰背包；"
    "需要完整背包/商店请在 state=shop 时读取。"
    "背包是 9x7 网格，正常摆放要求物品在包（bag）覆盖的格子里；坐标 x=列, y=行，从 0 开始。"
)


def _tool(name: str, description: str, properties: Optional[Dict[str, Any]] = None,
          required: Optional[List[str]] = None) -> Dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties or {},
            "required": required or [],
            "additionalProperties": False,
        },
    }


TOOLS: List[Dict[str, Any]] = [
    _tool(
        "bpb_get_state",
        "获取当前完整状态：state(title/shop/combat)、职业、回合、剩余重试次数、金币、"
        "当前 run 胜场 wins、累计胜场 total_wins、生存模式状态 survival、"
        "商店物品/技能及价格、保留项、刷新费、背包 9x7 摆盘（bags/items/grid）、储物箱、"
        "战斗结算是否可跳过。战斗期间只返回摘要（inventory_available=false），"
        "不会触碰背包/商店；结算后回到 shop 再读取完整状态。"
        "返回的 id 字段用于后续 buy/place/rotate/store/reserve/socket 操作；"
        "item.fusion_locked / item.locked 是融合锁定状态；item.is_gem 与 item.sockets 用于宝石镶嵌。",
    ),
    _tool(
        "bpb_get_phase",
        "轻量状态：state/round/tries/gold/wins/total_wins/survival/can_skip_result/last_result。"
        "战斗期间可安全调用，不会触碰背包；用于等待结算或判断是否进入下一阶段。",
    ),
    _tool(
        "bpb_get_backpack",
        "读取当前完整背包布局：所有已部署背包（位置/cells/shape/rotation）、"
        "所有已放置物品（位置/cells/shape/rotation/bag_id/floating/fusion_locked/is_gem/sockets）、grid、储物箱，"
        "以及 bags/items/floating/outside/fusion_locked/socketed_gems 计数。只读，不触发 normalize 或存档写入。",
    ),
    _tool(
        "bpb_get_star_slots",
        "读取星位/受影响格与宝石插槽。返回每件已放置物品的 affected_cells（按方向 0/2/4/7）、"
        "current_affected_items（当前命中物品）、extension_cells 和 sockets（index/位置/occupied/gem_id/gem_name）。"
        "可选 item_id 只查一件。",
        {"item_id": {"type": "integer", "description": "可选物品实例 id"}},
    ),
    _tool(
        "bpb_get_stamina",
        "读取耐力信息：玩家 stamina/max_stamina/stamina_regen（游戏未暴露时对应字段为 null 且 available=false）、"
        "每件物品的 stamina_cost/stamina_factor/types/伤害/冷却，以及已部署物品的总耐力消耗。",
    ),
    _tool(
        "bpb_get_recipes",
        "读取合成配方：每件背包/储物箱物品的 recipes（base/result/ingredients/all_ingredients/catalyst）、"
        "as_ingredient（作为材料的配方）、gated_items（牌堆可生成卡牌）。"
        "全量只查背包/储物箱；商店物品用 item_id 单查（全量遍历个别 shop 配方不稳定）。",
        {"item_id": {"type": "integer", "description": "可选物品实例 id；可传商店物品 id"}},
    ),
    _tool(
        "bpb_buy_item",
        "购买商店物品并放入储物箱。若 state.shop.choose_one=true（第 3/10 回合的技能商店），"
        "则选择一个技能并放入储物箱（返回 skill_id）；技能是 1×1 可摆放物品，"
        "再用 bpb_place_item 摆进背包。购买后会补发 dropped 信号，触发 Unidentified Skill 等 onDropped 购买效果。"
        "用 slot（1-5）或 item_id 指定。",
        {
            "slot": {"type": "integer", "minimum": 1, "maximum": 5, "description": "商店槽位，从 1 开始"},
            "item_id": {"type": "integer", "description": "商店物品/技能的 id（来自 bpb_get_state）"},
        },
    ),
    _tool(
        "bpb_refresh_shop",
        "刷新商店（消耗金币，费用见 state.shop.reroll_cost）。",
    ),
    _tool(
        "bpb_open_backpack_edit",
        "进入背包层编辑模式（inventoryEditMode=bag），用于移动/旋转背包本体。",
    ),
    _tool(
        "bpb_open_item_edit",
        "进入物品层编辑模式（inventoryEditMode=item）；可选 item_id 聚焦某件物品。",
        {"item_id": {"type": "integer", "description": "可选，要聚焦的物品 id"}},
    ),
    _tool(
        "bpb_reserve_item",
        "保留/取消保留商店物品（reserve）。保留后该物品会留在商店，跨刷新/下回合仍可购买；"
        "reserved=false 表示取消保留。用 slot（1-5）或 item_id 指定。",
        {
            "slot": {"type": "integer", "minimum": 1, "maximum": 5},
            "item_id": {"type": "integer"},
            "reserved": {"type": "boolean", "default": True},
        },
    ),
    _tool(
        "bpb_store_item",
        "把背包里的物品放回储物箱（腾出格子）。不能用于背包本体；用于给技能/新物品腾位置。",
        {"item_id": {"type": "integer", "description": "背包内物品 id"}},
        ["item_id"],
    ),
    _tool(
        "bpb_sell_item",
        "出售背包里的物品，立即获得金币（价格见 state.backpack.items[].sell_price）。"
        "储物箱里的物品需先 bpb_place_item 放回背包再出售。",
        {"item_id": {"type": "integer", "description": "背包内物品 id"}},
        ["item_id"],
    ),
    _tool(
        "bpb_set_fusion_lock",
        "锁定或解除物品的自动融合。locked=true 锁定（阻止自动合成），"
        "locked=false 解除；背包和储物箱物品可用，背包本体不可用。"
        "state 中 item.fusion_locked 反映结果。",
        {
            "item_id": {"type": "integer", "description": "物品 id（背包或储物箱）"},
            "locked": {"type": "boolean", "description": "true=锁定融合，false=解除融合锁定"},
        },
        ["item_id", "locked"],
    ),
    _tool(
        "bpb_socket_gem",
        "把宝石类物品镶到宿主物品的空镶嵌位。host_id 的 state.sockets 提供 socket_index、"
        "occupied、gem_id；宝石可以是背包或储物箱中的散装宝石。镶嵌是原子的，不走 drop/hotswap。",
        {
            "host_id": {"type": "integer", "description": "宿主物品 id（武器/防具等，且有 socket）"},
            "gem_id": {"type": "integer", "description": "宝石物品 id（如 Lump of Coal / Chipped Ruby）"},
            "socket_index": {"type": "integer", "minimum": 0, "description": "镶嵌位索引，默认 0"},
        },
        ["host_id", "gem_id"],
    ),
    _tool(
        "bpb_unsocket_gem",
        "从宿主物品的镶嵌位取下宝石。优先放回背包空格；没有空格时放储物箱。",
        {
            "host_id": {"type": "integer", "description": "宿主物品 id"},
            "socket_index": {"type": "integer", "minimum": 0, "description": "镶嵌位索引，默认 0"},
        },
        ["host_id"],
    ),
    _tool(
        "bpb_edit_items",
        "进入“只编辑物品”模式：背包固定不动，物品可以放到任意格子（包括包外）。"
        "用于购买后先把物品摆到理想位置。",
    ),
    _tool(
        "bpb_edit_bags",
        "进入“只编辑背包”模式：物品固定不动，背包可以移动/旋转，移动背包不会牵连物品。"
        "用于把背包移动到覆盖物品的位置。",
    ),
    _tool(
        "bpb_edit_all",
        "进入“编辑全部”模式并规范化落格；不会把跨包/包外物品移入储物箱。"
        "物品可以同时被多个背包覆盖，游戏没有单一背包限制。",
    ),
    _tool(
        "bpb_set_edit_mode",
        "切换编辑模式：all（全部）/bags（只背包）/items（只物品）；兼容 default/bag/item 别名。",
        {"mode": {"type": "string",
                  "enum": ["all", "bags", "items", "default", "bag", "item"],
                  "default": "all"}},
    ),
    _tool(
        "bpb_set_class",
        "标题界面选择职业（0=Ranger,1=Reaper,2=Berserker,3=Pyromancer,4=Mage,5=Adventurer,6=Engineer）；"
        "可同时指定 loadout（0-2），随后用 bpb_start_run 开局。",
        {
            "class_id": {"type": "integer", "minimum": 0, "maximum": 6},
            "loadout": {"type": "integer", "minimum": 0, "maximum": 2, "default": 0},
        },
        ["class_id"],
    ),
    _tool(
        "bpb_set_loadout",
        "标题界面选择初始 loadout（0-2）；具体物品见 state.title.classes[].loadouts。",
        {"loadout": {"type": "integer", "minimum": 0, "maximum": 2}},
        ["loadout"],
    ),
    _tool(
        "bpb_place_item",
        "原生落格：pickup(当前物品位置) → 设目标包围盒中心 → Item.drop()，"
        "成功返回的 cells 精确等于目标格，并触发游戏正常的落格/放置回调。"
        "物品/全部模式下允许放到包外（outside_bag=true）；"
        "物品可以同时覆盖多个背包，不要求属于单一背包；位置/朝向由游戏 drop 校验。",
        {
            "item_id": {"type": "integer", "description": "物品/技能 id（来自 state 的 backpack.items、storage 或 buy_item 返回的 skill_id）"},
            "x": {"type": "integer", "minimum": 0, "description": "左上角列，0-8"},
            "y": {"type": "integer", "minimum": 0, "description": "左上角行，0-6"},
        },
        ["item_id", "x", "y"],
    ),
    _tool(
        "bpb_place_bag",
        "移动背包到指定左上角格子 (x,y)。只允许移动空背包；非空背包返回 bag_not_empty，"
        "需先用 bpb_place_item/bpb_store_item 把内容移出，再移动空包。"
        "物品模式返回 bags_fixed_in_item_mode。",
        {
            "item_id": {"type": "integer", "description": "背包 id（来自 state 的 backpack.bags）"},
            "x": {"type": "integer", "minimum": 0},
            "y": {"type": "integer", "minimum": 0},
        },
        ["item_id", "x", "y"],
    ),
    _tool(
        "bpb_rotate_item",
        "游戏内原子旋转（已启用）：目标格全在包内且无重叠时，"
        "直接 removeItem → orientItem → addItemByTopLeft，不经过 drop/tryAddItem/hotswap。"
        "支持矩形和 L 形；目标不合法返回 cannot_rotate_in_place。BPB_ROTATE=0 可关闭。",
        {
            "item_id": {"type": "integer"},
            "direction": {"type": "string", "enum": ["right", "left"], "default": "right"},
        },
        ["item_id"],
    ),
    _tool(
        "bpb_rotate_bag",
        "游戏内原子旋转空背包（已启用）：目标格全在包内且无重叠时，"
        "removeItem → orientItem → addItemByTopLeft；非空背包返回 bag_not_empty。"
        "BPB_ROTATE=0 可关闭。",
        {
            "item_id": {"type": "integer"},
            "direction": {"type": "string", "enum": ["right", "left"], "default": "right"},
        },
        ["item_id"],
    ),
    _tool(
        "bpb_start_battle",
        "开始战斗；开战前只规范化物品位置/placedByPlayer，不会把跨包物品移入储物箱。"
        "随后用 bpb_wait_for_result 等待结算。",
    ),
    _tool(
        "bpb_skip_result",
        "跳过战斗结算界面回到商店（仅在 state.can_skip_result=true 时调用）。"
        "若 state.survival.prompt_visible=true，会返回 survival_choice_required，"
        "必须先 bpb_choose_survival / bpb_enter_survival / bpb_stop_here 做出选择。",
    ),
    _tool(
        "bpb_enter_survival",
        "10 胜提示时选择“进入生存模式”。仅在 state.survival.prompt_visible=true 且 "
        "state.survival.can_start=true 时可用；会继续本局进入生存模式。",
    ),
    _tool(
        "bpb_stop_here",
        "10 胜提示时选择“到此为止”。仅在 state.survival.prompt_visible=true 时可用；"
        "结束本轮并保留胜场。",
    ),
    _tool(
        "bpb_choose_survival",
        "统一处理 10 胜提示：choice=survival 等价 bpb_enter_survival，choice=stop 等价 bpb_stop_here。",
        {"choice": {"type": "string", "enum": ["survival", "stop"], "default": "survival"}},
        ["choice"],
    ),
    _tool(
        "bpb_wait_for_result",
        "等待战斗结算界面出现；auto_skip=true 时自动跳过并返回下一回合商店状态。"
        "若出现 10 胜生存选择提示，会返回 survival_choice_required，不会自动替你选择。",
        {
            "timeout_seconds": {"type": "number", "default": 90, "minimum": 5, "maximum": 300},
            "auto_skip": {"type": "boolean", "default": True},
        },
    ),
    _tool(
        "bpb_start_run",
        "开始新的一局。默认优先恢复挂起的 run；force_new=true 会删除挂起的 run 并强制全新开局"
        "（适用于旧存档损坏、continue 崩溃的情况）。mode=unranked/ranked。"
        "新局第一回合生命上限强制重置为 25（不继承上一局），返回 hp。"
        "可选 class_id/loadout：开局前先选择职业与初始 loadout。",
        {
            "mode": {"type": "string", "enum": ["unranked", "ranked"], "default": "unranked"},
            "force_new": {"type": "boolean", "default": False,
                          "description": "true=删除挂起 run 并强制新开一局"},
            "class_id": {"type": "integer", "minimum": 0, "maximum": 6},
            "loadout": {"type": "integer", "minimum": 0, "maximum": 2},
        },
    ),
    _tool(
        "bpb_continue",
        "从标题界面继续挂起的 run（等价于点击“继续”）。",
    ),
    _tool(
        "bpb_health",
        "检查游戏内网桥是否在线，返回 ping 与当前状态摘要。",
    ),
]


def _json_text(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2)


class McpServer:
    def __init__(self, api: Optional[GameAPI] = None, stdin: Any = None, stdout: Any = None) -> None:
        self.api = api or GameAPI()
        self.stdin = stdin or sys.stdin.buffer
        self.stdout = stdout or sys.stdout.buffer
        self._initialized = False

    # ------------------------------------------------------------------ framing
    def _read_message(self) -> Optional[Dict[str, Any]]:
        raw = self.stdin.readline()
        if not raw:
            return None
        text = raw.decode("utf-8", "replace").strip()
        if not text:
            return self._read_message()
        if text.lower().startswith("content-length:"):
            try:
                length = int(text.split(":", 1)[1].strip())
            except ValueError:
                return None
            # consume remaining headers
            while True:
                header = self.stdin.readline()
                if not header or header in (b"\r\n", b"\n"):
                    break
            body = self.stdin.read(length)
            return json.loads(body.decode("utf-8"))
        return json.loads(text)

    def _write(self, message: Dict[str, Any]) -> None:
        self.stdout.write((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))
        self.stdout.flush()

    def _reply(self, msg_id: Any, result: Any = None, error: Optional[Dict[str, Any]] = None) -> None:
        payload: Dict[str, Any] = {"jsonrpc": "2.0", "id": msg_id}
        if error is not None:
            payload["error"] = error
        else:
            payload["result"] = result
        self._write(payload)

    # ----------------------------------------------------------------- dispatch
    def run(self) -> int:
        while True:
            try:
                msg = self._read_message()
            except json.JSONDecodeError:
                self._reply(None, error={"code": -32700, "message": "Parse error"})
                continue
            if msg is None:
                return 0
            self.handle(msg)

    def handle(self, msg: Dict[str, Any]) -> None:
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        is_notification = "id" not in msg

        if method == "initialize":
            version = params.get("protocolVersion") or DEFAULT_PROTOCOL
            self._initialized = True
            self._reply(msg_id, {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": INSTRUCTIONS,
            })
        elif method == "notifications/initialized":
            pass
        elif method == "ping":
            self._reply(msg_id, {})
        elif method == "tools/list":
            self._reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            self._handle_tool_call(msg_id, params)
        elif method == "resources/list":
            self._reply(msg_id, {"resources": []})
        elif method == "prompts/list":
            self._reply(msg_id, {"prompts": []})
        elif method == "logging/setLevel":
            if not is_notification:
                self._reply(msg_id, {})
        else:
            if not is_notification:
                self._reply(msg_id, error={"code": -32601, "message": "Method not found: %s" % method})

    # -------------------------------------------------------------------- tools
    def _handle_tool_call(self, msg_id: Any, params: Dict[str, Any]) -> None:
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            data = self.call_tool(name, args)
            is_error = isinstance(data, dict) and data.get("ok") is False
        except GameNotRunning as exc:
            data = {
                "ok": False,
                "error": "game_not_running",
                "message": "无法连接游戏内网桥 127.0.0.1:8765。请先启动 Backpack Battles，"
                           "并确认已运行 python -m bpb_mcp.install 安装 override.cfg。",
                "detail": exc.payload,
            }
            is_error = True
        except BridgeError as exc:
            data = {"ok": False, "error": "bridge_error", "detail": exc.payload}
            is_error = True
        except Exception as exc:  # noqa: BLE001 - surface tool errors to the model
            data = {"ok": False, "error": "tool_exception", "message": str(exc)}
            is_error = True

        text = _json_text(data)
        result: Dict[str, Any] = {
            "content": [{"type": "text", "text": text}],
            "isError": is_error,
        }
        if isinstance(data, dict):
            result["structuredContent"] = data
        self._reply(msg_id, result)

    def call_tool(self, name: Optional[str], args: Dict[str, Any]) -> Any:
        if name == "bpb_get_state":
            return self.api.state()
        if name == "bpb_get_phase":
            return self.api.phase()
        if name == "bpb_get_backpack":
            return self.api.backpack()
        if name == "bpb_get_star_slots":
            return self.api.star_slots(args.get("item_id"))
        if name == "bpb_get_stamina":
            return self.api.stamina()
        if name == "bpb_get_recipes":
            return self.api.recipes(args.get("item_id"))
        if name == "bpb_buy_item":
            return self.api.buy_item(slot=args.get("slot"), item_id=args.get("item_id"))
        if name == "bpb_refresh_shop":
            return self.api.refresh_shop()
        if name == "bpb_open_backpack_edit":
            return self.api.open_backpack_edit()
        if name == "bpb_open_item_edit":
            return self.api.open_item_edit(item_id=args.get("item_id"))
        if name == "bpb_place_item":
            return self.api.place_item(int(args["item_id"]), int(args["x"]), int(args["y"]))
        if name == "bpb_store_item":
            return self.api.store_item(int(args["item_id"]))
        if name == "bpb_sell_item":
            return self.api.sell_item(int(args["item_id"]))
        if name == "bpb_set_fusion_lock":
            return self.api.set_fusion_lock(int(args["item_id"]), bool(args.get("locked", True)))
        if name == "bpb_socket_gem":
            return self.api.socket_gem(int(args["host_id"]), int(args["gem_id"]),
                                       int(args.get("socket_index", 0)))
        if name == "bpb_unsocket_gem":
            return self.api.unsocket_gem(int(args["host_id"]),
                                         int(args.get("socket_index", 0)))
        if name == "bpb_set_edit_mode":
            return self.api.set_edit_mode(args.get("mode", "all"))
        if name == "bpb_edit_items":
            return self.api.edit_items()
        if name == "bpb_edit_bags":
            return self.api.edit_bags()
        if name == "bpb_edit_all":
            return self.api.edit_all()
        if name == "bpb_set_class":
            return self.api.set_class(int(args["class_id"]), int(args.get("loadout", 0)))
        if name == "bpb_set_loadout":
            return self.api.set_loadout(int(args["loadout"]))
        if name == "bpb_reserve_item":
            return self.api.reserve_item(slot=args.get("slot"), item_id=args.get("item_id"),
                                         reserved=bool(args.get("reserved", True)))
        if name == "bpb_place_bag":
            return self.api.place_bag(int(args["item_id"]), int(args["x"]), int(args["y"]))
        if name == "bpb_rotate_item":
            return self.api.rotate_item(int(args["item_id"]), args.get("direction", "right"))
        if name == "bpb_rotate_bag":
            return self.api.rotate_bag(int(args["item_id"]), args.get("direction", "right"))
        if name == "bpb_start_battle":
            return self.api.start_battle()
        if name == "bpb_skip_result":
            return self.api.skip_result()
        if name == "bpb_enter_survival":
            return self.api.enter_survival()
        if name == "bpb_stop_here":
            return self.api.stop_here()
        if name == "bpb_choose_survival":
            return self.api.choose_survival(args.get("choice", "survival"))
        if name == "bpb_wait_for_result":
            timeout = float(args.get("timeout_seconds", 90))
            return self.api.wait_for_result(timeout=timeout, auto_skip=bool(args.get("auto_skip", True)))
        if name == "bpb_start_run":
            if args.get("class_id") is not None:
                self.api.set_class(int(args["class_id"]), int(args.get("loadout", 0)))
            elif args.get("loadout") is not None:
                self.api.set_loadout(int(args["loadout"]))
            return self.api.start_run(args.get("mode", "unranked"), force_new=bool(args.get("force_new", False)))
        if name == "bpb_continue":
            return self.api.continue_run()
        if name == "bpb_health":
            return self.api.health()
        raise ValueError("Unknown tool: %s" % name)


def main() -> int:
    server = McpServer()
    return server.run()


if __name__ == "__main__":
    raise SystemExit(main())
