extends SceneTree
## A lord looks the same wherever another lord appears (scripts/ui/look.gd).
##
## Every view of another lord carries a Look (server/internal/service/look.go):
## what they wear -- frame, title, name colour, crest -- and Royal Favour's seal.
## It is drawn on the rival and revenge cards, the kingdom's lords (the Realm
## panel and the Lords page) and the rankings (rows, podium, YOUR RANK). For
## four lords -- one plain, one framed without a seal, one sealed without a
## frame, one wearing everything under the longest name -- on both canvases
## (and under a 141 notch where a page opens):
##  - the seal is drawn only for a lord who has it, beside the name, clear of it;
##  - the name wears its colour only when one is worn, else the surface's own;
##  - the frame is drawn only when worn, in the surface's shape, never up;
##  - the title shows on the surface's line for it only when worn;
##  - a card's crest is the one worn, else the one the id picks;
##  - every worn colour reads on every plate a name is set on (WCAG 4.5).
##
## Run: godot --headless --path client --script tests/looks_everywhere.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const LONG := "Wwwwwwwwwwwwwwww"

var _fails := 0
var _checked := 0


func _lords() -> Array:
	return [
		{"player_id": "plain", "name": "Aldric", "avatar": "knight", "level": 12, "role": "member"},
		{"player_id": "framed", "name": "Seraphine", "avatar": "queen", "level": 30, "role": "marshal",
			"worn": {"frame": "frames/laurel"}, "vip_seal": false},
		{"player_id": "sealed", "name": "Darian", "avatar": "monk", "level": 44, "role": "member",
			"worn": {}, "vip_seal": true},
		{"player_id": "all", "name": LONG, "avatar": "king", "level": 99, "role": "king",
			"worn": {"frame": "frames/aureole", "title": "the Generous", "color": "#6FD28A", "crest": "icons/crest_dragon"},
			"vip_seal": true},
	]


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	root.get_node("GameState").set("snapshot", {"player": {"username": LONG, "avatar": "witch", "level": 88,
		"gold": "1", "action_seq": 1, "worn": {"color": "#8FB8FF", "title": "the Founder", "frame": "frames/patron"},
		"vip_seal": true}, "energy": {"current": 1, "max": 2}})
	_contrast()
	for canvas in CANVASES:
		await _attack(canvas)
		await _realm(canvas)
		await _lords_page(canvas)
		for inset in [0.0, 141.0]:
			await _rankings(canvas, inset)
			await _replay(canvas, inset, true)
			await _replay(canvas, inset, false)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every surface draws a lord's look, and only what they wear" % _checked)
	quit()


## One lord on one surface: name label `l` (its default colour `plain`), the
## portrait's frame host `portrait` (null where none), title label `title`
## (null where the surface has no line for it), and the box the name keeps to.
func _lord(tag: String, d: Dictionary, l: Label, plain: Color, portrait: Control, shape: String,
		title: Label, box: Rect2) -> void:
	_checked += 1
	var worn: Dictionary = d.get("worn", {})
	var seal: TextureRect = l.get_meta("look_seal") if l.has_meta("look_seal") else null
	var sealed := bool(d.get("vip_seal", false))
	_expect((seal != null and seal.visible) == sealed, "%s: %s's seal is %s" % [tag, d["name"], "drawn" if seal and seal.visible else "missing"])
	if sealed and seal != null:
		# Beside the words -- clear of where they end -- inside the name's box
		# across, and level with it: a seal is a little taller than a line.
		var f: Font = l.label_settings.font
		var words_end := l.position.x + minf(l.size.x, f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x)
		var sr := Rect2(seal.position, seal.size)
		_expect(sr.position.x >= words_end - 0.5, "%s: %s's seal sits on the name" % [tag, d["name"]])
		_expect(sr.position.x >= box.position.x - 1.0 and sr.end.x <= box.end.x + 1.0,
			"%s: %s's seal leaves the name's box (%s in %s)" % [tag, d["name"], sr, box])
		_expect(absf(sr.get_center().y - box.get_center().y) <= 1.0, "%s: %s's seal is not level with the name" % [tag, d["name"]])
		_expect(sr.size.y <= 60.0 and seal.texture.get_height() >= sr.size.y, "%s: the seal is drawn up" % tag)
	var want := Color(str(worn["color"])) if worn.has("color") else plain
	_expect(l.label_settings.font_color.is_equal_approx(want), "%s: %s's name is %s, want %s" % [tag, d["name"], l.label_settings.font_color.to_html(false), want.to_html(false)])
	if portrait != null:
		var ring: TextureRect = portrait.get_meta("look_frame") if portrait.has_meta("look_frame") else null
		var framed := worn.has("frame")
		_expect((ring != null and ring.visible) == framed, "%s: %s's frame is %s" % [tag, d["name"], "drawn" if ring and ring.visible else "missing"])
		if framed and ring != null:
			_expect(float(ring.get_meta("look_scale", 9.0)) <= 1.0 + 1e-6, "%s: %s's frame is drawn up x%.2f" % [tag, d["name"], float(ring.get_meta("look_scale", 9.0))])
			_expect(ring.texture.resource_path.contains("_" + shape), "%s: %s's frame is %s, want a %s" % [tag, d["name"], ring.texture.resource_path.get_file(), shape])
	if title != null:
		var t := str(worn.get("title", ""))
		_expect(title.visible == (t != "") and (t == "" or title.text == t), "%s: %s's title shows \"%s\"" % [tag, d["name"], title.text if title.visible else ""])


