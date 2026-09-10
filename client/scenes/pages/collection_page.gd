extends RefCounted
## THE COLLECTION — one of every design, given to the wall for good, paid in
## luck on every roll.
##
## It was a list of item names in a dialog, eight at most, offering pieces the
## wall would refuse. Here it is the wall: every design in the game by slot and
## tier, the ones held lit in their frames and the ones still to find dark, the
## luck it all adds up to, and above it the pieces in the bags the wall would
## take -- nobody is wearing them and their design is not on it yet.

const TILE := 150.0
const ROW_H := 250.0
const SLOTS := [["weapon", "WEAPONS"], ["armor", "ARMOUR"], ["horse", "HORSES"]]
const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]


static func open(host: Node, inventory: Dictionary) -> Sheet:
	var s := Sheet.open(host, "THE COLLECTION")
	s.set_meta("inventory", inventory)
	s.add_close()
	_load(s)
	return s


static func _pct(bp: int) -> String:
	return (str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)) + "%"


static func _load(s: Sheet) -> void:
	s.clear_body()
	var res: Api.Response = await Api.get_json("/v1/collection")
	if not is_instance_valid(s):
		return
	if not res.ok:
		s.paragraph("The Collection could not be read. " + res.error, 22, UI.RED)
		return
	var wall := res.data
	s.paragraph("%d of %d designs  ·  +%s luck on every roll" % [int(wall.get("held", 0)), int(wall.get("total", 0)),
		_pct(int(wall.get("luck_bp", 0)))], 30, UI.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	s.paragraph("Each new design adds %s; all three of a slot and tier add %s more. A donated piece is gone for good -- its design stays." % [
		_pct(int(wall.get("luck_per_piece_bp", 0))), _pct(int(wall.get("luck_per_set_bp", 0)))], 22, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)

	var held := {}
	for set in wall.get("sets", []):
		for e in set.get("entries", []):
			if bool(e.get("held", false)):
				held[str(e.get("def_id", ""))] = true
	var offer: Array = []
	var seen := {}
	for it in (s.get_meta("inventory") as Dictionary).get("items", []):
		var def := str(it.get("def_id", ""))
		if str(it.get("equipped_on", "")) != "" or held.has(def) or seen.has(def):
			continue
		seen[def] = true
		offer.append(it)
	offer.sort_custom(func(a, b): return TIERS.find(str(a.get("tier", ""))) > TIERS.find(str(b.get("tier", ""))))

	s.heading("NEW TO THE WALL" if not offer.is_empty() else "NOTHING NEW IN YOUR BAGS")
	for it in offer:
		var row := s.slot(128)
		var pic := UI.image("", Rect2(14, 12, 102, 102))
		pic.texture = Art.item(str(it.get("art", "")))
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(pic)
		row.add_child(UI.image("inventory/frame_" + str(it.get("tier", "common")), Rect2(10, 8, 110, 110)))
		Sheet.put(row, str(it.get("name", "")), Rect2(134, 14, s.inner_w - 360, 44), 26, UI.INK, "body", 700)
		Sheet.put(row, "%s %s" % [str(it.get("tier", "")).to_upper(), str(it.get("slot", "")).to_upper()],
			Rect2(134, 62, s.inner_w - 360, 34), 20, UI.DIM, "title", 600)
		var give := Sheet.button("DONATE", Dialog.CONFIRM_PLATE, Color("#F3FBF3"), 96, 24)
		UI.place(give, Rect2(s.inner_w - 206, 16, 192, 96))
		var id := str(it.get("id", ""))
		var name := str(it.get("name", ""))
		give.pressed.connect(func() -> void: await _donate(s, id, name))
		row.add_child(give)

	var by_slot := {}
	for set in wall.get("sets", []):
		var k := str(set.get("slot", ""))
		if not by_slot.has(k):
			by_slot[k] = []
		by_slot[k].append(set)
	for sl in SLOTS:
		s.heading(str(sl[1]))
		for set in by_slot.get(sl[0], []):
			_set_row(s, set)


static func _set_row(s: Sheet, set: Dictionary) -> void:
	var row := s.slot(ROW_H)
	var tier := str(set.get("tier", "common"))
	var badge := UI.image("inventory/badge_" + tier, Rect2(18, 16, 93, 38))
	badge.size = badge.texture.get_size()
	row.add_child(badge)
	if bool(set.get("complete", false)):
		Sheet.put(row, "SET COMPLETE", Rect2(128, 12, 300, 44), 20, UI.GOLD, "title", 700)
	var entries: Array = set.get("entries", [])
	var gap := (s.inner_w - 32.0 - TILE * 3.0) / 2.0
	for i in entries.size():
		var e: Dictionary = entries[i]
		var x := 16.0 + i * (TILE + gap)
		var have := bool(e.get("held", false))
		var tile := UI.image("inventory/item_tile_empty", Rect2(x, 62, TILE, TILE - 26))
		row.add_child(tile)
		var pic := UI.image("", Rect2(x + 14, 68, TILE - 28, TILE - 38))
		pic.texture = Art.item(str(e.get("art", "")))
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.modulate = Color.WHITE if have else Color(0.08, 0.1, 0.14, 0.9)
		row.add_child(pic)
		row.add_child(UI.image("inventory/frame_" + tier if have else "inventory/frame_common", Rect2(x, 62, TILE, TILE - 26)))
		Sheet.put(row, str(e.get("name", "")) if have else "?", Rect2(x - 8, 62 + TILE - 22, TILE + 16, 30), 18,
			UI.INK if have else UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)


static func _donate(s: Sheet, id: String, name: String) -> void:
	if not await Dialog.ask(s, {"title": "Give %s to the wall?" % name,
			"body": "The piece is gone for good; its design stays on the wall and adds its luck to every roll.",
			"confirm_text": "Donate"}):
		return
	var res: Api.Response = await GameState.act("/v1/collection/donate", {"item_id": id})
	if not res.ok or not is_instance_valid(s):
		return
	GameState.toast("%s is on the wall" % name)
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	if inv.ok and is_instance_valid(s):
		s.set_meta("inventory", inv.data)
	if is_instance_valid(s):
		_load(s)
