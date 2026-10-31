extends Reference

# Backpack Battles game API, executed inside the game process by McpBridge.
# Every function has the signature:  func name(ctx, args) -> Dictionary
# ctx = {bridge, tree, root, scene, req}; args = request arguments dictionary.

const CLASS_NAMES = ["Ranger", "Reaper", "Berserker", "Pyromancer", "Mage", "Adventurer", "Engineer"]
const CLASS_NAMES_ZH = ["游侠", "收割者", "狂战士", "火法师", "法师", "冒险者", "工程师"]
const MODE_NAMES = ["Ranked", "Unranked", "Lobbies", "Unselected", "History"]
const STATE_NAMES = ["title", "shop", "combat"]
const RESULT_NAMES = ["win", "loss", "draw", "run_over"]
const EDIT_MODE_NAMES = ["all", "bags", "items"]
const MAX_ROUNDS = 18

# ---------------------------------------------------------------- core lookups

func _game(ctx):
	return ctx.root.get_node_or_null("Game")

func _inv(ctx):
	var g = _game(ctx)
	if g == null or g.PLAYER == null:
		return null
	return g.PLAYER.INVENTORY

func _shop(ctx):
	return ctx.root.get_node_or_null("Main/Shop")

func _storage(ctx):
	var g = _game(ctx)
	if g == null:
		return null
	return g.STORAGEBOX

func _pair(v):
	return [int(v.x), int(v.y)]

func _cells_array(cells):
	var out = []
	for c in cells:
		out.append([int(c.x), int(c.y)])
	return out

func _sort_cells(cells):
	var n = cells.size()
	for i in range(1, n):
		var key = cells[i]
		var j = i - 1
		while j >= 0 and (cells[j].y > key.y or (cells[j].y == key.y and cells[j].x > key.x)):
			cells[j + 1] = cells[j]
			j -= 1
		cells[j + 1] = key
	return cells

func _cells_of(inv, it):
	var cells = []
	if inv == null or not is_instance_valid(it):
		return cells
	if it.isBag():
		for key in inv.bagCells.keys():
			if inv.bagCells[key] == it:
				cells.append(key)
	else:
		for key in inv.filledCells.keys():
			if inv.filledCells[key] == it:
				cells.append(key)
	return _sort_cells(cells)

func _bag_cells(inv, bag):
	var cells = []
	if inv == null or not is_instance_valid(bag):
		return cells
	for key in inv.bagCells.keys():
		if inv.bagCells[key] == bag:
			cells.append(key)
	return _sort_cells(cells)

func _in_storage(st, it):
	if st == null or not is_instance_valid(it):
		return false
	for x in st.items:
		if x == it:
			return true
	return false

func _all_items(ctx):
	var out = []
	var inv = _inv(ctx)
	var st = _storage(ctx)
	var shop = _shop(ctx)
	if inv != null:
		for it in inv.items:
			if is_instance_valid(it):
				out.append(it)
	if st != null:
		for it in st.items:
			if is_instance_valid(it):
				out.append(it)
	if shop != null:
		for s in shop.slots:
			var it = s.get("item")
			if is_instance_valid(it):
				out.append(it)
	return out

func _inventory_items(inv):
	var out = []
	var seen = {}
	if inv == null:
		return out
	for it in inv.items:
		if is_instance_valid(it) and not seen.has(it.get_instance_id()):
			seen[it.get_instance_id()] = true
			out.append(it)
	for it in inv.filledCells.values():
		if is_instance_valid(it) and not seen.has(it.get_instance_id()):
			seen[it.get_instance_id()] = true
			out.append(it)
	for it in inv.bagCells.values():
		if is_instance_valid(it) and not seen.has(it.get_instance_id()):
			seen[it.get_instance_id()] = true
			out.append(it)
	return out

func _owned_items(ctx):
	var out = []
	var seen = {}
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if inv != null:
		for it in _inventory_items(inv):
			if not seen.has(it.get_instance_id()):
				seen[it.get_instance_id()] = true
				out.append(it)
	if st != null:
		for it in st.items:
			if is_instance_valid(it) and not seen.has(it.get_instance_id()):
				seen[it.get_instance_id()] = true
				out.append(it)
	return out

func _find_item(ctx, args):
	var wanted = -1
	if args.has("item_id"):
		wanted = int(args.get("item_id"))
	var wanted_name = ""
	if args.has("name"):
		wanted_name = str(args.get("name"))
	for it in _owned_items(ctx):
		if wanted >= 0 and int(it.get_instance_id()) == wanted:
			return it
		if wanted_name != "" and str(it.getName()).to_lower() == wanted_name.to_lower():
			return it
	return null

func focus_item(ctx, args):
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if it.has_method("gainFocus"):
		it.gainFocus()
	return {"ok": true, "item_id": int(it.get_instance_id()), "name": str(it.getName())}

func _resolve_offer(shop, args):
	if shop == null:
		return null
	if args.has("slot"):
		var idx = int(args.get("slot")) - 1
		if idx >= 0 and idx < shop.slots.size():
			return shop.slots[idx]
		return null
	if args.has("item_id"):
		var wanted = int(args.get("item_id"))
		for s in shop.slots:
			var it = s.get("item")
			if is_instance_valid(it) and int(it.get_instance_id()) == wanted:
				return s
	return null

# ------------------------------------------------------------------- geometry

func _normalize_cells(cells):
	if cells.size() == 0:
		return []
	var minx = 9999
	var miny = 9999
	for c in cells:
		minx = min(minx, int(c.x))
		miny = min(miny, int(c.y))
	var out = []
	for c in cells:
		out.append(Vector2(int(c.x) - minx, int(c.y) - miny))
	return _sort_cells(out)

func _shape(it):
	# getNormalizedCollisionCells()[0] is the effective collision shape used by
	# the game's drop. Do not rotate it by faceDirection again: face only
	# changes the visual, which is the source of the 90-degree mismatch.
	var norm = it.getNormalizedCollisionCells()
	if norm == null or norm.size() == 0:
		return [Vector2(0, 0)]
	var base = norm[0]
	var out = []
	for c in base:
		out.append(Vector2(c.x, c.y))
	return _normalize_cells(out)

func _shape_size(it):
	var shape = _shape(it)
	var mx = 0
	var my = 0
	for c in shape:
		mx = max(mx, int(c.x))
		my = max(my, int(c.y))
	return [mx + 1, my + 1]

func _settle(inv, it, g):
	var cells = _cells_of(inv, it)
	if cells.size() > 0:
		it.global_position = _bbox_center(inv, cells)
	it.set("dragged", false)
	it.set("focus", false)
	if g != null:
		g.set("draggedItem", null)
		if g.has_method("recalculateCursor"):
			g.recalculateCursor()

func _normalize(ctx):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return
	g.set("draggedItem", null)
	var list = _inventory_items(inv)
	for it in list:
		if not is_instance_valid(it):
			continue
		it.set("dragged", false)
		it.set("focus", false)
		var cells = _cells_of(inv, it)
		if cells.size() > 0:
			_settle(inv, it, g)
		elif not _in_storage(st, it):
			it.pushToStorage()
	if g.has_method("recalculateCursor"):
		g.recalculateCursor()
	for bag in inv.bagCells.values():
		if is_instance_valid(bag):
			_ensure_in_items(inv, bag)

func _validate_cells(inv, cells, is_bag, item):
	var size = inv.inventorySize
	var w = int(size.x)
	var h = int(size.y)
	for c in cells:
		if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
			return "out_of_bounds"
	if is_bag:
		for c in cells:
			var other_bag = inv.bagCells.get(c, null)
			if is_instance_valid(other_bag) and other_bag != item:
				return "overlaps_bag"
			var other_item = inv.filledCells.get(c, null)
			if is_instance_valid(other_item) and other_item != item:
				var owner_bag = inv.bagCells.get(c, null)
				if owner_bag != item:
					return "overlaps_item"
	else:
		for c in cells:
			if not inv.bagCells.has(c):
				return "not_in_bag"
			var other_item = inv.filledCells.get(c, null)
			if is_instance_valid(other_item) and other_item != item:
				return "overlaps_item"
	return ""

func _validate_item_target(inv, cells, item):
	# Items may be outside bags while editing the item layer. Only bounds and
	# item-vs-item collisions matter here.
	var size = inv.inventorySize
	var w = int(size.x)
	var h = int(size.y)
	for c in cells:
		if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
			return "out_of_bounds"
		var other_item = inv.filledCells.get(c, null)
		if is_instance_valid(other_item) and other_item != item:
			return "overlaps_item"
	return ""

func _validate_rotation_item_target(inv, cells, item):
	var size = inv.inventorySize
	var w = int(size.x)
	var h = int(size.y)
	for c in cells:
		if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
			return "out_of_bounds"
		if not inv.bagCells.has(c):
			return "not_in_bag"
		var other_item = inv.filledCells.get(c, null)
		if is_instance_valid(other_item) and other_item != item:
			return "overlaps_item"
	return ""

func _validate_bag_target(inv, cells, bag):
	# Bags may be moved over fixed items (the items become covered by the bag).
	# Only other bags block the move.
	var size = inv.inventorySize
	var w = int(size.x)
	var h = int(size.y)
	for c in cells:
		if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
			return "out_of_bounds"
		var other_bag = inv.bagCells.get(c, null)
		if is_instance_valid(other_bag) and other_bag != bag:
			return "overlaps_bag"
	return ""

func _item_in_one_bag(inv, it):
	var cells = _cells_of(inv, it)
	if cells.size() == 0:
		return false
	var owner = null
	for c in cells:
		var bag = inv.bagCells.get(c, null)
		if not is_instance_valid(bag):
			return false
		if owner == null:
			owner = bag
		elif owner != bag:
			return false
	return true

func _detach_item(inv, it, was_storage, pos):
	if was_storage:
		it.pickup(pos)
	else:
		inv.removeItem(it)
		if inv.items.has(it):
			inv.items.erase(it)

func _drop_to_storage(inv, it):
	var iid = int(it.get_instance_id())
	var nm = str(it.getName())
	for c in _cells_of(inv, it):
		inv.filledCells.erase(c)
	inv.removeItem(it)
	if inv.items.has(it):
		inv.items.erase(it)
	it.pushToStorage()
	return {"item_id": iid, "name": nm}