# --- the rival and revenge cards --------------------------------------------------------

func _attack(canvas: Vector2) -> void:
	var tag := "attack %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/attack.gd") as GDScript).new()
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(tab)
	for i in 3:
		await process_frame
	var lords := _lords()
	tab.set("_data", {"might": 3000, "energy_cost": 11, "revenge": lords, "targets": lords})
	tab.set("_loaded", true)
	for view in ["revenge", "targets"]:
		tab.call("_set_view", view)
		tab.call("_paint")
		await process_frame
		var cards: Array = tab.get("_revenge_cards") if view == "revenge" else tab.get("_targets")
		var card_id := "revenge_card" if view == "revenge" else "target_card"
		for i in mini(cards.size(), lords.size()):
			var c: Dictionary = cards[i]
			var p: Dictionary = c["parts"]
			var d: Dictionary = lords[i]
			var box: Rect2 = tab.call("_part_rect", card_id, "name")
			box.size.x -= float((load("res://scenes/tabs/attack.gd") as GDScript).get_script_constant_map()["NAME_CLEAR"])
			_lord("%s %s" % [tag, view], d, p["name"], Color("#F3EEE6"), p["portrait"], "square", c.get("title"), box)
			var crest := str((d.get("worn", {}) as Dictionary).get("crest", root.get_node("Art").call("crest", str(d["player_id"]))))
			_expect((p["crest"] as TextureRect).texture.resource_path.ends_with(crest + ".png"),
				"%s %s: %s wears the crest %s" % [tag, view, d["name"], (p["crest"] as TextureRect).texture.resource_path.get_file()])
	host.queue_free()
	await process_frame


# --- the kingdom's lords ------------------------------------------------------------------

## Two lords asking to join, as KingdomView.requests carries them: one plain,
## one wearing everything under the longest name.
func _asking() -> Array:
	var all: Dictionary = _lords()[3].duplicate(true)
	all["player_id"] = "asks_all"
	all["name"] = "Xxxxxxxxxxxxxxxx"
	all["asks"] = true
	all.erase("role")
	return [{"player_id": "asks_plain", "name": "Osric", "avatar": "archer", "level": 21, "waiting": 60, "asks": true}, all]


func _kingdom_data() -> Dictionary:
	return {"in_kingdom": true, "kingdom": {"id": "k", "name": "Test", "tag": "TST", "level": 3, "members": 4, "member_cap": 20},
		"members": _lords(), "upgrades": [], "me": {"role": "king"}, "requests": _asking()}


func _realm(canvas: Vector2) -> void:
	var tag := "realm %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var page: Control = (load("res://scenes/tabs/kingdom.gd") as GDScript).new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(page)
	for i in 3:
		await process_frame
	page.set("_data", _kingdom_data())
	page.set("_loaded_once", true)
	page.call("_apply")
	for i in 3:
		await process_frame
	var rows: Array = page.get("_lords")
	# The panel sorts king, captain, then lords by level.
	var by_id := {}
	for d in _lords():
		by_id[d["name"].to_upper()] = d
	var box: Rect2 = page.call("_part_rect", "lord_row", "name")
	for r in rows:
		var p: Dictionary = r["parts"]
		var l: Label = p["name"]
		if not l.visible:
			continue
		var d: Dictionary = {}
		for k in by_id:
			if l.text == k or (k.begins_with("WWWW") and l.text.begins_with("WWWW")):
				d = by_id[k]
		if d.is_empty():
			_expect(false, "%s: a row names %s" % [tag, l.text])
			continue
		var face: Control = p["portrait"].get_meta("lord_face") if p["portrait"].has_meta("lord_face") else null
		_expect(face != null and face.visible and (face as TextureRect).texture.resource_path.contains("avatar_" + str(d["avatar"])),
			"%s: %s is not drawn with their own face" % [tag, d["name"]])
		_lord(tag, d, l, Color("#D8DCE0"), face, "ring", r.get("title"), box)
	host.queue_free()
	await process_frame


