extends RefCounted
## VICTORY ROAD — the fifteen milestones from level 3 to level 60, and what each
## gives. Painted: art/reference/road.png (the page), the road itself from the
## three node-less maps road_map_1..3.png and its markers from
## campaign_nodes_sheet.png, cut by art/slices/road.json and laid out by
## layout/road.json on the painted pages' host (PaintedPage).
##
## The road runs from the fields at the foot to the castle at the top. Each
## milestone is a shield on the painted road -- steel while ahead, gold once
## reached, gold in its halo while its reward waits -- with its level on the
## shield's plate and its reward box beside it, on the side the road bends away
## from. The marching lord stands on the highest one reached. The crowns (20,
## 40, 60) wear the crown on their shield. A tap on a waiting milestone claims
## it; a tap on any other says what it gives. CLAIM takes every one waiting.
##
## GET /v1/road; POST /v1/road/claim {} (all waiting) or {"index": i}. It is
## not the player's sequenced action: no action_seq, the answer's snapshot goes
## through GameState.adopt_async, and what it brought plays as the Royal
## Delivery. The DEEDS tab gives this page's place to the Deeds
## (scenes/pages/deeds_page.gd), in the order the Deeds' own painting has the
## two tabs, so the pair is one page under two tabs.
##
## Opened from the Family screen's ROAD card, from the Deeds' VICTORY ROAD tab,
## and by --page road.

const PAGE := "road"
const TABS := ["deeds", "victory_road"]
const CLAIM := "/v1/road/claim"
const DEEDS_PAGE := "res://scenes/pages/deeds_page.gd"
## Where a milestone's disc centre sits in its template (layout's "milestone").
const DISC := Vector2(64, 70)
## The shields' half-width at the disc, spikes and all, drawn down.
const DISC_R := 50.0
## The reward box: 12 from the shield's rim, centred on the shield and its
## plate (their middle is 10 under the disc's centre), a tile per line 64 apart
## and 12 in from its ends, each tile's picture in a 56x48 box over its amount.
const BOX_GAP := 12.0
const BOX_DROP := 10.0
const TILE_W := 64.0
const TILE_PAD := 12.0
const ICON_BOX := Rect2(4, 10, 56, 48)
## The map's own margin a box keeps from the window's rim.
const EDGE := 6.0
## The marching lord drawn down: his gold base's centre in his crop, set on the
## disc's centre a little low, where a figure standing on it would put its feet.
const LORD := "road/lord"
const LORD_SIZE := Vector2(95, 144)
const LORD_BASE := Vector2(45, 128)
const LORD_DROP := 6.0
## A milestone still ahead, and its box: the painted steel is already dim; its
## rewards are drawn back like a letter's claimed ones.
const AHEAD := Color(0.6, 0.6, 0.64)
const CLAIMED_ICONS := Color(0.78, 0.78, 0.8)
const NUMERAL_AHEAD := Color("#B8AE9C")


static func open(host: Node, opts: Dictionary = {}) -> Control:
	var p := PaintedPage.open(host, PAGE, opts)
	var r := Layout.rect_of(Layout.find(PAGE, "tabs"))
	var tabs := TabStrip.make(TABS, r, "victory_road")
	p.place(tabs, r)
	tabs.changed.connect(func(id: String) -> void:
		if id == "deeds":
			to_deeds(p))
	p.set_meta("tabs", tabs)
	p.set_meta("host", host)
	p.set_meta("opts", opts)
	p.on("claim", func() -> void: _claim(p, -1))
	p.set_enabled("claim", false)
	var content := p.content(PAGE)
	content.custom_minimum_size = Vector2(content.custom_minimum_size.x,
		float(Layout.find(PAGE, PAGE).get("height", content.custom_minimum_size.y)))
	_load(p)
	return p


## The Deeds in this page's place.
static func to_deeds(p: PaintedPage) -> PaintedPage:
	var o: Dictionary = (p.get_meta("opts", {}) as Dictionary).duplicate()
	o["instant"] = true
	var host: Node = p.get_meta("host", p)
	return p.swap(func() -> PaintedPage: return load(DEEDS_PAGE).open(host, o))


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/road")
	if not is_instance_valid(p):
		return
	if res.ok and res.data is Dictionary:
		paint(p, res.data)
	else:
		GameState.action_failed.emit("The road could not be read. " + res.error)


