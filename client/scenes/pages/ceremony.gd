class_name Ceremony
extends CanvasLayer
## The moments the game stops for: a level reached, a job mastered, a purchase
## delivered, a Tax Cart opened, a part of the realm opened. Each is one painted
## emblem over its light, what it brought, and a way on -- all of it cut from
## art/reference/ceremony_sheet.png (art/slices/ceremony_sheet.json), the cart's
## emblem from chests.png.
##
## A level-up was a toast -- "Level 31!" -- at the foot of the screen for two
## seconds, with the diamonds, the stat points and a newly opened tab left for
## the player to discover. A mastery milestone, a permanent raise on a job, had
## no moment at all. Then both were a title in type over the battle's burst.
## Now each wears its own painted emblem, and the four play one after another:
## a second one waiting (a raid that levels twice, a collect that levels and
## masters, a purchase landing mid-ceremony) plays after the first is closed
## rather than on top of it.
##
## Everything it says is the server's: the level and the job from the new
## snapshot, the points and diamonds as the snapshot moved, the tabs by the
## server's own `unlocked` flags, a delivery's lines as the server wrote them.

signal finished

const W := 941.0
const TAB_NAMES := {"jobs": "COLLECT", "hero": "FAMILY", "shop": "SHOP", "items": "INVENTORY",
	"estates": "THE ESTATES", "army": "ARMY", "bank": "THE TREASURY", "fight": "ATTACK", "house": "KINGDOM"}
## What a newly opened section shows in its frame: the mark it wears on the
## rail. The estates and the treasury live on the Family tab, so the estates
## wear the Family's mark and the treasury the shield its card carries.
const TAB_MARKS := {"jobs": "nav/collect", "hero": "nav/family", "shop": "nav/shop", "items": "nav/inventory",
	"estates": "nav/family", "army": "nav/army", "bank": "icons/city_shield", "fight": "nav/attack",
	"house": "nav/kingdom"}
const ON_FAMILY := ["estates", "bank"]

## The pieces. The sheet is on the design grid (941x1672), so every one is
## drawn at the size it was painted -- none is scaled up. The frame and the
## plate are nine-patches: their corners and chamfered ends stay painted-size
## and only their straight middles take the length.
const CREST := "ceremony/level_crest"
const SUNBURST := "ceremony/sunburst"
const MASTERY := "ceremony/mastery_banner"
const CHEST := "ceremony/delivery_chest"
const KEY := "ceremony/new_lands"
const COINS := "ceremony/coin_burst"
const FRAME := "ceremony/frame"
const PLATE := "ceremony/plate"
const CONTINUE := "ceremony/continue"
## A Tax Cart opened: chests.png's third card, the chest opened on the cart,
## with its empty plate (art/slices/chests.json), and the prize's name set in
## the plate -- its inside x 677..912, y 1469..1509 on the painting, 12 in from
## each side, in the ribbons' cream Cinzel.
const CART_CARD := "chests/card_opened"
const CART_NAME := Rect2(26, 294, 211, 33)
const CART_NAME_SIZE := 24
## The coins' light behind the card, a little above its middle, so it shows
## round the frame on both sides.
const CART_FOCUS := Vector2(131, 150)
## A week's chest opened (Collect's chest bar): the chest of its tier thrown
## open (rewards_sheet.png, art/slices/rewards_sheet.json), the sunburst turning
## behind its mouth, its name on the plate, and what it held.
const WEEK_CHESTS := ["icons/chest_wood_open", "icons/chest_silver_open", "icons/chest_gold_open"]
const WEEK_CHEST_FOCUS := [Vector2(110, 100), Vector2(110, 96), Vector2(110, 118)]

