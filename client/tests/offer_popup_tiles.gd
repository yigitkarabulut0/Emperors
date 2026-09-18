extends SceneTree
## The offer popup's tiles draw what an offer holds large, from paintings that
## are large.
##
## The tiles are 224 across and drew the mail's 46-unit reward icons at their
## own size: a diamond the size of a thumbnail in the middle of a plate. Every
## reward line of every offer the catalogue fires is drawn here at 96 units or
## more, from a source at least that big (never drawn up), and a frame is shown
## as it will be worn, round the lord's own face.
##
## Run: godot --headless --path client --script tests/offer_popup_tiles.gd

const MIN_DRAWN := 96.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1",
		"diamonds": 12, "action_seq": 1, "avatar": "queen"}, "energy": {"current": 1, "max": 2}, "sections": []})
	var popup_script: GDScript = load("res://scenes/court/offer_popup.gd")
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	# The offers the catalogue fires, with the lines the server sends for them.
	var offers := {
		"starter": [_d(300), _potions(3), _frame("frames/founder", "Founder (frame)")],
		"offer_empty": [_d(150), _potions(2)],
		"offer_l10": [_d(650), _potions(3), _frame("frames/oak", "Oak Wreath (frame)")],
		"offer_l20": [_d(1350), _potions(5), {"kind": "cosmetic", "amount": 1, "text": "Dragon (crest)", "icon": "icons/crest_dragon"}],
		"offer_l30": [_d(2800), _potions(8), _frame("frames/laurel", "Laurel (frame)")],
		"offer_defeat": [_d(100), {"kind": "token", "amount": 2, "text": "2 Protection Charters", "icon": "city_shield"}],
		"big": [_d(9000)],
	}
	for id in offers:
		var p: CanvasLayer = popup_script.new()
		p.call("setup", {"id": id, "store_id": "com.emperors.game." + id, "shelf": "offers", "ends_in": 3600,
			"available": true, "usd_cents": 499, "title": id, "lines": offers[id]}, host)
		root.add_child(p)
		for i in 3:
			await process_frame
		var ui: Dictionary = p.get("_ui")
		var lines: Array = offers[id]
		for i in lines.size():
			var line: Dictionary = lines[i]
			var icon: TextureRect = ui[["icon_1", "icon_2", "icon_3"][i]]
			_checked += 1
			if str(line.get("icon", "")).begins_with("frames/"):
				_framed(p, id, line)
				continue
			if not icon.visible or icon.texture == null:
				_fail("%s tile %d draws nothing for %s" % [id, i + 1, line["text"]])
				continue
			var src := icon.texture.get_size()
			var drawn := _drawn(src, icon.size, icon.stretch_mode)
			if maxf(drawn.x, drawn.y) < MIN_DRAWN:
				_fail("%s tile %d draws %s at %.0fx%.0f, under %.0f (%s)" % [id, i + 1, line["text"], drawn.x, drawn.y,
					MIN_DRAWN, icon.texture.resource_path])
			if drawn.x > src.x + 0.5 or drawn.y > src.y + 0.5:
				_fail("%s tile %d draws %s up from %s" % [id, i + 1, line["text"], src])
		# The vessel follows the packs: 650 diamonds are the 330 pack's chest.
		if id == "offer_l10":
			var want := "res://assets/store/vessel_330.png"
			var got := (ui["icon_1"] as TextureRect).texture.resource_path
			_expect(got == want, "650 diamonds wear %s, not the 330 pack's vessel" % got)
		if id == "big":
			var got := (ui["icon_1"] as TextureRect).texture.resource_path
			_expect(got.ends_with("vessel_8500.png"), "9,000 diamonds wear %s, not the royal chest" % got)
		p.queue_free()
		await process_frame

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d popup tiles drawn large from large paintings, frames round the lord's face" % _checked)
	quit()


## A frame reward: the square frame at 96 or more (never drawn up), and the
## lord's own face under its window.
func _framed(p: Node, id: String, line: Dictionary) -> void:
	var frame: TextureRect = null
	var face: TextureRect = null
	var stack: Array = [p]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is TextureRect and n.has_meta("framed_frame") and (n as TextureRect).texture.resource_path.contains(str(line["icon"]).get_file()):
			frame = n
			var holder: Node = n.get_parent()
			for k in holder.get_children():
				if k.has_meta("framed_face"):
					face = k
	if frame == null:
		_fail("%s: the frame %s is not drawn as worn" % [id, line["icon"]])
		return
	var src := frame.texture.get_size()
	_expect(maxf(frame.size.x, frame.size.y) >= MIN_DRAWN, "%s: %s is drawn %s, under %.0f" % [id, line["icon"], frame.size, MIN_DRAWN])
	_expect(frame.size.x <= src.x + 0.5 and frame.size.y <= src.y + 0.5, "%s: %s is drawn up from %s" % [id, line["icon"], src])
	_expect(face != null and face.texture != null and face.texture.resource_path.contains("avatar_queen"),
		"%s: %s frames no face, or not the lord's own" % [id, line["icon"]])
	if face != null:
		var fc := face.position + face.size / 2.0
		var frc := frame.position + frame.size / 2.0
		_expect(fc.distance_to(frc) < 1.0, "%s: the face is off the frame's window by %.1f" % [id, fc.distance_to(frc)])


## The size a TextureRect draws its texture at.
static func _drawn(src: Vector2, box: Vector2, mode: int) -> Vector2:
	if mode == TextureRect.STRETCH_KEEP_CENTERED or mode == TextureRect.STRETCH_KEEP:
		return src
	var k := minf(box.x / src.x, box.y / src.y)
	return src * k


static func _d(n: int) -> Dictionary:
	return {"kind": "diamonds", "amount": n, "text": "%d diamonds" % n, "icon": "diamond"}


static func _potions(n: int) -> Dictionary:
	return {"kind": "token", "amount": n, "text": "%d Energy Potions" % n, "icon": "energy_potion"}


static func _frame(art: String, text: String) -> Dictionary:
	return {"kind": "cosmetic", "amount": 1, "text": text, "icon": art}


func _fail(msg: String) -> void:
	_fails += 1
	printerr("  ", msg)


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fail(why)
