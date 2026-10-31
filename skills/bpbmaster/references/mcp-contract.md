# Backpack Battles MCP 操作约定

本参考依据配套项目的 `bpb_mcp/server.py`、`bpb_mcp/api.py` 和 `mod/bpb_api.gd` 核对。连接的 MCP 更新后，以当前工具 schema 和返回值为准，不要求固定服务器前缀。

## 调用和返回

MCP 工具返回通常同时有 `structuredContent` 和 `content[].text` 中的 JSON，优先使用可用的结构化结果。`isError=true`、`ok=false` 或明确错误字段均应处理，不能把成功发送请求当作操作成功。`survival_choice_required` 是必须处理的生存选择分支，不是人工接管的普通故障。

常见数据形状：

- `bpb_get_state {}`：**直接返回游戏状态对象**，如 `{"state":"shop","round":4,...}`；不是固定的 `result.state.state`。
- `bpb_get_phase {}`：返回 `{"ok":true,"state":"combat","round":4,...}`，`state` 是字符串。
- `bpb_get_backpack {}`：返回 `{"ok":true,"state":"shop","backpack":{...},"storage":[...]}`；只读，不 normalize、不写存档。
- `bpb_wait_for_result {...}`：返回 `{"ok":true,"result":"ready|skipped|already_shop|run_over|auto_returned","state":{...}}`；嵌套 `state` 可能只是轻量 phase，回店后需 `bpb_get_state`。
- 十胜提示下，`bpb_wait_for_result` 返回 `{"ok":false,"error":"survival_choice_required","state":{...}}`；`bpb_skip_result` 同名错误附 `survival`。`skip_failed.detail` 也可能嵌套该错误。这些情况先读提示并进入生存。
- `bpb_enter_survival {}` / `bpb_choose_survival {"choice":"survival"}` 成功返回 `{"ok":true,"choice":"survival","phase":{...}}`，键名是 `phase`，不是 `state`。

物品 `id` 为运行时实例 ID，不能用名称、槽位号或上一局 ID 代替。`slot` 从 1 开始，`x/y` 从 0 开始；`x` 为列，`y` 为行。`backpack.width/height` 当前通常为 9×7。

## 状态字段

| 字段 | 用途和限制 |
| --- | --- |
| `state` | `title` / `shop` / `combat`，决定当前可执行操作。 |
| `mode.name` | `Unranked` 为休闲；启动参数为小写 `unranked`。不代表生存状态。 |
| `round`, `max_rounds` | 当前回合和最大回合，当前最大 18；第 18 回合商店不等于已完成该回合。 |
| `tries` | 剩余重试次数；不是胜场，也不是战斗 HP。 |
| `wins`, `current_run_wins` | 当前 run 胜场；十胜判断以此为准。 |
| `total_wins` | 累计胜场；不是本局十胜判断依据。 |
| `hp.current/max` | 玩家生命。新局第一回合 `hp.max=25`，后续由游戏成长。 |
| `survival.prompt_visible` | 十胜“到此为止 / 进入生存”提示是否出现。 |
| `survival.can_start` | 是否允许进入生存；选择时应与提示同时为真。 |
| `survival.can_stop_here` | 是否允许“到此为止”；本技能目标下不选。 |
| `survival.was_max_wins` | 是否达到十胜上限；不能替代提示/生存判断。 |
| `survival.survival_mode` | 是否已进入生存；进入后检查为真且提示关闭。 |
| `gold`, `shop.reroll_cost` | 当前金币和真实刷新成本，不能假定刷新永远 1 金币。 |
| `shop.items[]` | 未购买商品：`id/slot/kind/is_bag/price/sell_price/on_sale/affordable/reserved/can_reserve/description/shape/cells_count` 等。 |
| `shop.choose_one` | 五选一技能商店标记；按字段判断，不把固定回合当唯一依据。 |
| `shop.reserved_items`, `reserved_count` | 已保留商品；刷新后检查是否仍生效。 |
| `backpack.bags[]` | 已部署背包：id/name/top_left/cells/shape/rotation/position/floating。`shape` 来自实际 cells。 |
| `backpack.items[]` | 已放置物品：id/name/cells/shape/top_left/rotation/bag_id/outside_bag/in_one_bag/placed_by_player/position/bbox_center/float_offset/floating。 |
| `backpack.grid[y][x]` | `bag_id` 表示背包覆盖，`item_id` 表示物品占用；`null` 是空格，不是可用背包格。 |
| `storage[]` | 储物箱物品；购买不会自动装入背包。 |
| `edit_mode.name` | `items` / `bags` / `all`。 |
| `backpack.outside_count`, `items[].outside_bag` | 辅助观察；`outside_count` 只统计完全不在包内的物品。 |
| `backpack.invalid_count`, `items[].in_one_bag` | `invalid_count` 为兼容字段；`in_one_bag=false` 只表示跨包，**不是非法**，游戏允许跨包。 |
| `items[].placed_by_player` | 是否走玩家落格流程；星位/触发辅助判断。 |
| `items[].position`, `bbox_center`, `float_offset`, `floating` | 视觉位置、目标包围盒中心、偏移；`floating` 表示偏移 >0.75px。 |
| `backpack.floating_count` | 浮空物品数；开战前应为 0。 |
| `items[].top_left` | 当前 cells 的最小 x/y 包围盒角；异形物品该点不一定被占用。 |
| `can_start_battle` | 按钮可用；不保证布局/战力合理。 |
| `can_skip_result` | 结算可跳过；不提供十胜选择内容。 |
| `last_result` | 上一回合 `win/loss/draw` 或空；不是当前战斗实时结果。 |

