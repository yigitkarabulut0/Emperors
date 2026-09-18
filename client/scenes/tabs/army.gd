extends Control
## ARMY — might, hero support, the soldier row, the selected soldier and the
## recruit menu. Layout: layout/army.json. Soldiers have no level: their tier is
## their rank, rolled at recruitment and rolled again by REROLL.

const SCREEN := "army"
const RerollPanel := preload("res://scenes/army/reroll_panel.gd")
const DISPLAY_NAME := {"peasant": "VILLAGER", "mercenary": "MERCENARY", "gladiator": "GLADIATOR"}
const BLURB := {"peasant": "Humble but reliable. The backbone of every army.",
	"mercenary": "Fights for coin, and fights well. Loyal while paid.",
	"gladiator": "Bred for the arena. Deadly, proud and expensive."}
const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII"]
const RECRUIT_TYPES := ["peasant", "mercenary", "gladiator"]
## The live SPEED label in the HERO SUPPORT row, measured off the painted
## DEFENCE beside it (ink x 523, rows 409..419, #BFCAD7).
const SUPPORT_LABEL_SIZE := 16
const SUPPORT_LABEL_COLOR := Color("#BFCAD7")
const SUPPORT_LABEL_RECT := Rect2(765, 402, 130, 24)
## How far a finger may travel on a card and still be tapping it. The strip's
## own deadzone, so a touch the strip would scroll on is never also a tap.
const DRAG_SLOP := 14.0
## From the end of the selected soldier's name to the tier chip after it: the
## painting has eight units from VILLAGER's ink (545) to the chip (553), and
## Cinzel's R at the name's size ends 2 units before its advance.
const TIER_CHIP_GAP := 6.0
## Where the tier chip must end: ten units short of the troop column's divider
## (716), as the troop bar starts twelve after it. MERCENARY with TIER VII, the
## longest name with the longest word, ends there.
const TIER_CHIP_RIGHT := 706.0
## The AWAY / BACK ribbon on a soldier's card: across the portrait's foot, where
## the painting leaves the figure's own shadow and nothing else stands. The
## portrait behind it is drawn back, so a card reads as away at a glance.
const RIBBON_Y := 128.0
const AWAY_TINT := Color(0.45, 0.5, 0.58)
const HuntPage := preload("res://scenes/pages/hunt_page.gd")

var _ui: Dictionary = {}
var _cards: Array = []
var _recruit_cards: Array = []
var _gear_tiles: Array = []
var _army: Dictionary = {}
var _odds: Dictionary = {}
var _support: Dictionary = {}
var _selected := 1
var _loaded_ms := -100000
var _busy := false
var _next_card: Dictionary = {}
## The selected soldier's portrait, in the window under the ring.
var _sel_art: TextureRect
## A press on a card, and how far it has travelled since.
var _press_travel := 0.0
var _press_scrolled := false
var _reroll: Control