func _restore_storage_item(inv, st, it):
	if not is_instance_valid(it):
		return
	for c in _cells_of(inv, it):
		inv.filledCells.erase(c)
	inv.removeItem(it)
	if inv.items.has(it):
		inv.items.erase(it)
	it.set("dragged", false)
	if st != null and st.has_method("addItem"):
		st.addItem(it)
	else:
		it.pushToStorage()

func _drop_uncovered(inv):
	var moved = []
	var list = _inventory_items(inv)
	for it in list:
		if not is_instance_valid(it) or it.isBag():
			continue
		if _cells_of(inv, it).size() == 0:
			continue
		if not _item_in_one_bag(inv, it):
			moved.append(_drop_to_storage(inv, it))
	return moved

func _bag_ids_for_cells(inv, cells):
	var ids = []
	for c in cells:
		var bag = inv.bagCells.get(c, null)
		if is_instance_valid(bag):
			var bid = int(bag.get_instance_id())
			if not ids.has(bid):
				ids.append(bid)
	return ids

func _target_bag_kind(inv, cells):
	var owner = null
	var has_null = false
	var ids = []
	for c in cells:
		var bag = inv.bagCells.get(c, null)
		if not is_instance_valid(bag):
			has_null = true
			continue
		var bid = int(bag.get_instance_id())
		if not ids.has(bid):
			ids.append(bid)
		if owner == null:
			owner = bag
	if has_null and ids.size() == 0:
		return {"kind": "outside", "bag": null}
	if has_null:
		return {"kind": "partial", "bag": owner}
	if ids.size() > 1:
		return {"kind": "multiple", "bag": null}
	if ids.size() == 1:
		return {"kind": "inside", "bag": owner}
	return {"kind": "outside", "bag": null}

func _avg_center(inv, cells):
	if cells.size() == 0:
		return Vector2(0, 0)
	var p = Vector2(0, 0)
	for c in cells:
		p += inv.cellToGlobalPos(c, true)
	return p / cells.size()

func _min_cell(cells):
	if cells.size() == 0:
		return Vector2(0, 0)
	var m = cells[0]
	for c in cells:
		if c.x < m.x:
			m.x = c.x
		if c.y < m.y:
			m.y = c.y
	return m

func _max_cell(cells):
	if cells.size() == 0:
		return Vector2(0, 0)
	var m = cells[0]
	for c in cells:
		if c.x > m.x:
			m.x = c.x
		if c.y > m.y:
			m.y = c.y
	return m

func _bbox_center(inv, cells):
	if cells.size() == 0:
		return Vector2(0, 0)
	var lo = _min_cell(cells)
	var hi = _max_cell(cells)
	return (inv.cellToGlobalPos(lo, true) + inv.cellToGlobalPos(hi, true)) / 2.0

func _same_cells(a, b):
	if a.size() != b.size():
		return false
	for c in a:
		if not b.has(c):
			return false
	return true

func _touch_bag(inv, cells):
	if cells.size() == 0:
		return
	var bag = inv.bagCells.get(cells[0], null)
	if not is_instance_valid(bag):
		return
	if bag.has_method("cacheAffectedCells"):
		bag.cacheAffectedCells()
	if bag.has_method("updateInsideRotationNode"):
		bag.updateInsideRotationNode()
	if bag.has_method("updateShaderRotation"):
		bag.updateShaderRotation()
	if bag.has_method("updateShadow"):
		bag.updateShadow()

func _normalize_placed(inv):
	var list = _inventory_items(inv)
	for it in list:
		if not is_instance_valid(it):
			continue
		if it.isBag():
			var bcells = _bag_cells(inv, it)
			if bcells.size() > 0:
				it.global_position = _bbox_center(inv, bcells)
				it.set("placedByPlayer", true)
				_touch_bag(inv, bcells)
			continue
		var cells = _cells_of(inv, it)
		if cells.size() > 0 and _item_in_one_bag(inv, it):
			it.global_position = _bbox_center(inv, cells)
			it.set("placedByPlayer", true)
			_touch_bag(inv, cells)

func _face_zero(it):
	it.set("faceDirection", 0)
	it.set("rotation", 0)
	it.set("rotation_degrees", 0)

func _finalize_bag(inv, bag):
	var cells = _bag_cells(inv, bag)
	if cells.size() == 0:
		return
	_face_zero(bag)
	bag.global_position = _bbox_center(inv, cells)
	bag.set("placedByPlayer", true)
	_touch_bag(inv, cells)

# --------------------------------------------------------------------- state

func _item_info(ctx, it, inv):
	var d = {}
	d["id"] = int(it.get_instance_id())
	d["name"] = str(it.getName())
	d["name_localized"] = str(it.getTranslatedName())
	d["price"] = int(it.getPrice())
	d["sell_price"] = int(it.getSellPrice())
	d["rarity"] = str(it.getTranslatedRarity())
	d["script"] = str(it.get_script().resource_path) if it.get_script() != null else ""
	d["is_bag"] = bool(it.isBag())
	d["is_gem"] = bool(it.isGem())
	d["sockets"] = _socket_list(it, inv)
	d["fusion_locked"] = bool(it.isLocked())
	d["locked"] = bool(it.isLocked())
	d["rotation"] = int(it.getFaceDirection())
	d["description"] = str(it.getDescription()).substr(0, 400)
	var size = it.getSizeInCells()
	d["size"] = [int(size.x), int(size.y)]
	d["shape"] = _cells_array(_shape(it))
	d["cells_count"] = int(it.getNumCells())
	if d["is_bag"] and (d["size"][0] <= 0 or d["size"][1] <= 0):
		d["size"] = _shape_size(it)
	var cells = _cells_of(inv, it)
	d["outside_bag"] = false
	d["in_one_bag"] = false
	d["placed_by_player"] = bool(it.get("placedByPlayer"))
	d["floating"] = false
	if cells.size() > 0:
		d["top_left"] = _pair(_min_cell(cells))
		d["cells"] = _cells_array(cells)
		d["shape"] = _cells_array(_normalize_cells(cells))
		d["in_one_bag"] = _item_in_one_bag(inv, it)
		var center = _bbox_center(inv, cells)
		var diff = it.global_position - center
		d["position"] = [it.global_position.x, it.global_position.y]
		d["bbox_center"] = [center.x, center.y]
		d["float_offset"] = [diff.x, diff.y]
		d["floating"] = diff.length() > 0.75
		var bag = inv.bagCells.get(cells[0], null)
		if is_instance_valid(bag):
			d["bag_id"] = int(bag.get_instance_id())
			d["bag_name"] = str(bag.getTranslatedName())
		else:
			d["outside_bag"] = true
	return d

func _backpack_state(ctx, inv):
	var size = inv.inventorySize
	var w = int(size.x)
	var h = int(size.y)
	var grid = []
	for y in range(h):
		var row = []
		for x in range(w):
			var key = Vector2(x, y)
			var cell = {}
			var bag = inv.bagCells.get(key, null)
			if is_instance_valid(bag):
				cell["bag_id"] = int(bag.get_instance_id())
				cell["bag"] = str(bag.getTranslatedName())
			var item = inv.filledCells.get(key, null)
			if is_instance_valid(item):
				cell["item_id"] = int(item.get_instance_id())
				cell["item"] = str(item.getTranslatedName())
			if cell.size() == 0:
				row.append(null)
			else:
				row.append(cell)
		grid.append(row)
	var bags = []
	var seen = {}
	for bag in inv.bagCells.values():
		if not is_instance_valid(bag):
			continue
		var bid = int(bag.get_instance_id())
		if seen.has(bid):
			continue
		seen[bid] = true
		var cells = _bag_cells(inv, bag)
		var d = _item_info(ctx, bag, inv)
		d["top_left"] = _pair(_min_cell(cells)) if cells.size() > 0 else [0, 0]
		d["cells"] = _cells_array(cells)
		if cells.size() > 0:
			d["shape"] = _cells_array(_normalize_cells(cells))
		bags.append(d)
	var items = []
	var list = _inventory_items(inv)
	for it in list:
		if not is_instance_valid(it):
			continue
		if it.isBag():
			continue
		# Fusion/consumption can leave a consumed item instance in inv.items
		# with no cells for a frame; it is not a backpack item.
		if _cells_of(inv, it).size() == 0:
			continue
		items.append(_item_info(ctx, it, inv))
	var outside = 0
	var invalid = 0
	var floating = 0
	var fusion_locked = 0
	for d in items:
		if bool(d.get("outside_bag", false)):
			outside += 1
		if bool(d.get("floating", false)):
			floating += 1
		if bool(d.get("fusion_locked", false)):
			fusion_locked += 1
	var socketed_gems = 0
	for owned in _owned_items(ctx):
		if is_instance_valid(owned):
			socketed_gems += owned.getGemsNoNull().size()
	return {"width": w, "height": h, "bags": bags, "items": items, "grid": grid,
		"outside_count": outside, "invalid_count": invalid, "floating_count": floating,
		"fusion_locked_count": fusion_locked,
		"socketed_gems_count": socketed_gems}

func _commit(g):
	# The game writes the run state itself at shop/round transitions. Forcing
	# actuallySaveRunState() mid-shop can write an incomplete suspended run and
	# corrupt it. Bags/items are kept in Inventory.items by _ensure_in_items,
	# so the game's own save includes them.
	pass

func _not_in_shop(g):
	if int(g.state) == 1:
		return null
	var sid = int(g.state)
	var sname = "unknown"
	if sid >= 0 and sid < STATE_NAMES.size():
		sname = STATE_NAMES[sid]
	return {"ok": false, "error": "not_in_shop", "state": sname}

func _title_state(ctx, g):
	var classes = []
	var keys = ["startingItems", "startingItems2", "startingItems3"]
	for i in range(g.classResources.size()):
		var r = g.classResources[i]
		var cname = CLASS_NAMES[i] if i < CLASS_NAMES.size() else "Unknown"
		var clocal = CLASS_NAMES_ZH[i] if i < CLASS_NAMES_ZH.size() else cname
		var loadouts = []
		for j in range(keys.size()):
			var arr = r.get(keys[j])
			var items = []
			if arr != null:
				for x in arr:
					if x != null:
						var nm = str(x.get("itemName"))
						if nm != "" and nm != "Null":
							items.append(nm)
			loadouts.append({"index": j, "items": items})
		classes.append({"id": i, "name": cname, "name_localized": clocal, "loadouts": loadouts})
	var configured = ""
	if g.has_method("getConfiguredLoadout"):
		configured = str(g.getConfiguredLoadout())
	return {"classes": classes, "selected_class": int(g.curClass),
		"configured_loadout": configured}

