extends Node
## SPLENDOUR — the wardrobe: portrait frames, titles, name colours and crests,
## cut from art/reference/wardrobe.png (art/slices/wardrobe.json, layout
## client/layout/wardrobe.json).
##
## A whole painted page like THE CROWN'S FAVOUR, on the painted pages' host
## (PaintedPage): a taller phone gives its extra height to the grid. This node
## lives on the page and keeps what it shows. The catalogue is the server's
## (GET /v1/cosmetics): every item comes with its art key and its colour already
## resolved, and the client keeps no list of its own.
##
## The tabs are the game's one tab strip (TabStrip, tabs_sheet_b's plates). A
## tab's items fill the painting's tiles, three to a row, scrolling past what
## the grid holds: a frame shows its own ring (frames/<art>_tile), a crest its
## shield, a title its words on the parchment scroll, a colour the enamel chip
## tinted with it. A tile marks what is worn (the wax tick), what is locked (the
## padlock, and where it comes from), what the Splendour shop sells (its price
## in diamonds) and what is held for a time (how long is left).
##
## A tap selects a tile; EQUIP then says what it will do and does it: wear
## what is owned, take off what is worn, buy what is sold (sequenced, as every
## diamond spend is), or nothing for what is locked. The strip under the grid
## shows the lord as the realm sees them.

## The page's layout, and this script (a static `open` cannot name its own).
const PAGE := "wardrobe"
const SELF := "res://scenes/court/wardrobe_view.gd"
## Tabs, as TabStrip names its plates, and the catalogue kind each shows.
const TABS := ["frames", "titles", "colours", "crests"]
const KIND := {"frames": "frame", "titles": "title", "colours": "name_color", "crests": "crest"}
## A title written on the scroll, in the brown ink of the paintings' parchment.
const SCROLL_INK := Color("#4A3016")
## The words on a tile that is not the lord's to wear.
const LOCKED_INK := Color("#9A9284")
## A price the lord can pay, in the Royal Store's ink (red when they cannot).
const PRICE_INK := Color("#F6F3EE")
const UNOWNED_ART := Color(0.55, 0.55, 0.6)
## A frame's name for the ring drawn in a tile, and the square round a face.
const TILE_SUFFIX := "_tile"
const SQUARE_SUFFIX := "_square"
## How far in from a tile's sides a colour's name sample may run: inside the rim.
const SAMPLE_INSET := 16.0
## A name colour's enamel chip (the Royal Store's cut of this painting's chip):
## the gold-rimmed chip, and its face, tinted, where it sits on the rim.
const CHIP := "icons/colour_chip"
const CHIP_FACE := "icons/colour_chip_face"
const CHIP_FACE_AT := Vector2(11, 11)
## The diamond after a price on EQUIP: its width against the word's size, and
## the space before it.
const DIAMOND_OF_WORD := 0.8
const EQUIP_GAP := 10

var _p: PaintedPage
var _tabs: TabStrip
var _grid: ScrollContainer
var _content: Control
var _look_face: TextureRect
var _look_frame: TextureRect
var _tiles: Array = []              ## [{node, parts, item}]
var _wardrobe: Dictionary = {}
var _tab := "frames"
var _selected := ""                 ## the selected item's id
var _busy := false


## Opens the page over the game and reads the wardrobe. `opts` goes to
## PaintedPage.open (a test's inset); "offline" skips the read (a test paints).
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	var v: Node = (load(SELF) as GDScript).new()
	v.name = "WardrobeView"
	p.add_child(v)
	v.call("_setup", p)
	if not bool(opts.get("offline", false)):
		v.call("refresh")
	return p


## The page's view, for a test or a capture that paints it.
static func of(p: PaintedPage) -> Node:
	return p.get_node_or_null("WardrobeView")