func _lords_page(canvas: Vector2) -> void:
	var tag := "lords page %dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var sec: Control = (load("res://scenes/kingdom/kingdom_section.gd") as GDScript).new()
	sec.setup("lords", _kingdom_data(), {})
	host.add_child(sec)
	for i in 3:
		await process_frame
	var lords := _lords() + _asking()
	for d in lords:
		var name_label: Label = null
		for n in _all(sec):
			if n is Label and (n as Label).has_meta("look_seal") and (n as Label).text.begins_with(str(d["name"]).substr(0, 4)):
				name_label = n
		_expect(name_label != null, "%s: no name for %s" % [tag, d["name"]])
		if name_label == null:
			continue
		var row: Control = name_label.get_parent()
		# A request is its own row, with the answer's two buttons.
		if d.has("asks"):
			var answers := 0
			for n in row.get_children():
				if n is Button and (n as Button).text in ["ACCEPT", "REFUSE"]:
					answers += 1
			_expect(answers == 2, "%s: %s's request is not a request row" % [tag, d["name"]])
		var face: Control = null
		var title: Label = null
		for n in row.get_children():
			if n is TextureRect and n.has_meta("lord_face"):
				face = n.get_meta("lord_face")
			if n is Label and n != name_label and (n as Label).label_settings.font_size <= 23 and (n as Label).text == str((d.get("worn", {}) as Dictionary).get("title", "")) and (n as Label).text != "":
				title = n
		var box := Rect2(name_label.position, Vector2(sec.get("WIDTH") - name_label.position.x, 44))
		_lord(tag, d, name_label, Color(1, 1, 1, 1) * UI_INK(), face, "ring", title if (d.get("worn", {}) as Dictionary).has("title") else null, box.grow_individual(0, 0, 400, 0))
	host.queue_free()
	await process_frame


func UI_INK() -> Color:
	return (load("res://scripts/ui/ui.gd") as GDScript).get_script_constant_map()["INK"]


# --- the rankings -------------------------------------------------------------------------

func _rankings(canvas: Vector2, inset: float) -> void:
	var tag := "rankings %dx%d inset %d" % [int(canvas.x), int(canvas.y), int(inset)]
	var vp := SubViewport.new()
	vp.size = Vector2i(canvas)
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = canvas
	vp.add_child(host)
	var script: GDScript = load("res://scenes/pages/leaderboard_page.gd")
	var page: Control = script.open(host, {"inset": inset})
	for i in 3:
		await process_frame
	var lords := _lords()
	var rows: Array = []
	# The four at ranks 1-4 and 5-8: the podium holds 1-3, the list the rest.
	for i in 8:
		var d: Dictionary = lords[i % 4].duplicate(true)
		d["rank"] = i + 1
		d["value"] = 999999 - i
		rows.append(d)
	script.paint(page, {"rows": rows, "my_rank": 12, "my_value": 5}, "might")
	for i in 3:
		await process_frame
	var ink := UI_INK()
	var L: GDScript = load("res://scripts/ui/layout.gd")
	for i in 3:
		var l: Label = page.call("node", "p%d_name" % (i + 1))
		var face: Control = null
		for n in _all(page):
			if n is TextureRect and n.has_meta("podium") and int(n.get_meta("podium")) == i:
				face = n
		_lord(tag + " podium", rows[i], l, ink, face, "ring", null, page.call("map_rect", L.rect_of(L.find("rankings", "p%d_name" % (i + 1)))))
	var list: Control = page.call("content", "list")
	for r in list.get_children():
		if r.has_meta("notice"):
			continue
		var rank_label: Label = null
		var name_label: Label = null
		var face: Control = null
		for n in r.get_children():
			if n is Label and (n as Label).text.begins_with("#"):
				rank_label = n
			elif n is Label and n.has_meta("look_seal"):
				name_label = n
			elif n is TextureRect and n.has_meta("look_frame"):
				face = n
		var rank := int(rank_label.text.substr(1))
		_lord(tag + " row", rows[rank - 1], name_label, ink, face, "ring", null, script.get_script_constant_map()["ROW_NAME"])
	# YOUR RANK: the asker's own look, from their snapshot's `worn`.
	var you: Label = page.call("node", "you_name")
	var mine := {"name": LONG, "worn": {"color": "#8FB8FF", "title": "the Founder", "frame": "frames/patron"}, "vip_seal": true}
	var you_face: Control = page.get_meta("you_face")
	_lord(tag + " YOUR RANK", mine, you, ink, you_face, "ring", null, page.call("map_rect", L.rect_of(L.find("rankings", "you_name"))))
	page.call("close")
	vp.queue_free()
	await process_frame