func _wins_info(g):
	var current = 0
	if g.has_method("getNumWins"):
		current = int(g.getNumWins())
	elif g.get("wins") != null:
		current = int(g.wins)
	var total = current
	if g.has_method("getRunWins"):
		total = int(g.getRunWins())
	return {"wins": current, "current_run_wins": current, "total_wins": total}

func _survival_info(ctx, g):
	var prompt = ctx.root.get_node_or_null("Main/UI/SurvivalPrompt")
	var visible = false
	if prompt != null and prompt.has_method("is_visible_in_tree"):
		visible = bool(prompt.is_visible_in_tree())
	var can_start = false
	if g.has_method("canStartSurvivalMode"):
		can_start = bool(g.canStartSurvivalMode())
	var was_max = false
	if g.has_method("wasMaxWins"):
		was_max = bool(g.wasMaxWins())
	var survival_mode = false
	if g.has_method("isSurvivalMode"):
		survival_mode = bool(g.isSurvivalMode())
	return {"prompt_visible": visible, "can_start": can_start,
		"can_stop_here": visible, "was_max_wins": was_max,
		"survival_mode": survival_mode}

func _combat_state(ctx, g):
	var state_id = int(g.state)
	var class_id = int(g.curClass)
	var mode_id = int(g.curMode)
	var cname = "Unknown"
	if class_id >= 0 and class_id < CLASS_NAMES.size():
		cname = CLASS_NAMES[class_id]
	var class_localized = cname
	if class_id >= 0 and class_id < CLASS_NAMES_ZH.size():
		class_localized = CLASS_NAMES_ZH[class_id]
	var mode_name = MODE_NAMES[mode_id] if mode_id >= 0 and mode_id < MODE_NAMES.size() else "Unknown"
	var last = -1
	if g.has_method("getLastRoundResult"):
		last = int(g.getLastRoundResult())
	var last_name = null
	if last == 0 or last == 1 or last == 2:
		last_name = RESULT_NAMES[last]
	var combat = ctx.root.get_node_or_null("Main/Combat")
	var post_visible = false
	if combat != null and combat.has_method("isPostCombatScreenVisible"):
		post_visible = bool(combat.isPostCombatScreenVisible())
	var out = {
		"state": "combat",
		"state_id": state_id,
		"round": int(g.curRound),
		"max_rounds": MAX_ROUNDS,
		"tries": int(g.tries),
		"gold": int(g.gold),
		"wins": _wins_info(g)["wins"],
		"current_run_wins": _wins_info(g)["current_run_wins"],
		"total_wins": _wins_info(g)["total_wins"],
		"survival": _survival_info(ctx, g),
		"class": {"id": class_id, "name": cname, "name_localized": class_localized},
		"mode": {"id": mode_id, "name": mode_name},
		"can_start_battle": false,
		"run_started": bool(g.runStarted),
		"last_result": last_name,
		"last_result_id": last,
		"combat": {"visible": combat != null and combat.visible, "post_combat_visible": post_visible},
		"can_skip_result": post_visible,
		"inventory_available": false,
		"combat_only": true,
		"shop": {"items": [], "reroll_cost": 0, "rerolls": 0, "items_bought": 0,
			"choose_one": false, "reserved_count": 0, "reserved_items": []},
		"backpack": null,
		"storage": [],
		"version": str(g.VERSION) if g.get("VERSION") != null else "",
	}
	return {"ok": true, "state": out}