## Measured on the sheet, in each crop's own coordinates.
## The crest's crimson disc runs x 147..357, y 141..318 on the sheet (the
## ribbon covers its foot): the level is written in the box inside it, and the
## sunburst sits on its centre.
const CREST_NUMBER := Rect2(122, 112, 186, 156)
const CREST_FOCUS := Vector2(215, 188)
## Where each other emblem's light sits: between the star and the MASTERY
## ribbon, on the chest's glowing mouth, on the key.
const MASTERY_FOCUS := Vector2(221, 110)
const CHEST_FOCUS := Vector2(210, 140)
const KEY_FOCUS := Vector2(254, 115)
## The frame's corners, fleurs included, reach 50 in; its navy panel starts 28
## in. Content keeps clear of both.
const FRAME_CORNER := 56
const FRAME_PAD := Vector2(60, 30)
## The plate's chamfered ends reach 30 in; it is drawn at its painted height.
const PLATE_END := 38
const PLATE_H := 88.0
const PLATE_MIN_W := 334.0
## A picture in the frame (a job's painting, a section's mark), and a list in
## it (what a level or a purchase brought).
const DISPLAY := Vector2(262, 238)
const LIST_W := 720.0
const ROW_H := 60.0
const ICON_BOX := 52.0
## What a purchase brought, as large as the offer showed it (RewardArt): up to
## three tiles to a row inside the list frame's 600-unit panel, each its
## picture in a 120-tall box over up to three lines of its words (the
## patronage's run to sixty letters). One line gets a tile 400 wide, two 294,
## three or more 192. Two rows of them at their tallest, the chest, the plate,
## the notes and CONTINUE come to about 1,385 units, inside the 1,483 the short
## canvas leaves under a Dynamic Island.
const TILE_COLS := 3
## The most tiles one delivery draws: two full rows.
const DELIVERY_TILES_MAX := 6
const TILE_W := {1: 400.0, 2: 294.0, 3: 192.0}
const TILE_ART_H := 120.0
## A tile's words: at most this tall (four lines), set at the largest size
## from 24 at which every tile's words fit it.
const TILE_WORDS_MAX_H := 116.0
const TILE_WORDS_GAP := 6.0
const TILE_GAP := 12.0
const TILE_ROW_GAP := 18.0
const CONTINUE_SIZE := Vector2(451, 170)
const GAP := 24.0
const MARGIN := 24.0
## The ribbons' own lettering: cream, with a dark edge and a drop shadow.
const CREAM := Color("#F7EDCF")
const EDGE := Color("#3A160B")
const DIAMOND_BLUE := Color("#9FD8FF")

static var _queue: Array = []
static var _showing := false

var _cfg: Dictionary = {}
var _root: Control
var _glow: TextureRect
var _spin := false
var _h := 1672.0
var _top := 0.0


## Plays a level-up: {level, levels, points, gems, unlocked: [section ids]}.
static func level_up(cfg: Dictionary) -> void:
	cfg["kind"] = "level"
	_enqueue(cfg)


## Plays a mastery milestone: {job, collects, bonus_bp, art}.
static func mastery(cfg: Dictionary) -> void:
	cfg["kind"] = "mastery"
	_enqueue(cfg)


## Plays a purchase delivered: the server's Delivery, {title, lines: [{kind,
## amount, text, icon}], first_bonus, vip_reached}. One that granted nothing
## (delivered before, or refunded before it reached us) has no moment.
static func delivery(host: Node, d: Dictionary) -> void:
	if bool(d.get("already", false)) or bool(d.get("revoked", false)) or (d.get("lines", []) as Array).is_empty():
		return
	_enqueue({"kind": "delivery", "delivery": d, "host": host})


## Plays a week's chest opened: its name, its tier (0 bronze, 1 silver, 2 gold)
## and the lines the /v1/weekly/chest answer brought. One that brought nothing
## has no moment.
static func chest(host: Node, title: String, tier: int, lines: Array) -> void:
	if lines.is_empty():
		return
	_enqueue({"kind": "chest", "title": title, "tier": clampi(tier, 0, 2), "lines": lines, "host": host})


## Plays a Tax Cart opened: the /v1/cart/open answer, {prize, name, lines}. One
## that brought nothing has no moment.
static func cart(host: Node, opened: Dictionary) -> void:
	if (opened.get("lines", []) as Array).is_empty():
		return
	_enqueue({"kind": "cart", "opened": opened, "host": host})


