"""Install / uninstall / diagnose the in-game bridge."""
from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

APP_ID = "2427700"
GAME_DIR_NAME = "Backpack Battles"
EXE_NAME = "BackpackBattles.exe"
AUTOLOAD_LINE = 'McpBridge="*user://mcp/McpBridge.gd"'


# --------------------------------------------------------------------- paths
def _steam_path() -> Optional[Path]:
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                value, _ = winreg.QueryValueEx(key, "SteamPath")
                return Path(value)
        except Exception:
            pass
    for candidate in (r"D:\Steam", r"C:\Program Files (x86)\Steam", r"C:\Program Files\Steam", r"E:\Steam"):
        p = Path(candidate)
        if p.exists():
            return p
    return None


def _library_paths(steam: Optional[Path]) -> list:
    paths = []
    if steam is None:
        return paths
    paths.append(steam)
    vdf = steam / "steamapps" / "libraryfolders.vdf"
    if vdf.exists():
        try:
            text = vdf.read_text(encoding="utf-8", errors="ignore")
            for match in re.finditer(r'"path"\s+"([^"]+)"', text):
                p = Path(match.group(1).replace("\\\\", "\\"))
                if p not in paths:
                    paths.append(p)
        except Exception:
            pass
    return paths


def find_game_dir(explicit: Optional[str] = None) -> Optional[Path]:
    if explicit:
        p = Path(explicit)
        if (p / EXE_NAME).exists() or (p / GAME_DIR_NAME / EXE_NAME).exists():
            return p if (p / EXE_NAME).exists() else p / GAME_DIR_NAME
        return None
    env = os.environ.get("BPB_GAME_DIR")
    if env:
        found = find_game_dir(env)
        if found:
            return found
    steam = _steam_path()
    for lib in _library_paths(steam):
        candidate = lib / "steamapps" / "common" / GAME_DIR_NAME
        if (candidate / EXE_NAME).exists():
            return candidate
    return None


def user_data_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "Godot" / "app_userdata" / GAME_DIR_NAME
    # Godot's Linux/macOS user dir, for completeness
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Godot" / "app_userdata" / GAME_DIR_NAME
    return Path.home() / ".local" / "share" / "godot" / "app_userdata" / GAME_DIR_NAME


def mod_source_dir() -> Path:
    return Path(__file__).resolve().parent.parent / "mod"


# ---------------------------------------------------------------- override.cfg
def _merge_override(existing: str) -> str:
    lines = existing.splitlines()
    out = []
    in_autoload = False
    wrote = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_autoload and not wrote:
                out.append(AUTOLOAD_LINE)
                wrote = True
            in_autoload = stripped.lower() == "[autoload]"
            out.append(line)
            continue
        if in_autoload and stripped.startswith("McpBridge="):
            out.append(AUTOLOAD_LINE)
            wrote = True
            continue
        out.append(line)
    if in_autoload and not wrote:
        out.append(AUTOLOAD_LINE)
        wrote = True
    if not wrote:
        if out and out[-1].strip() != "":
            out.append("")
        out.append("[autoload]")
        out.append(AUTOLOAD_LINE)
    return "\n".join(out).rstrip() + "\n"


def _remove_override(existing: str) -> str:
    lines = existing.splitlines()
    out = []
    in_autoload = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_autoload = stripped.lower() == "[autoload]"
            out.append(line)
            continue
        if in_autoload and stripped.startswith("McpBridge="):
            continue
        out.append(line)
    return "\n".join(out).rstrip() + "\n"