# --- a replay from the history -------------------------------------------------------------

## A revenge or history replay is opened from a BattleLogEntry: the rival's
## name, face and opponent_look go to the battle (attack.gd replay_opponent),
## which names them in their colour with their seal; plain when they wear none.
func _replay(canvas: Vector2, inset: float, dressed: bool) -> void:
	var tag := "replay %dx%d/%d %s" % [int(canvas.x), int(canvas.y), int(inset), "dressed" if dressed else "plain"]
	var entry := {"battle_id": "b", "opponent_name": "Hallking2", "opponent_avatar": "berserk"}
	if dressed:
		entry["opponent_look"] = {"worn": {"color": "#6FD28A", "title": "the Generous"}, "vip_seal": true}
	var opponent: Dictionary = (load("res://scenes/tabs/attack.gd") as GDScript).replay_opponent(entry)
	var result := {"v": 2, "rounds": 1, "winner": "d", "fortune_a_bp": 10000, "fortune_d_bp": 10000,
		"attacker_might": 3000, "defender_might": 5000, "perspective": "defender",
		"attacker": {"player_id": "A", "name": "Hallking2", "avatar": "berserk", "units": [{"id": "A", "hp": 9000}]},
		"defender": {"player_id": "D", "name": LONG, "avatar": "witch", "units": [{"id": "D", "hp": 8000}]},
		"events": [{"r": 1, "k": "round"}]}
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var screen: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	screen.setup(result, opponent)
	screen.set("top_inset", inset)
	host.add_child(screen)
	for i in 3:
		await process_frame
	var ui: Dictionary = screen.get("_ui")
	var l: Label = ui["name_them"]
	var seal: TextureRect = l.get_meta("look_seal") if l.has_meta("look_seal") else null
	_checked += 1
	_expect((seal != null and seal.visible) == dressed, "%s: the rival's seal is %s" % [tag, "drawn" if seal and seal.visible else "missing"])
	if dressed:
		_expect(l.label_settings.font_color.is_equal_approx(Color("#6FD28A")), "%s: the rival's name is %s, not their colour" % [tag, l.label_settings.font_color.to_html(false)])
	screen.queue_free()
	host.queue_free()
	await process_frame


# --- the colours read on every plate --------------------------------------------------------

## Each worn colour the catalogue sells against the ground of every plate a name
## is set on, at the name's own place in the painting.
func _contrast() -> void:
	var colours: Array = []
	var f := FileAccess.open(ProjectSettings.globalize_path("res://").path_join("../balance/cosmetics.json"), FileAccess.READ)
	var cat: Variant = JSON.parse_string(f.get_as_text())
	for c in (cat as Dictionary).get("items", []):
		if str(c.get("kind", "")) == "name_color":
			colours.append(Color(str(c["color"])))
	_expect(colours.size() >= 4, "the catalogue sells %d name colours" % colours.size())
	var plates := {
		"attack/target_card": Rect2(270, 14, 260, 40), "attack/revenge_card": Rect2(270, 62, 260, 36),
		"kingdom/lord_row": Rect2(99, 7, 150, 24), "rankings/row": Rect2(246, 16, 262, 32),
		"rankings/page": Rect2(380, 628, 181, 38), "inventory/card_frame": Rect2(160, 24, 300, 44),
	}
	for key in plates:
		var ground := _ground(key, plates[key])
		for c in colours:
			var ratio := _ratio(c, ground)
			_checked += 1
			_expect(ratio >= 4.5, "%s on %s's plate (%s) reads at %.1f:1" % [c.to_html(false), key, ground.to_html(false), ratio])


## The plate's ground under a name: the darker half of the pixels in the box.
func _ground(key: String, box: Rect2) -> Color:
	var img: Image = (load("res://assets/%s.png" % key) as Texture2D).get_image()
	img.decompress()
	var lums: Array = []
	for y in range(int(box.position.y), int(box.end.y)):
		for x in range(int(box.position.x), int(box.end.x)):
			if x < img.get_width() and y < img.get_height():
				var c := img.get_pixel(x, y)
				lums.append([c.get_luminance(), c])
	lums.sort_custom(func(a, b): return a[0] < b[0])
	var sum := Color(0, 0, 0, 0)
	var n := maxi(1, lums.size() / 2)
	for i in n:
		sum += lums[i][1]
	return sum / float(n)


func _ratio(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


func _lum(c: Color) -> float:
	var ch := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * ch.call(c.r) + 0.7152 * ch.call(c.g) + 0.0722 * ch.call(c.b)


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL  " + what)
