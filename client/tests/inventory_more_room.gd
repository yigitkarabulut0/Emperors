extends SceneTree
## A full armory offers MORE ROOM, and MORE ROOM leads to the Quartermaster.
##
## A full bag was a red count and, at the next buy, a toast saying to sell
## something. The Quartermaster (+50 slots, a Comfort in the Royal Store) is
## the other honest answer. What must hold:
##  - at the cap, with the Quartermaster not owned, the bag's count on the
##    EQUIPPED GEAR banner has MORE ROOM beside it: the screen's own green
##    plate at its painted height, on the banner's row, clear of the count,
##    with a thumb-sized tap area;
##  - below the cap, or once it is owned (the cap already counts its slots),
##    nothing is offered;
##  - a refusal for a full armory is a dialog with OK, and MORE ROOM beside it
##    only while the Quartermaster can be bought; it is no longer a toast;
##  - the Royal Store opens at its Comforts, scrolled so the card is in view.
##
## Run: godot --headless --path client --script tests/inventory_more_room.gd

const QM := {"id": "quartermaster", "store_id": "com.emperors.game.comfort.quartermaster", "kind": "comfort",
	"shelf": "comfort", "title": "The Quartermaster", "available": true,
	"lines": [{"kind": "comfort", "amount": 50, "text": "+50 bag slots, for good", "icon": "quartermaster"}]}

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var armory: GDScript = load("res://scripts/ui/armory.gd")
	if armory == null:
		print("FAIL  there is no Armory: a full bag offers nothing but selling")
		quit(1)
		return
	for canvas in [Vector2i(941, 1672), Vector2i(941, 2040)]:
		await _banner(armory, canvas, 150, 150, false, true, "at the cap, not owned")
		await _banner(armory, canvas, 149, 150, false, false, "one slot free")
		await _banner(armory, canvas, 200, 200, true, false, "at the cap, owned")
	await _dialog(armory)
	await _store(armory)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: MORE ROOM at a full armory, never once owned, and the Store opens at its Comforts" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _store_with(owned: bool) -> Dictionary:
	var qm := QM.duplicate(true)
	if owned:
		qm["owned"] = true
	return {"products": [qm]}


func _banner(armory: GDScript, canvas: Vector2i, used: int, cap: int, owned: bool, want: bool, what: String) -> void:
	armory.call("learn", _store_with(owned))
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var tab: Control = (load("res://scenes/tabs/inventory.gd") as GDScript).new()
	tab.size = Vector2(canvas)
	vp.add_child(tab)
	await process_frame
	tab.set("_inventory", {"used": used, "cap": cap, "items": [], "equipped": {}})
	tab.call("_paint")
	await process_frame
	await process_frame
	_checked += 1
	var more := tab.get("_more_room") as Button
	var tag := "%s (%dx%d)" % [what, canvas.x, canvas.y]
	if more == null:
		_fail("%s: the Inventory has no MORE ROOM" % tag)
	elif more.visible != want:
		_fail("%s: MORE ROOM is %s" % [tag, "offered" if more.visible else "not offered"])
	elif want:
		var label := tab.get("_bag_label") as Label
		var tap := Rect2(more.position, more.size)
		if tap.size.y < 95.0 or tap.size.x < 95.0:
			_fail("%s: MORE ROOM's tap area is %s, under a thumb" % [tag, tap.size])
		# The painted plate: the screen's green EQUIP plate, at its own height,
		# on the banner's row (y 234..280) and inside the panel (x < 929).
		var sb := more.get_theme_stylebox("normal") as StyleBoxTexture
		var paint := Rect2(tap.position + Vector2(-sb.expand_margin_left, -sb.expand_margin_top),
			tap.size + Vector2(sb.expand_margin_left + sb.expand_margin_right,
				sb.expand_margin_top + sb.expand_margin_bottom))
		if sb.texture == null or not sb.texture.resource_path.ends_with("inventory/btn_equip_plate.png"):
			_fail("%s: MORE ROOM is not the screen's own green plate" % tag)
		if absf(paint.size.y - 43.0) > 0.5 or paint.position.y < 234.0 or paint.end.y > 280.0 or paint.end.x > 929.0:
			_fail("%s: MORE ROOM's plate is painted at %s, off the banner's row" % [tag, paint])
		var s := label.label_settings
		var w := s.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		if label.position.x + label.size.x - w < 440.0 or label.position.x + label.size.x > paint.position.x - 8.0:
			_fail("%s: the count \"%s\" runs into MORE ROOM or the banner's title" % [tag, label.text])
	vp.queue_free()
	await process_frame