## Plays a section just opened: its id (balance/progression.json "sections")
## and the name to show, or "" for the game's own name for it.
static func new_lands(host: Node, section_id: String, title: String = "") -> void:
	_enqueue({"kind": "lands", "section": section_id, "title": title, "host": host})


static func _enqueue(cfg: Dictionary) -> void:
	_queue.append(cfg)
	if not _showing:
		_next()


static func _next() -> void:
	if _queue.is_empty():
		_showing = false
		return
	_showing = true
	var cfg: Dictionary = _queue.pop_front()
	var c: CanvasLayer = load("res://scenes/pages/ceremony.gd").new()
	c.set("_cfg", cfg)
	c.finished.connect(_next)
	var host: Variant = cfg.get("host")
	if host is Node and is_instance_valid(host) and (host as Node).is_inside_tree():
		(host as Node).add_child(c)
	else:
		Nav.overlay_parent().add_child(c)


func _ready() -> void:
	layer = 95
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var back := ColorRect.new()
	back.color = Color(UI.GROUND, 0.92)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(back)
	_root.modulate.a = 0.0

	var canvas := UI.canvas_size(self)
	_h = canvas.y
	# Under the notch nothing is read: the column starts below it. A test sets
	# the inset it wants to try; on a phone it is the display's own.
	_top = float(_cfg.get("inset", UI.safe_top(canvas)))

	var blocks: Array = []
	match str(_cfg.get("kind", "")):
		"level":
			_level(blocks)
		"mastery":
			_mastery(blocks)
		"delivery":
			_delivery(blocks)
		"cart":
			_cart(blocks)
		"chest":
			_week_chest(blocks)
		"lands":
			_lands(blocks)
	_lay_out(blocks)
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.22)


func _process(dt: float) -> void:
	if _glow != null and _spin:
		_glow.rotation += dt * 0.22


func _close() -> void:
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, 0.18)
	tw.tween_callback(func() -> void:
		finished.emit()
		queue_free())


# --- the four --------------------------------------------------------------------------

func _level(blocks: Array) -> void:
	var level := int(_cfg.get("level", 1))
	blocks.append(_emblem(CREST, SUNBURST, CREST_FOCUS, true, func(e: Control) -> void:
		# About two thirds of the disc across, as the ribbon's words fill theirs.
		var n := _cream(str(level), 116, 4)
		n.name = "Level"
		UI.place(n, CREST_NUMBER)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UI.fit_label(n, 116, 64)
		e.add_child(n)))
	var rows: Array = []
	var pts := int(_cfg.get("points", 0))
	if pts > 0:
		rows.append(["icons/stat_power", "+%d stat point%s to spend" % [pts, "" if pts == 1 else "s"], UI.INK])
	var gems := int(_cfg.get("gems", 0))
	if gems > 0:
		rows.append(["icons/diamond", "+%s diamond%s" % [UI.grouped(gems), "" if gems == 1 else "s"], DIAMOND_BLUE])
	rows.append(["icons/energy", "Energy refilled", UI.GREEN])
	# A rail mark carries its word under it, too small to read in a row; the
	# section's own moment (new_lands) shows the mark whole.
	for id in _cfg.get("unlocked", []):
		rows.append(["icons/crown_small", "%s is open" % str(TAB_NAMES.get(id, str(id).to_upper())), UI.GOLD])
	blocks.append(_list(rows))
	if pts > 0:
		blocks.append(_plate_button("SPEND THE POINTS", func() -> void:
			_close()
			var page: GDScript = load("res://scenes/pages/stats_page.gd")
			page.open(Nav.overlay_parent())))
	blocks.append(_continue())


