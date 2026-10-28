# Backpack Battles MCP 操作约定

本参考依据配套项目的 `bpb_mcp/server.py`、`bpb_mcp/api.py` 和 `mod/bpb_api.gd` 核对。它记录实际接口及易错语义；连接的 MCP 更新后，以当前工具 schema 和返回值为准，不要求固定服务器前缀。

## 调用和返回

MCP 工具返回通常同时有 `structuredContent` 和 `content[].text` 中的 JSON，优先使用可用的结构化结果。`isError=true`、`ok=false` 或明确错误字段均应处理，不能把成功发送请求当作操作成功。`survival_choice_required` 是必须处理的生存选择分支，不是需要人工接管的普通故障。

常见数据形状不同：

- `bpb_get_state {}`：直接返回游戏状态对象，如 `{"state":"shop","round":4,...}`；不是固定的 `result.state.state`。
- `bpb_get_phase {}`：返回 `{"ok":true,"state":"combat","round":4,...}`，其中 `state` 是字符串。
- `bpb_wait_for_result {...}`：返回 `{"ok":true,"result":"ready|skipped|already_shop|run_over|auto_returned","state":{...}}`；此处的 `state` 才是嵌套状态。嵌套对象可能只是轻量 phase，回到商店后需要 `bpb_get_state` 获取完整背包。
- 十胜提示下，`bpb_wait_for_result` 返回 `{"ok":false,"error":"survival_choice_required","state":{...}}`；`bpb_skip_result` 返回的同名错误附带 `survival` 对象。提示在自动跳过前刚出现时，也可能包装为 `{"ok":false,"error":"skip_failed","detail":{"ok":false,"error":"survival_choice_required","survival":{...}},"state":{...}}`。这些情况都先读提示并自动进入生存。
- `bpb_enter_survival {}` 或 `bpb_choose_survival {"choice":"survival"}` 成功返回 `{"ok":true,"choice":"survival","phase":{...}}`，此处键名为 `phase`，不能把它当成 `state` 嵌套；需要继续读取 phase 验证转场后的生存状态。

物品 `id` 为运行时实例 ID，不能用物品名称、槽位号或前一局 ID 代替。`slot` 从 1 开始，`x/y` 从 0 开始；`x` 为列，`y` 为行。读取 `backpack.width/height` 确定边界，当前实现通常为 9×7。

## 状态字段

| 字段 | 用途和限制 |
| --- | --- |
| `state` | `title` / `shop` / `combat`，决定当前可执行的操作。 |
| `mode.name` | `Unranked` 为休闲；启动参数则是小写 `unranked`。它不表示十胜后的生存状态。 |
| `round`, `max_rounds` | 当前回合和最大回合，当前最大值为 18；当前在第 18 回合不等于已完成该回合。 |
| `tries` | 剩余重试次数；不是胜场，也不是战斗生命。 |
| `wins`, `current_run_wins` | 两个字段均为当前 run 胜场；十胜判断以此为准，接手旧局也无需自行累计。 |
| `total_wins` | 游戏 `getRunWins()` 返回的累计胜场；不是本局十胜判断依据，新局不人为清零。 |
| `survival.prompt_visible` | 十胜“到此为止 / 进入生存模式”提示是否出现，选择分支的直接依据。 |
| `survival.can_start` | 当前是否允许进入生存；选择时应与提示可见同时为真。 |
| `survival.can_stop_here` | 是否允许“到此为止”；本技能争取十八回合的目标下不选择该项。 |
| `survival.was_max_wins` | 是否达到十胜上限；不能替代提示可见或已进入生存的判断。 |
| `survival.survival_mode` | 是否已进入生存模式；进入后检查该值为真且提示已关闭。 |
| `gold`, `shop.reroll_cost` | 当前金币和真实刷新成本，不能假定刷新永远只需 1 金币。 |
| `shop.items[]` | 当前未购买商品：`id/slot/kind/is_bag/price/sell_price/on_sale/affordable/reserved/can_reserve/description/shape/cells_count` 等。 |
| `shop.choose_one` | 五选一技能商店标记；按该字段判断，不把固定回合号当成唯一依据。 |
| `shop.reserved_items`, `reserved_count` | 已保留商品；刷新后检查保留是否仍生效。 |
| `backpack.bags[]` | 实际部署的背包、占格、形状和朝向；储物箱背包不在此列。 |
| `backpack.items[]` | 实际背包物品，包含技能；使用 `cells/shape/is_bag/description/sell_price` 等规划。 |
| `backpack.grid[y][x]` | `bag_id` 表示该格被背包覆盖，`item_id` 表示被物品占用；`null` 是棋盘空格，不是可用背包格。 |
| `storage[]` | 储物箱物品；购买不会自动装入背包。 |
| `edit_mode.name` | `items` / `bags` / `all`。 |
| `backpack.outside_count`, `items[].outside_bag` | 辅助观察字段，不能单独证明整件物品完整属于一个背包。当前实现检查物品首格，因此跨包或部分覆盖必须另查完整 `cells`。 |
| `can_start_battle` | 开战按钮可用；不保证构筑、技能、经济件都已正确上场。 |
| `can_skip_result` | 战斗结算可跳过；不提供十胜选择内容，不能据此假定生存已选。 |
| `last_result` | 上一回合 `win/loss/draw` 或空值；不是当前战斗实时结果。 |