战斗时 `inventory_available=false`、`combat_only=true`、`backpack=null`、`shop.items=[]` 是刻意省略，不代表物品丢失。战斗期用 `bpb_get_phase` / `bpb_wait_for_result`，不读背包。

`description` 截取最多 400 字符，可能含 `$t[...]`、`[sc ...]` 标记；未展示的配方/效果不等于不存在。

## 只读信息工具

### `bpb_get_backpack {}`

返回完整 `backpack.width/height`、`bags[]`、`items[]`、`grid`、`storage[]` 和 `counts.bags/items/floating/outside`。战斗期返回 `combat_only=true`、`inventory_available=false`。只读，不移动物品/不写存档。

### `bpb_get_star_slots {"item_id"?: 整数}`

只对已放置物品返回：

- `affected_cells`：方向 key `0/2/4/7` 对应的星位/受影响格（绝对格）。
- `current_affected_items`：当前命中的物品 id/name。
- `extension_cells`
- `sockets`：宝石插槽 `name/global_position/cell/gem_id/gem_name`。

没有缓存时数组为空；不要据此臆造星位。

### `bpb_get_stamina {}`

返回：

- `player.stamina/max_stamina/stamina_regen/current_available/max_available`；当前 stamina 未暴露时 `stamina=null`、`current_available=false`，不要猜。
- `items[]`：id/name/identifier、`stamina_cost`、`is_stamina_weapon`、`stamina_factor`、`types`、`min_damage/max_damage/cooldown`、`placed`。
- `deployed_stamina_cost`：已放置物品总耗。

包含背包、储物箱和商店物品；`placed=true` 才计入部署总耗。

### `bpb_get_recipes {"item_id"?: 整数}`

返回每件物品：

- `recipes[]`：`base`、`result`（fusedItem）、`ingredients`、`all_ingredients`、`catalyst`。
- `as_ingredient[]`：作为材料的配方。
- `gated_items[]`：牌堆可生成卡牌等。

全量默认只查背包/储物箱；商店物品用 `item_id` 单查（全量遍历个别 shop recipe 不稳定）。不结构化相邻/星位条件，不把 catalyst 或描述猜成额外规则。

## 工具参数速查