func _mastery(blocks: Array) -> void:
	var job: Dictionary = _cfg.get("job", {})
	blocks.append(_emblem(MASTERY, COINS, MASTERY_FOCUS, false, Callable()))
	var art := str(_cfg.get("art", ""))
	if art != "":
		blocks.append(_display(func(box: Control) -> void:
			# Only the painting's window shows: a job's painting runs two units
			# past the window its row's frame gives it (collect.gd).
			var collect: GDScript = load("res://scenes/tabs/collect.gd")
			var window: Rect2 = collect.JOB_WINDOW
			var clip := Control.new()
			clip.clip_contents = true
			clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			UI.place(clip, Rect2((box.size - window.size) / 2.0, window.size))
			clip.add_child(UI.image(art, Rect2(-window.position, collect.JOB_PAINTING_RECT.size)))
			box.add_child(clip)))
	blocks.append(_plate(str(job.get("name", "")).to_upper()))
	var bp := int(_cfg.get("bonus_bp", 0))
	var pct := str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)
	blocks.append(_lines([["%s collects" % UI.grouped(int(_cfg.get("collects", 0))), UI.INK],
		["+%s%% gold on every one, for good" % pct, UI.GOLD]]))
	blocks.append(_continue())


func _delivery(blocks: Array) -> void:
	var d: Dictionary = _cfg.get("delivery", {})
	blocks.append(_emblem(CHEST, COINS, CHEST_FOCUS, false, Callable()))
	var title := str(d.get("title", ""))
	if title != "":
		blocks.append(_plate(title.to_upper()))
	var lines: Array = []
	for l in d.get("lines", []):
		if l is Dictionary:
			lines.append(l)
	# Two rows of tiles are what the column holds on the short phone; a delivery
	# of more (the Victory Road claimed a dozen milestones at once) shows the
	# first rows and says how many more came with them, never running off the
	# screen with CONTINUE under it.
	var shown := lines.slice(0, DELIVERY_TILES_MAX) if lines.size() > DELIVERY_TILES_MAX else lines
	blocks.append(_tiles(shown))
	var notes: Array = []
	if lines.size() > shown.size():
		var more := lines.size() - shown.size()
		notes.append(["and %d more reward%s" % [more, "" if more == 1 else "s"], UI.INK])
	if bool(d.get("first_bonus", false)):
		notes.append(["First purchase: everything doubled", UI.GOLD])
	var vip := int(d.get("vip_reached", 0))
	if vip > 0:
		notes.append(["Royal Favour %d reached" % vip, UI.GOLD])
	if not notes.is_empty():
		blocks.append(_lines(notes))
	blocks.append(_continue())


## A week's chest opened: the chest of its tier thrown open over the turning
## sunburst, its name, and what it held.
func _week_chest(blocks: Array) -> void:
	var tier := int(_cfg.get("tier", 0))
	blocks.append(_emblem(WEEK_CHESTS[tier], SUNBURST, WEEK_CHEST_FOCUS[tier], true, Callable()))
	blocks.append(_plate(str(_cfg.get("title", "")).to_upper()))
	var lines: Array = []
	for l in _cfg.get("lines", []):
		if l is Dictionary:
			lines.append(l)
	blocks.append(_tiles(lines))
	blocks.append(_continue())


## The Tax Cart's prize: the opened chest's card with the prize named in its
## plate, over the coins' light; then what it held, as large as a purchase's.
func _cart(blocks: Array) -> void:
	var o: Dictionary = _cfg.get("opened", {})
	var prize := str(o.get("name", "")).to_upper()
	blocks.append(_emblem(CART_CARD, COINS, CART_FOCUS, false, func(e: Control) -> void:
		var n := _cream(prize, CART_NAME_SIZE, 0)
		n.name = "Prize"
		UI.place(n, CART_NAME)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UI.fit_label(n, CART_NAME_SIZE, 16)
		e.add_child(n)))
	var lines: Array = []
	for l in o.get("lines", []):
		if l is Dictionary:
			lines.append(l)
	blocks.append(_tiles(lines))
	blocks.append(_continue())


