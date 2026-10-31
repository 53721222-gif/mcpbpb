# Backpack Battles MCP

> 类似 **MCPTheSpire** 的《背包乱斗 / Backpack Battles》本地 MCP 服务：
> 在游戏内挂一个轻量 bridge，把**职业、回合、重试次数、金币、商店物品与价格、刷新费、背包摆盘、储物箱**暴露给大模型，并开放**购买、刷新、编辑背包/物品、摆放、旋转、开战**等操作。

---

## 1. 架构

```
┌──────────────────────────────┐        TCP 127.0.0.1:8765        ┌──────────────────┐
│  Backpack Battles (Godot 3.6)│  <───────────────────────────>  │  bpb_mcp.server  │
│  McpBridge.gd  (autoload)    │      newline-delimited JSON      │  (Python, stdio) │
│  bpb_api.gd    (game logic)  │                                  └────────┬─────────┘
└──────────────────────────────┘                                           │ MCP JSON-RPC
                                                                           ▼
                                                                    ┌──────────────┐
                                                                    │ LLM / MCP    │
                                                                    │ 客户端        │
                                                                    └──────────────┘
```

- **不修改 `BackpackBattles.pck`**，不注入 DLL，不使用 BepInEx。
- 利用 Godot 3.6 的 `override.cfg` 在 exe 同目录覆盖 `autoload`，脚本放在 `user://mcp/`。
- 游戏内 bridge 只监听 `127.0.0.1:8765`；Python 侧提供 MCP stdio 服务（可选 HTTP API）。
- 已在本机 **Backpack Battles 1.1.9b / Godot 3.6** 上验证；pck 未被改动，游戏日志仍显示 `[integrity_check:ok]`。

---

## 2. 功能

| 分类 | 工具名 | 说明 |
|---|---|---|
| 状态 | `bpb_get_state` | 完整状态（shop/title）；战斗期摘要；含 wins / total_wins / survival |
| 状态 | `bpb_get_phase` | 轻量状态：state/round/tries/gold/wins/total_wins/survival，战斗期安全 |
| 状态 | `bpb_get_backpack` | 完整背包布局：bags/items 位置、cells、shape、rotation、grid、storage，只读 |
| 信息 | `bpb_get_star_slots` | 星位/受影响格（方向 0/2/4/7）、当前命中物品、extension_cells、宝石 sockets |
| 信息 | `bpb_get_stamina` | 玩家 stamina/max/regen、每件物品 stamina_cost/types/伤害，已部署总耗 |
| 信息 | `bpb_get_recipes` | base/result/ingredients/催化剂、作为材料配方、牌堆 gated_items |
| 购买 | `bpb_buy_item` | 买商店物品并放入**储物箱**（`slot` 1-5 或 `item_id`）；会补发 `dropped` 信号，触发 `onDropped` 购买效果（如未挖掘潜力）；技能商店返回 `skill_id` |
| 商店 | `bpb_reserve_item` | 保留/取消保留商店物品（免费，跨刷新保留） |
| 商店 | `bpb_refresh_shop` | 刷新商店（扣金币） |
| 背包 | `bpb_store_item` | 把背包物品放回储物箱，腾出格子 |
| 背包 | `bpb_sell_item` | 出售背包物品，立即获得金币（储物箱物品需先放回背包） |
| 背包 | `bpb_set_fusion_lock` | 锁定/解除物品自动融合（`item_id` + `locked=true/false`）；背包/储物箱物品可用，背包本体不可用 |
| 宝石 | `bpb_socket_gem` | 把宝石镶到宿主物品的空镶嵌位（`host_id` + `gem_id` + `socket_index`，默认 0） |
| 宝石 | `bpb_unsocket_gem` | 从宿主镶嵌位取下宝石；优先放回背包，没空格则进储物箱 |
| 编辑 | `bpb_open_backpack_edit` | 进入背包层编辑模式（等价 bags） |
| 编辑 | `bpb_open_item_edit` | 进入物品层编辑模式（等价 items） |
| 编辑 | `bpb_edit_items` | 只编辑物品：背包固定，物品可放到任意格子（包括包外） |
| 编辑 | `bpb_edit_bags` | 只编辑背包：物品固定，背包可移动/旋转，不牵连物品 |
| 编辑 | `bpb_edit_all` | 编辑全部：只规范化落格，不再把跨包/包外物品移走 |
| 编辑 | `bpb_set_edit_mode` | 兼容别名：all/bags/items/default/bag/item |
| 摆放 | `bpb_place_item` | 原生 drop 落格（pickup 当前位置 → drop）；物品/全部模式允许包外/跨包 |
| 摆放 | `bpb_place_bag` | 移动**空背包**；非空返回 `bag_not_empty`。背包模式物品绝对位置不变 |
| 旋转 | `bpb_rotate_item` | 游戏内原子旋转：removeItem→orientItem→addItemByTopLeft，绕过 drop/hotswap；目标需在包内且不重叠；`BPB_ROTATE=0` 关闭 |
| 旋转 | `bpb_rotate_bag` | 游戏内原子旋转空背包；非空返回 `bag_not_empty`；`BPB_ROTATE=0` 关闭 |
| 战斗 | `bpb_start_battle` | 开始战斗；开战前只规范化落格，不移走跨包物品 |
| 战斗 | `bpb_wait_for_result` | 等待结算；自动跳过并回商店；十胜时不会先跳过，返回 `survival_choice_required` |
| 战斗 | `bpb_skip_result` | 手动跳过结算；十胜提示出现前后都被拦截，需先选择 |
| 10胜 | `bpb_enter_survival` | 选择“进入生存模式”；`can_start=true` 即可，原生提示延迟时会主动打开 |
| 10胜 | `bpb_stop_here` | 选择“到此为止”（结束本轮，保留胜场） |
| 10胜 | `bpb_choose_survival` | 统一选择：`choice=survival/stop` |
| 开局 | `bpb_set_class` / `bpb_set_loadout` | 标题界面选择职业 / 初始 loadout |
| 开局 | `bpb_start_run` / `bpb_continue` | 新开一局（可带 class_id/loadout）/ 继续挂起的 run |
| 诊断 | `bpb_health` | 检查网桥与当前状态 |