战斗时 `inventory_available=false`、`combat_only=true`、`backpack=null`、`shop.items=[]` 是刻意省略清单，不代表所有物品丢失。战斗期间使用轻量 phase 和等待工具。

完整状态和战斗摘要中的 `wins/current_run_wins/total_wins/survival` 位于游戏状态对象顶层，轻量 `bpb_get_phase` 也提供这些字段；战斗中无需访问背包来确认胜场或生存提示。

`description` 目前截取最多 400 个字符，且可能有 `$t[...]`、`[sc ...]` 等富文本标记；描述中未出现的配方或效果不等于不存在。接口仍没有完整星位坐标和配方目录，不能构造这些字段。

## 工具参数速查

下表为短名；所有未列出的参数都不应凭空添加。需要进一步语义时查看对应小节。

| 工具 | 参数 |
| --- | --- |
| `bpb_get_state`, `bpb_get_phase`, `bpb_health` | `{}`。 |
| `bpb_start_run` | `{"mode":"unranked","force_new":true}`；可选整数 `class_id`、`loadout`，可选值以当前 schema 为准。 |
| `bpb_continue` | `{}`，继续挂起的旧局。 |
| `bpb_set_class` | `{"class_id":整数,"loadout":整数}`，仅标题界面；loadout 可省略。 |
| `bpb_set_loadout` | `{"loadout":整数}`，仅标题界面。 |
| `bpb_buy_item` | `{"item_id":整数}` 或 `{"slot":1至5}`，选一种定位。 |
| `bpb_reserve_item` | `{"item_id":整数,"reserved":true}` 或用 `slot`；取消为 `false`。 |
| `bpb_refresh_shop` | `{}`，扣除当前刷新费。 |
| `bpb_sell_item`, `bpb_store_item` | `{"item_id":整数}`。 |
| `bpb_edit_items`, `bpb_edit_bags`, `bpb_edit_all` | `{}`。 |
| `bpb_set_edit_mode` | `{"mode":"items"}` / `"bags"` / `"all"`，与上述三者等价。 |
| `bpb_place_item`, `bpb_place_bag` | `{"item_id":整数,"x":整数,"y":整数}`。 |
| `bpb_rotate_item`, `bpb_rotate_bag` | `{"item_id":整数,"direction":"right"}` 或 `"left"`。 |
| `bpb_start_battle`, `bpb_skip_result` | `{}`；后者只在普通结算确认可跳过时使用。 |
| `bpb_enter_survival` | `{}`；提示可见且 `survival.can_start=true` 时进入生存。 |
| `bpb_choose_survival` | `{"choice":"survival"}`；与进入生存等价。schema 还接受 `"stop"`，本技能目标下禁止选它。 |
| `bpb_stop_here` | `{}`；结束本局的选择，本技能目标下禁止调用。 |
| `bpb_wait_for_result` | `{"timeout_seconds":90,"auto_skip":false}`；当前超时范围 5–300 秒，默认自动跳过。 |

`bpb_open_item_edit`（可选 `item_id`）和 `bpb_open_backpack_edit` 是编辑入口别名，常规流程直接使用三段 `bpb_edit_*` 即可。

## 购买、出售和保留的真实效果