func _lands(blocks: Array) -> void:
	var id := str(_cfg.get("section", ""))
	var title := str(_cfg.get("title", ""))
	if title == "":
		title = str(TAB_NAMES.get(id, id.to_upper()))
	blocks.append(_emblem(KEY, SUNBURST, KEY_FOCUS, true, Callable()))
	blocks.append(_display(func(box: Control) -> void:
		var mark := Art.tex(str(TAB_MARKS.get(id, "icons/reward_crown")))
		box.add_child(_fitted(mark, Rect2(FRAME_PAD, box.size - 2.0 * FRAME_PAD)))))
	blocks.append(_plate(title.to_upper()))
	blocks.append(_lines([["Waiting for you %s." % ("on the Family tab" if id in ON_FAMILY else "on the rail"),
		UI.INK]]))
	blocks.append(_continue())


# --- the parts ---------------------------------------------------------------------------
# Each is a block of the column: {h, put(y)}. _lay_out stacks them.

## An emblem over its light. The light is centred on `focus` and may reach
## above the emblem; the block is tall enough to keep it on the screen.
func _emblem(asset: String, glow: String, focus: Vector2, spin: bool, dress: Callable) -> Dictionary:
	var tex := Art.tex(asset)
	var gtex := Art.tex(glow)
	var size := tex.get_size()
	var gsize := gtex.get_size()
	var above := maxf(0.0, gsize.y / 2.0 - focus.y)
	return {"h": above + size.y, "put": func(y: float) -> void:
		var x := (W - size.x) / 2.0
		_glow = UI.image(glow, Rect2(Vector2(x, y + above) + focus - gsize / 2.0, gsize))
		_glow.pivot_offset = gsize / 2.0
		_glow.name = "Glow"
		_root.add_child(_glow)
		_spin = spin
		if not spin:
			# Coins do not turn; they breathe.
			var tw := create_tween().set_loops()
			tw.tween_property(_glow, "modulate:a", 0.78, 1.1).set_trans(Tween.TRANS_SINE)
			tw.tween_property(_glow, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
		var e := Control.new()
		e.name = "Emblem"
		e.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(e, Rect2(x, y + above, size.x, size.y))
		e.add_child(UI.image(asset, Rect2(Vector2.ZERO, size)))
		if dress.is_valid():
			dress.call(e)
		_root.add_child(e)
		e.pivot_offset = size / 2.0
		e.scale = Vector2(0.6, 0.6)
		create_tween().tween_property(e, "scale", Vector2.ONE, 0.42) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)}


## The frame holding one picture, which `fill` adds to the box it is given.
func _display(fill: Callable) -> Dictionary:
	return {"h": DISPLAY.y, "put": func(y: float) -> void:
		var f := _frame(Rect2((W - DISPLAY.x) / 2.0, y, DISPLAY.x, DISPLAY.y))
		f.name = "Display"
		fill.call(f)}


## The frame holding a list: one row per [icon, text, colour]. An icon is an
## asset name or a texture; it is drawn at its own size, or smaller to fit.
func _list(rows: Array) -> Dictionary:
	var h := rows.size() * ROW_H + 2.0 * FRAME_PAD.y
	return {"h": h, "rows": rows.size(), "put": func(y: float, row_h: float) -> void:
		var hh := rows.size() * row_h + 2.0 * FRAME_PAD.y
		var f := _frame(Rect2((W - LIST_W) / 2.0, y, LIST_W, hh))
		f.name = "List"
		for i in rows.size():
			var r: Array = rows[i]
			var ry := FRAME_PAD.y + i * row_h
			var icon: Texture2D = r[0] if r[0] is Texture2D else Art.tex(str(r[0]))
			f.add_child(_fitted(icon, Rect2(FRAME_PAD.x - 18.0, ry + (row_h - ICON_BOX) / 2.0, ICON_BOX, ICON_BOX)))
			var t := UI.label(str(r[1]), 30, r[2], "body", 700)
			t.name = "Row%d" % i
			var tx := FRAME_PAD.x - 18.0 + ICON_BOX + 18.0
			UI.place(t, Rect2(tx, ry, LIST_W - tx - FRAME_PAD.x + 18.0, row_h))
			UI.fit_label(t, 30, 18)
			f.add_child(t)}