> 购买后物品/技能进**储物箱**，不会自动进背包；需要再调用 `bpb_place_item`。购买与放置都会补发 `dropped` 信号，触发 `onDropped` 类效果（未挖掘潜力、Lootbox、Amulet Unidentified 等）。技能也是 1×1 可摆放 Item。
>
> **融合锁定**：`state.backpack.items[].fusion_locked` / `storage[].fusion_locked` 表示物品是否锁定自动融合；`state.backpack.fusion_locked_count` 是背包内数量。用 `bpb_set_fusion_lock` 切换，锁定后不能用该物品自动合成，解锁后恢复；背包本体不可锁定。
>
> **宝石镶嵌**：`state.backpack.items[].sockets` / `storage[].sockets` 是每个镶嵌位的 `{index, occupied, gem_id, gem_name}`；`is_gem=true` 的物品是散装宝石。用 `bpb_socket_gem` 镶入、`bpb_unsocket_gem` 取下；`socketed_gems_count` 是已镶数量。
>
> **购买后编辑流程**：`bpb_edit_items`（物品可放包外）→ `bpb_edit_bags`（移动背包覆盖物品，物品固定）→ `bpb_edit_all`（规范化落格；跨包物品保留）。
>
> 标题界面先看 `state.title.classes[].loadouts`，用 `bpb_set_class` / `bpb_set_loadout` 选择，再 `bpb_start_run`。
>
> **10 胜提示**：原生提示有约 1 秒延迟；检测到 `wins=10` 且 `survival.can_start=true` 就应准备选择，不要先 `bpb_skip_result`。用 `bpb_enter_survival` 或 `bpb_stop_here` 明确选择；`bpb_skip_result` / `bpb_wait_for_result` 在提示出现前后都会被拦截，不会先结算奖杯。

---

## 3. 环境要求

- Windows 10/11
- 已安装 **Backpack Battles**（Steam AppID `2427700`）
- Python **3.8+**（本项目无第三方依赖）
- 游戏必须正在运行（bridge 在游戏进程内）

本项目在以下环境验证：

- 游戏版本 `1.1.9b`
- Godot `3.6.stable.custom_build`
- Python `3.9.1`（64 位）
- 游戏目录：`D:\Steam\steamapps\common\Backpack Battles`

---

## 4. 安装

在项目目录（例如 `D:\mcpbpb`）执行：

```bat
cd /d D:\mcpbpb
python -m bpb_mcp.cli install
python -m bpb_mcp.cli doctor
```

安装器会：

1. 自动定位 Steam 游戏目录（注册表 / `libraryfolders.vdf`，也可 `--game-dir` 指定）；
2. 复制 `mod/McpBridge.gd`、`mod/bpb_api.gd` 到：
   ```
   %APPDATA%\Godot\app_userdata\Backpack Battles\mcp\
   ```
3. 在 `BackpackBattles.exe` 同目录创建 / 合并 `override.cfg`：
   ```ini
   [autoload]
   McpBridge="*user://mcp/McpBridge.gd"
   ```
   已有 `override.cfg` 会先备份为 `override.cfg.bak.<时间戳>`，并保留其他 section / autoload。

**为什么不用改 pck？**