func _setup(p: PaintedPage) -> void:
	_p = p
	var tr := Layout.rect_of(Layout.element(PAGE, "tabs"))
	_tabs = TabStrip.make(TABS, tr, _tab)
	_tabs.changed.connect(_on_tab)
	_p.place(_tabs, tr)

	# The grid runs down the page's stretch band: a taller phone shows more tiles.
	_grid = ScrollContainer.new()
	_grid.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_grid.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_grid.scroll_deadzone = 14
	_p.place(_grid, Layout.rect_of(Layout.element(PAGE, "grid")))
	_content = Control.new()
	_content.custom_minimum_size = _grid.size
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_grid.add_child(_content)

	# The strip's face and the frame round it: textures change, the nodes stay.
	_look_face = UI.image(Art.avatar(""), Rect2())
	_look_face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_look_face.clip_contents = true
	_p.place(_look_face, Layout.rect_of(Layout.element(PAGE, "look_face")))
	_look_frame = UI.image("inventory/frame_common", Rect2())
	_look_frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_p.place(_look_frame, Layout.rect_of(Layout.element(PAGE, "look_frame")))

	_p.on("equip", _equip)


func refresh() -> void:
	await _load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/cosmetics")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The wardrobe could not be opened. " + res.error)
		return
	paint(res.data)


## Paints a /v1/cosmetics answer (a WardrobeView). Public for tests and captures.
func paint(wardrobe: Dictionary) -> void:
	_wardrobe = wardrobe
	var shown := items_of(wardrobe, _tab)
	if _selected == "" or not _has(shown, _selected):
		_selected = default_pick(shown)
	_paint_grid(shown)
	_paint_look()
	_paint_equip()


func _on_tab(id: String) -> void:
	_tab = id
	_selected = ""
	_grid.scroll_vertical = 0
	paint(_wardrobe)


## A tab's items, in the catalogue's order (the server lists what is owned first).
static func items_of(wardrobe: Dictionary, tab: String) -> Array:
	var kind := str(KIND.get(tab, ""))
	var out: Array = []
	for it in wardrobe.get("items", []):
		if str(it.get("kind", "")) == kind:
			out.append(it)
	return out


## What a tab opens on: the item worn, else the first owned, else the first.
static func default_pick(items: Array) -> String:
	for it in items:
		if bool(it.get("worn", false)):
			return str(it.get("id", ""))
	for it in items:
		if bool(it.get("owned", false)):
			return str(it.get("id", ""))
	return str(items[0].get("id", "")) if not items.is_empty() else ""


static func _has(items: Array, id: String) -> bool:
	for it in items:
		if str(it.get("id", "")) == id:
			return true
	return false


# --- the grid ----------------------------------------------------------------------

func _paint_grid(items: Array) -> void:
	for t in _tiles:
		t["node"].queue_free()
	_tiles.clear()
	var grid := Layout.element(PAGE, "grid")
	var g := Layout.rect_of(grid)
	var origin: Array = grid.get("origin", [50, 461])
	var pitch: Array = grid.get("pitch", [284, 270])
	var cols := int(grid.get("columns", 3))
	var tpl := Layout.element(PAGE, "tile")
	var rows := int(ceil(float(items.size()) / float(cols)))
	var have := _diamonds()
	for i in items.size():
		var it: Dictionary = items[i]
		var built := Layout.instantiate(tpl)
		built["node"].position = Vector2(float(origin[0]) - g.position.x + float(pitch[0]) * (i % cols),
			float(origin[1]) - g.position.y + float(pitch[1]) * (i / cols))
		built["item"] = it
		_content.add_child(built["node"])
		dress_tile(built, it, str(GameState.player().get("username", "")), have)
		var hit := UI.hotspot(Rect2(Vector2.ZERO, Layout.rect_of(tpl).size), true)
		hit.pressed.connect(_select.bind(str(it.get("id", ""))))
		built["node"].add_child(hit)
		(built["parts"]["sel"] as CanvasItem).visible = str(it.get("id", "")) == _selected
		_tiles.append(built)
	var used := float(origin[1]) - g.position.y + float(pitch[1]) * float(rows) + 8.0
	_content.custom_minimum_size = Vector2(_grid.size.x, maxf(_grid.size.y, used))


