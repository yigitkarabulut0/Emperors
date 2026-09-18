extends SceneTree
## A Victory Road claim of many milestones stays on the phone.
##
## CLAIM takes every milestone waiting, and a lord who comes back at level 47
## gets thirteen at once: 24 reward lines in one answer. The Royal Delivery laid
## a tile per line, three to a row, with no end -- eight rows ran the ceremony
## and its CONTINUE off the bottom of the screen. It now draws two rows and
## says how many more came with them. On the short phone under a notch and the
## tall one:
##  - a delivery of 24 lines draws six tiles and "and 18 more rewards";
##  - every piece of it, CONTINUE included, is on the screen below the notch;
##  - a delivery of six or fewer is drawn whole, with no such note.
##
## Run: godot --headless --path client --script tests/road_claim_delivery.gd

const CANVASES := [[Vector2i(941, 1624), 141.0], [Vector2i(941, 2040), 141.0], [Vector2i(941, 1672), 0.0]]

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var many: Array = []
	for i in 12:
		many.append({"kind": "diamonds", "amount": 10 + i * 5, "text": "%d diamonds" % (10 + i * 5), "icon": "diamond"})
		many.append({"kind": "token", "id": "flask_large", "amount": 1, "text": "Great Flask", "icon": "flask_large"})
	var few: Array = many.slice(0, 5)
	for c in CANVASES:
		await _check(c[0], c[1], many, 6, "and 18 more rewards")
		await _check(c[0], c[1], few, 5, "")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: a road claim of a dozen milestones is delivered on the screen, with how many more" % _checked)
	quit()


func _expect(ok: bool, msg: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + msg)


func _check(canvas: Vector2i, inset: float, lines: Array, tiles: int, note: String) -> void:
	var tag := "%dx%d inset %d, %d lines" % [canvas.x, canvas.y, int(inset), lines.size()]
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var c: CanvasLayer = (load("res://scenes/pages/ceremony.gd") as GDScript).new()
	c.set("_cfg", {"kind": "delivery", "delivery": {"title": "VICTORY ROAD", "lines": lines}, "inset": inset})
	vp.add_child(c)
	for i in 4:
		await process_frame
	var r: Control = c.get("_root")
	_expect(r != null, "%s: nothing was built" % tag)
	if r == null:
		vp.queue_free()
		return
	var texts: Array = []
	for n in _all(r):
		var ctl := n as Control
		if ctl == null or ctl == r or not ctl.is_visible_in_tree() or ctl is ColorRect:
			continue
		if ctl is Label:
			texts.append((ctl as Label).text)
		if ctl.name != "Glow":
			var rect := Rect2(ctl.global_position, ctl.size)
			_expect(rect.position.y >= inset - 0.5 and rect.end.y <= float(canvas.y) + 0.5,
				"%s: %s is at %s, off the screen below %d" % [tag, ctl.name, rect, int(inset)])
	var drawn := 0
	for t in texts:
		for l in lines:
			if t == str(l["text"]):
				drawn += 1
				break
	_expect(drawn == tiles, "%s: %d reward tiles drawn, want %d" % [tag, drawn, tiles])
	if note != "":
		_expect(note in texts, "%s: no \"%s\" under the tiles (said: %s)" % [tag, note, texts])
	else:
		for t in texts:
			_expect(not str(t).begins_with("and "), "%s: says \"%s\" though every reward is drawn" % [tag, t])
	vp.queue_free()
	await process_frame


func _all(n: Node) -> Array:
	var out: Array = [n]
	for ch in n.get_children():
		out.append_array(_all(ch))
	return out
