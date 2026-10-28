extends Node

# Backpack Battles local bridge.
# Listens on 127.0.0.1:8765 for newline-delimited JSON requests.
# Also exposes a runtime GDScript REPL via {"cmd":"run","source":"..."} so the
# MCP server can be developed without restarting the game.

const PORT = 8765
const HOST = "127.0.0.1"
const MAX_DEPTH = 12

var server = TCP_Server.new()
var clients = []
var log_file = null
var started_at = 0
var api_script = null
var api_obj = null
var api_hash = ""

func _ready():
	started_at = OS.get_ticks_msec()
	log_file = File.new()
	log_file.open("user://mcp/bridge.log", File.WRITE)
	_log("bridge starting pid=" + str(OS.get_process_id()))
	var err = server.listen(PORT, HOST)
	_log("listen " + HOST + ":" + str(PORT) + " err=" + str(err))
	set_process(true)

func _log(s):
	if log_file != null and log_file.is_open():
		log_file.store_line("[%d] %s" % [OS.get_ticks_msec(), s])
		log_file.flush()
	print("[McpBridge] " + s)

func _exit_tree():
	_log("bridge exit")
	if log_file != null and log_file.is_open():
		log_file.close()

func _process(_delta):
	if server.is_connection_available():
		var peer = server.take_connection()
		if peer != null:
			clients.append({"peer": peer, "buf": ""})
			_log("client connected, total=" + str(clients.size()))

	var alive = []
	for c in clients:
		var peer = c["peer"]
		var status = peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			_log("client disconnected status=" + str(status))
			continue
		peer.poll()
		var n = peer.get_available_bytes()
		if n > 0:
			var chunk = peer.get_utf8_string(n)
			c["buf"] = c["buf"] + chunk
			while true:
				var idx = c["buf"].find("\n")
				if idx < 0:
					break
				var line = c["buf"].substr(0, idx)
				c["buf"] = c["buf"].substr(idx + 1)
				if line.strip_edges() != "":
					_handle_line(peer, line)
		alive.append(c)
	clients = alive

func _send(peer, obj):
	var txt = JSON.print(obj)
	peer.put_data((txt + "\n").to_utf8())

func _handle_line(peer, line):
	var parsed = JSON.parse(line)
	if parsed.error != OK:
		_send(peer, {"ok": false, "error": "json_parse", "detail": parsed.error_string})
		return
	var req = parsed.result
	if typeof(req) != TYPE_DICTIONARY:
		_send(peer, {"ok": false, "error": "request_must_be_object"})
		return
	var id = req.get("id", null)
	var resp = null
	var t0 = OS.get_ticks_msec()
	var cmd = str(req.get("cmd", ""))
	_log("cmd=" + cmd)
	if cmd == "ping":
		resp = {"ok": true, "result": {"pong": true, "uptime_ms": OS.get_ticks_msec() - started_at, "version": "0.1.0"}}
	elif cmd == "tree":
		var node = _resolve(req.get("path", "/root"))
		if node == null:
			resp = {"ok": false, "error": "node_not_found", "path": str(req.get("path", "/root"))}
		else:
			resp = {"ok": true, "result": _tree(node, int(req.get("depth", 2)), bool(req.get("scripts", true)))}
	elif cmd == "props":
		resp = _cmd_props(req)
	elif cmd == "methods":
		resp = _cmd_methods(req)
	elif cmd == "signals":
		var node = _resolve(req.get("path", ""))
		if node == null:
			resp = {"ok": false, "error": "node_not_found"}
		else:
			resp = {"ok": true, "result": _safe(node.get_signal_list())}
	elif cmd == "get":
		var node = _resolve(req.get("path", ""))
		if node == null:
			resp = {"ok": false, "error": "node_not_found"}
		else:
			var prop = str(req.get("prop", ""))
			resp = {"ok": true, "result": _safe(node.get(prop))}
	elif cmd == "set":
		var node = _resolve(req.get("path", ""))
		if node == null:
			resp = {"ok": false, "error": "node_not_found"}
		else:
			var prop = str(req.get("prop", ""))
			node.set(prop, req.get("value", null))
			resp = {"ok": true, "result": _safe(node.get(prop))}
	elif cmd == "call":
		var node = _resolve(req.get("path", ""))
		if node == null:
			resp = {"ok": false, "error": "node_not_found"}
		else:
			var method = str(req.get("method", ""))
			if not node.has_method(method):
				resp = {"ok": false, "error": "no_method", "method": method}
			else:
				var args = req.get("args", [])
				if typeof(args) != TYPE_ARRAY:
					args = [args]
				var r = node.callv(method, args)
				resp = {"ok": true, "result": _safe(r)}
	elif cmd == "run":
		resp = _cmd_run(req)
	elif cmd == "api":
		resp = _cmd_api(req)
	elif cmd == "globals":
		resp = {"ok": true, "result": _globals()}
	else:
		resp = {"ok": false, "error": "unknown_cmd", "cmd": cmd}
	resp["id"] = id
	resp["ms"] = OS.get_ticks_msec() - t0
	_send(peer, resp)

func _resolve(path):
	if path == null:
		return null
	var p = str(path)
	if p == "" or p == "/root":
		return get_tree().root
	if p == "/":
		return get_tree().root
	return get_tree().root.get_node_or_null(p)

func _globals():
	var out = []
	for child in get_tree().root.get_children():
		var script_path = ""
		if child.get_script() != null:
			script_path = str(child.get_script().resource_path)
		out.append({"name": str(child.get_name()), "class": child.get_class(), "script": script_path})
	return out