Godot 3.6 在启动时会读取 exe 同目录的 `override.cfg`，并据此注册 autoload；脚本从 `user://` 加载。因此：

- 不触碰 314MB 的 `BackpackBattles.pck`；
- 不需要 BepInEx / DLL 注入；
- 游戏更新后通常只需重新 `install`；
- 不会影响 pck 的完整性校验。

### 卸载

```bat
python -m bpb_mcp.cli uninstall
```

移除 `override.cfg` 中的 `McpBridge` autoload 和 `user://mcp/` 下的两个脚本；备份文件保留。

---

## 5. 启动与验证

1. 启动游戏（Steam 或 `python -m bpb_mcp.cli launch`）。
2. 进入标题界面，点击「继续 / 新游戏」，进入商店。
3. 验证：

```bat
python -m bpb_mcp.cli health
python -m bpb_mcp.cli state
```

`health` 正常输出示例：

```json
{
  "ok": true,
  "bridge": {"pong": true, "uptime_ms": 12345, "version": "0.1.0"},
  "game_state": "shop",
  "round": 2,
  "gold": 18,
  "version": "1.1.9"
}
```

---

## 6. 接入 MCP 客户端

### Claude Desktop

编辑 `claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "backpack-battles": {
      "command": "python",
      "args": ["-m", "bpb_mcp.server"],
      "cwd": "D:\\mcpbpb"
    }
  }
}
```

如果客户端找不到 `python`，把 `command` 换成 Python 绝对路径，例如：

```json
"command": "C:\\Users\\<你>\\AppData\\Local\\Programs\\Python\\Python39\\python.exe"
```

### Cursor / Cline / 其他 MCP 客户端

同样是 **stdio** 方式：

- command: `python`
- args: `["-m", "bpb_mcp.server"]`
- cwd: `D:\mcpbpb`

仓库里也提供了 `start_mcp.bat`，可直接作为 command 使用。

---

## 7. 典型工作流

```text
0. 标题界面（可选）
   bpb_get_state → state.title.classes[].loadouts
   bpb_set_class {"class_id":2,"loadout":0}
   bpb_start_run {"force_new":true}

1. bpb_get_state
   → 看 state=shop、shop.items（slot/price/size/id/kind）、shop.choose_one、
     shop.reserved、backpack.grid、storage

2. bpb_buy_item {"slot": 1}
   → 普通商店：金币扣减，物品进 storage
   → 技能商店（choose_one=true）：选择技能，金币扣减，技能进 storage，返回 skill_id

3. bpb_get_state
   → 从 storage[].id 或 buy_item 返回的 skill_id 拿到 id

4. bpb_place_item {"item_id": 123456, "x": 3, "y": 3}
   → 放进背包某个包覆盖的格子；返回 cells/top_left
   → 背包满了先 bpb_store_item {"item_id": 旧物品id} 腾格
   → 想换金币用 bpb_sell_item {"item_id": 旧物品id}

5. bpb_reserve_item {"slot": 1, "reserved": true}
   → 保留商品（免费）；reserved:false 取消保留

6. bpb_refresh_shop
   → 刷新（看 shop.reroll_cost）；保留项仍会保留

7. bpb_start_battle
   → 等待真正进入 combat 后返回

8. bpb_wait_for_result {"timeout_seconds": 90}
   → 等待结算界面，自动跳过，返回下一回合 shop 状态
   → 战斗期间 bpb_get_state 只返回摘要，不读背包；用 bpb_get_phase 轮询
```

> 模型不需要关心鼠标、拖拽、动画；所有操作都是确定性的格子/ID 操作。

### 购买后编辑顺序

```text
1. bpb_edit_items
   → 背包固定；bpb_place_item 可把物品放到任意格子，包括包外（outside_bag=true）

2. bpb_edit_bags
   → 物品固定；bpb_place_bag 移动**空背包**去覆盖物品（非空包先移出内容）；背包放置强制 face=0/rotation=0，避免显示与 cells 差 90°
   → 移动背包不会牵连物品的绝对格子

3. bpb_edit_all
   → 物品/背包都可编辑；物品可以同时覆盖多个背包，不会被自动移动
   → 返回 moved_to_storage（物品 id/name 列表）
```

- `bpb_edit_bags` 下调 `bpb_place_item` 返回 `items_fixed_in_bag_mode`。
- `bpb_edit_items` 下调 `bpb_place_bag` 返回 `bags_fixed_in_item_mode`；`bpb_rotate_bag` 对空背包原子旋转，非空返回 `bag_not_empty`。
- `bpb_edit_all` 是最终化步骤；之后检查 `backpack.floating_count == 0`，并确认关键物品仍在背包中。跨包允许。

### 10 胜提示