## The refusal: a dialog, MORE ROOM only while it can be bought.
func _dialog(armory: GDScript) -> void:
	for owned in [false, true]:
		armory.call("learn", _store_with(owned))
		var host := Control.new()
		host.size = Vector2(941, 1672)
		root.add_child(host)
		armory.call("refused", host, "your armory is full — sell something first")
		for i in 3:
			await process_frame
		var words := []
		for n in _all(root):
			if n is Button and (n as Button).is_visible_in_tree():
				words.append((n as Button).text)
		_checked += 1
		var has_more := "MORE ROOM" in words
		if not "OK" in words:
			_fail("the full-armory dialog has no OK (%s)" % str(words))
		if has_more == owned:
			_fail("the full-armory dialog %s MORE ROOM with the Quartermaster %s" % [
				"offers" if has_more else "does not offer", "owned" if owned else "not owned"])
		for n in root.get_children():
			if n is CanvasLayer:
				n.queue_free()
		host.queue_free()
		await process_frame
	# GameState says a full armory on its own signal, not the toast's.
	var gs: Node = root.get_node("GameState")
	if not gs.has_signal("armory_full"):
		_fail("GameState has no armory_full: a full armory is still a toast")
	var src := FileAccess.get_file_as_string("res://scripts/autoload/game_state.gd")
	if not src.contains("res.code == \"inventory_full\""):
		_fail("GameState.act does not tell a full armory from any other refusal")


## The Store opened at its Comforts has the card in view.
func _store(armory: GDScript) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var view: Control = (load("res://scenes/court/store_view.gd") as GDScript).new()
	view.size = Vector2(941, 1672)
	vp.add_child(view)
	await process_frame
	if not view.has_method("open_at"):
		_fail("the Royal Store cannot be opened at a section")
		vp.queue_free()
		return
	var steward := QM.duplicate(true)
	steward["id"] = "steward"
	steward["store_id"] = "com.emperors.game.comfort.steward"
	steward["title"] = "The Steward"
	var packs := []
	for i in 6:
		packs.append({"id": "pack_%d" % i, "store_id": "com.emperors.game.diamonds.%d" % i, "kind": "diamonds",
			"shelf": "diamonds", "title": "Pack", "available": true, "lines": [{"kind": "diamonds",
			"amount": 100, "text": "100 diamonds", "icon": "diamond"}]})
	var store := {"products": packs + [steward, QM.duplicate(true)], "vip": {"level": 0},
		"stipend": {}, "patronage": {}, "deals": {}, "herald": {"enabled": false}}
	view.call("open_at", "comfort")
	view.call("paint", store)
	for i in 4:
		await process_frame
	_checked += 1
	var sc := (view.get("_ui") as Dictionary)["list"] as ScrollContainer
	var ys: Dictionary = view.get("_section_y")
	if not ys.has("sec_comforts"):
		_fail("the Store painted no Comforts")
	else:
		var top := float(ys["sec_comforts"]) - float(sc.scroll_vertical)
		if top < 0.0 or top > sc.size.y - 200.0:
			_fail("opened at its Comforts, the Store shows them at %.0f of a %.0f list" % [top, sc.size.y])
		# Below the first screen, it scrolled to them; on it, it had no need.
		if float(ys["sec_comforts"]) > sc.size.y - 200.0 and sc.scroll_vertical <= 0:
			_fail("opened at its Comforts, the Store did not scroll to them")
	# What the Store shows it tells the Armory: owned or not, fresh.
	var qm: Dictionary = armory.call("quartermaster")
	if qm.is_empty():
		_fail("the Store's paint did not tell the Armory about the Quartermaster")
	vp.queue_free()
	await process_frame


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
