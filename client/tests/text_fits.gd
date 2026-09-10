extends SceneTree
## A live word stays inside the box the painting gave it, however long it is.
##
## Family's upgrade cards and the Attack page's rows were filled with plain
## labels, so a long name or a nine-digit number ran over the card's edge or
## under the next label. Checked with the longest things the server can send:
## sixteen-letter names, amounts in the hundreds of millions.
##
## Run: godot --headless --path client --script tests/text_fits.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 57, "xp": 123456789,
		"xp_to_next": 234567890, "gold": "987654321", "treasury": "876543210", "diamonds": 12345,
		"stat_points_unspent": 3, "action_seq": 1}, "energy": {"current": 400, "max": 513}})
	await _family()
	await _attack()
	if _fails > 0:
		print("FAIL  %d label(s) run out of their box" % _fails)
		quit(1)
		return
	print("PASS  %d live labels fit their boxes with the longest values" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _family() -> void:
	var host := Control.new()
	host.size = Vector2(941, 2040)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/family.gd") as GDScript).new()
	tab.size = host.size
	host.add_child(tab)
	await process_frame
	var ups: Array = []
	for b in ["collect_income_bp", "tax_income_bp", "soldier_spd_bp", "max_energy_flat", "steal_cap_bp"]:
		ups.append({"id": b, "name": "Watchtower Beacons", "bucket": b, "level": 19, "max_level": 20,
			"per_level": 400, "effect_now": 7600, "effect_next": 8000, "next_cost": 987654321, "maxed": false})
	tab.set("_estates", {"upgrades": ups, "upgrades_unlocked": true,
		"holdings": [{"id": "h", "name": "Watchtower Beacons Hall", "level": 44, "max_level": 50,
			"unlocked": true, "unlock_level": 20, "next_cost": 987654321, "yield_per_hour_milli": 987654321000,
			"yield_per_level_milli": 1000}],
		"tax": {"per_hour_milli": 123456789}, "treasury": {"vault": "987654321", "deposit_fee_bp": 1000,
			"unlock_level": 8, "unlocked": true}})
	tab.set("_legacy", {"stacks": 9, "max_stacks": 10, "income_bp": 9000, "next_bp": 1000, "available": false, "level_cap": 60})
	tab.set("_inventory", {"hero": {"attack": 987654, "defense": 876543, "power": 9876543}, "equipped": {}, "items": []})
	tab.call("_paint_all")
	await process_frame
	_walk(tab, "family")
	host.queue_free()
	await process_frame


func _attack() -> void:
	var host := Control.new()
	host.size = Vector2(941, 2040)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.size = host.size
	host.add_child(tab)
	await process_frame
	var t := {"player_id": "x", "name": "Wwwwwwwwwwwwwwww", "avatar": "king", "level": 57,
		"might": 987654321, "estimated_steal": 987654321, "steal_rate_bp": 300, "energy_cost": 16}
	var r := t.duplicate()
	r["steal_rate_bp"] = 400
	r["expires_in"] = 86000
	tab.set("_data", {"might": 987654321, "energy_cost": 16, "revenge": [r], "targets": [t, t, t]})
	var h: Array = []
	for won in [true, false]:
		for raided in [true, false]:
			h.append({"battle_id": "b", "won": won, "raided": raided, "opponent_name": "Wwwwwwwwwwwwwwww",
				"gold": -987654321 if raided and not won else 987654321, "at": "2026-09-10T10:00:00Z"})
	tab.set("_history", h)
	tab.set("_loaded", true)
	tab.call("_paint")
	await process_frame
	_walk(tab, "attack")
	host.queue_free()
	await process_frame


func _walk(n: Node, screen: String) -> void:
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for c in cur.get_children():
			stack.append(c)
		if not (cur is Label) or not (cur as Label).is_visible_in_tree():
			continue
		var l := cur as Label
		if l.text == "" or l.autowrap_mode != TextServer.AUTOWRAP_OFF or l.text.contains("\n"):
			continue
		if not l.has_meta("box_w"):
			continue
		_checked += 1
		var s := l.label_settings
		var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		var box: float = float(l.get_meta("box_w"))
		if w > box + 2.0:
			_fail("%s: \"%s\" is %.0f wide in a %.0f box" % [screen, l.text, w, box])