## A phone taller than the design gets its extra height as room between the
## panels -- before the selected soldier, before the recruits and above the
## ground -- instead of as one band of bare ground under the recruit cards. The
## header, the hero support and the soldier strip stay together: the painting
## shows its army between them. Below the strip the ground between panels is
## plain, so a wider gap is more of the same ground. SECTION_STARTS are the
## design heights where the two lower sections begin.
const SECTION_STARTS := [890.0, 1278.0]
const SECTION_GAP_MAX := 80.0
var _sections: Array = [[], []]    ## per section, [node, its design y]


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_ui["soldier_strip"].set_meta("origin", Layout.rect_of(Layout.element(SCREEN, "soldier_strip")).position)
	_ui["auto_equip"].pressed.connect(_auto_equip)
	_ui["dismiss"].pressed.connect(_dismiss)
	_ui["reroll_tap"].pressed.connect(_open_reroll)
	_ui["hunt_tap"].pressed.connect(_hunt)
	# Both words are set in type on their plates, fitted to what a plate holds
	# beside its icon, as DISMISS's word is baked into its own. HUNT's changes
	# with what the soldier is doing and is set on every paint; REROLL's is
	# fixed copy and is the layout's own.
	for id in ["hunt", "reroll"]:
		UI.fit_label((_ui[id].get_meta("parts") as Dictionary)["label"], 26, 18)
	_ui["recruit_info"].pressed.connect(_show_odds)
	_ui["support_info"].pressed.connect(func() -> void:
		Dialog.ask(self, {"title": "Hero support", "body": "Your Family upgrades (Armoury, Bulwark, Stables) lift every soldier's attack, defence and speed.", "confirm_text": "OK"}))
	# A drag the strip takes is a drag, never a tap. The card's own button
	# still sees the press (it passes the drag on), so without this a swipe that
	# began on a card selected it when the finger lifted.
	var strip: ScrollContainer = _ui["soldier_strip"]
	strip.scroll_started.connect(func() -> void: _press_scrolled = true)
	_gear_tiles = _ui["gear_tile"]
	for i in _gear_tiles.size():
		_gear_tiles[i]["parts"]["tap"].pressed.connect(_choose_gear.bind(["weapon", "armor", "horse"][i]))
		_add_empty_face(_gear_tiles[i], i)
	_recruit_cards = _ui["recruit_card"]
	for i in _recruit_cards.size():
		_recruit_cards[i]["parts"]["recruit"].pressed.connect(_recruit.bind(RECRUIT_TYPES[i]))
		if i == 0: GuideTargets.register("army.recruit", _recruit_cards[i]["parts"]["recruit"])
		var card: TextureRect = _recruit_cards[i]["parts"]["card"]
		card.texture = Art.tex("army/recruit_" + ["villager", "mercenary", "gladiator"][i])
		var chip: Control = _recruit_cards[i]["parts"]["chip"]
		if chip is NinePatchRect:
			chip.patch_margin_left = 8; chip.patch_margin_right = 8; chip.patch_margin_top = 6; chip.patch_margin_bottom = 6
	# The third support cell reads the Stables bonus (soldier speed); its painted
	# label said "troop hp", so the label is live, set as the painted ATTACK and
	# DEFENCE are: from their left edge in the cell (x 767), caps 11 tall on
	# rows 409..419 (Cinzel 16), in their grey-blue. It was centred in the cell,
	# six units above the others, at 18.
	var speed_label := UI.label("SPEED", SUPPORT_LABEL_SIZE, SUPPORT_LABEL_COLOR, "title", 500)
	UI.place(speed_label, SUPPORT_LABEL_RECT)
	add_child(speed_label)
	# Every soldier is drawn in the ring's window, under the ring, at the
	# window's own size: each type has a large painting in each look now
	# (SoldierArt). The panel behind has the painting's villager baked in, frame
	# and numeral; the window and the ring cover all of it.
	var window: Control = _ui["sel_window"]
	_sel_art = TextureRect.new()
	_sel_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sel_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_sel_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(_sel_art, Rect2(Vector2.ZERO, window.size))
	window.add_child(_sel_art)
	# Everything on the page by the section it stands in; the ground, pinned
	# to the foot, stays where it is.
	for c in get_children():
		var n := c as Control
		if n == null or n.anchor_top > 0.0:
			continue
		for k in range(SECTION_STARTS.size() - 1, -1, -1):
			if n.position.y >= SECTION_STARTS[k]:
				_sections[k].append([n, n.position.y])
				break
	resized.connect(_fit_page)
	_fit_page()


func _fit_page() -> void:
	var gap := clampf((size.y - 1672.0) / 3.0, 0.0, SECTION_GAP_MAX)
	for k in _sections.size():
		for pair in _sections[k]:
			(pair[0] as Control).position.y = float(pair[1]) + gap * float(k + 1)


func refresh() -> void:
	# While the reroll panel is open it owns the soldier: a reload underneath it
	# would repaint the card between two of its rolls.
	if _reroll != null:
		return
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


## Reads the army again at once, whatever the last read's age: what a page that
## changed something (the roads) calls when it is done.
func reload_now() -> void:
	await _load()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/army")
	if res.ok:
		_army = res.data
	var o: Api.Response = await Api.get_json("/v1/army/odds")
	if o.ok:
		_odds = o.data
	var e: Api.Response = await Api.get_json("/v1/estates")
	if e.ok:
		_support = {}
		for u in e.data.get("upgrades", []):
			_support[str(u.get("bucket", ""))] = int(u.get("effect_now", 0))
	_paint()


func _slots() -> Array:
	return _army.get("slots", [])


func _slot(index: int) -> Dictionary:
	for s in _slots():
		if int(s.get("index", 0)) == index:
			return s
	return {}