| 工具 | 参数 |
| --- | --- |
| `bpb_get_state`, `bpb_get_phase`, `bpb_health` | `{}`。 |
| `bpb_get_backpack` | `{}`；只读完整布局。 |
| `bpb_get_star_slots` | 可选 `{"item_id":整数}`。 |
| `bpb_get_stamina` | `{}`。 |
| `bpb_get_recipes` | 可选 `{"item_id":整数}`；可传商店物品 id。 |
| `bpb_start_run` | `{"mode":"unranked","force_new":true}`；可选 `class_id`、`loadout`。新局第一回合 `hp.max=25`。 |
| `bpb_continue` | `{}`，继续挂起旧局。 |
| `bpb_set_class` | `{"class_id":整数,"loadout":整数}`，仅标题。 |
| `bpb_set_loadout` | `{"loadout":整数}`，仅标题。 |
| `bpb_buy_item` | `{"item_id":整数}` 或 `{"slot":1至5}`。 |
| `bpb_reserve_item` | `{"item_id":整数,"reserved":true}` 或用 `slot`。 |
| `bpb_refresh_shop` | `{}`，扣当前刷新费。 |
| `bpb_sell_item`, `bpb_store_item` | `{"item_id":整数}`。 |
| `bpb_set_fusion_lock` | `{"item_id":整数,"locked":true|false}`；锁定/解除自动融合，背包/储物箱物品可用。 |
| `bpb_socket_gem` | `{"host_id":整数,"gem_id":整数,"socket_index":整数}`；把宝石镶到宿主空镶嵌位。 |
| `bpb_unsocket_gem` | `{"host_id":整数,"socket_index":整数}`；取下宝石，优先回背包，否则储物箱。 |
| `bpb_edit_items`, `bpb_edit_bags`, `bpb_edit_all` | `{}`。 |
| `bpb_set_edit_mode` | `{"mode":"items"|"bags"|"all"}`。 |
| `bpb_place_item`, `bpb_place_bag` | `{"item_id":整数,"x":整数,"y":整数}`。 |
| `bpb_rotate_item` | `{"item_id":整数,"direction":"right"|"left"}`；原子旋转，目标需在包内且不重叠。 |
| `bpb_rotate_bag` | 同上；原子旋转空背包，非空返回 `bag_not_empty`。 |
| `bpb_start_battle`, `bpb_skip_result` | `{}`；skip 只在普通结算可跳过时使用。 |
| `bpb_enter_survival` | `{}`；提示可见且 `can_start=true` 时。 |
| `bpb_choose_survival` | `{"choice":"survival"}`；禁止 `stop`。 |
| `bpb_stop_here` | `{}`；本技能目标下禁止。 |
| `bpb_wait_for_result` | `{"timeout_seconds":90,"auto_skip":false}`；范围 5–300 秒。 |

`bpb_open_item_edit` / `bpb_open_backpack_edit` 是编辑入口别名，常规流程直接用 `bpb_edit_*`。

## 购买、出售和保留

- 普通购买进入 `storage`；购买 API 会补发 `dropped` 信号，触发 `onDropped` 类购买效果（如未挖掘潜力/Unidentified Skill）。成功后读状态确认金币/拥有物品。牌堆等购买后立即刷新 offer 的物品可能释放原实例；金币已扣或购买计数增加即成功，可能返回 `shop_refreshed=true`、`item_id=-1`，不要当失败或重复购买。
- 技能购买结束一次性技能商店并返回 `skill_id`，购买时也补发 `dropped`；仍需 `bpb_place_item` 部署。
- 保留免费，可跨刷新/下一回合；先检查 `can_reserve`。`reserved=true` 不是已购买。
- 出售只支持背包内物品；储物箱直接出售报 `sell_from_storage_unsupported`。非空背包不能卖，错误 `bag_not_empty`；先移出内容或换包。

## 融合锁定

- 物品状态里有 `fusion_locked`（兼容字段 `locked`）；`state.backpack.fusion_locked_count` 是背包内锁定数量。
- 用 `bpb_set_fusion_lock {"item_id":..., "locked":true|false}` 锁定/解除；背包和储物箱物品都可，背包本体返回 `bag_not_lockable`，未拥有物品返回 `item_not_owned`。
- 锁定后该物品不参与自动融合；需要合成时先 `locked=false`，否则配料不会被消耗/合成。
- 重复设置同一状态返回 `ok=true` 且 `changed=false`，不是失败。

## 宝石镶嵌

- 宿主物品 `state.backpack.items[].sockets` / `storage[].sockets` 列出每个 socket：`index`、`occupied`、`gem_id`、`gem_name`；`is_gem=true` 的散装物品才是宝石。
- 用 `bpb_socket_gem {"host_id":...,"gem_id":...,"socket_index":0}`；宿主必须有 socket，socket 必须为空，gem 必须未镶入。
- 用 `bpb_unsocket_gem {"host_id":...,"socket_index":0}`；宝石优先进入背包空格，没空格则进储物箱。
- 已占用的 socket 返回 `socket_occupied`；先 unsocket 再换宝石，不要假设 hotswap。
- 煤/红宝石碎片等宝石可以来自背包或储物箱；不要把它们当成普通背包物品重复摆放。

## 落格、旋转、最终化

`shape` 是相对最小 x/y 归一化的格列表；目标格为 `[(x+dx,y+dy) for (dx,dy) in shape]`，不等于矩形面积。`cells` 是实际绝对格；`top_left` 是最小包围盒角。