```text
bpb_get_state
  → state.wins=10, state.survival.was_max_wins=true
  → state.survival.can_start=true（即使 prompt_visible 还在 1 秒延迟中）
  → prompt_visible=true 时显示界面

选择一：
bpb_enter_survival          # 进入生存模式（不会先结算奖杯）
或
bpb_stop_here               # 到此为止
或
bpb_choose_survival {"choice":"survival"|"stop"}

注意：
bpb_skip_result / bpb_wait_for_result 在十胜提示出现前后都返回
survival_choice_required；不会 auto-skip 到 endRun/奖杯结算。
进入后 state.survival.just_started=true；等切回 shop 再进行下一回合。
```

---

## 8. 状态结构

`bpb_get_state` 返回的核心字段：

```json
{
  "state": "shop",
  "state_id": 1,
  "round": 2,
  "max_rounds": 18,
  "tries": 4,
  "gold": 18,
  "wins": 10,
  "current_run_wins": 10,
  "total_wins": 112,
  "survival": {
    "prompt_visible": false,
    "can_start": false,
    "can_stop_here": false,
    "was_max_wins": false,
    "survival_mode": false
  },
  "class": {"id": 0, "name": "Ranger", "name_localized": "游侠"},
  "mode": {"id": 1, "name": "Unranked"},
  "hp": {"current": 35, "max": 35},
  "edit_mode": {"id": 0, "name": "all"},
  "can_start_battle": true,
  "run_started": true,
  "last_result": "loss",
  "combat": {"visible": false, "post_combat_visible": false},
  "can_skip_result": false,
  "version": "1.1.9",

  "shop": {
    "reroll_cost": 1,
    "rerolls": 0,
    "items_bought": 1,
    "choose_one": false,
    "reserved_count": 1,
    "reserved_items": [{"id": 2483562, "name": "Customer Card", "name_localized": "会员卡"}],
    "items": [
      {
        "slot": 1,
        "kind": "item",
        "reserved": false,
        "can_reserve": true,
        "id": 124371,
        "name": "Lump of Coal",
        "name_localized": "一坨煤炭",
        "price": 2,
        "sell_price": 1,
        "rarity": "普通",
        "size": [1, 1],
        "cells_count": 1,
        "rotation": 0,
        "on_sale": false,
        "affordable": true,
        "description": "……"
      }
    ]
  },

  "backpack": {
    "width": 9,
    "height": 7,
    "bags": [
      {
        "id": 81202,
        "name": "Vineweave Basket",
        "name_localized": "藤条编织篮",
        "top_left": [2, 2],
        "cells": [[2,2],[3,2],[4,2],[2,3],[3,3],[4,3],[2,4],[3,4],[4,4]],
        "size": [3, 3],
        "rotation": 0
      }
    ],
    "items": [
      {
        "id": 81297,
        "name": "Healing Herbs",
        "name_localized": "治疗草药",
        "top_left": [2, 2],
        "cells": [[2, 2]],
        "rotation": 0,
        "price": 4,
        "sell_price": 2,
        "rarity": "普通",
        "is_bag": false,
        "bag_id": 81202,
        "bag_name": "藤条编织篮",
        "size": [1, 1]
      }
    ],
    "grid": [
      [null, null, null, ...],
      [null, null, {"bag_id":81202,"bag":"藤条编织篮"}, ...]
    ]
  },

  "storage": [
    {"id": 124371, "name": "Lump of Coal", "name_localized": "一坨煤炭", "price": 2, "sell_price": 1, "size": [1,1]}
  ]
}
```

### 标题界面

```json
{
  "state": "title",
  "title": {
    "selected_class": 0,
    "configured_loadout": "0",
    "classes": [
      {
        "id": 0,
        "name": "Ranger",
        "name_localized": "游侠",
        "loadouts": [
          {"index": 0, "items": ["Ranger Bag", "Leather Bag", "Leather Bag", "Lucky Clover", "Wooden Sword"]},
          {"index": 1, "items": ["Vineweave Basket", "Leather Bag", "Healing Herbs", "Stone"]},
          {"index": 2, "items": ["Random Loadout Bag"]}
        ]
      }
    ]
  }
}
```

### 战斗期

```json
{
  "state": "combat",
  "combat_only": true,
  "inventory_available": false,
  "round": 3,
  "tries": 4,
  "gold": 21,
  "wins": 10,
  "current_run_wins": 10,
  "total_wins": 112,
  "survival": {
    "prompt_visible": true,
    "can_start": true,
    "can_stop_here": true,
    "was_max_wins": true,
    "survival_mode": false
  },
  "can_skip_result": true,
  "last_result": "loss",
  "shop": {"items": [], "reroll_cost": 0, "rerolls": 0, "items_bought": 0,
           "choose_one": false, "reserved_count": 0, "reserved_items": []},
  "backpack": null,
  "storage": []
}
```