func _paint() -> void:
	if _army.is_empty():
		return
	_ui["might_value"].text = UI.grouped(int(_army.get("totals", {}).get("might", 0)))
	_ui["support_attack"].text = "+%d%%" % (int(_support.get("soldier_atk_bp", 0)) / 100)
	_ui["support_defence"].text = "+%d%%" % (int(_support.get("soldier_def_bp", 0)) / 100)
	_ui["support_troop"].text = "+%d%%" % (int(_support.get("soldier_spd_bp", 0)) / 100)
	var slots := _slots()
	var filled := 0
	for s in slots:
		if s.get("soldier", null) is Dictionary:
			filled += 1
	_ui["soldiers_count"].text = "(%d/%d)" % [filled, slots.size()]
	if _slot(_selected).is_empty() and not slots.is_empty():
		_selected = int(slots[0].get("index", 1))
	_build_strip(slots.size())
	for i in _cards.size():
		_paint_card(i)
	_paint_next_slot()
	_paint_selected()
	_paint_recruits()


## One card per slot the player owns, with the next-slot tile after the last.
##
## The layout used to paint four cards at fixed positions, which is what the
## reference happened to show; a player can hold ten, and slots five upward were
## simply not on the screen -- so neither were the soldiers in them, and only
## the first four could be selected or dismissed. The row scrolls sideways
## instead, and "unlock the next slot" is where it belongs: at the end of it.
##
## Cards stand where the template's rect puts the first one: at the painting's
## height, so the selection ring round a card is never cut by the strip's top.
## They used to stand at the strip's very top edge, and the ring above them was
## clipped off -- the highlight looked broken.
func _build_strip(count: int) -> void:
	var sc: ScrollContainer = _ui["soldier_strip"]
	var content: Control = sc.get_meta("content")
	var tpl := Layout.find(SCREEN, "soldier_card")
	var pitch := float(tpl.get("pitch", 153))
	var origin := Layout.rect_of(tpl).position
	while _cards.size() < count:
		var i := _cards.size()
		var built := Layout.instantiate(tpl)
		built["node"].position = origin + Vector2(i * pitch, 0)
		content.add_child(built["node"])
		var p: Dictionary = built["parts"]
		var tap: BaseButton = p["tap"]
		tap.button_down.connect(func() -> void:
			_press_travel = 0.0
			_press_scrolled = false)
		tap.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseMotion and (ev as InputEventMouseMotion).button_mask != 0:
				_press_travel += (ev as InputEventMouseMotion).relative.length())
		tap.pressed.connect(_tapped.bind(i + 1))
		_cards.append(built)
	for i in _cards.size():
		_cards[i]["node"].visible = i < count
	if _next_card.is_empty():
		_next_card = Layout.instantiate(Layout.find(SCREEN, "next_slot_card"))
		content.add_child(_next_card["node"])
		_next_card["parts"]["unlock"].pressed.connect(_buy_slot)
	_next_card["node"].position = Vector2(origin.x + count * pitch, 0)
	# Every slot owned: no next one to buy, so no card for it and no room left.
	var more := next_slot(_army) != {}
	_next_card["node"].visible = more
	content.custom_minimum_size = Vector2(origin.x + count * pitch + (143 + 8 if more else 0), sc.size.y)


## A card was let go of. Only a touch that stayed put selects: a swipe along
## the row, a swipe up the screen that began on a card, or a touch that stopped
## a moving row is not a choice of soldier.
func _tapped(index: int) -> void:
	if _press_scrolled or _press_travel > DRAG_SLOP:
		return
	_select(index)


