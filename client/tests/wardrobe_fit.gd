extends SceneTree
## SPLENDOUR holds on every phone and marks every cosmetic for what it is.
##
## The page is its painting (art/reference/wardrobe.png) on the painted pages'
## host, filled from the real catalogue (balance/cosmetics.json, answered as
## GetWardrobe answers it). For a patron who wears a frame held for a time and
## a new lord with 100 diamonds who owns only the four free crests, on
## 941x1672 and 941x2040, with and without a Dynamic Island, under each tab:
##  - the page is a PaintedPage whose grid takes a taller phone's height;
##  - every tile shows its own item and keeps it inside itself: a frame's ring,
##    a crest drawn down into the box (they are cut 182x240, taller than it),
##    a title centred between the scroll's rollers, a colour's chip with the
##    lord's name in it across no more than the tile (a sixteen-letter name
##    ran twenty units past the tile's side), every word whole;
##  - worn wears the wax tick, locked the padlock and where it comes from, sold
##    its price beside the diamond (red when the lord has too few), held for a
##    time how long is left;
##  - EQUIP says what it will do for the tile selected -- EQUIP, TAKE OFF, BUY
##    and the price, LOCKED and dark -- inside its plate;
##  - the strip under the grid shows the lord as they are dressed;
##  - the tabs switch the grid, and CLOSE closes.
##
## Run: godot --headless --path client --script tests/wardrobe_fit.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const VIEW := "res://scenes/court/wardrobe_view.gd"
const TABS := ["frames", "titles", "colours", "crests"]
const KIND := {"frames": "frame", "titles": "title", "colours": "name_color", "crests": "crest"}
const LORD := "Wwwwwwwwwwwwwwww"