## The frame holding what a purchase brought, each line drawn as large as the
## offer showed it (RewardArt, shared with the offer popup's tiles): its
## picture over its words, three to a row, a short last row centred. The frame
## is a nine-patch, so it grows to hold them, and is as wide as its widest row
## needs. Every tile's words are set at one size -- the smallest any of them
## needs -- so the tiles read as equals.
func _tiles(lines: Array) -> Dictionary:
	var n := lines.size()
	var rows := maxi(1, int(ceil(n / float(TILE_COLS))))
	var tile_w: float = TILE_W[clampi(n, 1, TILE_COLS)]
	# One size for every tile's words, the largest at which all of them fit.
	var font := UI.settings(24, UI.INK, "body", 700).font
	var size := 24
	var words_h := 0.0
	while true:
		words_h = 0.0
		for l in lines:
			words_h = maxf(words_h, font.get_multiline_string_size(str(l.get("text", "")),
				HORIZONTAL_ALIGNMENT_CENTER, tile_w, size).y)
		if words_h <= TILE_WORDS_MAX_H or size <= 16:
			break
		size -= 1
	words_h = ceilf(words_h)
	var tile_h := TILE_ART_H + TILE_WORDS_GAP + words_h
	var h := rows * tile_h + (rows - 1) * TILE_ROW_GAP + 2.0 * FRAME_PAD.y
	var cols := mini(TILE_COLS, maxi(1, n))
	var fw := minf(LIST_W, cols * tile_w + (cols - 1) * TILE_GAP + 2.0 * FRAME_PAD.x)
	return {"h": h, "put": func(y: float) -> void:
		var f := _frame(Rect2((W - fw) / 2.0, y, fw, h))
		f.name = "Tiles"
		var avatar := str(GameState.player().get("avatar", ""))
		for i in n:
			var row := i / TILE_COLS
			var in_row := mini(TILE_COLS, n - row * TILE_COLS)
			var row_w := in_row * tile_w + (in_row - 1) * TILE_GAP
			var x := (fw - row_w) / 2.0 + (i % TILE_COLS) * (tile_w + TILE_GAP)
			var ty := FRAME_PAD.y + row * (tile_h + TILE_ROW_GAP)
			var slot := UI.image("", Rect2(x, ty, tile_w, TILE_ART_H))
			slot.name = "Art%d" % i
			f.add_child(slot)
			RewardArt.dress(slot, lines[i], avatar)
			var t := UI.label(str(lines[i].get("text", "")), size, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
			t.name = "Row%d" % i
			t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			t.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			UI.place(t, Rect2(x, ty + TILE_ART_H + TILE_WORDS_GAP, tile_w, words_h))
			f.add_child(t)}


## The name plate, as long as its name needs, never shorter than painted and
## never wider than the list frame: a longer name is set smaller.
func _plate(text: String) -> Dictionary:
	var size := 30
	var font := UI.settings(size, CREAM, "title", 700).font
	var w := clampf(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 2.0 * (PLATE_END + 18.0),
		PLATE_MIN_W, LIST_W)
	return {"h": PLATE_H, "put": func(y: float) -> void:
		var p := NinePatchRect.new()
		p.name = "Plate"
		p.texture = Art.tex(PLATE)
		_nine(p, PLATE_END, 20)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(p, Rect2((W - w) / 2.0, y, w, PLATE_H))
		var l := _cream(text, size, 0)
		l.name = "PlateText"
		UI.place(l, Rect2(PLATE_END, 0, w - 2.0 * PLATE_END, PLATE_H - 4.0))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UI.fit_label(l, size, 18)
		p.add_child(l)
		_root.add_child(p)}


## The plate as a button, for a second way on (the level's points): the kit's
## plate face, its ends kept whole and drawn at its painted height, so only
## its straight middle takes the length.
func _plate_button(word: String, action: Callable) -> Dictionary:
	var w := 440.0
	return {"h": PLATE_H, "put": func(y: float) -> void:
		var b := UI.plate_face(PLATE, PLATE_END)
		b.name = "PlateButton"
		UI.place(b, Rect2((W - w) / 2.0, y, w, PLATE_H))
		var l := _cream(word, 28, 0)
		UI.place(l, Rect2(PLATE_END, 0, w - 2.0 * PLATE_END, PLATE_H - 4.0))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UI.fit_label(l, 28, 18)
		b.add_child(l)
		b.pressed.connect(action)
		_root.add_child(b)}


## Lines of type under the frame.
func _lines(lines: Array) -> Dictionary:
	return {"h": lines.size() * 46.0, "put": func(y: float) -> void:
		for i in lines.size():
			var l := UI.label(str(lines[i][0]), 30, lines[i][1], "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
			l.name = "Line%d" % i
			UI.place(l, Rect2(MARGIN + 20.0, y + i * 46.0, W - 2.0 * (MARGIN + 20.0), 46))
			UI.fit_label(l, 30, 18)
			_root.add_child(l)}


## The painted CONTINUE, word and all.
func _continue() -> Dictionary:
	return {"h": CONTINUE_SIZE.y, "put": func(y: float) -> void:
		var b := UI.tex_button(CONTINUE, Rect2((W - CONTINUE_SIZE.x) / 2.0, y, CONTINUE_SIZE.x, CONTINUE_SIZE.y))
		b.name = "Continue"
		b.pressed.connect(_close)
		_root.add_child(b)}


## Stacks the blocks down the screen, under the notch, a little above centre.
## A column too tall for the screen (a purchase of many lines on the short
## canvas under a Dynamic Island) closes its gaps, then its rows, before
## anything can leave the screen.
func _lay_out(blocks: Array) -> void:
	var avail := _h - _top - 2.0 * MARGIN
	var total := 0.0
	for b in blocks:
		total += float(b["h"])
	var gap := GAP
	var row_h := ROW_H
	if total + gap * (blocks.size() - 1) > avail:
		gap = maxf(8.0, (avail - total) / maxf(1.0, blocks.size() - 1.0))
	var over := total + gap * (blocks.size() - 1) - avail
	if over > 0.0:
		var rows := 0
		for b in blocks:
			rows += int(b.get("rows", 0))
		if rows > 0:
			row_h = maxf(44.0, ROW_H - over / rows)
			total -= rows * (ROW_H - row_h)
	var used := total + gap * (blocks.size() - 1)
	var y := _top + MARGIN + maxf(0.0, (avail - used) * 0.42)
	for b in blocks:
		if b.has("rows"):
			b["put"].call(y, row_h)
			y += float(b["rows"]) * row_h + 2.0 * FRAME_PAD.y + gap
		else:
			b["put"].call(y)
			y += float(b["h"]) + gap


func _frame(rect: Rect2) -> NinePatchRect:
	var f := NinePatchRect.new()
	f.texture = Art.tex(FRAME)
	_nine(f, FRAME_CORNER, FRAME_CORNER)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(f, rect)
	_root.add_child(f)
	return f


static func _nine(p: NinePatchRect, side: int, cap: int) -> void:
	p.patch_margin_left = side
	p.patch_margin_right = side
	p.patch_margin_top = cap
	p.patch_margin_bottom = cap


## A texture in a box: its own size, or smaller to fit, never larger.
static func _fitted(tex: Texture2D, box: Rect2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s := tex.get_size() if tex != null else box.size
	var k := minf(1.0, minf(box.size.x / maxf(s.x, 1.0), box.size.y / maxf(s.y, 1.0)))
	var draw := s * k
	t.position = box.position + (box.size - draw) / 2.0
	t.size = draw
	t.stretch_mode = TextureRect.STRETCH_SCALE
	return t


## The ribbons' lettering in type: cream, a dark edge `edge` wide, a drop shadow.
static func _cream(text: String, size: int, edge: int) -> Label:
	var l := UI.label(text, size, CREAM, "title", 800)
	var s := l.label_settings
	if edge > 0:
		s.outline_size = edge
		s.outline_color = EDGE
	s.shadow_color = Color(0, 0, 0, 0.55)
	s.shadow_offset = Vector2(0, 3)
	return l
