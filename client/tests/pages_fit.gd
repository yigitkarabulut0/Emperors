extends SceneTree
## Every page over the game fits the phone and takes a thumb.
##
## The pages -- profile, rankings, daily, stats, treasury, gear, history,
## rules, the Collection, the tour -- are Sheets, and the ceremonies are their
## own overlay. What must hold at both canvases: the plate is on the screen,
## every button in it is at least 95 units (44 pt) tall and inside the plate,
## and nothing in a row hangs past the row.
##
## Run: godot --headless --path client --script tests/pages_fit.gd
##
## The pages are loaded at run time and never named as a class here: a class
## named in this script is compiled before the autoloads exist, fails, and every
## call after it fails quietly.

const MIN_H := 95.0
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "avatar": "knight", "level": 30,
		"gold": "987654321", "treasury": "876543210", "diamonds": 12, "stat_points_unspent": 3, "stat_attack": 10,
		"stat_defense": 6, "stat_energy": 12}, "energy": {"current": 185, "max": 236},
		"prices": {"rename_diamonds": 20, "stat_gains": {"attack": 4, "defense": 4, "energy": 5}}})
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _all(canvas)
	if _checked == 0:
		print("FAIL  no page opened, so nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d buttons on every page fit the phone and take a thumb" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _all(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var pg := "res://scenes/pages/%s.gd"
	var items := [{"id": "a", "name": "The Unbroken Breastplate", "slot": "armor", "tier": "mystic", "art": "armor_04",
		"defense": 987654, "power": 987654, "equipped_on": "s", "worn_by": "Gladiator in slot 10"}]
	var pages := {
		"profile": func(h: Control) -> Variant: return load(pg % "profile_page").open(h),
		"daily": func(h: Control) -> Variant: return load(pg % "daily_page").open(h, {"day": 7, "streak": 13, "claimable": true, "reward": 40, "rewards": [5, 5, 10, 10, 15, 20, 40]}),
		"stats": func(h: Control) -> Variant: return load(pg % "stats_page").open(h),
		"treasury": func(h: Control) -> Variant: return load(pg % "treasury_page").open(h, {"vault": "876543210", "deposit_fee_bp": 1000, "unlock_level": 8, "unlocked": true}),
		"history": func(h: Control) -> Variant: return load(pg % "history_page").open(h, [{"battle_id": "b", "won": false, "raided": true,
			"opponent_name": "Wwwwwwwwwwwwwwww", "opponent_level": 60, "gold": -987654321, "at": "2026-09-10T09:00:00Z"}], func(_e): pass),
		"rules": func(h: Control) -> Variant: return load(pg % "rules_page").open(h, {}),
		"tour": func(h: Control) -> Variant: return load(pg % "onboarding").open(h),
		"odds": func(h: Control) -> Variant: return load(pg % "odds_page").open(h, {"types": [
			{"type_id": "peasant", "odds": [{"tier": "common", "bp": 7179}, {"tier": "uncommon", "bp": 2175}, {"tier": "rare", "bp": 512}, {"tier": "epic", "bp": 110}, {"tier": "legendary", "bp": 18}, {"tier": "mystic", "bp": 5}, {"tier": "special", "bp": 1}]},
			{"type_id": "mercenary", "odds": [{"tier": "uncommon", "bp": 7000}, {"tier": "rare", "bp": 3000}]},
			{"type_id": "gladiator", "odds": []}]}, ["peasant", "mercenary", "gladiator"],
			{"peasant": "VILLAGER", "mercenary": "MERCENARY", "gladiator": "GLADIATOR"}),
	}
	for name in pages:
		var host := Control.new()
		host.size = canvas
		root.add_child(host)
		var sheet: Control = (pages[name] as Callable).call(host)
		for i in 4:
			await process_frame
		_check_sheet(sheet, "%s %s" % [tag, name], canvas)
		sheet.call("close")
		host.queue_free()
		await process_frame
	# The gear page awaits its choice; open it, measure it, close it.
	var host2 := Control.new()
	host2.size = canvas
	root.add_child(host2)
	var picker: GDScript = load(pg % "item_picker")
	picker.pick(host2, "YOUR ARMOUR", items, items[0])
	for i in 4:
		await process_frame
	var open_sheet: Control = null
	for c in root.get_children():
		if c is CanvasLayer:
			for cc in c.get_children():
				if cc is Control and cc.has_method("add_close"):
					open_sheet = cc
	if open_sheet == null:
		_fail("%s: the gear page did not open" % tag)
	else:
		_check_sheet(open_sheet, "%s gear" % tag, canvas)
		open_sheet.call("close")
	host2.queue_free()
	await process_frame


func _check_sheet(sheet: Control, tag: String, canvas: Vector2) -> void:
	var plate: Control = sheet.get("_plate")
	var pr := Rect2(plate.global_position, plate.size)
	if pr.position.x < 0 or pr.position.y < 0 or pr.end.x > canvas.x + 0.5 or pr.end.y > canvas.y + 0.5:
		_fail("%s: the plate spans %s, off a %s canvas" % [tag, pr, canvas])
	var stack: Array = [plate]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button and (n as Button).is_visible_in_tree() and not (n as Button).flat:
			var b := n as Button
			_checked += 1
			if b.size.y < MIN_H:
				_fail("%s: \"%s\" is %.0f tall, under %.0f" % [tag, b.text, b.size.y, MIN_H])
			var br := Rect2(b.global_position, b.size)
			var parent := b.get_parent() as Control
			if parent is NinePatchRect and parent != plate:
				var rr := Rect2(parent.global_position, parent.size)
				if br.end.x > rr.end.x + 1.0 or br.position.x < rr.position.x - 1.0:
					_fail("%s: \"%s\" hangs off its row" % [tag, b.text])
