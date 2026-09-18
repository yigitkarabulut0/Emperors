extends SceneTree
## BATTLE HISTORY and THE COLLECTION are their paintings, on the painted pages'
## host, and say what the server says.
##
## History (art/reference/history.png):
## - its tab words are type -- ALL, MY RAIDS, ON ME -- and the painting's own
##   misspelt "MY RADS" is erased from the page; the chosen tab wears the lit
##   plate;
## - each row is the painting's row for its outcome (won, lost, held, raided),
##   the gold in its box at any size, and the opponent drawn as every screen
##   draws a lord (Look.paint_name): their worn colour only when they wear one,
##   Royal Favour's seal only when they have it, and the longest name whole
##   beside the seal, inside its plate;
## - MY RAIDS lists only the player's raids and ON ME only the raids on them,
##   each with its own word when there are none.
## The Collection (art/reference/collection.png):
## - the seven frames of each slot are its tiers: the grandest held design in
##   each, n/3 under it, gold when the set is whole, dark while none is held;
## - the offers are what the bags hold that the wall would take, one row each
##   with its DONATE, and a word when there is nothing.
## Both fit 941x1672, 941x2040 and 941x2040 under a 141 notch, the list taking
## the tall canvas's extra height, CLOSE on the screen.
##
## Run: godot --headless --path client --script tests/painted_history_collection.gd

const CASES := [[Vector2(941, 1672), 0.0], [Vector2(941, 2040), 0.0], [Vector2(941, 2040), 141.0]]
const TIERS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
## UI.GOLD, named here rather than through UI: a class named in this script is
## compiled before the autoloads it uses exist.
const GOLD := Color("#E9C46A")

var _fails := 0
var _checked := 0
var _list_h := {}


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_the_misspelling_is_gone()
	for c in CASES:
		await _history(c[0], c[1])
		await _collection(c[0], c[1])
	_checked += 1
	if float(_list_h.get("history 2040", 0.0)) <= float(_list_h.get("history 1672", 0.0)):
		_fail("the history list is no taller on 941x2040 than on 941x1672")
	if float(_list_h.get("collection 2040", 0.0)) <= float(_list_h.get("collection 1672", 0.0)):
		_fail("the offer list is no taller on 941x2040 than on 941x1672")
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: history and the wall are their paintings and read the server" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## The painted tab words are erased from the page: no ink left on the plates
## where ALL, MY RADS and ON ME were.
func _the_misspelling_is_gone() -> void:
	var img := Image.load_from_file("res://assets/history/page.png")
	_checked += 1
	if img == null:
		_fail("there is no history/page")
		return
	for r in [Rect2i(190, 551, 60, 26), Rect2i(420, 551, 130, 26), Rect2i(684, 551, 92, 26)]:
		var ink := 0
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var c := img.get_pixel(x, y)
				if c.r + c.g + c.b > 2.1:
					ink += 1
		if ink > 3:
			_fail("history/page still carries painted tab words at %s (%d bright pixels)" % [r, ink])


func _entries() -> Array:
	return [
		{"battle_id": "a", "won": true, "raided": false, "opponent_name": "Wwwwwwwwwwwwwwww", "opponent_level": 60,
			"gold": 987654321, "at": "2026-09-10T09:00:00Z", "opponent_look": {"worn": {"color": "#6FD28A"}, "vip_seal": true}},
		{"battle_id": "b", "won": false, "raided": false, "opponent_name": "Seraphine", "opponent_level": 33,
			"gold": 0, "at": "2026-09-10T09:00:00Z"},
		{"battle_id": "c", "won": true, "raided": true, "opponent_name": "Keldric", "opponent_level": 29,
			"gold": 12400, "at": "2026-09-10T09:00:00Z", "opponent_look": {"worn": {}, "vip_seal": true}},
		{"battle_id": "d", "won": false, "raided": true, "opponent_name": "Malric", "opponent_level": 31,
			"gold": -987654321, "at": "2026-09-10T09:00:00Z"},
	]


func _host(canvas: Vector2) -> Control:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	return host