## Fills the page from a /v1/road answer. Separate from the load so a test can
## hand it the hard cases.
static func paint(p: PaintedPage, road: Dictionary) -> void:
	p.set_meta("road", road)
	var level := int(road.get("level", GameState.player().get("level", 1)))
	p.set_text("level", "LEVEL %d" % level)
	var content := p.content(PAGE)
	var spots: Array = Layout.find(PAGE, PAGE).get("nodes", [])
	var stones: Array = road.get("milestones", [])
	if stones.size() > spots.size():
		push_warning("[road] %d milestones and %d places measured on the road" % [stones.size(), spots.size()])
	var built: Array = p.get_meta("milestones", [])
	var highest := -1
	for i in mini(stones.size(), spots.size()):
		var m: Dictionary = stones[i]
		if i >= built.size():
			built.append(_build(p, content, i))
		var spot: Array = spots[i]
		_dress(built[i], m, Vector2(float(spot[0]), float(spot[1])), str(spot[2]))
		if bool(m.get("reached", false)):
			highest = i
	for i in range(mini(stones.size(), spots.size()), built.size()):
		(built[i]["node"] as Control).visible = false
		(built[i]["box"]["node"] as Control).visible = false
	p.set_meta("milestones", built)
	_stand_lord(p, content, spots, highest)
	var waiting := int(road.get("claimable", 0))
	p.set_enabled("claim", waiting > 0)
	# Opened at the lord's milestone (the first one for a lord with none yet),
	# once: a claim that repaints the page leaves the road where it was.
	if not p.has_meta("scrolled"):
		p.set_meta("scrolled", true)
		_scroll_to(p, spots, maxi(highest, 0))


## One milestone's nodes: its shield template and its reward box, built once and
## dressed on every paint.
static func _build(p: PaintedPage, content: Control, i: int) -> Dictionary:
	var box := Layout.instantiate(Layout.find(PAGE, "reward_box"))
	content.add_child(box["node"])
	var stone := Layout.instantiate(Layout.find(PAGE, "milestone"))
	content.add_child(stone["node"])
	(stone["parts"]["tap"] as BaseButton).pressed.connect(func() -> void: _tapped(p, i))
	# A tap anywhere on the box is a tap on its milestone.
	var hit := UI.hotspot(Rect2(Vector2.ZERO, (box["node"] as Control).size), true)
	hit.pressed.connect(func() -> void: _tapped(p, i))
	(box["node"] as Control).add_child(hit)
	box["hit"] = hit
	box["tiles"] = []
	return {"node": stone["node"], "parts": stone["parts"], "box": box, "index": i}


static func _dress(b: Dictionary, m: Dictionary, at: Vector2, side: String) -> void:
	var parts: Dictionary = b["parts"]
	var reached := bool(m.get("reached", false))
	var claimed := bool(m.get("claimed", false))
	var waiting := reached and not claimed
	var node: Control = b["node"]
	node.visible = true
	node.position = at - DISC
	(parts["shield_ahead"] as CanvasItem).visible = not reached
	(parts["shield_reached"] as CanvasItem).visible = claimed
	(parts["shield_current"] as CanvasItem).visible = waiting
	(parts["crown"] as CanvasItem).visible = bool(m.get("crown", false))
	(parts["crown"] as CanvasItem).modulate = Color.WHITE if reached else AHEAD
	var numeral: Label = parts["numeral"]
	numeral.text = "LV %d" % int(m.get("level", 0))
	numeral.label_settings.font_color = Color("#F4EFE6") if reached else NUMERAL_AHEAD
	UI.fit_line(numeral, numeral.label_settings.font_size, 14)
	_dress_box(b["box"], m.get("lines", []), at, side, reached, claimed)


## The reward box beside a milestone: a tile per line, the box as wide as its
## tiles, on the milestone's side of the road and inside the window.
static func _dress_box(box: Dictionary, lines: Array, at: Vector2, side: String, reached: bool, claimed: bool) -> void:
	var node: Control = box["node"]
	var parts: Dictionary = box["parts"]
	var n := maxi(1, lines.size())
	var w := TILE_PAD * 2.0 + TILE_W * float(n)
	var h := node.size.y
	node.size = Vector2(w, h)
	(parts["box"] as Control).size = Vector2(w, h)
	(box["hit"] as Control).size = Vector2(w, h)
	var x := at.x + DISC_R + BOX_GAP if side == "right" else at.x - DISC_R - BOX_GAP - w
	var content_w := float(Layout.find(PAGE, PAGE)["rect"][2])
	node.position = Vector2(clampf(x, EDGE, content_w - EDGE - w), at.y + BOX_DROP - h / 2.0).round()
	node.visible = true
	node.modulate = Color.WHITE if reached else AHEAD
	var seal: Control = parts["seal"]
	seal.position.x = w - seal.size.x + 3.0
	seal.visible = claimed
	var proto: Label = parts["amount"]
	proto.visible = false
	var tiles: Array = box["tiles"]
	for t in tiles:
		(t["icon"] as Node).queue_free()
		(t["amount"] as Node).queue_free()
		if t.has("ground") and is_instance_valid(t["ground"]):
			(t["ground"] as Node).queue_free()
	tiles.clear()
	for i in lines.size():
		var line: Dictionary = lines[i]
		var tile_x := TILE_PAD + TILE_W * float(i)
		var tex := Art.reward_line_icon(line)
		var icon := TextureRect.new()
		icon.texture = tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(icon, fitted(tex, Rect2(ICON_BOX.position + Vector2(tile_x, 0), ICON_BOX.size)))
		node.add_child(icon)
		var ground := ItemGround.for_line(icon, line, Rect2(icon.position, icon.size))
		icon.modulate = CLAIMED_ICONS if claimed else Color.WHITE
		var amount := proto.duplicate() as Label
		amount.label_settings = proto.label_settings.duplicate()
		amount.visible = true
		amount.position = Vector2(tile_x, proto.position.y)
		amount.size = Vector2(TILE_W, proto.size.y)
		amount.set_meta("box_w", TILE_W)
		node.add_child(amount)
		amount.text = amount_words(line)
		UI.fit_line(amount, proto.label_settings.font_size, 14)
		tiles.append({"icon": icon, "amount": amount, "ground": ground})
	node.move_child(seal, node.get_child_count() - 1)
	node.move_child(box["hit"], node.get_child_count() - 1)