## Fills one tile with one item. Static and public, so a test can dress a tile
## and look at what it shows. `lord` is the name a colour is written in, `have`
## the diamonds the lord holds (below zero: not known, no price is red).
static func dress_tile(built: Dictionary, it: Dictionary, lord: String, have: int = -1) -> void:
	var p: Dictionary = built["parts"]
	var node: Control = built["node"]
	var art := Layout.rect_of(Layout.find(PAGE, "art"))
	var owned := bool(it.get("owned", false))
	var worn := bool(it.get("worn", false))
	var price := int(it.get("shop_diamonds", 0))
	var locked := not owned and price <= 0
	var kind := str(it.get("kind", ""))
	var shown: Array = []
	match kind:
		"frame":
			shown.append(fit_art(str(it.get("art", "")) + TILE_SUFFIX, art))
		"crest":
			# The shields are cut 182x240, taller than the box: drawn down to it.
			shown.append(fit_art(str(it.get("art", "")), art))
		"title":
			# The scroll is painted 286 wide and the box is 224.
			var scroll := fit_art("wardrobe/title_scroll", art)
			var at := scroll.position
			var sz := scroll.size
			shown.append(scroll)
			# Between the rollers. Placed empty and written after: a Label sized
			# out of the tree keeps the width of the text it had then, and a long
			# one pushed its words off centre, onto the roller.
			var words := UI.label("", 26, SCROLL_INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
			words.label_settings.shadow_color = Color(0, 0, 0, 0)
			UI.place(words, Rect2(at.x + sz.x * 0.16, at.y + sz.y * 0.24, sz.x * 0.68, sz.y * 0.52))
			words.text = str(it.get("text", ""))
			UI.fit_line(words, 26, 16)
			shown.append(words)
		"name_color":
			# The enamel chip as the Royal Store draws one: its face in the colour.
			var col := Color(str(it.get("color", "#FFFFFF")))
			var chip_size := Art.tex(CHIP).get_size()
			var chip_at := Rect2((art.position + Vector2((art.size.x - chip_size.x) / 2.0, 6)).round(), chip_size)
			shown.append(UI.image(CHIP, chip_at))
			var face := UI.image(CHIP_FACE, Rect2(chip_at.position + CHIP_FACE_AT, Art.tex(CHIP_FACE).get_size()))
			face.modulate = col
			shown.append(face)
			# The lord's own name in it, under the chip: what the colour is for.
			# The whole width inside the tile's rim, so the longest name (sixteen
			# letters) is still whole at the smallest size.
			var sample := UI.label("", 24, col, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
			UI.place(sample, Rect2(SAMPLE_INSET, chip_at.end.y + 10, node.size.x - 2.0 * SAMPLE_INSET, 40))
			sample.text = lord
			UI.fit_line(sample, 24, 14)
			shown.append(sample)
	# Over the tile, under its plate words, tick and lock -- in the order drawn:
	# the chip under its enamel, the scroll under its words.
	var plate: Control = p["plate"]
	for i in shown.size():
		var n: Node = shown[i]
		node.add_child(n)
		node.move_child(n, plate.get_index() + 1 + i)
		if locked and n is TextureRect:
			(n as CanvasItem).modulate = (n as CanvasItem).modulate * UNOWNED_ART
	(p["seal"] as CanvasItem).visible = worn
	(p["lock"] as CanvasItem).visible = locked
	(p["diamond"] as CanvasItem).visible = not owned and price > 0
	var name: Label = p["name"]
	var hint: Label = p["hint"]
	var words := tile_words(it)
	name.text = words[0]
	name.label_settings.font_color = UI.GOLD if worn else (LOCKED_INK if locked else UI.INK)
	hint.text = words[1]
	hint.visible = words[1] != ""
	var box := Layout.rect_of(Layout.find(PAGE, "name"))
	if hint.visible:
		# Two lines on the plate: the name a little higher, the hint under it.
		UI.place(name, Rect2(box.position.x, box.position.y - 2, box.size.x, 22))
		UI.fit_line(name, 17, 13)
		UI.fit_line(hint, 14, 11)
	elif not owned and price > 0:
		# Beside the plate's diamond, written as the Royal Store writes a
		# diamond price: in its numerals, red when the lord has too few.
		var d := Layout.rect_of(Layout.find(PAGE, "diamond"))
		UI.place(name, Rect2(d.end.x + 6, box.position.y, box.end.x - d.end.x - 6, box.size.y))
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name.label_settings.font = UI.font("body", 800)
		name.label_settings.font_color = UI.RED if have >= 0 and price > have else PRICE_INK
		UI.fit_line(name, 22, 14)
	else:
		UI.place(name, box)
		UI.fit_line(name, 19, 13)


## `asset` in `box`: drawn down to fit, never up, centred on whole units.
static func fit_art(asset: String, box: Rect2) -> TextureRect:
	var t := UI.image(asset, box)
	if t.texture != null:
		var tex_size := t.texture.get_size()
		var s := minf(1.0, minf(box.size.x / tex_size.x, box.size.y / tex_size.y))
		var sz := (tex_size * s).round()
		UI.place(t, Rect2((box.position + (box.size - sz) / 2.0).round(), sz))
	return t


## What a tile's plate says: [line, second line or ""]. An item held for a time
## says how long is left; one on sale, its price; one locked, where it comes from.
static func tile_words(it: Dictionary) -> Array:
	var name := str(it.get("name", ""))
	var owned := bool(it.get("owned", false))
	var price := int(it.get("shop_diamonds", 0))
	if owned:
		var left := int(it.get("expires_in", 0))
		return [name, "%s left" % UI.time_left(left)] if left > 0 else [name, ""]
	if price > 0:
		return [UI.grouped(price), ""]
	var source := str(it.get("source", ""))
	return [name, source if source != "" else "Not yet yours"]


func _select(id: String) -> void:
	if id == _selected:
		return
	_selected = id
	for t in _tiles:
		(t["parts"]["sel"] as CanvasItem).visible = str(t["item"].get("id", "")) == id
	_paint_equip()


## The lord's diamonds, as the wardrobe's last answer counted them.
func _diamonds() -> int:
	return int(_wardrobe.get("diamonds", GameState.player().get("diamonds", 0)))


func _item(id: String) -> Dictionary:
	for it in _wardrobe.get("items", []):
		if str(it.get("id", "")) == id:
			return it
	return {}


# --- EQUIP -------------------------------------------------------------------------

## What EQUIP does for an item: "wear", "take_off", "buy" or "" (locked, or
## nothing selected), and the word it says.
static func equip_action(it: Dictionary) -> Array:
	if it.is_empty():
		return ["", "EQUIP"]
	if bool(it.get("worn", false)):
		return ["take_off", "TAKE OFF"]
	if bool(it.get("owned", false)):
		return ["wear", "EQUIP"]
	var price := int(it.get("shop_diamonds", 0))
	if price > 0:
		return ["buy", "BUY %s" % UI.grouped(price)]
	return ["", "LOCKED"]


func _paint_equip() -> void:
	var b := _p.node("equip") as Button
	var act := equip_action(_item(_selected))
	b.text = act[1]
	b.disabled = act[0] == "" or _busy
	# A price wears the diamond after it, as CLAIM does on the Favour page.
	var buy: bool = act[0] == "buy"
	b.icon = Art.tex("icons/diamond") if buy else null
	b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.add_theme_constant_override("h_separation", EQUIP_GAP)
	# EQUIP is painted at 54; a longer word comes down, never past the plate.
	var box := b.size.x - 2.0 * 24.0
	var f: Font = b.get_theme_font("font")
	var size_pt := 54
	while size_pt > 30 and equip_width(f, b.text, size_pt, buy) > box:
		size_pt -= 2
	b.add_theme_font_size_override("font_size", size_pt)
	b.add_theme_constant_override("icon_max_width", int(roundf(size_pt * DIAMOND_OF_WORD)))


## How wide EQUIP's word is at `size_pt`, with the diamond after a price.
static func equip_width(f: Font, text: String, size_pt: int, diamond: bool) -> float:
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_pt).x
	return w + (roundf(size_pt * DIAMOND_OF_WORD) + EQUIP_GAP if diamond else 0.0)


func _equip() -> void:
	if _busy:
		return
	var it := _item(_selected)
	var act := equip_action(it)
	match act[0]:
		"wear":
			await _wear(str(it.get("kind", "")), str(it.get("id", "")))
		"take_off":
			await _wear(str(it.get("kind", "")), "")
		"buy":
			await _buy(it)


func _wear(kind: String, id: String) -> void:
	_busy = true
	_paint_equip()
	# Not sequenced: what a lord wears touches nothing a queued collect reads.
	var res: Api.Response = await Api.post_json("/v1/cosmetics/wear", {"kind": kind, "id": id})
	if res.ok:
		GameState.toast("Worn" if id != "" else "Taken off")
		paint(res.data)
	else:
		GameState.action_failed.emit(res.error)
	_busy = false
	if is_inside_tree():
		_paint_equip()


func _buy(it: Dictionary) -> void:
	var price := int(it.get("shop_diamonds", 0))
	var have := _diamonds()
	if have < price:
		await Dialog.ask(self, {"title": "Not enough diamonds",
			"body": "%s costs %s diamonds and you have %s. Diamonds come from the Royal Store, levels and the daily calendar." % [
				str(it.get("name", "")), UI.grouped(price), UI.grouped(have)], "confirm_text": "OK"})
		return
	if not await Dialog.ask(self, {"title": "Buy %s?" % str(it.get("name", "")),
			"body": "For %s diamonds. You wear it at once, and it is yours for good." % UI.grouped(price),
			"confirm_text": "Buy"}):
		return
	_busy = true
	_paint_equip()
	var res: Api.Response = await GameState.act("/v1/cosmetics/buy", {"id": str(it.get("id", ""))})
	if res.ok:
		GameState.toast("%s is yours" % str(it.get("name", "")))
		paint(res.data)
	_busy = false
	if is_inside_tree():
		_paint_equip()


# --- the strip: the lord as the realm sees them ---------------------------------------

func _paint_look() -> void:
	var worn: Dictionary = _wardrobe.get("worn", {})
	var p := GameState.player()
	_look_face.texture = Art.tex(Art.avatar(str(p.get("avatar", ""))))
	var frame_art := str(worn.get("frame", ""))
	_look_frame.texture = Art.tex(frame_art + SQUARE_SUFFIX if frame_art != "" else "inventory/frame_common")

	var name := _p.node("look_name") as Label
	name.text = str(p.get("username", ""))
	var colour := str(worn.get("color", ""))
	name.label_settings.font_color = Color(colour) if colour != "" else UI.INK
	UI.fit_line(name, 30, 18)
	var title := _p.node("look_title") as Label
	var t := str(worn.get("title", ""))
	title.text = t if t != "" else "no title"
	title.label_settings.font_color = SCROLL_INK if t != "" else Color(SCROLL_INK, 0.55)
	title.label_settings.shadow_color = Color(0, 0, 0, 0)
	UI.fit_line(title, 24, 14)
	_p.node("look_enamel").modulate = Color(colour) if colour != "" else Color.WHITE
	var crest := str(worn.get("crest", ""))
	var shield := _p.node("look_crest") as TextureRect
	Look.paint_crest(shield, crest if crest != "" else "icons/crest_lion")
	shield.modulate = Color.WHITE if crest != "" else Color(1, 1, 1, 0.35)