`bpb_place_item` 使用游戏原生流程：

1. 从储物箱移出（若来自 storage）；
2. 强制 `faceDirection=0 / rotation=0`（放置时使用基础碰撞）；
3. `pickup(当前物品位置)`；
4. 设目标包围盒中心；
5. `drop()`；
6. 校验实际 `cells`。

- **物品可以同时覆盖多个背包，游戏没有单一背包限制。** `in_one_bag=false` 不是非法。
- 成功返回真实 `cells/rotation/top_left`；失败为 `out_of_bounds`、`overlaps_item`、`placement_rejected`。不要用旧坐标补偿。
- `bpb_place_bag` 只移动空背包，非空返回 `bag_not_empty`；放置强制 `face=0/rotation=0`。

### 原子旋转（已启用）

`bpb_rotate_item` / `bpb_rotate_bag` 使用游戏内原子链，不调用 `drop()`、`tryAddItem()` 或 Hotswap：

1. 校验目标格全部在包内、无其他物品重叠；
2. `Inventory.removeItem(item)`；
3. `orientItem(item, top_left, face)`；
4. `addItemByTopLeft(item, top_left)`；
5. 清 `draggedItem`、`dragged=false`，更新 inventory。

限制：

- `bpb_rotate_item` 需已放置物品；`bpb_rotate_bag` 仅空背包。
- 目标格必须全在背包覆盖内且无重叠；否则返回 `cannot_rotate_in_place`，不移动物品。
- 不执行 affected 星星/音效；只更新位置和朝向。
- `BPB_ROTATE=0` 可关闭，返回 `rotate_disabled`。
- 旋转结果以返回/新读取的 `cells/rotation` 为准。

### 编辑模式

1. `items`：仅物品可移动/旋转；允许临时在包外；物品不能重叠/越界；背包操作报 `bags_fixed_in_item_mode`。
2. `bags`：仅背包可移动；物品绝对格不变；包可覆盖物品；包与包不能重叠。
3. `all`：只规范化位置/朝向，**不会因跨包把物品移入储物箱**。

`bpb_edit_all` / `bpb_start_battle` 只做 normalize，不移走跨包物品。开战前检查：

- `state=shop`、`edit_mode.name=all`、`can_start_battle=true`
- 关键物品实际 cells 在棋盘内、彼此不重叠
- `backpack.floating_count == 0`
- 允许跨包，不需要 `in_one_bag=true`
- 关键物品没有意外进入储物箱

**并发限制**：同一游戏同时只应有一个 MCP 客户端/服务；两个窗口并发会交错修改背包/商店，造成浮空或闪退。发现不一致先停掉多余客户端。

## 结算与生存

普通战斗推荐 `bpb_wait_for_result {"timeout_seconds":90,"auto_skip":true}`；`auto_skip=false` 在普通结算可跳过时返回 `result="ready"`。十胜提示都会返回 `survival_choice_required`，需明确选择。

处理顺序：

1. 读返回状态或 `bpb_get_phase`；只要 `survival.prompt_visible=true`，优先处理。
2. 确认 `can_start=true` 后调用 `bpb_enter_survival {}` 或 `bpb_choose_survival {"choice":"survival"}`；禁止 `stop`。
3. 检查 `ok` 和 `phase`，再用 `bpb_get_phase` 确认 `survival_mode=true`、`prompt_visible=false`。
4. 回 shop 重新读完整状态；仍 combat 则按 phase 等待。`result="skipped"` 也可能仍 combat，不能据此购物或重复开战。

`survival_prompt_not_visible` 可能表示提示尚未出现/已处理，重新读 phase；`cannot_start_survival` 检查 `can_start` 并有限等待；持续失败报告具体错误并保留当前局。仅 `wins>=10`、`was_max_wins=true` 或累计胜场高不构成再次点击理由。

`bpb_start_run` 只支持 `unranked/ranked`，不是生存选择。标题未加载可 `title_not_ready`；商店转场可短暂 `can_start_battle=false`。`timeout` 不代表本局结束。

## 异常与版本

- 游戏崩溃/重载后实例 ID 全变；重新 `bpb_get_state` / `bpb_get_backpack`。
- `bpb_health` 的 `bridge.uptime_ms` 变小提示游戏重启；不要复用旧 item id。
- `bpb_get_state` 在 combat 只返回摘要；战斗期用 phase/等待，不碰背包。
- 缺工具或字段时报告版本不匹配，不要退回旧手动流程或伪造数据。