> 战斗期间 `bpb_get_state` 不访问背包/商店，避免游戏在战斗过渡时崩溃。需要完整背包请在 `state=shop` 时读取；等待结算用 `bpb_get_phase` / `bpb_wait_for_result`。

### 字段说明

- `state`：`title` / `shop` / `combat`。
- `inventory_available`：`false` 表示当前是战斗摘要，`backpack` 为 `null`、`shop.items` 为空。
- `combat_only`：战斗摘要标记。
- `title`：仅标题界面出现；含职业、当前选择、loadout 及其初始物品。
- `tries`：剩余重试次数（失败会减少）。
- `round`：当前回合（1-18）。
- `wins` / `current_run_wins`：当前 run 胜场（10 胜触发提示）。
- `total_wins`：累计胜场（来自游戏 `getRunWins()`）。
- `survival`：
  - `prompt_visible`：10 胜“到此为止 / 进入生存模式”提示是否出现；
  - `can_start`：是否可选择进入生存；
  - `can_stop_here`：是否可选择到此为止；
  - `was_max_wins`：是否达到 10 胜上限；
  - `survival_mode`：当前是否已在生存模式；
  - `just_started`：生存模式刚确认、仍在切回商店的过渡中；此时不要跳过结算。
- `shop.items[].price`：当前价格（含折扣）；`on_sale` 表示是否打折。
- `shop.choose_one`：当前是否为**五选一技能商店**（第 3/10 回合）。
- `shop.items[].kind`：`item` 或 `skill`（技能商店时）。
- `shop.items[].reserved` / `can_reserve`：是否已保留 / 是否可保留。
- `shop.reserved_count` / `reserved_items`：当前保留的商品数量与列表。
- `script`：物品脚本路径（可用于区分技能/普通 Exclusive 物品）。
- `shape`：物品当前朝向的归一化占用格（相对左上角）。
- `sell_price`：出售价格；用 `bpb_sell_item` 卖出。
- `fusion_locked` / `locked`：该物品是否锁定自动融合；用 `bpb_set_fusion_lock` 切换。
- `backpack.fusion_locked_count`：背包内已锁定自动融合的物品数量。
- `is_gem`：该物品是否宝石类（可镶嵌）。
- `sockets`：该物品的镶嵌位列表 `{index,occupied,gem_id,gem_name}`；用 `bpb_socket_gem` / `bpb_unsocket_gem`。
- `backpack.socketed_gems_count`：已镶入宿主物品的宝石数量（背包 + 储物箱宿主）。
- `edit_mode`：`all` / `bags` / `items`。
- `backpack.outside_count`：当前不在任何背包内的物品数量。
- `backpack.invalid_count`：兼容字段，当前不把跨包/包外算非法；正常为 0。
- `backpack.items[].outside_bag`：该物品是否在包外（物品模式可临时这样放）。
- `backpack.items[].in_one_bag`：该物品所有格是否属于同一个背包；**false 不代表非法**，游戏允许跨包。
- `backpack.items[].placed_by_player`：是否走玩家落格流程（影响星位/触发）。
- `backpack.items[].position` / `bbox_center` / `float_offset`：视觉位置、目标包围盒中心、偏移。
- `backpack.items[].floating`：该物品是否浮空（偏移 > 0.75px）。
- `backpack.floating_count`：浮空物品数量；正常应为 0。
- `backpack.grid[y][x]`：
  - `null`：空格（不在任何包内）；
  - `{"bag_id","bag"}`：只被背包覆盖，可放物品；
  - `{"bag_id","bag","item_id","item"}`：已被物品占用；
  - `{"item_id","item"}`：物品在包外（仅物品模式会出现）。
- `top_left`：该物品/背包占据格子的最小 `(x, y)`。
- `cells`：精确占用格列表。
- `storage`：储物箱物品（购买后先到这里；全部模式放不下的物品也会自动到这里）。
- `can_skip_result`：结算界面是否已出现（只有此时才能 `bpb_skip_result` / `bpb_wait_for_result` 跳过）。
- `last_result`：**上一回合**结果（`win` / `loss` / `draw`）；不是当前战斗的实时结果。

> 坐标：`x` 为列 0-8，`y` 为行 0-6。正常摆放要求物品在**背包覆盖的格子**里；`items` 模式允许临时放在包外，`all` 模式会把不落在同一背包内的物品自动移入储物箱。

> **技能商店**：第 3/10 回合 `shop.choose_one=true`，`shop.items[].kind="skill"`。技能在内部也是 `RigidBody2D` 的 Item（1×1、有价格/描述），**可以摆放**：`bpb_buy_item` 会选择技能并放入储物箱（返回 `skill_id`），购买/放置都补发 `dropped`，未挖掘潜力会正常识别；再调用 `bpb_place_item` 摆进背包；技能会随背包一起持久化，重启后仍在。