func _history(canvas: Vector2, inset: float) -> void:
	var tag := "history %dx%d/%d" % [int(canvas.x), int(canvas.y), int(inset)]
	var host := _host(canvas)
	var page: GDScript = load("res://scenes/pages/history_page.gd")
	var played := []
	var p: Control = page.open(host, _entries(), func(e): played.append(e), {"inset": inset})
	await process_frame
	await process_frame
	if not p.has_method("content"):
		_fail("%s: the page is not on the painted host" % tag)
		host.queue_free()
		return
	_checked += 1
	# ALL / MY RAIDS / ON ME are the game's tab strip on the short plates, the
	# words painted on them (the painting's own plate spelled MY RADS).
	var strip: Control = page.call("tabs", p)
	if strip == null or strip.ids != ["all", "my_raids", "on_me"] or not bool(strip.get("short")):
		_fail("%s: the tabs are not a TabStrip of the short ALL / MY RAIDS / ON ME plates" % tag)
	_lit_only(p, "tab_all", tag)
	var rows := _rows(p, "list")
	var want := ["won", "lost", "held", "raided"]
	if rows.size() != 4:
		_fail("%s: 4 battles drew %d rows" % [tag, rows.size()])
	else:
		for i in 4:
			var parts: Dictionary = rows[i]
			var art: TextureRect = parts["art"]
			if art.texture == null or not art.texture.resource_path.ends_with("row_%s.png" % want[i]):
				_fail("%s: row %d is %s, want the %s row" % [tag, i + 1, art.texture.resource_path if art.texture else "nothing", want[i]])
			var g: Label = parts["gold"]
			var s := g.label_settings
			var w := s.font.get_string_size(g.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
			if w > float(g.get_meta("box_w", g.size.x)) + 0.5:
				_fail("%s: row %d's gold \"%s\" runs out of its box" % [tag, i + 1, g.text])
		_looks(rows, tag)
		# A tap plays that fight (once the page has armed, as a player's would).
		await create_timer(0.3).timeout
		(rows[2]["tap"] as BaseButton).pressed.emit()
		if played.size() != 1 or str(played[0].get("battle_id", "")) != "c":
			_fail("%s: tapping the third row did not play its fight" % tag)
	# The tabs sort the list.
	page.show_tab(p, "tab_mine")
	await process_frame
	_lit_only(p, "tab_mine", tag)
	if _rows(p, "list").size() != 2:
		_fail("%s: MY RAIDS shows %d rows, want the 2 raids the player made" % [tag, _rows(p, "list").size()])
	page.show_tab(p, "tab_on_me")
	await process_frame
	if _rows(p, "list").size() != 2:
		_fail("%s: ON ME shows %d rows, want the 2 raids on the player" % [tag, _rows(p, "list").size()])
	_list_h["history %d" % int(canvas.y)] = maxf(float(_list_h.get("history %d" % int(canvas.y), 0.0)),
		(p.call("node", "list") as Control).size.y) if inset == 0.0 else float(_list_h.get("history %d" % int(canvas.y), 0.0))
	_on_screen(p, "close", canvas, tag)
	p.call("close")
	host.queue_free()
	await process_frame
	# No battles at all: the page says so.
	host = _host(canvas)
	p = page.open(host, [], func(_e): pass, {"inset": inset})
	await process_frame
	var empty := p.call("node", "empty") as Label
	if empty == null or not empty.visible or empty.text == "":
		_fail("%s: an empty history says nothing" % tag)
	p.call("close")
	host.queue_free()
	await process_frame


## Row by row: the seal where the entry has it and nowhere else, the worn colour
## where one is worn and the plate's ivory otherwise, and the longest name
## whole beside its seal, all inside the name plate.
func _looks(rows: Array, tag: String) -> void:
	var e := _entries()
	var tpl: Dictionary = load("res://scripts/ui/layout.gd").find("history", "row")
	var plate := Rect2()
	for part in tpl.get("parts", []):
		if str(part.get("id", "")) == "name":
			var r: Array = part["rect"]
			plate = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
	for i in rows.size():
		var name: Label = rows[i]["name"]
		var look: Dictionary = e[i].get("opponent_look", {})
		var seal: TextureRect = name.get_meta("look_seal") if name.has_meta("look_seal") else null
		var sealed := bool(look.get("vip_seal", false))
		var shown := seal != null and seal.visible
		if shown != sealed:
			_fail("%s: row %d %s Royal Favour's seal" % [tag, i + 1, "shows" if shown else "lacks"])
		var worn := str((look.get("worn", {}) as Dictionary).get("color", ""))
		var want := Color(worn) if worn != "" else Color("#F1E9DA")
		if not name.label_settings.font_color.is_equal_approx(want):
			_fail("%s: row %d's name is %s, want %s" % [tag, i + 1, name.label_settings.font_color.to_html(false), want.to_html(false)])
		if name.text != str(e[i].get("opponent_name", "")):
			_fail("%s: row %d's name reads \"%s\" -- cut short" % [tag, i + 1, name.text])
		var s := name.label_settings
		var words := s.font.get_string_size(name.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		var end := name.position.x + words
		if shown:
			end = seal.position.x + seal.size.x
			if seal.position.x < name.position.x + words:
				_fail("%s: row %d's seal lies over its name" % [tag, i + 1])
		if name.position.x < plate.position.x - 0.5 or end > plate.end.x + 0.5:
			_fail("%s: row %d's name%s runs to %.0f, past its plate's %.0f" % [tag, i + 1,
				" and seal" if shown else "", end, plate.end.x])


func _lit_only(p: Control, tab: String, tag: String) -> void:
	var page: GDScript = load("res://scenes/pages/history_page.gd")
	var strip: Control = page.call("tabs", p)
	if strip == null:
		return
	var plates := {"tab_all": "all", "tab_mine": "my_raids", "tab_on_me": "on_me"}
	for t in plates:
		var tex: Texture2D = strip.plate(plates[t]).texture
		var lit: bool = tex != null and tex.resource_path.ends_with("tabs/short_%s_lit.png" % plates[t])
		if lit != (t == tab):
			_fail("%s: with %s chosen, %s is %s" % [tag, tab, t, "lit" if lit else "unlit"])


## The live rows in a scroll region: each row's parts, top to bottom.
func _rows(p: Control, scroll_id: String) -> Array:
	var content: Control = p.call("content", scroll_id)
	var out: Array = []
	for c in content.get_children():
		if c.is_queued_for_deletion():
			continue
		if c.has_meta("parts"):
			out.append(c.get_meta("parts"))
	out.sort_custom(func(a, b): return (a.values()[0] as Control).get_parent().position.y < (b.values()[0] as Control).get_parent().position.y)
	return out


func _on_screen(p: Control, id: String, canvas: Vector2, tag: String) -> void:
	var n := p.call("node", id) as Control
	if n == null:
		_fail("%s: no %s" % [tag, id])
		return
	var r := n.get_global_rect()
	if r.position.y < 0.0 or r.end.y > canvas.y + 0.5 or r.position.x < 0.0 or r.end.x > canvas.x + 0.5:
		_fail("%s: %s is at %s, off the %s screen" % [tag, id, r, canvas])


func _collection(canvas: Vector2, inset: float) -> void:
	var tag := "collection %dx%d/%d" % [int(canvas.x), int(canvas.y), int(inset)]
	var f := FileAccess.open("res://../balance/items.json", FileAccess.READ)
	var defs: Array = JSON.parse_string(f.get_as_text())["definitions"]
	var sets := {}
	for d in defs:
		var key := "%s/%s" % [d["slot"], d["tier"]]
		if not sets.has(key):
			sets[key] = {"slot": d["slot"], "tier": d["tier"], "entries": []}
		# Weapons: every common held, one rare; nothing else.
		var held: bool = d["slot"] == "weapon" and (d["tier"] == "common" or d["id"] == "weapon_rare_02")
		sets[key]["entries"].append({"def_id": d["id"], "name": d["name"], "art": d["art"], "held": held})
	var wall := {"held": 4, "total": 63, "luck_bp": 240, "luck_per_piece_bp": 60, "luck_per_set_bp": 120, "sets": sets.values()}
	var items := [
		{"id": "1", "def_id": "armor_rare_01", "name": "Riverbend Aegis", "slot": "armor", "tier": "rare", "art": "armor_07", "equipped_on": ""},
		{"id": "2", "def_id": "armor_rare_01", "name": "Riverbend Aegis", "slot": "armor", "tier": "rare", "art": "armor_07", "equipped_on": ""},
		{"id": "3", "def_id": "weapon_common_01", "name": "Rusted Arming Sword", "slot": "weapon", "tier": "common", "art": "weapon_01", "equipped_on": ""},
		{"id": "4", "def_id": "horse_epic_01", "name": "Duskmane Rouncey", "slot": "horse", "tier": "epic", "art": "horse_10", "equipped_on": "hero"},
		{"id": "5", "def_id": "horse_special_03", "name": "Sunrise Charger", "slot": "horse", "tier": "special", "art": "horse_21", "equipped_on": ""},
	]
	var host := _host(canvas)
	var page: GDScript = load("res://scenes/pages/collection_page.gd")
	var p: Control = page.open(host, {"items": items}, {"inset": inset})
	await process_frame
	if not p.has_method("content"):
		_fail("%s: the page is not on the painted host" % tag)
		host.queue_free()
		return
	p.set_meta("wall", wall)
	page.paint(p)
	await process_frame
	_checked += 1
	var cells: Array = p.get("parts").get("cell", [])
	if cells.size() != 21:
		_fail("%s: %d tier frames, want 21 (three slots, seven tiers)" % [tag, cells.size()])
	else:
		var common: Dictionary = cells[0]["parts"]
		var rare: Dictionary = cells[2]["parts"]
		var special: Dictionary = cells[6]["parts"]
		if (common["count"] as Label).text != "3/3" or not (common["count"] as Label).label_settings.font_color.is_equal_approx(GOLD):
			_fail("%s: the whole common weapon set reads \"%s\", not a gold 3/3" % [tag, (common["count"] as Label).text])
		if (rare["count"] as Label).text != "1/3":
			_fail("%s: one rare weapon held reads \"%s\"" % [tag, (rare["count"] as Label).text])
		var rp: TextureRect = rare["pic"]
		if rp.texture == null or not rp.texture.resource_path.ends_with("weapon_08.png") or rp.modulate != Color.WHITE:
			_fail("%s: the rare frame does not show its held design (weapon_08) lit" % tag)
		if (special["pic"] as TextureRect).modulate == Color.WHITE or (special["count"] as Label).text != "0/3":
			_fail("%s: a tier with nothing held is not dark at 0/3" % tag)
	var rows := _rows(p, "offers")
	# Riverbend Aegis once (not twice), Sunrise Charger; not the held common sword, not the worn horse.
	var names: Array = []
	for r in rows:
		names.append((r["name"] as Label).text)
	if names != ["Sunrise Charger", "Riverbend Aegis"]:
		_fail("%s: the wall is offered %s, want [Sunrise Charger, Riverbend Aegis]" % [tag, names])
	for r in rows:
		if not r.has("donate"):
			_fail("%s: an offer has no DONATE" % tag)
	if (p.call("node", "offers_empty") as Control).visible:
		_fail("%s: the empty word shows over offers" % tag)
	_list_h["collection %d" % int(canvas.y)] = (p.call("node", "offers") as Control).size.y if inset == 0.0 \
		else float(_list_h.get("collection %d" % int(canvas.y), 0.0))
	_on_screen(p, "close", canvas, tag)
	p.call("close")
	host.queue_free()
	await process_frame
	host = _host(canvas)
	p = page.open(host, {"items": []}, {"inset": inset})
	await process_frame
	p.set_meta("wall", wall)
	page.paint(p)
	var none := p.call("node", "offers_empty") as Label
	if none == null or not none.visible or none.text == "":
		_fail("%s: with nothing to give, the page says nothing" % tag)
	p.call("close")
	host.queue_free()
	await process_frame
