"""Command line interface for Backpack Battles MCP."""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from . import __version__
from .api import GameAPI
from .bridge import BridgeError, GameNotRunning


def _print(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def main(argv: Any = None) -> int:
    parser = argparse.ArgumentParser(prog="bpb_mcp", description="Backpack Battles MCP / 本地状态与操作接口")
    parser.add_argument("--version", action="version", version="%(prog)s " + __version__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("state", help="打印完整游戏状态")
    sub.add_parser("phase", help="打印轻量状态（战斗期安全）")
    sub.add_parser("health", help="检查网桥与游戏状态")
    sub.add_parser("tools", help="列出 MCP 工具")

    p = sub.add_parser("buy", help="购买商店物品到储物箱")
    p.add_argument("--slot", type=int, help="商店槽位 1-5")
    p.add_argument("--item-id", type=int, help="商店物品 id")

    sub.add_parser("refresh", help="刷新商店")

    p = sub.add_parser("edit", help="切换编辑模式")
    p.add_argument("--mode", choices=["all", "bags", "items", "default", "bag", "item"], default="bags")
    sub.add_parser("edit-items", help="只编辑物品（物品可放包外）")
    sub.add_parser("edit-bags", help="只编辑背包（物品固定）")
    sub.add_parser("edit-all", help="编辑全部（放不下的物品自动进仓库）")

    p = sub.add_parser("place", help="把物品摆放到背包格子")
    p.add_argument("--item-id", type=int, required=True)
    p.add_argument("--x", type=int, required=True)
    p.add_argument("--y", type=int, required=True)

    p = sub.add_parser("place-bag", help="把背包摆放到网格")
    p.add_argument("--item-id", type=int, required=True)
    p.add_argument("--x", type=int, required=True)
    p.add_argument("--y", type=int, required=True)

    p = sub.add_parser("store", help="把背包物品放回储物箱")
    p.add_argument("--item-id", type=int, required=True)

    p = sub.add_parser("sell", help="出售背包物品")
    p.add_argument("--item-id", type=int, required=True)

    p = sub.add_parser("set-class", help="标题界面选择职业")
    p.add_argument("--class-id", type=int, required=True)
    p.add_argument("--loadout", type=int)

    p = sub.add_parser("set-loadout", help="标题界面选择初始 loadout")
    p.add_argument("--index", type=int, required=True)

    p = sub.add_parser("reserve", help="保留/取消保留商店物品")
    p.add_argument("--slot", type=int)
    p.add_argument("--item-id", type=int)
    p.add_argument("--unreserve", action="store_true")

    p = sub.add_parser("rotate", help="旋转物品或背包")
    p.add_argument("--item-id", type=int, required=True)
    p.add_argument("--left", action="store_true")

    sub.add_parser("battle", help="开始战斗")

    p = sub.add_parser("wait-result", help="等待战斗结算并自动跳过")
    p.add_argument("--timeout", type=float, default=90.0)
    p.add_argument("--no-skip", action="store_true")

    sub.add_parser("skip", help="跳过结算界面")

    sub.add_parser("enter-survival", help="10 胜提示：进入生存模式")
    sub.add_parser("stop-here", help="10 胜提示：到此为止")
    p = sub.add_parser("choose-survival", help="10 胜提示：选择 survival/stop")
    p.add_argument("--choice", choices=["survival", "stop"], required=True)

    p = sub.add_parser("start-run", help="开始/恢复一局")
    p.add_argument("--mode", choices=["unranked", "ranked"], default="unranked")
    p.add_argument("--force-new", action="store_true", help="删除挂起 run 并强制新开")
    p.add_argument("--class-id", type=int)
    p.add_argument("--loadout", type=int)

    sub.add_parser("continue", help="从标题继续挂起的 run")

    p = sub.add_parser("install", help="安装游戏内网桥")
    p.add_argument("--game-dir", help="Backpack Battles 安装目录")

    p = sub.add_parser("uninstall", help="卸载游戏内网桥")
    p.add_argument("--game-dir", help="Backpack Battles 安装目录")

    p = sub.add_parser("doctor", help="诊断安装与连接")
    p.add_argument("--game-dir", help="Backpack Battles 安装目录")

    p = sub.add_parser("launch", help="通过 Steam 启动游戏并等待网桥")
    p.add_argument("--game-dir", help="Backpack Battles 安装目录")
    p.add_argument("--no-wait", action="store_true")

    p = sub.add_parser("http", help="启动本地 HTTP API")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8766)

    args = parser.parse_args(argv)
    cmd = args.command

    try:
        if cmd == "state":
            _print(GameAPI().state())
        elif cmd == "phase":
            _print(GameAPI().phase())
        elif cmd == "health":
            _print(GameAPI().health())
        elif cmd == "tools":
            from .server import TOOLS

            _print(TOOLS)
        elif cmd == "buy":
            _print(GameAPI().buy_item(slot=args.slot, item_id=args.item_id))
        elif cmd == "refresh":
            _print(GameAPI().refresh_shop())
        elif cmd == "edit":
            _print(GameAPI().set_edit_mode(args.mode))
        elif cmd == "edit-items":
            _print(GameAPI().edit_items())
        elif cmd == "edit-bags":
            _print(GameAPI().edit_bags())
        elif cmd == "edit-all":
            _print(GameAPI().edit_all())
        elif cmd == "place":
            _print(GameAPI().place_item(args.item_id, args.x, args.y))
        elif cmd == "place-bag":
            _print(GameAPI().place_bag(args.item_id, args.x, args.y))
        elif cmd == "store":
            _print(GameAPI().store_item(args.item_id))
        elif cmd == "sell":
            _print(GameAPI().sell_item(args.item_id))
        elif cmd == "set-class":
            _print(GameAPI().set_class(args.class_id, args.loadout or 0))
        elif cmd == "set-loadout":
            _print(GameAPI().set_loadout(args.index))
        elif cmd == "reserve":
            _print(GameAPI().reserve_item(slot=args.slot, item_id=args.item_id,
                                          reserved=not args.unreserve))
        elif cmd == "rotate":
            _print(GameAPI().rotate_item(args.item_id, "left" if args.left else "right"))
        elif cmd == "battle":
            _print(GameAPI().start_battle())
        elif cmd == "wait-result":
            _print(GameAPI().wait_for_result(timeout=args.timeout, auto_skip=not args.no_skip))
        elif cmd == "skip":
            _print(GameAPI().skip_result())
        elif cmd == "enter-survival":
            _print(GameAPI().enter_survival())
        elif cmd == "stop-here":
            _print(GameAPI().stop_here())
        elif cmd == "choose-survival":
            _print(GameAPI().choose_survival(args.choice))
        elif cmd == "start-run":
            api = GameAPI()
            if args.class_id is not None:
                api.set_class(args.class_id, args.loadout or 0)
            elif args.loadout is not None:
                api.set_loadout(args.loadout)
            _print(api.start_run(args.mode, force_new=args.force_new))
        elif cmd == "continue":
            _print(GameAPI().continue_run())
        elif cmd == "install":
            from .installer import install

            return install(args.game_dir)
        elif cmd == "uninstall":
            from .installer import uninstall

            return uninstall(args.game_dir)
        elif cmd == "doctor":
            from .installer import doctor

            return doctor(args.game_dir)
        elif cmd == "launch":
            from .installer import launch

            return launch(args.game_dir, wait=not args.no_wait)
        elif cmd == "http":
            from .http_api import serve

            serve(args.host, args.port)
        else:
            parser.error("unknown command")
    except GameNotRunning as exc:
        print("无法连接游戏内网桥: %s" % exc, file=sys.stderr)
        print("请先启动游戏，并确认已安装：python -m bpb_mcp install", file=sys.stderr)
        return 2
    except BridgeError as exc:
        print(json.dumps(exc.payload, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