func get_phase(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	var state_id = int(g.state)
	var state_name = "unknown"
	if state_id >= 0 and state_id < STATE_NAMES.size():
		state_name = STATE_NAMES[state_id]
	var last = -1
	if g.has_method("getLastRoundResult"):
		last = int(g.getLastRoundResult())
	var last_name = null
	if last == 0 or last == 1 or last == 2:
		last_name = RESULT_NAMES[last]
	var combat = ctx.root.get_node_or_null("Main/Combat")
	var post_visible = false
	if combat != null and combat.has_method("isPostCombatScreenVisible"):
		post_visible = bool(combat.isPostCombatScreenVisible())
	return {"ok": true, "state": state_name, "state_id": state_id,
		"round": int(g.curRound), "tries": int(g.tries), "gold": int(g.gold),
		"wins": _wins_info(g)["wins"], "current_run_wins": _wins_info(g)["current_run_wins"],
		"total_wins": _wins_info(g)["total_wins"], "survival": _survival_info(ctx, g),
		"can_skip_result": post_visible, "last_result": last_name,
		"version": str(g.VERSION) if g.get("VERSION") != null else ""}

func get_state(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) == 2:
		return _combat_state(ctx, g)
	var inv = _inv(ctx)
	var shop = _shop(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var state_id = int(g.state)
	var class_id = int(g.curClass)
	var mode_id = int(g.curMode)
	var state_name = "unknown"
	if state_id >= 0 and state_id < STATE_NAMES.size():
		state_name = STATE_NAMES[state_id]
	var cname = "Unknown"
	if class_id >= 0 and class_id < CLASS_NAMES.size():
		cname = CLASS_NAMES[class_id]
	var class_localized = cname
	if class_id >= 0 and class_id < CLASS_NAMES_ZH.size():
		class_localized = CLASS_NAMES_ZH[class_id]
	var mode_name = MODE_NAMES[mode_id] if mode_id >= 0 and mode_id < MODE_NAMES.size() else "Unknown"
	var edit_id = int(g.inventoryEditMode)
	var out = {}
	out["state"] = state_name
	out["state_id"] = state_id
	out["round"] = int(g.curRound)
	out["max_rounds"] = MAX_ROUNDS
	out["tries"] = int(g.tries)
	out["gold"] = int(g.gold)
	out["wins"] = _wins_info(g)["wins"]
	out["current_run_wins"] = _wins_info(g)["current_run_wins"]
	out["total_wins"] = _wins_info(g)["total_wins"]
	out["survival"] = _survival_info(ctx, g)
	out["class"] = {"id": class_id, "name": cname, "name_localized": class_localized}
	out["mode"] = {"id": mode_id, "name": mode_name}
	out["hp"] = {"current": int(g.PLAYER.curHealth), "max": int(g.PLAYER.maxHealth)}
	out["edit_mode"] = {"id": edit_id, "name": EDIT_MODE_NAMES[edit_id] if edit_id >= 0 and edit_id < EDIT_MODE_NAMES.size() else "default"}
	out["can_start_battle"] = bool(g.canSwitchToCombat)
	out["run_started"] = bool(g.runStarted)
	var last = -1
	if g.has_method("getLastRoundResult"):
		last = int(g.getLastRoundResult())
	var last_name = null
	if last == 0 or last == 1 or last == 2:
		last_name = RESULT_NAMES[last]
	out["last_result"] = last_name
	out["last_result_id"] = last
	var combat = ctx.root.get_node_or_null("Main/Combat")
	var post_visible = false
	if combat != null and combat.has_method("isPostCombatScreenVisible"):
		post_visible = bool(combat.isPostCombatScreenVisible())
	out["combat"] = {"visible": state_id == 2 and combat != null and combat.visible, "post_combat_visible": post_visible}
	out["can_skip_result"] = post_visible
	out["version"] = str(g.VERSION) if g.get("VERSION") != null else ""
	if state_id == 0:
		out["title"] = _title_state(ctx, g)
	var shop_out = {"items": [], "reroll_cost": 0, "rerolls": 0, "items_bought": 0,
		"choose_one": false, "reserved_count": 0, "reserved_items": []}
	if shop != null:
		shop_out["choose_one"] = bool(shop.chooseOneShop)
		shop_out["reroll_cost"] = int(shop.getRerollCost())
		shop_out["rerolls"] = int(shop.rerollsThisRound)
		shop_out["items_bought"] = int(shop.itemsBoughtThisRound)
		for i in range(shop.slots.size()):
			var offer = shop.slots[i]
			var it = offer.get("item")
			if not is_instance_valid(it) or offer.bought:
				continue
			var d = _item_info(ctx, it, inv)
			d["slot"] = i + 1
			d["kind"] = "skill" if shop.chooseOneShop else "item"
			d["reserved"] = bool(offer.get("reserved"))
			d["can_reserve"] = bool(offer.canPlayerReserve()) if offer.has_method("canPlayerReserve") else false
			d["on_sale"] = bool(offer.onSale)
			d["price"] = int(it.getPrice())
			d["affordable"] = int(g.gold) >= int(it.getPrice())
			shop_out["items"].append(d)
		var reserved_items = []
		if shop.has_method("getReservedItemsNoNull"):
			for it in shop.getReservedItemsNoNull():
				if is_instance_valid(it):
					reserved_items.append({"id": int(it.get_instance_id()), "name": str(it.getName()),
						"name_localized": str(it.getTranslatedName())})
		shop_out["reserved_count"] = reserved_items.size()
		shop_out["reserved_items"] = reserved_items
	out["shop"] = shop_out
	out["backpack"] = _backpack_state(ctx, inv)
	var storage = []
	if st != null:
		var slist = st.items.duplicate()
		for it in slist:
			if is_instance_valid(it):
				storage.append(_item_info(ctx, it, inv))
	out["storage"] = storage
	return {"ok": true, "state": out}

# ------------------------------------------------------------------- actions

func store_item(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null or st == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if it.isBag():
		return {"ok": false, "error": "cannot_store_bag", "detail": "move the bag instead"}
	if _in_storage(st, it):
		return {"ok": true, "already_stored": true, "item_id": int(it.get_instance_id())}
	var cells = _cells_of(inv, it)
	if cells.size() == 0:
		return {"ok": false, "error": "item_not_placed"}
	inv.removeItem(it)
	if is_instance_valid(it):
		it.pushToStorage()
	_commit(g)
	var still = _cells_of(inv, it) if is_instance_valid(it) else []
	if still.size() > 0:
		return {"ok": false, "error": "store_failed_still_placed"}
	return {"ok": true, "item_id": int(it.get_instance_id()) if is_instance_valid(it) else -1,
		"name": str(it.getName()) if is_instance_valid(it) else "",
		"storage_count": st.items.size(), "freed_cells": _cells_array(cells)}

func sell_item(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if st != null and _in_storage(st, it):
		return {"ok": false, "error": "sell_from_storage_unsupported",
			"detail": "move the item into a backpack first"}
	if it.isBag() and _bag_contents(inv, it).size() > 0:
		return {"ok": false, "error": "bag_not_empty", "detail": "empty the bag before selling it"}
	var iid = int(it.get_instance_id())
	var nm = str(it.getName())
	var price = int(it.getSellPrice())
	var gold_before = int(g.gold)
	var sb = ctx.root.find_node("Sellbox", true, false)
	if sb == null or not sb.has_method("sellItem"):
		return {"ok": false, "error": "sellbox_not_found"}
	# Remove from the backpack first: Sellbox.sellItem() only pays out and
	# queues its own removal, so calling it directly can be repeated for
	# duplicate gold while the item is still present.
	inv.removeItem(it)
	if inv.items.has(it):
		inv.items.erase(it)
	sb.sellItem(it)
	_commit(g)
	return {"ok": true, "sold": true, "item_id": iid, "name": nm,
		"sell_price": price, "gold_before": gold_before, "gold": int(g.gold),
		"gold_gained": int(g.gold) - gold_before}

func set_fusion_lock(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if it.isBag():
		return {"ok": false, "error": "bag_not_lockable",
			"detail": "fusion lock applies to items, not bags"}
	var owner = int(it.ownerType)
	if owner != 1 and owner != 2:
		return {"ok": false, "error": "item_not_owned",
			"detail": "only backpack/storage items can be fusion-locked"}
	if bool(it.get("fusing")):
		return {"ok": false, "error": "item_is_fusing"}
	var desired = true
	if args.has("locked"):
		var lv = args.get("locked")
		if typeof(lv) == TYPE_BOOL:
			desired = bool(lv)
		else:
			desired = str(lv).to_lower() in ["1", "true", "yes", "on"]
	var before = bool(it.isLocked())
	var changed = false
	if before != desired:
		# setLocked is the game's own toggle: it updates locked, removes/adds
		# the item from CraftingManager, refreshes previews and plays the
		# lock/unlock animation. Do not mutate `locked` directly.
		it.setLocked(desired, true)
		changed = true
	var after = bool(it.isLocked())
	return {"ok": true, "item_id": int(it.get_instance_id()),
		"name": str(it.getName()), "name_localized": str(it.getTranslatedName()),
		"previous_fusion_locked": before, "fusion_locked": after,
		"locked": after, "changed": changed,
		"in_storage": _in_storage(_storage(ctx), it)}

func socket_gem(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var host = _find_item(ctx, {"item_id": int(args.get("host_id", -1))})
	var gem = _find_item(ctx, {"item_id": int(args.get("gem_id", -1))})
	if host == null or gem == null:
		return {"ok": false, "error": "item_not_found"}
	if host == gem:
		return {"ok": false, "error": "same_item"}
	if host.isGem():
		return {"ok": false, "error": "host_is_gem"}
	if not host.hasSockets():
		return {"ok": false, "error": "no_sockets"}
	var socks = host.get("sockets")
	if socks == null or typeof(socks) != TYPE_ARRAY or socks.size() == 0:
		return {"ok": false, "error": "no_sockets"}
	var idx = int(args.get("socket_index", 0))
	if idx < 0 or idx >= socks.size():
		return {"ok": false, "error": "socket_index_invalid", "socket_count": socks.size()}
	if not gem.isGem():
		return {"ok": false, "error": "not_a_gem"}
	if gem.get("socket") != null:
		return {"ok": false, "error": "gem_already_socketed"}
	if is_instance_valid(socks[idx].get("gem")):
		return {"ok": false, "error": "socket_occupied",
			"detail": "unsocket the current gem first"}
	var gem_id = int(gem.get_instance_id())
	var gem_name = str(gem.getName())
	if _in_storage(st, gem):
		st.removeItem(gem)
	else:
		inv.removeItem(gem)
	if is_instance_valid(gem):
		gem.set("placedByPlayer", true)
		host.setGem(idx, gem)
		gem.global_position = socks[idx].global_position
		gem.rotation = host.rotation
		_commit(g)
		return {"ok": true, "socketed": true, "host_id": int(host.get_instance_id()),
			"host_name": str(host.getName()), "gem_id": gem_id, "gem_name": gem_name,
			"socket_index": idx, "sockets": _socket_list(host, inv)}
	return {"ok": false, "error": "gem_freed_during_socket"}

func unsocket_gem(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var host = _find_item(ctx, {"item_id": int(args.get("host_id", -1))})
	if host == null:
		return {"ok": false, "error": "item_not_found"}
	var socks = host.get("sockets")
	if socks == null or typeof(socks) != TYPE_ARRAY or socks.size() == 0:
		return {"ok": false, "error": "no_sockets"}
	var idx = int(args.get("socket_index", 0))
	if idx < 0 or idx >= socks.size():
		return {"ok": false, "error": "socket_index_invalid", "socket_count": socks.size()}
	var gem = socks[idx].get("gem")
	if not is_instance_valid(gem):
		return {"ok": false, "error": "socket_empty"}
	var gem_id = int(gem.get_instance_id())
	var gem_name = str(gem.getName())
	gem.unsocket()
	if is_instance_valid(gem):
		gem.set("placedByPlayer", true)
		var added = inv.addItemWherePossible(gem)
		if not added:
			gem.pushToStorage(Game.STORAGEBOX.center)
		_commit(g)
		return {"ok": true, "unsocketed": true, "host_id": int(host.get_instance_id()),
			"host_name": str(host.getName()), "gem_id": gem_id, "gem_name": gem_name,
			"socket_index": idx, "to_inventory": bool(added),
			"sockets": _socket_list(host, inv)}
	return {"ok": false, "error": "gem_freed_during_unsocket"}

func buy_item(ctx, args):
	var g = _game(ctx)
	var shop = _shop(ctx)
	var st = _storage(ctx)
	if g == null or shop == null or st == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var offer = _resolve_offer(shop, args)
	if offer == null:
		return {"ok": false, "error": "offer_not_found"}
	var it = offer.get("item")
	if not is_instance_valid(it):
		return {"ok": false, "error": "offer_item_freed"}
	if offer.bought:
		return {"ok": false, "error": "already_bought"}
	var price = int(it.getPrice())
	if int(g.gold) < price:
		return {"ok": false, "error": "not_enough_gold", "price": price, "gold": int(g.gold)}
	var name = str(it.getName())
	var localized = str(it.getTranslatedName())
	var item_id = int(it.get_instance_id())
	var choose_one = bool(shop.chooseOneShop)
	var gold_before = int(g.gold)
	var bought_before = int(shop.itemsBoughtThisRound)
	offer.buy()
	if choose_one:
		var ended = not bool(shop.chooseOneShop)
		var spent = int(g.gold) < gold_before
		var counted = int(shop.itemsBoughtThisRound) > bought_before
		if not (ended or spent or counted):
			return {"ok": false, "error": "choose_skill_rejected", "name": name, "price": price}
		var skill_id = -1
		if is_instance_valid(it):
			skill_id = int(it.get_instance_id())
			if not _in_storage(st, it):
				it.pushToStorage()
			if _in_storage(st, it):
				it.reactToDropResult(Item.DropResult.AddedToStorageBox)
		_commit(g)
		return {"ok": true, "chosen": true, "skill": name, "skill_id": skill_id,
			"name_localized": localized, "price": price, "gold": int(g.gold),
			"storage_count": st.items.size(),
			"note": "skill is in storage; call bpb_place_item with skill_id"}
	var spent = int(g.gold) < gold_before
	var counted = int(shop.itemsBoughtThisRound) > bought_before
	var stored = is_instance_valid(it) and _in_storage(st, it)
	# Some items (notably Deck/牌堆) immediately replace their shop offer and
	# can free the original instance. Gold spent / bought counter / storage is
	# the source of truth, not offer.bought.
	if not (spent or counted or stored):
		return {"ok": false, "error": "buy_rejected", "name": name, "price": price}
	if is_instance_valid(it) and not _in_storage(st, it):
		it.pushToStorage()
	if is_instance_valid(it) and _in_storage(st, it):
		# Normal shop purchases reach storage via a real drag/drop. Emit the
		# same dropped signal so onDropped effects (e.g. Unidentified Skill)
		# identify/trigger instead of remaining an inert floating item.
		it.reactToDropResult(Item.DropResult.AddedToStorageBox)
	_commit(g)
	var refreshed = not is_instance_valid(it)
	if is_instance_valid(offer):
		refreshed = refreshed or not bool(offer.bought)
	return {"ok": true, "item_id": item_id if is_instance_valid(it) else -1,
		"name": name, "name_localized": localized, "price": price,
		"gold": int(g.gold), "storage_count": st.items.size(),
		"gold_spent": gold_before - int(g.gold),
		"shop_refreshed": refreshed}

func reroll_shop(ctx, args):
	var g = _game(ctx)
	var shop = _shop(ctx)
	if g == null or shop == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	var cost = int(shop.getRerollCost())
	if int(g.gold) < cost:
		return {"ok": false, "error": "not_enough_gold", "cost": cost, "gold": int(g.gold)}
	var gold_before = int(g.gold)
	var rerolls_before = int(shop.rerollsThisRound)
	shop.reroll()
	var changed = int(g.gold) != gold_before or int(shop.rerollsThisRound) != rerolls_before
	_commit(g)
	return {"ok": changed, "error": "" if changed else "reroll_rejected",
		"cost": cost, "gold": int(g.gold), "rerolls": int(shop.rerollsThisRound)}

func normalize(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	_normalize(ctx)
	return {"ok": true}

func reserve_shop_item(ctx, args):
	var g = _game(ctx)
	var shop = _shop(ctx)
	if g == null or shop == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	var offer = _resolve_offer(shop, args)
	if offer == null:
		return {"ok": false, "error": "offer_not_found"}
	var it = offer.get("item")
	if not is_instance_valid(it):
		return {"ok": false, "error": "offer_item_freed"}
	if offer.has_method("canPlayerReserve") and not offer.canPlayerReserve():
		return {"ok": false, "error": "cannot_reserve", "name": str(it.getName())}
	var want = true
	if args.has("reserved"):
		want = bool(args.get("reserved"))
	var before = bool(offer.get("reserved"))
	if before == want:
		var count0 = 0
		if shop.has_method("getReservedItemsNoNull"):
			count0 = shop.getReservedItemsNoNull().size()
		return {"ok": true, "reserved": before, "unchanged": true,
			"name": str(it.getName()), "reserved_count": count0}
	var gold_before = int(g.gold)
	if offer.has_method("onReserveButtonPressed"):
		offer.onReserveButtonPressed()
	elif offer.has_method("setReserved"):
		offer.setReserved(want)
	var after = bool(offer.get("reserved"))
	if after != want and offer.has_method("setReserved"):
		offer.setReserved(want)
		after = bool(offer.get("reserved"))
	_commit(g)
	var count = 0
	if shop.has_method("getReservedItemsNoNull"):
		count = shop.getReservedItemsNoNull().size()
	return {"ok": after == want, "reserved": after, "name": str(it.getName()),
		"price": int(it.getPrice()), "gold": int(g.gold), "reserved_count": count,
		"gold_spent": gold_before - int(g.gold)}

func set_edit_mode(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var mode = str(args.get("mode", "all")).to_lower()
	var m = 0
	if mode == "bag" or mode == "bags" or mode == "1":
		m = 1
	elif mode == "item" or mode == "items" or mode == "2":
		m = 2
	elif mode == "all" or mode == "default" or mode == "0" or mode == "":
		m = 0
	else:
		return {"ok": false, "error": "invalid_mode", "mode": mode}
	if int(g.inventoryEditMode) != m:
		g.setInventoryEditMode(m)
	if m == 0:
		_normalize_placed(inv)
	return {"ok": true, "mode": m, "mode_name": EDIT_MODE_NAMES[m],
		"moved_to_storage": []}

func place_item(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if it.isBag():
		return place_bag(ctx, args)
	var mode = int(g.inventoryEditMode)
	if mode == 1:
		return {"ok": false, "error": "items_fixed_in_bag_mode",
			"detail": "switch to item/all edit mode before moving items"}
	var x = int(args.get("x", 0))
	var y = int(args.get("y", 0))
	var was_storage = _in_storage(st, it)
	var old_cells = _cells_of(inv, it)
	var old_pos = it.global_position
	# Canonical orientation: the game's drop uses base collision cells while
	# faceDirection only rotates the visual. Reset face to 0 so shape and
	# actual drop agree (1x2/1x4 long items otherwise differ by 90 degrees).
	it.set("faceDirection", 0)
	it.set("rotation", 0)
	it.set("rotation_degrees", 0)
	var shape = _shape(it)
	var target = []
	for c in shape:
		target.append(Vector2(x + int(c.x), y + int(c.y)))
	var err = _validate_item_target(inv, target, it)
	if err != "":
		return {"ok": false, "error": err, "x": x, "y": y}
	if was_storage and st != null:
		st.removeItem(it)
	var kindinfo = _target_bag_kind(inv, target)
	var kind = str(kindinfo.get("kind", "outside"))
	var pos = _bbox_center(inv, target)
	var iid = int(it.get_instance_id())
	var nm = str(it.getName())
	# Canonical placement: pickup at the CURRENT position (so pickupPosition
	# carries no synthetic offset), move to the target center, then let the
	# game's own drop() run. This is what triggers placement/effect hooks.
	it.pickup(it.global_position)
	it.global_position = pos
	it.set("placedByPlayer", true)
	var drop_res = it.drop()
	if is_instance_valid(it):
		it.reactToDropResult(drop_res)
	if not is_instance_valid(it):
		_commit(g)
		return {"ok": true, "item_id": iid, "name": nm, "placed": true,
			"replaced": true, "moved_to_storage": []}
	var actual = _cells_of(inv, it)
	if not _same_cells(actual, target):
		# Roll back using the same native flow when possible.
		if was_storage:
			_restore_storage_item(inv, st, it)
		elif old_cells.size() > 0:
			it.pickup(it.global_position)
			it.global_position = _bbox_center(inv, old_cells)
			var rollback_res = it.drop()
			if is_instance_valid(it):
				it.reactToDropResult(rollback_res)
			var restored = _cells_of(inv, it)
			if not _same_cells(restored, old_cells):
				_detach_item(inv, it, false, it.global_position)
				inv.addItem(it, old_cells, true)
				it.global_position = old_pos
		else:
			it.pickup(it.global_position)
			it.pushToStorage()
		return {"ok": false, "error": "placement_rejected", "name": nm,
			"target_cells": _cells_array(target), "actual_cells": _cells_array(actual)}
	it.global_position = _bbox_center(inv, actual)
	it.set("placedByPlayer", true)
	it.set("placed", true)
	it.set("dragged", false)
	_touch_bag(inv, actual)
	_commit(g)
	return {"ok": true, "item_id": iid, "name": nm,
		"name_localized": str(it.getTranslatedName()) if is_instance_valid(it) else "",
		"top_left": _pair(_min_cell(actual)), "cells": _cells_array(actual),
		"rotation": int(it.getFaceDirection()), "placed": true, "stored": false,
		"outside_bag": kind == "outside", "moved_to_storage": []}

func _ensure_in_items(inv, it):
	if is_instance_valid(it) and not inv.items.has(it):
		inv.items.append(it)

func _bag_contents(inv, bag):
	var out = []
	var bagset = {}
	for c in _bag_cells(inv, bag):
		bagset[c] = true
	for it in _inventory_items(inv):
		if not is_instance_valid(it) or it == bag or it.isBag():
			continue
		var cells = _cells_of(inv, it)
		var inside = false
		for c in cells:
			if bagset.has(c):
				inside = true
				break
		if inside:
			out.append({"item": it, "cells": cells})
	return out

func _detach_bag_items(inv, bag):
	var out = _bag_contents(inv, bag)
	for e in out:
		var it = e["item"]
		inv.removeItem(it)
		if inv.items.has(it):
			inv.items.erase(it)
		it.set("dragged", false)
	return out

func _readd_bag_items(inv, contents):
	for e in contents:
		var it = e["item"]
		var cells = e["cells"]
		if not is_instance_valid(it) or cells.size() == 0:
			continue
		inv.addItem(it, cells, true)
		_ensure_in_items(inv, it)
		it.global_position = _bbox_center(inv, cells)
		it.set("placedByPlayer", true)
		it.set("placed", true)
		it.set("dragged", false)

func place_bag(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var mode = int(g.inventoryEditMode)
	if mode == 2:
		return {"ok": false, "error": "bags_fixed_in_item_mode",
			"detail": "switch to bag/all edit mode before moving bags"}
	var bag = _find_item(ctx, args)
	if bag == null or not bag.isBag():
		return {"ok": false, "error": "bag_not_found"}
	var x = int(args.get("x", 0))
	var y = int(args.get("y", 0))
	var old_cells = _bag_cells(inv, bag)
	if old_cells.size() == 0:
		if st == null or not _in_storage(st, bag):
			return {"ok": false, "error": "bag_not_placed"}
		_face_zero(bag)
		var shape0 = _shape(bag)
		var target0 = []
		for c in shape0:
			target0.append(Vector2(x + int(c.x), y + int(c.y)))
		var err0 = _validate_bag_target(inv, target0, bag)
		if err0 != "":
			return {"ok": false, "error": err0, "x": x, "y": y}
		bag.pickup()
		inv.addItem(bag, target0, true)
		_ensure_in_items(inv, bag)
		_settle(inv, bag, g)
		_finalize_bag(inv, bag)
		var moved0 = []
		_commit(g)
		return {"ok": true, "bag_id": int(bag.get_instance_id()), "name": str(bag.getName()),
			"top_left": _pair(_min_cell(_bag_cells(inv, bag))), "cells": _cells_array(_bag_cells(inv, bag)),
			"moved_items": 0, "from_storage": true, "moved_to_storage": moved0}
	var occupied = _bag_contents(inv, bag)
	if occupied.size() > 0:
		return {"ok": false, "error": "bag_not_empty", "item_count": occupied.size(),
			"detail": "non-empty bag move is unsafe in the game's save/combat state; move contents out first"}
	_face_zero(bag)
	var shape = _shape(bag)
	var target = []
	for c in shape:
		target.append(Vector2(x + int(c.x), y + int(c.y)))
	var err = _validate_bag_target(inv, target, bag)
	if err != "":
		return {"ok": false, "error": err, "x": x, "y": y}
	bag.pickup()
	inv.addItem(bag, target, true)
	_ensure_in_items(inv, bag)
	_settle(inv, bag, g)
	_finalize_bag(inv, bag)
	var moved = []
	_commit(g)
	return {"ok": true, "bag_id": int(bag.get_instance_id()), "name": str(bag.getName()),
		"top_left": _pair(_min_cell(_bag_cells(inv, bag))), "cells": _cells_array(_bag_cells(inv, bag)),
		"moved_items": 0, "moved_to_storage": moved}

func _rot(it, left):
	if left:
		it.rotateLeft()
	else:
		it.rotateRight()

func rotate_item(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	if it.isBag():
		return rotate_bag(ctx, args)
	var mode = int(g.inventoryEditMode)
	if mode == 1:
		return {"ok": false, "error": "items_fixed_in_bag_mode",
			"detail": "switch to item/all edit mode before rotating items"}
	var left = str(args.get("direction", "right")) == "left"
	return {"ok": false, "error": "rotate_unsupported", "item_id": int(it.get_instance_id()),
		"detail": "rotation is disabled: experimental native rotation is unstable for irregular items and was reverted"}
	if _in_storage(st, it):
		return {"ok": false, "error": "rotate_unsupported", "item_id": int(it.get_instance_id()),
			"detail": "item face only changes the visual; the game's drop keeps the base collision. Placement resets face to 0."}
	var old_cells = _cells_of(inv, it)
	if old_cells.size() == 0:
		_rot(it, left)
		_commit(g)
		return {"ok": true, "rotation": int(it.getFaceDirection()), "placed": false}
	# The game's faceDirection only rotates the visual; drop/occupied cells keep
	# the base collision. Rotating in place can also hard-crash on the second
	# rotation. Placement resets face to 0, so item rotation is unsupported.
	return {"ok": false, "error": "rotate_unsupported", "item_id": int(it.get_instance_id()),
		"detail": "item face only changes the visual; drop uses base collision. Placement resets face to 0."}
	var top = _min_cell(old_cells)
	var old_pos = it.global_position
	it.pickup(old_pos)
	_rot(it, left)
	var shape = _shape(it)
	var target = []
	for c in shape:
		target.append(Vector2(int(top.x + c.x), int(top.y + c.y)))
	var err = _validate_item_target(inv, target, it)
	if err != "":
		_rot(it, not left)
		inv.addItem(it, old_cells, true)
		it.global_position = old_pos
		_settle(inv, it, g)
		return {"ok": false, "error": "cannot_rotate_in_place", "detail": err,
			"rotation": int(it.getFaceDirection())}
	it.global_position = _bbox_center(inv, target)
	it.set("placedByPlayer", true)
	it.drop()
	if not is_instance_valid(it):
		_commit(g)
		return {"ok": true, "rotation": -1, "placed": true, "replaced": true}
	var actual = _cells_of(inv, it)
	if not _same_cells(actual, target):
		it.pickup(it.global_position)
		inv.addItem(it, old_cells, true)
		it.global_position = old_pos
		it.set("dragged", false)
		return {"ok": false, "error": "cannot_rotate_in_place",
			"actual_cells": _cells_array(actual), "target_cells": _cells_array(target)}
	it.global_position = _bbox_center(inv, actual)
	it.set("placedByPlayer", true)
	it.set("placed", true)
	it.set("dragged", false)
	_touch_bag(inv, actual)
	_commit(g)
	return {"ok": true, "rotation": int(it.getFaceDirection()), "top_left": _pair(_min_cell(actual)),
		"cells": _cells_array(actual), "stored": false,
		"moved_to_storage": []}

func rotate_bag(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	return {"ok": false, "error": "rotate_unsupported", "item_id": int(args.get("item_id", -1)),
		"detail": "rotation is disabled: experimental native rotation is unstable for irregular items and was reverted"}
	_normalize(ctx)
	var mode = int(g.inventoryEditMode)
	if mode == 2:
		return {"ok": false, "error": "bags_fixed_in_item_mode",
			"detail": "switch to bag/all edit mode before rotating bags"}
	var bag = _find_item(ctx, args)
	if bag == null or not bag.isBag():
		return {"ok": false, "error": "bag_not_found"}
	var left = str(args.get("direction", "right")) == "left"
	if _in_storage(st, bag):
		_rot(bag, left)
		_commit(g)
		return {"ok": true, "rotation": int(bag.getFaceDirection()), "placed": false}
	var old_cells = _bag_cells(inv, bag)
	if old_cells.size() == 0:
		_rot(bag, left)
		_commit(g)
		return {"ok": true, "rotation": int(bag.getFaceDirection()), "placed": false}
	var top = _min_cell(old_cells)
	var occupied = _bag_contents(inv, bag)
	if occupied.size() > 0:
		return {"ok": false, "error": "bag_not_empty", "item_count": occupied.size(),
			"detail": "non-empty bag rotation is unsafe in the game's save/combat state; move contents out first"}
	bag.pickup()
	_rot(bag, left)
	var shape = _shape(bag)
	var target = []
	for c in shape:
		target.append(Vector2(int(top.x + c.x), int(top.y + c.y)))
	var err = _validate_bag_target(inv, target, bag)
	if err != "":
		_rot(bag, not left)
		inv.addItem(bag, old_cells, true)
		_settle(inv, bag, g)
		return {"ok": false, "error": "cannot_rotate_bag_in_place", "detail": err}
	inv.addItem(bag, target, true)
	_ensure_in_items(inv, bag)
	_settle(inv, bag, g)
	_finalize_bag(inv, bag)
	var moved = []
	_commit(g)
	return {"ok": true, "rotation": int(bag.getFaceDirection()), "top_left": _pair(top),
		"cells": _cells_array(_bag_cells(inv, bag)), "moved_items": 0,
		"moved_to_storage": moved}

func enter_survival(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	var surv = _survival_info(ctx, g)
	if not surv.prompt_visible:
		return {"ok": false, "error": "survival_prompt_not_visible", "survival": surv}
	if not surv.can_start:
		return {"ok": false, "error": "cannot_start_survival", "survival": surv}
	var combat = ctx.root.get_node_or_null("Main/Combat")
	if combat == null or not combat.has_method("startSurvivalMode"):
		return {"ok": false, "error": "start_survival_unavailable"}
	combat.startSurvivalMode()
	_commit(g)
	return {"ok": true, "choice": "survival", "phase": get_phase(ctx, {})}

func stop_here(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	var surv = _survival_info(ctx, g)
	if not surv.prompt_visible:
		return {"ok": false, "error": "survival_prompt_not_visible", "survival": surv}
	var combat = ctx.root.get_node_or_null("Main/Combat")
	if combat == null or not combat.has_method("cancelSurvivalMode"):
		return {"ok": false, "error": "stop_here_unavailable"}
	combat.cancelSurvivalMode()
	_commit(g)
	return {"ok": true, "choice": "stop", "phase": get_phase(ctx, {})}

func choose_survival(ctx, args):
	var choice = str(args.get("choice", "survival")).to_lower()
	if choice == "survival" or choice == "start" or choice == "enter":
		return enter_survival(ctx, args)
	if choice == "stop" or choice == "take" or choice == "win" or choice == "end":
		return stop_here(ctx, args)
	return {"ok": false, "error": "invalid_choice", "choice": choice}

func start_battle(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	_normalize(ctx)
	_normalize_placed(inv)
	if not g.canSwitchToCombat:
		return {"ok": false, "error": "cannot_start_battle", "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	g.switchToCombat()
	_commit(g)
	return {"ok": true, "round": int(g.curRound), "state": "combat", "moved_to_storage": []}

func skip_result(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) != 2:
		return {"ok": false, "error": "not_in_combat", "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	var surv = _survival_info(ctx, g)
	if surv.prompt_visible:
		return {"ok": false, "error": "survival_choice_required", "survival": surv}
	var combat = ctx.root.get_node_or_null("Main/Combat")
	if combat == null:
		return {"ok": false, "error": "no_combat_node"}
	if combat.has_method("isPostCombatScreenVisible") and not combat.isPostCombatScreenVisible():
		return {"ok": false, "error": "result_screen_not_visible"}
	combat.skipRoundResult()
	return {"ok": true}

func _title_ready(ctx, g):
	var t = ctx.root.get_node_or_null("Main/TitleScreen")
	if t == null or not t.visible:
		return false
	if g.classResources == null or g.classResources.size() == 0:
		return false
	return true

func _has_continue_save(g):
	var f = File.new()
	if f.file_exists("user://continue.save"):
		return true
	if f.file_exists("user://full/continue.save"):
		return true
	var dir = Directory.new()
	if dir.open("user://") == OK:
		dir.list_dir_begin()
		var n = dir.get_next()
		while n != "":
			if n != "." and n != ".." and dir.current_is_dir():
				if f.file_exists("user://%s/continue.save" % n):
					return true
				if f.file_exists("user://%s/full/continue.save" % n):
					return true
			n = dir.get_next()
		dir.list_dir_end()
	return false

func _title_has_continue(ctx):
	var t = ctx.root.get_node_or_null("Main/TitleScreen")
	if t == null:
		return false
	var btn = t.get("continueButton")
	return btn != null and bool(btn.visible)

func set_loadout(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) != 0:
		return {"ok": false, "error": "not_at_title", "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	var idx = int(args.get("loadout", 0))
	if g.has_method("setLoadout"):
		g.setLoadout(idx)
	var configured = ""
	if g.has_method("getConfiguredLoadout"):
		configured = str(g.getConfiguredLoadout())
	return {"ok": true, "index": idx, "configured": configured}

func set_class(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) != 0:
		return {"ok": false, "error": "not_at_title", "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	var idx = int(args.get("class", 0))
	g.set("curClass", idx)
	var loadout = -1
	if args.has("loadout") and g.has_method("setLoadout"):
		loadout = int(args.get("loadout", 0))
		g.setLoadout(loadout)
	var selected = ""
	if g.has_method("getSelectedClass"):
		selected = str(g.getSelectedClass())
	var configured = ""
	if g.has_method("getConfiguredLoadout"):
		configured = str(g.getConfiguredLoadout())
	return {"ok": true, "class": int(g.curClass), "selected": selected,
		"loadout": loadout, "configured": configured}

func start_run(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) != 0:
		return {"ok": false, "error": "already_in_run", "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	if not _title_ready(ctx, g):
		return {"ok": false, "error": "title_not_ready", "hint": "wait 3-5 seconds after the title screen appears"}
	var mode = 1
	if str(args.get("mode", "unranked")) == "ranked":
		mode = 0
	if bool(args.get("force_new", false)):
		if g.has_method("deleteRunState"):
			g.deleteRunState()
		g.startFreshRun(mode)
		if g.PLAYER != null:
			g.PLAYER.maxHealth = 25
			g.PLAYER.curHealth = 25
		g.titleToShop()
		if g.PLAYER != null:
			g.PLAYER.maxHealth = 25
			g.PLAYER.curHealth = 25
		return {"ok": true, "resumed": false, "forced_new": true, "mode": mode,
			"hp": {"current": int(g.PLAYER.curHealth) if g.PLAYER != null else 0,
				"max": int(g.PLAYER.maxHealth) if g.PLAYER != null else 0}}
	if _title_has_continue(ctx) and _has_continue_save(g):
		var t = ctx.root.get_node("Main/TitleScreen")
		t.onContinuePressed()
		return {"ok": true, "resumed": true, "mode": int(g.curMode), "note": "resuming suspended run"}
	g.startFreshRun(mode)
	if g.PLAYER != null:
		g.PLAYER.maxHealth = 25
		g.PLAYER.curHealth = 25
	g.titleToShop()
	if g.PLAYER != null:
		g.PLAYER.maxHealth = 25
		g.PLAYER.curHealth = 25
	return {"ok": true, "resumed": false, "mode": mode, "note": "shop transition may take 1-2 seconds",
		"hp": {"current": int(g.PLAYER.curHealth) if g.PLAYER != null else 0,
			"max": int(g.PLAYER.maxHealth) if g.PLAYER != null else 0}}

func continue_run(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) != 0:
		return {"ok": true, "already_in_run": true, "state": STATE_NAMES[int(g.state)] if g.state >= 0 and g.state < 3 else "unknown"}
	if not _title_ready(ctx, g):
		return {"ok": false, "error": "title_not_ready", "hint": "wait 3-5 seconds after the title screen appears"}
	if not _has_continue_save(g):
		return {"ok": false, "error": "no_run_to_continue"}
	if _title_has_continue(ctx):
		var t = ctx.root.get_node("Main/TitleScreen")
		t.onContinuePressed()
		return {"ok": true, "resumed": true, "mode": int(g.curMode)}
	g.titleToShop()
	return {"ok": true, "resumed": false}

# --------------------------------------------------------------- info readers

func get_backpack(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) == 2:
		return {"ok": true, "combat_only": true, "inventory_available": false,
			"state": "combat", "round": int(g.curRound)}
	var bp = _backpack_state(ctx, inv)
	var storage = []
	if st != null:
		for it in st.items:
			if is_instance_valid(it):
				storage.append(_item_info(ctx, it, inv))
	return {"ok": true, "state": "shop", "round": int(g.curRound), "gold": int(g.gold),
		"backpack": bp, "storage": storage,
		"counts": {"bags": bp["bags"].size(), "items": bp["items"].size(),
			"floating": int(bp["floating_count"]), "outside": int(bp["outside_count"])}}

func _dict_cells(value):
	var out = {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	for k in value.keys():
		var v = value[k]
		if typeof(v) == TYPE_ARRAY:
			out[str(k)] = _cells_array(v)
		else:
			out[str(k)] = []
	return out

func _affected_items(value):
	var out = {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	for k in value.keys():
		var items = value[k]
		var arr = []
		if typeof(items) == TYPE_DICTIONARY:
			for item in items.keys():
				if is_instance_valid(item):
					arr.append({"id": int(item.get_instance_id()), "name": str(item.getName())})
		out[str(k)] = arr
	return out

func _socket_info(inv, sock, index = -1):
	if not is_instance_valid(sock):
		return null
	var sname = str(sock.getName())
	if sname == "" or sname == "Null":
		sname = "GemSocket"
	var d = {"index": int(index), "name": sname,
		"global_position": [sock.global_position.x, sock.global_position.y]}
	if inv != null and inv.has_method("globalPosToCell"):
		var cell = inv.call("globalPosToCell", sock.global_position)
		if cell != null:
			d["cell"] = _pair(cell)
	var gem = sock.get("gem")
	d["occupied"] = is_instance_valid(gem)
	if is_instance_valid(gem):
		d["gem_id"] = int(gem.get_instance_id())
		d["gem_name"] = str(gem.getName())
		d["gem_key"] = str(gem.getName())
		d["gem_locked"] = bool(gem.isLocked())
	return d

func _socket_list(it, inv = null):
	var out = []
	if it == null or not is_instance_valid(it):
		return out
	var socks = it.get("sockets")
	if socks == null or typeof(socks) != TYPE_ARRAY:
		return out
	for i in range(socks.size()):
		var si = _socket_info(inv, socks[i], i)
		if si != null:
			out.append(si)
	return out

func _star_item_info(inv, it):
	var cells = _cells_of(inv, it)
	var out = {"id": int(it.get_instance_id()), "name": str(it.getName()),
		"cells": _cells_array(cells), "top_left": _pair(_min_cell(cells)) if cells.size() > 0 else [0, 0],
		"rotation": int(it.getFaceDirection()),
		"affected_cells": _dict_cells(it.get("affectedCellsCache")),
		"current_affected_items": _affected_items(it.get("currentAffectedItems")),
		"extension_cells": _cells_array(it.get("extensionCells")) if typeof(it.get("extensionCells")) == TYPE_ARRAY else [],
		"sockets": []}
	var socks = it.get("sockets")
	if socks != null and typeof(socks) == TYPE_ARRAY:
		for i in range(socks.size()):
			var si = _socket_info(inv, socks[i], i)
			if si != null:
				out["sockets"].append(si)
	return out

func get_star_slots(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) == 2:
		return {"ok": true, "combat_only": true, "inventory_available": false, "items": []}
	var want = int(args.get("item_id", -1))
	var items = []
	for it in _inventory_items(inv):
		if not is_instance_valid(it) or it.isBag():
			continue
		if _cells_of(inv, it).size() == 0:
			continue
		if want >= 0 and int(it.get_instance_id()) != want:
			continue
		items.append(_star_item_info(inv, it))
	return {"ok": true, "state": "shop", "round": int(g.curRound), "items": items,
		"note": "affected_cells 的 key 为星位方向（0/2/4/7）；current_affected_items 为当前命中的物品；sockets 为宝石插槽。"}

func _desc_id(d):
	if d == null:
		return ""
	if d.get("identifier") != null:
		return str(d.get("identifier"))
	if d.get("name") != null:
		return str(d.get("name"))
	return ""

func _flatten_descs(value, out):
	if typeof(value) != TYPE_ARRAY:
		return
	for x in value:
		if typeof(x) == TYPE_ARRAY:
			_flatten_descs(x, out)
		elif x != null:
			var id = _desc_id(x)
			if id != "" and not out.has(id):
				out[id] = true

func _recipe_info(r):
	if r == null:
		return null
	var ids = {}
	_flatten_descs(r.get("ingredients"), ids)
	var allids = {}
	_flatten_descs(r.get("allIngredients"), allids)
	return {"base": _desc_id(r.get("baseItem")),
		"result": _desc_id(r.get("fusedItem")),
		"ingredients": ids.keys(),
		"all_ingredients": allids.keys(),
		"catalyst": str(r.get("catalyst"))}

func _recipes_for_item(ctx, it, inv):
	var d = it.get("descriptor")
	var out = {"id": int(it.get_instance_id()), "name": str(it.getName()),
		"identifier": _desc_id(d), "stamina_cost": 0.0,
		"recipes": [], "as_ingredient": [], "gated_items": []}
	if d == null:
		return out
	out["stamina_cost"] = float(d.get("staminaCost"))
	var recs = d.get("recipes")
	if typeof(recs) == TYPE_ARRAY:
		for r in recs:
			var ri = _recipe_info(r)
			if ri != null:
				out["recipes"].append(ri)
	var asing = d.get("recipesAsIngredient")
	if typeof(asing) == TYPE_ARRAY:
		for r in asing:
			var ri2 = _recipe_info(r)
			if ri2 != null:
				out["as_ingredient"].append(ri2)
	var gated = d.get("gatedItems")
	if typeof(gated) == TYPE_ARRAY:
		for x in gated:
			var gid = _desc_id(x)
			if gid != "":
				out["gated_items"].append(gid)
	return out

func _all_info_items(ctx, include_shop = false):
	var g = _game(ctx)
	var inv = _inv(ctx)
	var st = _storage(ctx)
	var seen = {}
	var out = []
	if inv != null:
		for it in _inventory_items(inv):
			if not is_instance_valid(it) or it.isBag():
				continue
			var iid = int(it.get_instance_id())
			if seen.has(iid):
				continue
			seen[iid] = true
			out.append(it)
	if st != null:
		for it in st.items:
			if not is_instance_valid(it) or it.isBag():
				continue
			var sid = int(it.get_instance_id())
			if seen.has(sid):
				continue
			seen[sid] = true
			out.append(it)
	if not include_shop:
		return out
	var shop = _shop(ctx)
	if shop != null:
		for offer in shop.slots:
			if offer == null or offer.get("item") == null:
				continue
			var oi = offer.get("item")
			if not is_instance_valid(oi) or oi.isBag():
				continue
			var oid = int(oi.get_instance_id())
			if seen.has(oid):
				continue
			seen[oid] = true
			out.append(oi)
	return out

func get_stamina(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) == 2:
		return {"ok": true, "combat_only": true, "inventory_available": false}
	var p = g.PLAYER
	var cur = p.get("stamina") if p != null else null
	if cur == null and p != null:
		cur = p.get("currentStamina")
	var mx = p.get("maxStamina") if p != null else null
	var items = []
	var total = 0.0
	for it in _all_info_items(ctx, true):
		var d = it.get("descriptor")
		var cost = float(d.get("staminaCost")) if d != null else 0.0
		var placed = _cells_of(inv, it).size() > 0
		var types = d.get("types") if d != null else []
		var info = {"id": int(it.get_instance_id()), "name": str(it.getName()),
			"identifier": _desc_id(d), "stamina_cost": cost,
			"is_stamina_weapon": cost > 0.0,
			"stamina_factor": float(it.get("staminaFactor")),
			"placed": placed, "types": types if typeof(types) == TYPE_ARRAY else [],
			"min_damage": float(d.get("minDam")) if d != null else 0.0,
			"max_damage": float(d.get("maxDam")) if d != null else 0.0,
			"cooldown": float(d.get("cd")) if d != null else 0.0}
		if placed:
			total += cost
		items.append(info)
	return {"ok": true, "state": "shop", "round": int(g.curRound),
		"player": {"stamina": cur, "max_stamina": mx,
			"stamina_regen": p.get("staminaRegen") if p != null else null,
			"current_available": cur != null, "max_available": mx != null},
		"deployed_stamina_cost": total, "items": items}

func _rotation_target(cells, left):
	var top = _min_cell(cells)
	var rel = []
	for c in cells:
		var r = c - top
		var p = Vector2(r.y, -r.x) if left else Vector2(-r.y, r.x)
		rel.append(p)
	var norm = _normalize_cells(rel)
	var target = []
	for c in norm:
		target.append(top + c)
	return target

func _set_face(it, face):
	it.set("faceDirection", face)
	it.set("rotation_degrees", face * 90)
	it.set("rotation", deg2rad(face * 90))

func _rotate_item_exec(ctx, g, inv, st, it, left):
	if _in_storage(st, it):
		return {"ok": false, "error": "rotate_storage_unsupported", "item_id": int(it.get_instance_id()),
			"detail": "rotate the item after placing it; storage rotation has no cells to update"}
	var old_cells = _cells_of(inv, it)
	if old_cells.size() == 0:
		return {"ok": false, "error": "item_not_placed"}
	var target = _rotation_target(old_cells, left)
	var err = _validate_item_target(inv, target, it)
	if err != "":
		return {"ok": false, "error": "cannot_rotate_in_place", "detail": err,
			"cells": _cells_array(old_cells)}
	var face = (int(it.getFaceDirection()) + (3 if left else 1)) % 4
	var old_pos = it.global_position
	_detach_item(inv, it, false, it.global_position)
	inv.addItem(it, target, true)
	_ensure_in_items(inv, it)
	var actual = _cells_of(inv, it)
	if not _same_cells(actual, target):
		_detach_item(inv, it, false, it.global_position)
		inv.addItem(it, old_cells, true)
		it.global_position = old_pos
		return {"ok": false, "error": "cannot_rotate_in_place",
			"target_cells": _cells_array(target), "actual_cells": _cells_array(actual)}
	_set_face(it, face)
	it.global_position = _bbox_center(inv, actual)
	it.set("placedByPlayer", true)
	it.set("placed", true)
	it.set("dragged", false)
	_touch_bag(inv, actual)
	_commit(g)
	return {"ok": true, "rotation": face, "top_left": _pair(_min_cell(actual)),
		"cells": _cells_array(actual), "stored": false, "moved_to_storage": []}

func _rotate_bag_exec(ctx, g, inv, st, args):
	var bag = _find_item(ctx, args)
	if bag == null or not bag.isBag():
		return {"ok": false, "error": "bag_not_found"}
	if _in_storage(st, bag):
		return {"ok": false, "error": "rotate_storage_unsupported", "bag_id": int(bag.get_instance_id())}
	var occupied = _bag_contents(inv, bag)
	if occupied.size() > 0:
		return {"ok": false, "error": "bag_not_empty", "item_count": occupied.size(),
			"detail": "move contents out before rotating a bag"}
	var old_cells = _bag_cells(inv, bag)
	if old_cells.size() == 0:
		return {"ok": false, "error": "bag_not_placed"}
	var left = str(args.get("direction", "right")) == "left"
	var target = _rotation_target(old_cells, left)
	var err = _validate_bag_target(inv, target, bag)
	if err != "":
		return {"ok": false, "error": "cannot_rotate_in_place", "detail": err,
			"cells": _cells_array(old_cells)}
	var face = (int(bag.getFaceDirection()) + (3 if left else 1)) % 4
	var old_pos = bag.global_position
	bag.pickup()
	inv.addItem(bag, target, true)
	_ensure_in_items(inv, bag)
	var actual = _bag_cells(inv, bag)
	if not _same_cells(actual, target):
		bag.pickup()
		inv.addItem(bag, old_cells, true)
		bag.global_position = old_pos
		return {"ok": false, "error": "cannot_rotate_in_place",
			"target_cells": _cells_array(target), "actual_cells": _cells_array(actual)}
	_set_face(bag, face)
	bag.global_position = _bbox_center(inv, actual)
	bag.set("placedByPlayer", true)
	_touch_bag(inv, actual)
	_commit(g)
	return {"ok": true, "rotation": face, "top_left": _pair(_min_cell(actual)),
		"cells": _cells_array(actual), "moved_items": 0, "moved_to_storage": []}

func native_rotate_prepare(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var guard = _not_in_shop(g)
	if guard != null:
		return guard
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	var old_cells = []
	if it.isBag():
		old_cells = _bag_cells(inv, it)
		if old_cells.size() == 0:
			return {"ok": false, "error": "bag_not_placed"}
		var occupied = _bag_contents(inv, it)
		if occupied.size() > 0:
			return {"ok": false, "error": "bag_not_empty", "item_count": occupied.size(),
				"detail": "rotation currently supports empty bags only"}
		g.setInventoryEditMode(1)
	else:
		old_cells = _cells_of(inv, it)
		if old_cells.size() == 0:
			return {"ok": false, "error": "item_not_placed"}
		g.setInventoryEditMode(2)
	var left = str(args.get("direction", "right")) == "left"
	var target = _rotation_target(old_cells, left)
	var target_err = _validate_bag_target(inv, target, it) if it.isBag() else _validate_rotation_item_target(inv, target, it)
	if target_err != "":
		return {"ok": false, "error": "cannot_rotate_in_place", "detail": target_err,
			"target_cells": _cells_array(target)}
	var pos = inv.cellToGlobalPos(old_cells[0], true)
	var target_pos = _bbox_center(inv, target)
	it.set_meta("mcp_rotate_old_cells", old_cells)
	it.set_meta("mcp_rotate_old_pos", it.global_position)
	it.set_meta("mcp_rotate_old_face", int(it.getFaceDirection()))
	return {"ok": true, "item_id": int(it.get_instance_id()), "name": str(it.getName()),
		"is_bag": bool(it.isBag()), "edit_mode": int(g.inventoryEditMode),
		"old_cells": _cells_array(old_cells), "face": int(it.getFaceDirection()),
		"target_cells": _cells_array(target),
		"viewport": [pos.x, pos.y], "target_viewport": [target_pos.x, target_pos.y]}

func viewport_mouse(ctx, args):
	var vp = ctx.root.get_viewport()
	var p = vp.get_mouse_position()
	return {"ok": true, "mouse": [p.x, p.y]}

func native_rotate_finish(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	var old_cells = it.get_meta("mcp_rotate_old_cells", [])
	var old_face = int(it.get_meta("mcp_rotate_old_face", int(it.getFaceDirection())))
	var left = bool(args.get("left", false))
	var target = _rotation_target(old_cells, left)
	var is_bag = it.isBag()
	var err = _validate_bag_target(inv, target, it) if is_bag else _validate_rotation_item_target(inv, target, it)
	if err != "":
		return {"ok": false, "error": "cannot_rotate_in_place", "detail": err}
	var tmin = _min_cell(target)
	it.set_process(false)
	inv.removeItem(it)
	inv.orientItem(it, tmin, int(it.getFaceDirection()))
	inv.addItemByTopLeft(it, tmin)
	it.set("dragged", false)
	it.set("placed", true)
	it.set("placedByPlayer", true)
	it.set("focus", false)
	g.set("draggedItem", null)
	g.onInventoryChanged()
	inv.cleanUp()
	it.set_process(true)
	var actual = _bag_cells(inv, it) if is_bag else _cells_of(inv, it)
	return {"ok": true, "rotation": int(it.getFaceDirection()), "cells": _cells_array(actual),
		"target_cells": _cells_array(target), "is_bag": is_bag,
		"atomic": true}

func _abort_native_rotate(inv, g, it, old_cells, old_pos, old_face):
	if not is_instance_valid(it):
		return
	it.pickup(it.global_position)
	if old_cells.size() > 0:
		inv.addItem(it, old_cells, true)
		it.global_position = old_pos
	it.set("faceDirection", old_face)
	it.set("rotation_degrees", old_face * 90)
	it.set("dragged", false)
	g.set("draggedItem", null)

func native_rotate_abort(ctx, args):
	var g = _game(ctx)
	var inv = _inv(ctx)
	if g == null or inv == null:
		return {"ok": false, "error": "game_not_ready"}
	var it = g.get("draggedItem")
	if is_instance_valid(it):
		var old_cells = it.get_meta("mcp_rotate_old_cells", [])
		var old_pos = it.get_meta("mcp_rotate_old_pos", it.global_position)
		var old_face = int(it.get_meta("mcp_rotate_old_face", int(it.getFaceDirection())))
		_abort_native_rotate(inv, g, it, old_cells, old_pos, old_face)
	return {"ok": true}

func native_rotate_rotate(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	var it = _find_item(ctx, args)
	if it == null:
		return {"ok": false, "error": "item_not_found"}
	var face = (int(it.getFaceDirection()) + (3 if bool(args.get("left", false)) else 1)) % 4
	it.setFaceDirectionInstant(face)
	it.previewCellCollision()
	_game(ctx).onItemRotated()
	return {"ok": true, "face": int(it.getFaceDirection())}

func native_rotate_key(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	var it = g.get("draggedItem")
	if not is_instance_valid(it):
		return {"ok": false, "error": "item_not_held"}
	var down = InputEventKey.new()
	down.scancode = KEY_R
	down.physical_scancode = KEY_R
	down.unicode = 114
	down.pressed = true
	Input.parse_input_event(down)
	var up = InputEventKey.new()
	up.scancode = KEY_R
	up.physical_scancode = KEY_R
	up.unicode = 114
	up.pressed = false
	Input.parse_input_event(up)
	return {"ok": true, "face": int(it.getFaceDirection())}

func get_recipes(ctx, args):
	var g = _game(ctx)
	if g == null:
		return {"ok": false, "error": "game_not_ready"}
	if int(g.state) == 2:
		return {"ok": true, "combat_only": true, "inventory_available": false}
	var want = int(args.get("item_id", -1))
	var items = []
	if want >= 0:
		var one = _find_item(ctx, args)
		if not is_instance_valid(one):
			var shop0 = _shop(ctx)
			if shop0 != null:
				for offer0 in shop0.slots:
					if offer0 == null or offer0.get("item") == null:
						continue
					var oi0 = offer0.get("item")
					if is_instance_valid(oi0) and int(oi0.get_instance_id()) == want:
						one = oi0
						break
		if is_instance_valid(one) and not one.isBag():
			items.append(_recipes_for_item(ctx, one, _inv(ctx)))
	else:
		for it in _all_info_items(ctx, false):
			items.append(_recipes_for_item(ctx, it, _inv(ctx)))
	return {"ok": true, "state": "shop", "round": int(g.curRound), "items": items,
		"note": "recipes 的 base 是当前物品，result 是 fusedItem；as_ingredient 是使用该物品的配方；gated_items 是牌堆可生成卡牌；商店物品请用 item_id 单查。"}