# -------------------------------------------------------------------- install
def _write_text(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def install(game_dir: Optional[str] = None, verbose: bool = True) -> int:
    game = find_game_dir(game_dir)
    if game is None:
        print("ERROR: 找不到 Backpack Battles 安装目录。请用 --game-dir 指定。", file=sys.stderr)
        return 2
    if not (game / EXE_NAME).exists():
        print("ERROR: %s 下没有 %s" % (game, EXE_NAME), file=sys.stderr)
        return 2

    src = mod_source_dir()
    for name in ("McpBridge.gd", "bpb_api.gd"):
        if not (src / name).exists():
            print("ERROR: 缺少 mod 文件 %s" % (src / name), file=sys.stderr)
            return 2

    ud = user_data_dir()
    mcp_dir = ud / "mcp"
    mcp_dir.mkdir(parents=True, exist_ok=True)
    for name in ("McpBridge.gd", "bpb_api.gd"):
        shutil.copy2(src / name, mcp_dir / name)

    override = game / "override.cfg"
    if override.exists():
        backup = game / ("override.cfg.bak." + datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(override, backup)
        existing = override.read_text(encoding="utf-8", errors="ignore")
        merged = _merge_override(existing)
    else:
        merged = _merge_override("")
    _write_text(override, merged)

    if verbose:
        print("已安装 Backpack Battles MCP bridge")
        print("  游戏目录: %s" % game)
        print("  override: %s" % override)
        print("  脚本目录: %s" % mcp_dir)
        print("")
        print("下一步:")
        print("  1. 启动游戏（Steam 或 bpb_mcp launch）")
        print("  2. 进入一局（标题界面点“继续/新游戏”）")
        print("  3. python -m bpb_mcp.cli health")
    return 0


def uninstall(game_dir: Optional[str] = None) -> int:
    game = find_game_dir(game_dir)
    if game is not None:
        override = game / "override.cfg"
        if override.exists():
            existing = override.read_text(encoding="utf-8", errors="ignore")
            stripped = _remove_override(existing)
            if stripped.strip():
                _write_text(override, stripped)
            else:
                override.unlink()
    mcp_dir = user_data_dir() / "mcp"
    for name in ("McpBridge.gd", "bpb_api.gd"):
        p = mcp_dir / name
        if p.exists():
            p.unlink()
    print("已卸载 override.cfg 中的 autoload 与 MCP 脚本（备份文件保留）。")
    return 0


# -------------------------------------------------------------------- launch
def launch(game_dir: Optional[str] = None, wait: bool = True, timeout: float = 90.0) -> int:
    game = find_game_dir(game_dir)
    steam = _steam_path()
    exe = steam / "steam.exe" if steam else None
    if exe is not None and exe.exists():
        subprocess.Popen([str(exe), "-applaunch", APP_ID], cwd=str(exe.parent))
        print("已通过 Steam 启动 appid %s" % APP_ID)
    elif game is not None:
        subprocess.Popen([str(game / EXE_NAME)], cwd=str(game))
        print("已直接启动 %s" % (game / EXE_NAME))
    else:
        print("ERROR: 找不到 Steam 或游戏目录。", file=sys.stderr)
        return 2
    if wait:
        ok = wait_for_bridge(timeout)
        print("游戏内网桥: %s" % ("在线" if ok else "未就绪"))
        return 0 if ok else 1
    return 0


def wait_for_bridge(timeout: float = 60.0, host: str = "127.0.0.1", port: int = 8765) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.5)
    return False


# -------------------------------------------------------------------- doctor
def doctor(game_dir: Optional[str] = None) -> int:
    from .api import GameAPI
    from .bridge import BridgeError

    game = find_game_dir(game_dir)
    ud = user_data_dir()
    mcp_dir = ud / "mcp"
    checks = []
    checks.append(("game_dir", str(game) if game else None, game is not None))
    override = game / "override.cfg" if game else None
    override_ok = bool(override and override.exists() and "McpBridge=" in override.read_text(encoding="utf-8", errors="ignore"))
    checks.append(("override.cfg", str(override) if override else None, override_ok))
    for name in ("McpBridge.gd", "bpb_api.gd"):
        p = mcp_dir / name
        checks.append((name, str(p), p.exists()))
    port_ok = False
    bridge_port = int(os.environ.get("BPB_BRIDGE_PORT", 8765))
    try:
        with socket.create_connection(("127.0.0.1", bridge_port), timeout=1.0):
            port_ok = True
    except OSError:
        pass
    checks.append(("bridge port %d" % bridge_port, "127.0.0.1:%d" % bridge_port, port_ok))
    api_ok = False
    detail = ""
    if port_ok:
        try:
            pong = GameAPI().ping()
            api_ok = bool(pong.get("pong"))
            detail = str(pong)
        except BridgeError as exc:
            detail = str(exc)[:300]
    checks.append(("bridge ping", detail, api_ok))

    print("Backpack Battles MCP doctor")
    print("=" * 60)
    for name, where, ok in checks:
        print("%-20s %-5s %s" % (name, "OK" if ok else "FAIL", where or ""))
    print("=" * 60)
    if all(ok for _, _, ok in checks):
        print("全部正常。可以启动 MCP server: python -m bpb_mcp.server")
        return 0
    print("有检查项失败，请先运行: python -m bpb_mcp.install")
    return 1