> **保留商店物品**：`bpb_reserve_item` 可保留/取消保留商品（免费）。`shop.items[].reserved`、`shop.reserved_count`、`shop.reserved_items` 会反映保留状态；保留项在刷新商店后仍保留。

---

## 9. 工具参数速查

| 工具 | 参数 |
|---|---|
| `bpb_get_state` | 无（战斗期返回摘要；含 wins/total_wins/survival） |
| `bpb_get_phase` | 无（含 wins/total_wins/survival） |
| `bpb_get_backpack` | 无（只读，不 normalize） |
| `bpb_get_star_slots` | `item_id`（可选；只查一件） |
| `bpb_get_stamina` | 无 |
| `bpb_get_recipes` | `item_id`（可选；可传商店物品 id；全量默认只查背包/储物箱） |
| `bpb_buy_item` | `slot`（1-5）或 `item_id`；技能商店时选择技能并放入储物箱，返回 `skill_id` |
| `bpb_reserve_item` | `slot` 或 `item_id`；`reserved`（默认 true，false=取消保留） |
| `bpb_store_item` | `item_id`（把背包物品放回储物箱） |
| `bpb_sell_item` | `item_id`（出售背包物品） |
| `bpb_refresh_shop` | 无 |
| `bpb_open_backpack_edit` | 无（等价 `bpb_edit_bags`） |
| `bpb_open_item_edit` | `item_id`（可选；等价 `bpb_edit_items`） |
| `bpb_edit_items` | 无（只编辑物品，背包固定） |
| `bpb_edit_bags` | 无（只编辑背包，物品固定） |
| `bpb_edit_all` | 无（全部；只规范化落格，不移走跨包物品） |
| `bpb_set_edit_mode` | `mode`: `all`/`bags`/`items`（兼容 `default`/`bag`/`item`） |
| `bpb_set_class` | `class_id`（0-6）, `loadout`（0-2，可选） |
| `bpb_set_loadout` | `loadout`（0-2） |
| `bpb_place_item` | `item_id`, `x`, `y`（原生 drop；允许跨包/包外） |
| `bpb_place_bag` | `item_id`, `x`, `y`（**仅空包**；非空返回 `bag_not_empty`） |
| `bpb_rotate_item` | `item_id`, `direction`（原子旋转，目标需在包内且不重叠） |
| `bpb_rotate_bag` | `item_id`, `direction`（原子旋转，空背包） |
| `bpb_start_battle` | 无（开战前只规范化落格，不移走跨包物品） |
| `bpb_skip_result` | 无（10 胜提示下返回 `survival_choice_required`） |
| `bpb_wait_for_result` | `timeout_seconds`（默认 90）, `auto_skip`（默认 true；提示下不自动选） |
| `bpb_enter_survival` | 无（选择进入生存模式） |
| `bpb_stop_here` | 无（选择到此为止） |
| `bpb_choose_survival` | `choice`: `survival`/`stop` |
| `bpb_start_run` | `mode`: `unranked`/`ranked`；`force_new`: 强制新开；`class_id`/`loadout`（可选） |
| `bpb_continue` | 无 |
| `bpb_health` | 无 |

---

## 10. 可选 HTTP API

给非 MCP 客户端（脚本、网页、其他 Agent 框架）：

```bat
python -m bpb_mcp.cli http --port 8766
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 网桥 + 游戏状态摘要 |
| GET | `/state` | 完整状态（战斗期自动返回摘要） |
| GET | `/phase` | 轻量状态（战斗期安全） |
| GET | `/tools` | 工具 schema |
| POST | `/action` | `{"action":"buy_item","args":{"slot":1}}` |

示例（PowerShell）：

```powershell
Invoke-RestMethod http://127.0.0.1:8766/state
Invoke-RestMethod http://127.0.0.1:8766/action -Method Post `
  -ContentType 'application/json' `
  -Body '{"action":"buy_item","args":{"slot":1}}'
```

默认只绑定 `127.0.0.1`；不要暴露到公网。

---

## 11. 命令行