## A picture in its tile's box: its own proportions, drawn down to fit and never
## up, centred.
static func fitted(tex: Texture2D, box: Rect2) -> Rect2:
	if tex == null:
		return box
	var s := tex.get_size()
	var k := minf(1.0, minf(box.size.x / s.x, box.size.y / s.y))
	var size := (s * k).round()
	return Rect2(box.position + (box.size - size) / 2.0, size)


## What a tile says under its picture: a sum of diamonds as its number, a count
## of anything as "×N" when there is more than one, nothing for one thing (its
## picture says what it is; a tap on the milestone says it in words).
static func amount_words(line: Dictionary) -> String:
	var amount := int(line.get("amount", 0))
	match str(line.get("kind", "")):
		"diamonds", "gold", "xp", "favour":
			return UI.grouped(amount)
	return "×%d" % amount if amount > 1 else ""


## The lord on the highest milestone reached; not on the road before the first.
static func _stand_lord(p: PaintedPage, content: Control, spots: Array, highest: int) -> void:
	var lord: TextureRect = p.get_meta("lord") if p.has_meta("lord") else null
	if lord == null:
		lord = UI.image(LORD, Rect2(Vector2.ZERO, LORD_SIZE))
		lord.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(lord)
		p.set_meta("lord", lord)
	lord.visible = highest >= 0
	if highest >= 0:
		var spot: Array = spots[highest]
		lord.position = Vector2(float(spot[0]), float(spot[1]) + LORD_DROP) - LORD_BASE
	content.move_child(lord, content.get_child_count() - 1)


## The window scrolled so milestone `i` stands in its middle.
static func _scroll_to(p: PaintedPage, spots: Array, i: int) -> void:
	var sc := p.node(PAGE) as ScrollContainer
	if sc == null or spots.is_empty():
		return
	await p.get_tree().process_frame
	if not is_instance_valid(sc):
		return
	var content := p.content(PAGE)
	var y := float(spots[clampi(i, 0, spots.size() - 1)][1])
	sc.scroll_vertical = int(clampf(y - sc.size.y / 2.0, 0.0, maxf(0.0, content.custom_minimum_size.y - sc.size.y)))


static func _tapped(p: PaintedPage, i: int) -> void:
	var road: Dictionary = p.get_meta("road", {})
	var stones: Array = road.get("milestones", [])
	if i >= stones.size():
		return
	var m: Dictionary = stones[i]
	if bool(m.get("reached", false)) and not bool(m.get("claimed", false)):
		_claim(p, int(m.get("index", i)))
		return
	var words: Array = []
	for l in m.get("lines", []):
		words.append(str(l.get("text", "")))
	var state := "Claimed." if bool(m.get("claimed", false)) else "Reach level %d to claim it." % int(m.get("level", 0))
	await Dialog.ask(p, {"title": "LEVEL %d" % int(m.get("level", 0)),
		"body": "\n".join(words) + "\n\n" + state, "confirm_text": "OK"})


## CLAIM (index -1) or one milestone. One at a time.
static func _claim(p: PaintedPage, index: int) -> void:
	if bool(p.get_meta("busy", false)):
		return
	p.set_meta("busy", true)
	var res: Api.Response = await Api.post_json(CLAIM, {} if index < 0 else {"index": index})
	if not is_instance_valid(p):
		return
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var road: Variant = res.data.get("road", null)
		if road is Dictionary:
			paint(p, road)
			# The Family's ROAD card counts what waits; the next heartbeat would
			# say it in thirty seconds, the page knows it now.
			var b := GameState.badges.duplicate()
			b["road"] = int((road as Dictionary).get("claimable", 0))
			GameState.set_badges(b)
		var lines: Array = res.data.get("lines", [])
		if not lines.is_empty():
			var ceremony: GDScript = load("res://scenes/pages/ceremony.gd")
			ceremony.delivery(p.get_meta("host", p), {"title": "VICTORY ROAD", "lines": lines})
	elif res.code == "inventory_full":
		await Armory.refused(p, res.error, Armory.sentence(res.error)
			+ " Sell or wear something, then claim it.")
	elif res.code == "nothing_to_claim":
		GameState.toast("Nothing waits on the road yet")
		_load(p)
	else:
		GameState.action_failed.emit(res.error)
	if is_instance_valid(p):
		p.set_meta("busy", false)