func _paint_card(i: int) -> void:
	var c: Dictionary = _cards[i]
	var p: Dictionary = c["parts"]
	var s := _slot(i + 1)
	c["node"].visible = not s.is_empty()
	if s.is_empty():
		return
	var soldier: Variant = s.get("soldier", null)
	var selected := _selected == i + 1
	p["selected_frame"].visible = selected
	if soldier is Dictionary:
		var type := str(soldier.get("type", "peasant"))
		var tier := SoldierArt.tier_of(str(soldier.get("tier", "common")))
		p["portrait"].texture = Art.tex(SoldierArt.portrait(type, tier))
		p["portrait"].modulate = Color.WHITE
		p["numeral"].texture = Art.tex(SoldierArt.numeral(tier))
		p["numeral"].visible = true
		p["name"].text = DISPLAY_NAME.get(type, type.to_upper())
		# At the painting's size, with its margins: at 22 GLADIATOR and
		# MERCENARY ran from one edge of the card to the other.
		UI.fit_label(p["name"], 18, 14)
		p["attack"].text = UI.grouped(int(soldier.get("attack", 0)))
		p["defence"].text = UI.grouped(int(soldier.get("defense", 0)))
		p["power"].text = UI.grouped(int(soldier.get("might", soldier.get("ehp", 0))))
		p["troop"].text = UI.grouped(int(soldier.get("hp", 0)))
		for k in ["attack", "defence", "power"]:
			UI.fit_label(p[k], 22, 16)
		UI.fit_label(p["troop"], 20, 15)
		# The ribbon: a soldier on a road is not in the yard, and the card says
		# so before a lord taps it and finds out.
		_ribbon(c, soldier.get("away", null))
	else:
		p["portrait"].texture = Art.tex(SoldierArt.portrait("peasant", 1))
		p["portrait"].modulate = Color(0.25, 0.25, 0.3)
		p["numeral"].visible = false
		p["name"].text = "EMPTY"
		for k in ["attack", "defence", "power", "troop"]:
			p[k].text = "-"
		_ribbon(c, null)