func _tree(node, depth, with_scripts):
	var d = {
		"name": str(node.get_name()),
		"class": node.get_class(),
		"path": str(node.get_path()),
		"child_count": node.get_child_count()
	}
	if with_scripts and node.get_script() != null:
		d["script"] = str(node.get_script().resource_path)
	if depth > 0:
		var kids = []
		for c in node.get_children():
			kids.append(_tree(c, depth - 1, with_scripts))
		d["children"] = kids
	return d

func _cmd_props(req):
	var node = _resolve(req.get("path", ""))
	if node == null:
		return {"ok": false, "error": "node_not_found"}
	var filt = str(req.get("filter", ""))
	var want_values = bool(req.get("values", false))
	var out = []
	for p in node.get_property_list():
		var name = str(p.get("name", ""))
		if filt != "" and filt.to_lower() in name.to_lower():# substring filter
			pass
		elif filt != "":
			continue
		var entry = {"name": name, "type": int(p.get("type", 0)), "usage": int(p.get("usage", 0))}
		if want_values:
			entry["value"] = _safe(node.get(name))
		out.append(entry)
	return {"ok": true, "result": out}

func _cmd_methods(req):
	var node = _resolve(req.get("path", ""))
	if node == null:
		return {"ok": false, "error": "node_not_found"}
	var filt = str(req.get("filter", ""))
	var out = []
	for m in node.get_method_list():
		var name = str(m.get("name", ""))
		if filt != "" and not (filt.to_lower() in name.to_lower()):
			continue
		var args = []
		for a in m.get("args", []):
			args.append({"name": str(a.get("name", "")), "type": int(a.get("type", 0))})
		out.append({"name": name, "args": args, "flags": int(m.get("flags", 0))})
	return {"ok": true, "result": out}

func _load_api():
	var path = "user://mcp/bpb_api.gd"
	var f = File.new()
	if not f.file_exists(path):
		return null
	var e = f.open(path, File.READ)
	if e != OK:
		return null
	var src = f.get_as_text()
	f.close()
	var h = src.md5_text()
	if api_obj != null and h == api_hash:
		return api_obj
	var s = GDScript.new()
	s.set_source_code(src)
	var err = s.reload()
	if err != OK:
		_log("api compile failed code=" + str(err))
		return null
	api_script = s
	api_obj = s.new()
	api_hash = h
	_log("api loaded hash=" + h)
	return api_obj

func _cmd_api(req):
	var obj = _load_api()
	if obj == null:
		return {"ok": false, "error": "api_load_failed"}
	var fn = str(req.get("fn", ""))
	if fn == "" or not obj.has_method(fn):
		return {"ok": false, "error": "unknown_api_fn", "fn": fn}
	var args = req.get("args", {})
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	var ctx = {
		"bridge": self,
		"tree": get_tree(),
		"root": get_tree().root,
		"scene": get_tree().current_scene,
		"req": req
	}
	var r = obj.call(fn, ctx, args)
	return {"ok": true, "result": _safe(r)}

func _cmd_run(req):
	var src = str(req.get("source", ""))
	if src.strip_edges() == "":
		return {"ok": false, "error": "empty_source"}
	var script = GDScript.new()
	script.set_source_code(src)
	var err = script.reload()
	if err != OK:
		return {"ok": false, "error": "compile_failed", "code": err}
	var obj = script.new()
	if obj == null:
		return {"ok": false, "error": "instantiate_failed"}
	if not obj.has_method("run"):
		return {"ok": false, "error": "missing_run_method"}
	var ctx = {
		"bridge": self,
		"tree": get_tree(),
		"root": get_tree().root,
		"scene": get_tree().current_scene,
		"req": req
	}
	var r = obj.run(ctx)
	return {"ok": true, "result": _safe(r)}

func _num(x):
	if typeof(x) == TYPE_REAL and (is_nan(x) or is_inf(x)):
		return null
	return x

func _safe(v, depth = 0):
	if depth > MAX_DEPTH:
		return "<max_depth>"
	var t = typeof(v)
	if v == null:
		return null
	if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_STRING:
		return v
	if t == TYPE_REAL:
		return _num(v)
	if t == TYPE_VECTOR2:
		return {"x": _num(v.x), "y": _num(v.y)}
	if t == TYPE_VECTOR3:
		return {"x": _num(v.x), "y": _num(v.y), "z": _num(v.z)}
	if t == TYPE_RECT2:
		return {"x": _num(v.position.x), "y": _num(v.position.y), "w": _num(v.size.x), "h": _num(v.size.y)}
	if t == TYPE_COLOR:
		return {"r": _num(v.r), "g": _num(v.g), "b": _num(v.b), "a": _num(v.a)}
	if t == TYPE_NODE_PATH:
		return str(v)
	if t == TYPE_DICTIONARY:
		var d = {}
		for k in v.keys():
			d[str(k)] = _safe(v[k], depth + 1)
		return d
	if t == TYPE_ARRAY or t == TYPE_RAW_ARRAY or t == TYPE_INT_ARRAY or t == TYPE_REAL_ARRAY or t == TYPE_STRING_ARRAY or t == TYPE_VECTOR2_ARRAY or t == TYPE_COLOR_ARRAY:
		var a = []
		for i in range(v.size()):
			a.append(_safe(v[i], depth + 1))
		return a
	if t == TYPE_OBJECT:
		if not is_instance_valid(v):
			return {"__freed": true}
		var o = {"__class": v.get_class()}
		if v is Node:
			o["path"] = str(v.get_path())
			o["name"] = str(v.get_name())
		var sc = v.get_script()
		if sc != null:
			var sp = ""
			if sc.resource_path != "":
				sp = str(sc.resource_path)
			o["script"] = sp
		return o
	return str(v)