## Loaded, not named: a test script compiles before the autoloads the UI
## scripts use exist.
var _L: GDScript
var _U: GDScript
var _fails := 0
var _checked := 0
var _W: GDScript
var _doc: Dictionary


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_L = load("res://scripts/ui/layout.gd")
	_U = load("res://scripts/ui/ui.gd")
	_W = load(VIEW)
	if _W == null or not _W.get_script_constant_map().has("PAGE"):
		print("FAIL  wardrobe_view.gd is not a painted page")
		quit(1)
		return
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/cosmetics.json")
	_doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	_actions()
	var patron := _catalogue({"frame_patron": 27 * 86400 + 5 * 3600, "frame_founder": 0, "title_founder": 0,
		"color_emerald": 0}, ["frame_patron", "title_founder", "color_emerald", "crest_lion"], 1240)
	var fresh := _catalogue({}, [], 100)
	for canvas in CANVASES:
		for inset in INSETS:
			var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
			await _case("a patron, %s" % tag, canvas, inset, patron)
			await _case("a new lord with 100 diamonds, %s" % tag, canvas, inset, fresh)
	if _checked < 8 * 4:
		_fail("only %d of 32 tabs were measured" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d Splendour tabs hold on both canvases, under the notch, every tile marked" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## The catalogue as GetWardrobe answers it for a lord who owns `owned` (id ->
## seconds left, 0 for good) and wears `worn`: by kind, what is owned first.
func _catalogue(owned: Dictionary, worn: Array, diamonds: int) -> Dictionary:
	var items: Array = []
	var look := {}
	var order := {"frame": 0, "title": 1, "name_color": 2, "crest": 3}
	for c in _doc["items"]:
		var id := str(c["id"])
		var has := owned.has(id) or bool(c.get("default_owned", false))
		var cv := {"id": id, "kind": c["kind"], "name": c["name"], "owned": has, "worn": has and id in worn}
		for k in ["text", "color", "art"]:
			if c.has(k):
				cv[k] = c[k]
		if not has:
			if int(c.get("shop_diamonds", 0)) > 0:
				cv["shop_diamonds"] = int(c["shop_diamonds"])
			cv["source"] = str(c.get("source_hint", ""))
		elif int(owned.get(id, 0)) > 0:
			cv["expires_in"] = int(owned[id])
		if cv["worn"]:
			look[{"frame": "frame", "title": "title", "name_color": "color", "crest": "crest"}[c["kind"]]] = \
				c.get("art", c.get("text", c.get("color", "")))
		items.append([order[c["kind"]], 0 if has else 1, items.size(), cv])
	items.sort()
	return {"items": items.map(func(k: Array) -> Dictionary: return k[3]), "worn": look, "diamonds": diamonds}


func _host(canvas: Vector2i) -> Control:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	return host


func _case(what: String, canvas: Vector2i, inset: float, wardrobe: Dictionary) -> void:
	root.get_node("GameState").set("snapshot", {"player": {"username": LORD, "avatar": "queen", "level": 30,
		"gold": "987654321", "diamonds": int(wardrobe["diamonds"]), "action_seq": 1},
		"energy": {"current": 185, "max": 236}})
	var host := _host(canvas)
	var p: Control = _W.call("open", host, {"inset": inset, "offline": true})
	var s: Script = p.get_script() if p != null else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s: the page is not a PaintedPage" % what)
		host.get_parent().queue_free()
		return
	var v: Node = _W.call("of", p)
	v.call("paint", wardrobe)
	await create_timer(0.4).timeout
	var grid := v.get("_grid") as ScrollContainer
	var painted_h: float = (_L.rect_of(_L.element("wardrobe", "grid")) as Rect2).size.y
	var extra := float(p.get("extra"))
	if absf(grid.size.y - (painted_h + extra)) > 1.0:
		_fail("%s: the grid is %.0f tall, not its %.0f and the page's %.0f more" % [what, grid.size.y, painted_h, extra])
	for tab in TABS:
		(v.get("_tabs") as Object).call("select", tab, true)
		await process_frame
		_checked += 1
		_tab(v, p, "%s, %s" % [what, tab], tab, wardrobe, Vector2(canvas), inset)
	_look(p, what, wardrobe)
	# The shortest name after the longest: the name's label keeps the box it
	# was measured into. Built around the painting's sixteen-letter sample, a
	# label grows to it, and a fitter that does not size it back leaves a
	# short name placed by the sample's width.
	for who in ["Al", LORD]:
		(root.get_node("GameState").get("snapshot")["player"] as Dictionary)["username"] = who
		v.call("paint", wardrobe)
		await process_frame
		_look_box(p, "%s, the name \"%s\"" % [what, who], who)
	(p.call("node", "close") as BaseButton).pressed.emit()
	await create_timer(0.3).timeout
	for c in host.get_parent().get_children():
		if c is CanvasLayer and not c.is_queued_for_deletion():
			_fail("%s: CLOSE left the page open" % what)
			break
	host.get_parent().queue_free()
	await process_frame


func _tab(v: Node, p: Control, what: String, tab: String, wardrobe: Dictionary, canvas: Vector2, inset: float) -> void:
	var tiles: Array = v.get("_tiles")
	var want: Array = []
	for it in wardrobe["items"]:
		if str(it["kind"]) == KIND[tab]:
			want.append(it)
	if tiles.size() != want.size():
		_fail("%s: %d tiles for %d items" % [what, tiles.size(), want.size()])
		return
	var tile_size: Vector2 = (_L.rect_of(_L.element("wardrobe", "tile")) as Rect2).size
	var art: Rect2 = _L.rect_of(_L.find("wardrobe", "art"))
	var selected := 0
	for i in tiles.size():
		var t: Dictionary = tiles[i]
		var it: Dictionary = t["item"]
		if str(it["id"]) != str(want[i]["id"]):
			_fail("%s: tile %d is %s, not %s" % [what, i, it["id"], want[i]["id"]])
		var label := "%s: %s" % [what, it["id"]]
		_inside(t, label, tile_size, art, str(it["kind"]))
		_marks(t, label, it, int(wardrobe["diamonds"]))
		if (t["parts"]["sel"] as CanvasItem).visible:
			selected += 1
	if selected != 1:
		_fail("%s: %d tiles selected" % [what, selected])
	# EQUIP, for the tile the tab opened on.
	var chosen := {}
	for it in want:
		if str(it["id"]) == str(v.get("_selected")):
			chosen = it
	var act: Array = _W.call("equip_action", chosen)
	var b := p.call("node", "equip") as Button
	if b.text != str(act[1]) or b.disabled != (str(act[0]) == ""):
		_fail("%s: EQUIP says \"%s\" (%s) for %s" % [what, b.text, "dark" if b.disabled else "lit", chosen.get("id")])
	var f: Font = b.get_theme_font("font")
	var w: float = _W.call("equip_width", f, b.text, b.get_theme_font_size("font_size"), b.icon != null)
	if w > b.size.x - 48.0 + 0.5:
		_fail("%s: EQUIP's \"%s\" is %.0f wide on a %.0f plate" % [what, b.text, w, b.size.x])
	if (b.icon != null) != (str(act[0]) == "buy"):
		_fail("%s: EQUIP %s the diamond for \"%s\"" % [what, "wears" if b.icon != null else "lacks", b.text])
	# The page itself on the screen, under the notch: the buttons, the strip,
	# the tabs and the grid's own box (tiles past it scroll, clipped).
	for id in ["equip", "close", "look_name", "look_title"]:
		_on_screen(p.call("node", id) as Control, "%s: %s" % [what, id], canvas, inset)
	_on_screen(v.get("_grid") as Control, what + ": the grid", canvas, inset)
	_on_screen(v.get("_tabs") as Control, what + ": the tabs", canvas, inset)
	if str((v.get("_tabs") as Object).get("selected")) != tab:
		_fail("%s: the strip lights %s" % [what, str((v.get("_tabs") as Object).get("selected"))])


## Everything a tile draws stays inside it; its art inside the art box.
func _inside(t: Dictionary, what: String, tile: Vector2, art: Rect2, kind: String) -> void:
	var node: Control = t["node"]
	for c in node.get_children():
		var n := c as Control
		if n == null or not n.visible or n == t["parts"]["sel"] or n is BaseButton:
			continue
		var r := Rect2(n.position, n.size)
		if n is TextureRect:
			var tr := n as TextureRect
			if tr.texture != null and tr.stretch_mode != TextureRect.STRETCH_SCALE:
				# Drawn at the texture's own size, centred in its rect.
				var ts := tr.texture.get_size()
				r = Rect2(r.position + (r.size - ts) / 2.0, ts)
		if r.position.x < -0.5 or r.position.y < -0.5 or r.end.x > tile.x + 0.5 or r.end.y > tile.y + 0.5:
			_fail("%s: %s runs out of its tile (%s)" % [what, n.name, r])
		if n is Label:
			_fits(n as Label, "%s: %s" % [what, n.name])
		elif n is TextureRect and n != t["parts"]["plate"] and not (n in [t["parts"]["seal"], t["parts"]["lock"],
				t["parts"]["diamond"]]) and not art.grow(0.5).encloses(r):
			_fail("%s: its picture %s leaves the art box %s" % [what, r, art])
	# A title's words are centred between the scroll's rollers.
	if kind == "title":
		var scroll: TextureRect = null
		var words: Label = null
		for c in node.get_children():
			if c is TextureRect and (c as TextureRect).texture == root.get_node("Art").call("tex", "wardrobe/title_scroll"):
				scroll = c
			elif c is Label and c != t["parts"]["name"] and c != t["parts"]["hint"]:
				words = c
		if scroll == null or words == null:
			_fail("%s: a title with no scroll or no words" % what)
		elif absf(words.position.x + words.size.x / 2.0 - (scroll.position.x + scroll.size.x / 2.0)) > 1.0:
			_fail("%s: the title's words are %.0f off the scroll's middle" % [what,
				words.position.x + words.size.x / 2.0 - (scroll.position.x + scroll.size.x / 2.0)])


func _marks(t: Dictionary, what: String, it: Dictionary, have: int) -> void:
	var p: Dictionary = t["parts"]
	var owned := bool(it.get("owned", false))
	var price := int(it.get("shop_diamonds", 0))
	var locked := not owned and price <= 0
	if (p["seal"] as CanvasItem).visible != bool(it.get("worn", false)):
		_fail("%s: the wax tick is %s" % [what, "on" if (p["seal"] as CanvasItem).visible else "off"])
	if (p["lock"] as CanvasItem).visible != locked:
		_fail("%s: the padlock is %s" % [what, "on" if (p["lock"] as CanvasItem).visible else "off"])
	if (p["diamond"] as CanvasItem).visible != (not owned and price > 0):
		_fail("%s: the diamond is %s" % [what, "on" if (p["diamond"] as CanvasItem).visible else "off"])
	var name: Label = p["name"]
	var hint: Label = p["hint"]
	if locked and (not hint.visible or hint.text != str(it.get("source", ""))):
		_fail("%s: a locked tile says \"%s\", not where it comes from" % [what, hint.text])
	if not owned and price > 0:
		if name.text != _U.grouped(price):
			_fail("%s: a sold tile says \"%s\", not its price" % [what, name.text])
		var red: bool = name.label_settings.font_color.is_equal_approx(_U.get_script_constant_map()["RED"])
		if red != (price > have):
			_fail("%s: %s costs %d with %d held and is %s" % [what, it["id"], price, have, "red" if red else "not red"])
	if owned and int(it.get("expires_in", 0)) > 0 and (not hint.visible or not hint.text.ends_with("left")):
		_fail("%s: a frame held for a time says \"%s\"" % [what, hint.text])
	if owned and int(it.get("expires_in", 0)) == 0 and name.text != str(it.get("name", "")):
		_fail("%s: an owned tile says \"%s\"" % [what, name.text])


## The strip: the lord as they are dressed.
func _look(p: Control, what: String, wardrobe: Dictionary) -> void:
	var worn: Dictionary = wardrobe["worn"]
	var name := p.call("node", "look_name") as Label
	var colour := str(worn.get("color", ""))
	var ink: Color = _U.get_script_constant_map()["INK"]
	if colour != "":
		ink = Color(colour)
	if name.text != LORD or not name.label_settings.font_color.is_equal_approx(ink):
		_fail("%s: the strip's name is \"%s\" in %s" % [what, name.text, name.label_settings.font_color])
	_fits(name, what + ": the strip's name")
	var title := p.call("node", "look_title") as Label
	var want := str(worn.get("title", ""))
	if title.text != (want if want != "" else "no title"):
		_fail("%s: the scroll says \"%s\"" % [what, title.text])
	_fits(title, what + ": the scroll")
	var face := p.call("node", "look_enamel") as CanvasItem
	if not face.modulate.is_equal_approx(Color(colour) if colour != "" else Color.WHITE):
		_fail("%s: the strip's chip is %s" % [what, face.modulate])


## The strip's name sits in its own box: where the layout put it, no wider.
func _look_box(p: Control, what: String, who: String) -> void:
	var l := p.call("node", "look_name") as Label
	var box: Rect2 = _L.rect_of(_L.element("wardrobe", "look_name"))
	if l == null or l.text != who:
		_fail("%s: the strip says \"%s\"" % [what, l.text if l != null else ""])
		return
	if absf(l.position.x - box.position.x) > 0.5 or l.size.x > box.size.x + 0.5:
		_fail("%s: the name's label is %.0f wide at x %.0f, its box %.0f at x %.0f" % [what, l.size.x,
			l.position.x, box.size.x, box.position.x])
	var s := l.label_settings
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	if w > box.size.x + 0.5:
		_fail("%s: the name is %.0f wide in its %.0f box" % [what, w, box.size.x])


func _on_screen(c: Control, what: String, canvas: Vector2, inset: float) -> void:
	if c == null:
		_fail(what + " is missing")
		return
	var r := c.get_global_rect()
	if r.position.y < inset - 0.5 or r.end.y > canvas.y + 0.5 or r.position.x < -0.5 or r.end.x > canvas.x + 0.5:
		_fail("%s is at %s, off the screen or under the notch" % [what, r])


## A label's words fit its box at the size they were set at.
func _fits(l: Label, what: String) -> void:
	var box := float(l.get_meta("box_w", l.size.x))
	var s := l.label_settings
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	if w > box + 0.5 or l.size.x > box + 0.5:
		_fail("%s \"%s\" is %.0f wide in a %.0f box (the label %.0f)" % [what, l.text, w, box, l.size.x])


## EQUIP's rule, without a page.
func _actions() -> void:
	var cases := [
		[{}, ["", "EQUIP"]],
		[{"id": "a", "owned": true, "worn": true}, ["take_off", "TAKE OFF"]],
		[{"id": "a", "owned": true, "worn": false}, ["wear", "EQUIP"]],
		[{"id": "a", "owned": false, "shop_diamonds": 1250}, ["buy", "BUY 1,250"]],
		[{"id": "a", "owned": false, "source": "Royal Favour X"}, ["", "LOCKED"]],
	]
	for c in cases:
		var got: Array = _W.call("equip_action", c[0])
		if got != c[1]:
			_fail("EQUIP for %s is %s, not %s" % [c[0], got, c[1]])