- 普通购买进入 `storage`；成功后读新状态，确认商品移除、金币改变、拥有物品新增。技能购买会结束一次性技能商店并返回 `skill_id`，仍需 `bpb_place_item` 部署。
- 保留免费，可跨刷新及下一回合；先检查 `can_reserve`。不要把 `reserved=true` 当作已经购买，也不要把所有槽位无差别锁住。
- 出售仅支持背包内物品；储物箱直接出售报 `sell_from_storage_unsupported`。先将其合法放回背包；背包满时可暂存一个非核心物品来腾位置，卖完再恢复并走完整最终化检查。
- 非空背包不能卖，错误为 `bag_not_empty`；`bpb_store_item` 也不能用于背包本体。若确有必要换包，先在编辑模式中把其内容移到可由其他背包完整覆盖的位置，再确认空包后出售，不能破坏关键容量。
- 购买/摆放等修改由游戏在商店关闭或回合推进时保存，不要以退出、重启游戏作为常规布局或购买的提交方式。

## 形状、旋转和最终化

`shape` 是当前朝向、相对占格最小 x/y 归一化的格列表；目标占格为 `[(x+dx,y+dy) for (dx,dy) in shape]`，不等于 `size[0] * size[1]` 的整块矩形。已摆物品的 `cells` 是实际绝对占格；不要假定 `top_left` 这个点本身一定被异形物品占用。

旋转可能返回新朝向、`cells` 和 `top_left`；按结果或重新读取的 `shape` 使用。`cannot_rotate_in_place` 表示旋转未成功，不要据请求方向更新计划；换空位或先存入储物箱旋转再尝试。

三个模式：

1. `items`：仅物品可移动/旋转。允许暂时位于包外；不同物品不能相互重叠、不能越界。背包操作报 `bags_fixed_in_item_mode`。
2. `bags`：仅背包可移动/旋转；可从储物箱摆入背包。固定物品的绝对格不变，包可覆盖这些物品；包与包不能重叠。物品操作报 `items_fixed_in_bag_mode`。
3. `all`：最终化时，**每件物品必须由同一个背包完整覆盖**，否则自动进入储物箱，返回 `moved_to_storage`。在该模式继续移动背包也可能让原物品掉入储物箱。

最终合法性按完整格集合验证：对每件计划上场的物品 `i`，必须有某个背包 `b` 满足 `set(i.cells) <= set(b.cells)`；并检查物品彼此不重叠、包彼此不重叠、所有格均在边界内。`B > A` 只是采购容量判断，不是这个检查的替代。

## 结算与自动进入生存

普通战斗推荐 `bpb_wait_for_result {"timeout_seconds":90,"auto_skip":true}` 推进结算；`auto_skip=false` 则在普通结算可跳过时返回 `result="ready"`。两个模式遇到十胜提示都会被拦截，返回 `survival_choice_required`，需要明确调用生存选择工具，不会自动替模型作出选择。

处理顺序：

1. 读取返回状态或 `bpb_get_phase`。无论等待工具是成功、直接返回选择错误，还是 `skip_failed` 中嵌套该错误，只要实际 `survival.prompt_visible=true` 就优先处理选择。
2. 确认 `survival.can_start=true` 后调用 `bpb_enter_survival {}`，或等价的 `bpb_choose_survival {"choice":"survival"}`。不能调用 `bpb_stop_here` 或传入 `choice="stop"`，不需要用户再次确认。
3. 检查返回 `ok` 和 `phase`，再以新的 `bpb_get_phase` 确认 `survival.survival_mode=true`、`survival.prompt_visible=false`。状态尚未稳定时有限等待，不能仅凭选择请求成功就认定转场完成。
4. 若回到 `shop`，重新读完整状态并恢复购买循环；若仍在 `combat`，依据 phase 等待或处理普通结算。`result="skipped"` 也可能在等待转场超时后附带仍为 `combat` 的状态，不能据该标签直接购物或重复开战。

`survival_prompt_not_visible` 可能表示提示尚未出现或已经处理，重新读 phase；`cannot_start_survival` 时检查 `can_start` 并有限等待；`start_survival_unavailable` 或持续无法进入则报告具体运行错误并保留当前局。已进入生存且没有提示时不重复选择；仅 `wins>=10`、`was_max_wins=true` 或累计胜场很高都不构成再次点击的理由。

`bpb_start_run` 仍只支持 `unranked/ranked`，不是生存选择工具。标题界面暂未加载可出现 `title_not_ready`，商店转场也可短暂 `can_start_battle=false`，稍等后有限重试。`timeout` 不代表本局结束；先检查 phase 和生存提示。缺少新增工具或字段时报告运行服务/客户端版本不匹配，不要退回旧的手动续局作为正常流程。