```bat
python -m bpb_mcp.cli state
python -m bpb_mcp.cli phase
python -m bpb_mcp.cli health
python -m bpb_mcp.cli buy --slot 1
python -m bpb_mcp.cli reserve --slot 1
python -m bpb_mcp.cli reserve --slot 1 --unreserve
python -m bpb_mcp.cli store --item-id 123456
python -m bpb_mcp.cli sell --item-id 123456
python -m bpb_mcp.cli refresh
python -m bpb_mcp.cli edit --mode bags
python -m bpb_mcp.cli edit-items
python -m bpb_mcp.cli edit-bags
python -m bpb_mcp.cli edit-all
python -m bpb_mcp.cli set-class --class-id 2 --loadout 0
python -m bpb_mcp.cli set-loadout --index 0
python -m bpb_mcp.cli place --item-id 123456 --x 3 --y 3
python -m bpb_mcp.cli place-bag --item-id 81202 --x 2 --y 2
python -m bpb_mcp.cli rotate --item-id 123456
python -m bpb_mcp.cli battle
python -m bpb_mcp.cli wait-result
python -m bpb_mcp.cli enter-survival
python -m bpb_mcp.cli stop-here
python -m bpb_mcp.cli choose-survival --choice survival
python -m bpb_mcp.cli start-run --mode unranked
python -m bpb_mcp.cli start-run --mode unranked --force-new
python -m bpb_mcp.cli start-run --class-id 2 --loadout 0
python -m bpb_mcp.cli continue
python -m bpb_mcp.cli install
python -m bpb_mcp.cli doctor
python -m bpb_mcp.cli launch
```

---

## 12. 故障排查

### `game_not_running` / 连接被拒绝

- 游戏没启动；先启动游戏。
- `override.cfg` 没放到 `BackpackBattles.exe` 同目录。
- 游戏是旧进程：必须**重启游戏**后 autoload 才生效。
- 端口 8765 被占用：改 `mod/McpBridge.gd` 的 `PORT`，并同步 Python `Bridge` 端口（或设置 `BPB_BRIDGE_PORT`，需自行扩展）。

### `api_load_failed`

游戏内 `user://mcp/bpb_api.gd` 编译失败。查看：

```
%APPDATA%\Godot\app_userdata\Backpack Battles\logs\godot.log
```

搜索 `Parse Error`。修改 `mod/bpb_api.gd` 后重新 `install`；bridge 会按文件 MD5 **热加载**，无需重启游戏。

### `override.cfg` 看起来没生效

游戏日志应有：

```
[McpBridge] bridge starting pid=...
[McpBridge] listen 127.0.0.1:8765 err=0
```

没有则检查：

- 文件是否在 exe 同目录（不是 `Backpack Battles_Data`，游戏是 Godot 不是 Unity）；
- 文件编码是否为 UTF-8；
- 是否被其他工具覆盖（安装器会备份并合并）。

### `can_start_battle=false`

刚回到商店的 1-2 秒内，转场动画尚未结束。等一会儿再读状态，或使用 `bpb_wait_for_result`（它会等到 `can_start_battle=true`）。

### 刚启动游戏时 `start_run` 返回 `title_not_ready`

标题界面 / 职业资源还没加载完。等 3-5 秒后重试；`GameAPI.start_run` / `continue_run` 会自动重试约 6 秒。

### `skip_result` 报 `result_screen_not_visible`

结算界面还没出现。不要提前调用；用 `bpb_wait_for_result`，它只在 `can_skip_result=true` 时跳过。

### 游戏更新后失效

内部类/方法名可能变化。用 `tools/pck_inspect.py` / `tools/pck_extract.py` 重新检查 pck，调整 `mod/bpb_api.gd`。当前验证版本 `1.1.9b`。

### 安装器找不到游戏

```bat
python -m bpb_mcp.cli install --game-dir "D:\Steam\steamapps\common\Backpack Battles"
```

---

## 13. 安全声明

- 游戏内 bridge 只绑定 `127.0.0.1:8765`。
- bridge 会加载并执行 `user://mcp/bpb_api.gd` 中的 GDScript；任何能写这个文件的人都能在游戏进程内执行代码。请勿把该目录共享给不可信程序。
- HTTP API 默认只绑定 localhost；不要改成 `0.0.0.0` 暴露到公网。
- 本工具用于单机/私人对局的状态读取与操作自动化；在线排位请自行遵守游戏规则。

---

## 14. 开发

### 目录

```
mcpbpb/
├─ bpb_mcp/
│  ├─ bridge.py        TCP 客户端（127.0.0.1:8765）
│  ├─ api.py           高层 API + wait/轮询
│  ├─ server.py        MCP stdio 服务（无第三方依赖）
│  ├─ http_api.py      可选 HTTP API
│  ├─ installer.py     override.cfg / user:// 安装、doctor、launch
│  └─ cli.py           命令行
├─ mod/
│  ├─ McpBridge.gd     游戏内 TCP 网桥 + 热加载
│  └─ bpb_api.gd       游戏内状态序列化与操作逻辑
├─ tools/
│  ├─ pck_inspect.py   解析 Godot pck
│  ├─ pck_extract.py   提取 pck 文件
│  ├─ bpb_tcp.py       原始 TCP 客户端
│  └─ smoke_live.py    实时状态 smoke test
├─ tests/test_offline.py
├─ start_mcp.bat
├─ start_http.bat
└─ README.md
```