## AWAY / BACK across a soldier's card: one label on the painted card, in the
## card's own type, drawn over the portrait's foot where nothing else stands.
func _ribbon(card: Dictionary, away: Variant) -> void:
	var l: Label = card.get("ribbon")
	if l == null:
		var node: Control = card["node"]
		l = UI.label("", 20, UI.INK, "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Rect2(6, RIBBON_Y, node.size.x - 12, 30))
		l.set_meta("box_w", node.size.x - 12)
		node.add_child(l)
		card["ribbon"] = l
	var on := away is Dictionary
	l.visible = on
	(card["parts"]["portrait"] as CanvasItem).modulate = AWAY_TINT if on else Color.WHITE
	if not on:
		return
	var a: Dictionary = away
	l.text = "BACK" if bool(a.get("back", false)) else "AWAY"
	l.modulate = UI.GOLD if bool(a.get("back", false)) else Color("#BFCAD7")


## The army view's next slot to buy, or {} when every slot is owned: the
## server sends null then, and a null read into a Dictionary is a script error.
static func next_slot(army: Dictionary) -> Dictionary:
	var ns: Variant = army.get("next_slot", null)
	return ns if ns is Dictionary else {}


func _paint_next_slot() -> void:
	if _next_card.is_empty():
		return
	var np: Dictionary = _next_card["parts"]
	var ns := next_slot(_army)
	_next_card["node"].visible = not ns.is_empty()
	if ns.is_empty():
		return
	var unlocked := bool(ns.get("unlocked", false))
	if bool(ns.get("free", false)):
		np["price"].text = "FREE"
	elif unlocked:
		np["price"].text = UI.short_number(int(ns.get("cost", 0)))
	else:
		np["price"].text = "LV %d" % int(ns.get("level_gate", 1))
	# In the tile, clear of its frame: an unfitted 76,076 grew its label past
	# the box and ran to the tile's edge.
	UI.fit_line(np["price"], 26, 18)
	np["unlock"].modulate = Color.WHITE if unlocked else Color(0.5, 0.5, 0.5)


func _paint_selected() -> void:
	var s := _slot(_selected)
	var soldier: Variant = s.get("soldier", null) if not s.is_empty() else null
	var has := soldier is Dictionary
	_ui["sel_tier_chip"].visible = has
	# REROLL and DISMISS stay, dimmed when there is nobody to roll or dismiss:
	# the panel is cut with both taken off, and an empty slot used to show the
	# painting's DISMISS at full strength beside an empty troop bar that read
	# full.
	_ui["reroll"].modulate = Color.WHITE if has else Color(0.5, 0.5, 0.5)
	_ui["hunt"].modulate = Color.WHITE if has else Color(0.5, 0.5, 0.5)
	_ui["dismiss"].modulate = Color.WHITE if has else Color(0.5, 0.5, 0.5)
	_ui["dismiss"].disabled = not has
	if not has:
		_ui["sel_name"].text = "EMPTY SLOT"
		_ui["sel_tier_text"].text = ""
		_fit_title()
		_ui["sel_description"].text = "Recruit a soldier below into this slot."
		for k in ["sel_attack", "sel_defence", "sel_power"]:
			_ui[k].text = "-"
		_ui["sel_state"].text = ""
		_hunt_word("HUNT")
		# An empty slot has no tier, so no numeral; and a dimmed villager in the
		# window rather than nothing, since the panel's own villager -- numeral
		# and all -- is baked in under it and an empty window would show him lit.
		_ui["sel_numeral"].visible = false
		_sel_art.texture = Art.tex(SoldierArt.large("peasant", 1))
		_sel_art.modulate = Color(0.25, 0.25, 0.3)
		# Empty tiles, not hidden ones: the panel behind has the painting's own
		# gear baked into it, so hiding the tiles showed a spear, a jerkin and a
		# horse on a slot that holds nobody.
		for t in _gear_tiles:
			t["node"].visible = true
			t["parts"]["painting"].visible = false
			t["parts"]["art"].modulate = Color(0.4, 0.4, 0.45)
			t["parts"]["level"].text = ""
			t["ghost"].visible = false
			t["word"].visible = false
		return
	var type := str(soldier.get("type", "peasant"))
	var tier := SoldierArt.tier_of(str(soldier.get("tier", "common")))
	_sel_art.texture = Art.tex(SoldierArt.large(type, tier))
	_sel_art.modulate = Color.WHITE
	_ui["sel_numeral"].visible = true
	_ui["sel_numeral"].texture = Art.tex(SoldierArt.numeral_large(tier))
	_ui["sel_name"].text = DISPLAY_NAME.get(type, type.to_upper())
	_ui["sel_tier_text"].text = "TIER " + ROMAN[clampi(tier, 1, 7)]
	_fit_title()
	_ui["sel_description"].text = BLURB.get(type, "")
	_ui["sel_attack"].text = UI.grouped(int(soldier.get("attack", 0)))
	_ui["sel_defence"].text = UI.grouped(int(soldier.get("defense", 0)))
	# POWER is the unit's own Might, the score the army and the raid band
	# compare; it printed effective HP under the same word.
	_ui["sel_power"].text = UI.grouped(int(soldier.get("might", soldier.get("ehp", 0))))
	for k in ["sel_attack", "sel_defence", "sel_power"]:
		UI.fit_label(_ui[k], 24, 16)
	_paint_away(soldier)
	var eq: Dictionary = soldier.get("equipped", {})
	for i in _gear_tiles.size():
		var slot: String = ["weapon", "armor", "horse"][i]
		var t: Dictionary = _gear_tiles[i]
		t["node"].visible = true
		var item: Variant = eq.get(slot, null)
		# The tile is the painting's empty gear frame; the worn item's design is
		# drawn inset into it.
		var painting: TextureRect = t["parts"]["painting"]
		painting.visible = item is Dictionary
		t["ghost"].visible = not (item is Dictionary)
		t["word"].visible = not (item is Dictionary)
		t["parts"]["art"].modulate = Color.WHITE
		# The worn piece on its rarity's velvet; a bare slot keeps its empty tile.
		ItemGround.in_gear_tile(painting, t["parts"]["art"], "army/gear_tile_empty",
			str(item.get("tier", "common")) if item is Dictionary else "")
		if item is Dictionary:
			painting.texture = Art.item(str(item.get("art", "")))
			t["parts"]["level"].text = "Lv. %d" % int(item.get("ilvl", 1))
		else:
			t["parts"]["level"].text = ""


## The selected soldier's name at the painting's one size, in its box, and the
## tier chip after it, holding its word at the chip's one size.
##
## The chip was pinned where the painting has it (553), so the name's box ended
## there, and each name was shrunk to fit it: VILLAGER at 28, GLADIATOR at 23,
## MERCENARY at 22 -- the name changed size from one soldier to the next -- and
## EMPTY SLOT was not fitted at all, so it kept whichever size the soldier
## before it had. Built round its sample the label was also wider than its box
## (181 against 150). Every name now fits the box the layout gives it (only a
## name that could not would shrink), the label is sized back to that box, and
## the chip moves to follow the name.
##
## The chip is the painting's, drawn round TIER I; TIER III and TIER VII ran
## into its rims. A longer word widens it by what the word is longer, to no
## further than TIER_CHIP_RIGHT, and only a word held there would shrink.
## The selected soldier's own state: in the yard, on a road, or at the gate.
##
## The word on HUNT's plate changes with it, because it is the same decision
## each time -- send them, call them back, let them in -- and three plates for
## three states would be two plates a lord can never press.
func _paint_away(soldier: Dictionary) -> void:
	var away: Variant = soldier.get("away", null)
	if not (away is Dictionary):
		_ui["sel_state"].text = "IN THE YARD"
		UI.fit_label(_ui["sel_state"], 24, 16)
		_hunt_word("HUNT")
		return
	var a: Dictionary = away
	var back := bool(a.get("back", false))
	_ui["sel_state"].text = "AT THE GATE" if back else "%s  ·  %s" % [
		str(a.get("field", "AWAY")).to_upper(), UI.short_duration(int(a.get("ends_in", 0)))]
	UI.fit_label(_ui["sel_state"], 24, 14)
	_hunt_word("BACK" if back else "AWAY")


## The word on HUNT's plate, and its icon: the crosshair while there is somebody
## to send, and nothing but the word once they are gone.
func _hunt_word(word: String) -> void:
	var parts: Dictionary = _ui["hunt"].get_meta("parts")
	(parts["label"] as Label).text = word
	UI.fit_label(parts["label"], 26, 18)
	(parts["icon"] as Control).visible = word == "HUNT"


func _fit_title() -> void:
	var l: Label = _ui["sel_name"]
	UI.fit_line(l, int(Layout.element(SCREEN, "sel_name").get("size", 29)), 20)
	var x := roundf(l.position.x + minf(_advance(l, l.text), float(l.get_meta("box_w", l.size.x))) + TIER_CHIP_GAP)
	var chip: Control = _ui["sel_tier_chip"]
	var word: Label = _ui["sel_tier_text"]
	var chip_rect := Layout.rect_of(Layout.element(SCREEN, "sel_tier_chip"))
	var word_part := Layout.element(SCREEN, "sel_tier_text")
	var word_size := int(word_part.get("size", 18))
	word.label_settings.font_size = word_size
	var room := chip_rect.size.x - _advance(word, "TIER I")
	var w := clampf(_advance(word, word.text) + room, chip_rect.size.x, TIER_CHIP_RIGHT - x)
	chip.position.x = x
	chip.size.x = w
	word.position.x = x + Layout.rect_of(word_part).position.x - chip_rect.position.x
	word.size.x = w
	word.set_meta("box_w", w - room)
	UI.fit_label(word, word_size, 13)


## How wide `text` is in the label's type at its current size.
func _advance(l: Label, text: String) -> float:
	var s := l.label_settings
	return s.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x


## What an empty gear tile shows: a faint ghost of the painting's own piece for
## that slot and the slot's name under it. It said "none", lowercase, in the
## corner of a tile dimmed nearly black -- which read as broken, not as a slot
## waiting to be filled.
const GEAR_GHOSTS := ["items/army_spear", "items/army_leather_armor", "items/army_horse"]
const GEAR_WORDS := ["WEAPON", "ARMOR", "HORSE"]


func _add_empty_face(t: Dictionary, i: int) -> void:
	var paint: Control = t["parts"]["painting"]
	var node: Control = t["node"]
	var face := UI.empty_slot_face(node, Rect2(paint.position, paint.size), GEAR_GHOSTS[i], GEAR_WORDS[i],
		Rect2(0, 72, node.size.x, 24), t["parts"]["tap"])
	t["ghost"] = face[0]
	t["word"] = face[1]


## The recruit cards: the painting, the tier range on its chip, the price.
##
## The published odds used to be printed under the chip as well -- "72% T1
## 22% T2" -- so every card said its tier twice. The chip is the card's one
## statement of tier now; the full odds, every tier of every type, are one tap
## away on the painted (i) above the cards.
func _paint_recruits() -> void:
	var recruits: Array = _army.get("recruits", [])
	for i in _recruit_cards.size():
		var type: String = RECRUIT_TYPES[i]
		var p: Dictionary = _recruit_cards[i]["parts"]
		var span := _tier_span(type)
		p["chip_text"].text = "TIER %s - %s" % [ROMAN[span.x], ROMAN[span.y]] if span.x > 0 else ""
		var cost := 0
		var free := false
		for r in recruits:
			if str(r.get("type_id", "")) == type:
				cost = int(r.get("cost", 0))
				free = bool(r.get("free", false))
		p["price"].text = "FREE" if free else UI.grouped(cost)
		UI.fit_label(p["price"], 26, 18)


## The lowest and highest tier a type can be drawn at, by the server's odds.
func _tier_span(type: String) -> Vector2i:
	var lo := 7
	var hi := 0
	for o in _odds_for(type):
		if int(o.get("bp", 0)) > 0:
			var ti := SoldierArt.tier_of(str(o.get("tier", "common")))
			lo = mini(lo, ti)
			hi = maxi(hi, ti)
	return Vector2i(lo, hi) if hi > 0 else Vector2i.ZERO


func _odds_for(type: String) -> Array:
	for t in _odds.get("types", []):
		if str(t.get("type_id", "")) == type:
			return t.get("odds", [])
	return []


## Every type's published odds, every tier, as the server computes them for this
## player's level and luck. A recruit is paid-for chance, and the chance is shown
## before it is paid for; so is every reroll, which draws from the same table.
func _show_odds() -> void:
	load("res://scenes/pages/odds_page.gd").open(self, _odds, RECRUIT_TYPES, DISPLAY_NAME)


# --- actions ------------------------------------------------------------------------

func _select(index: int) -> void:
	_selected = index
	_paint()
	_reveal(index)


## Brings a card that is partly off the row's edge fully into view, so the
## soldier just chosen is never half behind the panel's border.
func _reveal(index: int) -> void:
	if index < 1 or index > _cards.size():
		return
	var sc: ScrollContainer = _ui["soldier_strip"]
	var card: Control = _cards[index - 1]["node"]
	var left := card.position.x - 4.0
	var right := card.position.x + card.size.x + 4.0
	var at := float(sc.scroll_horizontal)
	var target := at
	if left < at:
		target = left
	elif right > at + sc.size.x:
		target = right - sc.size.x
	if absf(target - at) < 1.0:
		return
	create_tween().tween_property(sc, "scroll_horizontal", int(maxf(0.0, target)), 0.22) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _first_empty_slot() -> int:
	for s in _slots():
		if not (s.get("soldier", null) is Dictionary):
			return int(s.get("index", 0))
	return 0


func _recruit(type: String) -> void:
	if _busy:
		return
	var target := _selected if not (_slot(_selected).get("soldier", null) is Dictionary) else _first_empty_slot()
	if target == 0:
		GameState.action_failed.emit("No empty slot — unlock one or dismiss a soldier")
		return
	var cost := 0
	for r in _army.get("recruits", []):
		if str(r.get("type_id", "")) == type:
			cost = int(r.get("cost", 0))
	if not await Dialog.ask(self, {"title": "Recruit a %s?" % DISPLAY_NAME.get(type, type).capitalize(),
			"body": "Into slot %d for %s gold. The tier is rolled on recruitment." % [target, UI.grouped(cost)], "confirm_text": "Recruit"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/recruit", {"slot": target, "type_id": type})
	if res.ok:
		var s: Dictionary = res.data.get("soldier", {})
		GameState.toast("Recruited a %s %s" % [str(s.get("tier", "")).capitalize(), str(s.get("name", ""))])
		_selected = target
		await _load()
	_busy = false


func _buy_slot() -> void:
	if _busy:
		return
	var ns: Dictionary = _army.get("next_slot", {})
	if not bool(ns.get("unlocked", false)):
		GameState.action_failed.emit("Unlocks at level %d" % int(ns.get("level_gate", 1)))
		return
	var cost := int(ns.get("cost", 0))
	if not await Dialog.ask(self, {"title": "Unlock a slot?", "body": "Slot %d for %s gold." % [int(ns.get("index", 0)), "free" if bool(ns.get("free", false)) else UI.grouped(cost)], "confirm_text": "Unlock"}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/slot", {})
	if res.ok:
		await _load()
	_busy = false


func _dismiss() -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		return
	if not await Dialog.ask(self, {"title": "Dismiss this %s?" % str(soldier.get("name", "soldier")).to_lower(),
			"body": "Their gear returns to your inventory. The soldier is gone for good.", "confirm_text": "Dismiss", "danger": true}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/dismiss", {"soldier_id": str(soldier.get("id", ""))})
	if res.ok:
		await _load()
	_busy = false


## Opens the reroll panel on the selected soldier. The Army screen stops
## loading underneath it, and loads once when it closes: the panel has changed
## the soldier, perhaps a hundred times.
## HUNT: the roads for this soldier, or what to do about one already on a road.
func _hunt() -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		GameState.action_failed.emit("Recruit a soldier into this slot to send them out")
		return
	var s: Dictionary = soldier
	var away: Variant = s.get("away", null)
	_busy = true
	if away is Dictionary:
		await _settle_hunt(s, away)
	else:
		var res: Api.Response = await Api.get_json("/v1/hunt?soldier=%s" % str(s.get("id", "")))
		if res.ok and res.data is Dictionary:
			# Their kind goes with them: the page draws the same figure the
			# yard's card does, and without it every soldier went out a peasant.
			HuntPage.open(self, self, {
				"id": str(s.get("id", "")), "name": str(s.get("name", "")),
				"tier": str(s.get("tier", "")), "type": str(s.get("type", "peasant")),
			}, res.data)
		else:
			GameState.action_failed.emit(res.error)
	_busy = false


## A soldier at the gate is let in with what they found; one still on the road
## may be called back, and brings nothing at all.
func _settle_hunt(soldier: Dictionary, away: Dictionary) -> void:
	var id := str(away.get("id", ""))
	if bool(away.get("back", false)):
		var res: Api.Response = await GameState.act("/v1/hunt/collect", {"id": id},
			{"hunt_soon": "They are still on the road.", "hunt_gone": "They are home already."})
		if res.ok:
			GameState.toast("%s is home: %s" % [str(soldier.get("name", "The soldier")),
				_haul_words(res.data.get("granted", {}))])
			await _load()
		return
	if not await Dialog.ask(self, {
			"title": "Call them back?",
			"body": "%s is %s from home. Called back early they bring NOTHING: the haul is what the road paid for the waiting." % [
				str(soldier.get("name", "The soldier")), UI.short_duration(int(away.get("ends_in", 0)))],
			"confirm_text": "Call back", "danger": true}):
		return
	var res: Api.Response = await Api.post_json("/v1/hunt/recall", {"id": id})
	if res.ok:
		GameState.toast("%s is called back, empty-handed." % str(soldier.get("name", "The soldier")))
		await _load()
	else:
		GameState.action_failed.emit(res.error)


## What a haul was worth, in the words the server wrote for it.
static func _haul_words(granted: Dictionary) -> String:
	var lines: Array = granted.get("lines", [])
	if lines.is_empty():
		return "nothing at all"
	var words: Array[String] = []
	for i in mini(lines.size(), 3):
		words.append(str(lines[i].get("text", "")))
	return ", ".join(words)


func _open_reroll() -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or _reroll != null:
		return
	if not (soldier is Dictionary):
		GameState.action_failed.emit("Recruit a soldier into this slot to reroll them")
		return
	var type := str(soldier.get("type", "peasant"))
	_reroll = RerollPanel.open(self, {
		"soldier": soldier,
		"odds": _odds_for(type),
		"name": DISPLAY_NAME.get(type, type.to_upper()),
		"type": type,
	})
	_reroll.closed.connect(func() -> void:
		_reroll = null
		_load())


func _auto_equip() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/autoequip", {"scope": "army"})
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.toast("Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])
		await _load()
	_busy = false


## This soldier's gear for one slot: everything that fits and is not already on
## them, best first, on the gear page. A piece someone else wears -- the hero,
## another soldier -- is shown with their name on it and taking it asks first.
func _choose_gear(slot: String) -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		return
	_busy = true
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	_busy = false
	if not inv.ok:
		return
	var sid := str(soldier.get("id", ""))
	var items: Array = []
	var wearing: Dictionary = {}
	for it in inv.data.get("items", []):
		if str(it.get("slot", "")) != slot:
			continue
		if str(it.get("equipped_on", "")) == sid:
			wearing = it
			continue
		items.append(it)
	items.sort_custom(func(a, b): return int(a.get("power", 0)) > int(b.get("power", 0)))
	var picker: GDScript = load("res://scenes/pages/item_picker.gd")
	var pick: String = await picker.pick(self, "%s FOR THIS SOLDIER" % slot.to_upper(), items, wearing)
	if pick == "":
		return
	var path := "/v1/army/equip"
	var body := {"soldier_id": sid, "item_id": pick}
	if pick == "__unequip":
		path = "/v1/inventory/unequip"
		body = {"item_id": str(wearing.get("id", ""))}
	else:
		for it in items:
			if str(it.get("id", "")) == pick and str(it.get("worn_by", "")) != "":
				if not await Dialog.ask(self, {"title": "Take it from them?",
						"body": "%s is worn by %s. They will fight without it." % [str(it.get("name", "")),
							"your hero" if str(it.get("equipped_on", "")) == "hero" else "your " + str(it.get("worn_by", ""))],
						"confirm_text": "Take it"}):
					return
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	if res.ok:
		await _load()
	_busy = false