### 热加载

修改 `mod/bpb_api.gd` 后：

```bat
python -m bpb_mcp.cli install
```

bridge 在下一次 `api` 调用时按 MD5 重新编译；**不需要重启游戏**。修改 `McpBridge.gd` 才需要重启。

### 添加新操作

1. 在 `mod/bpb_api.gd` 增加 `func my_action(ctx, args): ...`；
2. 在 `bpb_mcp/api.py` 增加方法；
3. 在 `bpb_mcp/server.py` 的 `TOOLS` 和 `call_tool` 中注册；
4. `python -m bpb_mcp.cli install`。

### 测试

```bat
python -m unittest discover -s tests -v
python tools\smoke_live.py
```

---

## 15. 已知限制

- **10 胜选择**：`state.survival.prompt_visible=true` 时必须用 `bpb_enter_survival` / `bpb_stop_here` / `bpb_choose_survival` 明确选择；`bpb_skip_result` / `bpb_wait_for_result` 会返回 `survival_choice_required`，不会自动选择。
- **胜场**：`wins` / `current_run_wins` 是当前 run 胜场（10 胜触发提示）；`total_wins` 来自 `getRunWins()`，是累计胜场。
- **编辑模式**：`items` 只编辑物品（包固定，物品可临时在包外）；`bags` 只编辑背包（物品绝对格固定）；`all` 全部可编辑。**物品可以同时覆盖多个背包，游戏没有单一背包限制。**
- **背包移动/旋转**：只允许移动空背包；非空包返回 `bag_not_empty`。放置会强制 `faceDirection=0 / rotation=0`，按基础 shape 落格。旋转使用游戏内原子链：校验目标格全部在包内且无重叠，然后 `removeItem → orientItem → addItemByTopLeft`，不调用 `drop/tryAddItem/hotswap`。Pan 等 L 形已验证 4 连转、开战、重启。目标非法返回 `cannot_rotate_in_place`；`BPB_ROTATE=0` 可关闭。
- **并发限制**：同一游戏同时只应有一个 MCP 客户端/服务在操作；两个窗口并发调用会交错修改背包/商店，造成浮空或闪退。
- **落格/浮空**：`bpb_place_item` 使用游戏原生 `pickup(当前位置) → 设目标包围盒中心 → drop()`，触发正常落格回调并写回包围盒位置；跨包不拒绝。位置/朝向由游戏 drop 校验。
- **开战前最终化**：`bpb_start_battle` 只规范化位置/`placedByPlayer`，不会把跨包物品移入储物箱。
- **战斗期状态**：为避免战斗过渡时访问背包导致游戏崩溃，`bpb_get_state` 在 `state=combat` 只返回摘要（`combat_only=true`、`inventory_available=false`、`backpack=null`、`shop.items=[]`）。战斗期用 `bpb_get_phase` / `bpb_wait_for_result`，回到 shop 再读完整状态。
- **出售**：`bpb_sell_item` 只出售背包内物品；储物箱物品需先 `bpb_place_item` 放回背包。出售会立即移除物品并加金币；非空背包不能直接出售（`bag_not_empty`）。
- **物品 id**：`id` 是游戏运行时的 instance id；游戏重启/continue 后会变化，操作前重新 `bpb_get_state`。
- **技能**：技能是 1×1 可摆放 Item，会占背包格；背包满时先用 `bpb_store_item` 腾格，再 `bpb_place_item`。技能随背包持久化。
- **保留项**：`bpb_reserve_item` 免费；保留项在刷新商店后仍会保留。取消保留传 `reserved=false`。
- **存档写入时机**：购买/摆放/旋转会在商店关闭或回合推进时由游戏写入 run 存档；不要在商店界面直接退出游戏，否则本次修改可能尚未保存。
- **物品形状/旋转**：普通矩形/常见 L 形物品已验证；带自定义旋转逻辑的物品若原地放不下会回滚并返回 `cannot_rotate_in_place`，换个位置再试。
- **描述文本**：游戏返回的 `description` 含 `$t[...]`、`[sc ...]` 等富文本标记，模型可自行忽略。
- **`last_result`** 是上一回合结果，不是当前战斗实时结果；用 `can_skip_result` 判断结算是否出现。
- **游戏版本**：内部方法名基于 `1.1.9b`；更新后可能需要调整。
- **仅本地**：依赖游戏进程与 `127.0.0.1`，不支持远程/云游戏。
- **不修改 pck**：如果游戏未来移除 `override.cfg` 支持，需要改为 pck 注入方案。

---

## 16. License

MIT
