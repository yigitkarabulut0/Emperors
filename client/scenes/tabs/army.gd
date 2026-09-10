extends Control
## ARMY — might, hero support, the soldier row, the selected soldier and the
## recruit menu. Layout: layout/army.json. Soldiers have no level: their tier is
## their rank, rolled at recruitment and rolled again by REROLL.

const SCREEN := "army"
const RerollPanel := preload("res://scenes/army/reroll_panel.gd")
const PORTRAIT := {"peasant": "portraits/soldier_villager", "mercenary": "portraits/soldier_mercenary", "gladiator": "portraits/soldier_gladiator"}
const DISPLAY_NAME := {"peasant": "VILLAGER", "mercenary": "MERCENARY", "gladiator": "GLADIATOR"}
const BLURB := {"peasant": "Humble but reliable. The backbone of every army.",
	"mercenary": "Fights for coin, and fights well. Loyal while paid.",
	"gladiator": "Bred for the arena. Deadly, proud and expensive."}
const TIER_INDEX := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}
const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII"]
const RECRUIT_TYPES := ["peasant", "mercenary", "gladiator"]
## How far a finger may travel on a card and still be tapping it. The strip's
## own deadzone, so a touch the strip would scroll on is never also a tap.
const DRAG_SLOP := 14.0
## The live numeral for tiers without a painted one is fitted to what the
## diamond's dark centre holds, not to the diamond's box: "VII" at the plate's
## size touched its gold edge.
const NUMERAL_ROOM := 30.0
const LARGE_NUMERAL_ROOM := 44.0

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
var _numeral_labels: Dictionary = {}
var _next_card: Dictionary = {}
var _sel_numeral_label: Label
var _sel_small: TextureRect
## A press on a card, and how far it has travelled since.
var _press_travel := 0.0
var _press_scrolled := false
var _reroll: Control


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_ui["soldier_strip"].set_meta("origin", Layout.rect_of(Layout.element(SCREEN, "soldier_strip")).position)
	_ui["auto_equip"].pressed.connect(_auto_equip)
	_ui["dismiss"].pressed.connect(_dismiss)
	_ui["reroll_tap"].pressed.connect(_open_reroll)
	# The word is set in type on HUNT's plate, fitted to what the plate holds
	# beside the arrows, as DISMISS's word is to its own.
	UI.fit_label((_ui["reroll"].get_meta("parts") as Dictionary)["label"], 26, 18)
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
	_recruit_cards = _ui["recruit_card"]
	for i in _recruit_cards.size():
		_recruit_cards[i]["parts"]["recruit"].pressed.connect(_recruit.bind(RECRUIT_TYPES[i]))
		var card: TextureRect = _recruit_cards[i]["parts"]["card"]
		card.texture = Art.tex("army/recruit_" + ["villager", "mercenary", "gladiator"][i])
		var chip: Control = _recruit_cards[i]["parts"]["chip"]
		if chip is NinePatchRect:
			chip.patch_margin_left = 8; chip.patch_margin_right = 8; chip.patch_margin_top = 6; chip.patch_margin_bottom = 6
	# The third support cell reads the Stables bonus (soldier speed); its painted
	# label said "troop hp", so the label is live.
	var speed_label := UI.label("SPEED", 18, Color("#C9D2DC"), "title", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(speed_label, Rect2(745, 398, 150, 24))
	add_child(speed_label)
	# A soldier with no large painting of its own is drawn in the ring's window,
	# cover-fitted, under the ring -- not stretched over the villager's frame.
	var window: Control = _ui["sel_window"]
	_sel_small = TextureRect.new()
	_sel_small.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sel_small.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_sel_small.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(_sel_small, Rect2(Vector2.ZERO, window.size))
	window.add_child(_sel_small)
	_sel_numeral_label = UI.label("", 30, Color("#F2E6C8"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_sel_numeral_label, Layout.rect_of(Layout.element(SCREEN, "sel_numeral")))
	_sel_numeral_label.set_meta("box_w", LARGE_NUMERAL_ROOM)
	_sel_numeral_label.visible = false
	add_child(_sel_numeral_label)


func refresh() -> void:
	# While the reroll panel is open it owns the soldier: a reload underneath it
	# would repaint the card between two of its rolls.
	if _reroll != null:
		return
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


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
		var l := UI.label("", 22, Color("#F2E6C8"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Layout.rect_of(Layout.find(SCREEN, "numeral")))
		l.set_meta("box_w", NUMERAL_ROOM)
		l.visible = false
		built["node"].add_child(l)
		# Above the plate, below the tap target that has to stay on top.
		built["node"].move_child(l, tap.get_index())
		_numeral_labels[i] = l
		_cards.append(built)
	for i in _cards.size():
		_cards[i]["node"].visible = i < count
	if _next_card.is_empty():
		_next_card = Layout.instantiate(Layout.find(SCREEN, "next_slot_card"))
		content.add_child(_next_card["node"])
		_next_card["parts"]["unlock"].pressed.connect(_buy_slot)
	_next_card["node"].position = Vector2(origin.x + count * pitch, 0)
	content.custom_minimum_size = Vector2(origin.x + count * pitch + 143 + 8, sc.size.y)


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
		var tier := int(TIER_INDEX.get(str(soldier.get("tier", "common")), 1))
		p["portrait"].texture = Art.tex(PORTRAIT.get(type, PORTRAIT["peasant"]))
		p["portrait"].modulate = Color.WHITE
		_numeral(p["numeral"], _numeral_labels[i], tier)
		p["name"].text = DISPLAY_NAME.get(type, type.to_upper())
		UI.fit_label(p["name"], 22, 15)
		p["attack"].text = UI.grouped(int(soldier.get("attack", 0)))
		p["defence"].text = UI.grouped(int(soldier.get("defense", 0)))
		p["power"].text = UI.grouped(int(soldier.get("ehp", 0)))
		p["troop"].text = UI.grouped(int(soldier.get("hp", 0)))
	else:
		p["portrait"].texture = Art.tex("portraits/soldier_villager")
		p["portrait"].modulate = Color(0.25, 0.25, 0.3)
		p["numeral"].visible = false
		_numeral_labels[i].visible = false
		p["name"].text = "EMPTY"
		for k in ["attack", "defence", "power", "troop"]:
			p[k].text = "-"


## Tiers I-III have painted numerals; higher tiers get the blank plate and live text.
func _numeral(plate: TextureRect, label: Label, tier: int) -> void:
	plate.visible = true
	if tier <= 3:
		plate.texture = Art.tex("army/numeral_%d" % tier)
		label.visible = false
	else:
		plate.texture = Art.tex("army/numeral_blank")
		label.text = ROMAN[clampi(tier, 1, 7)]
		UI.fit_label(label, 22, 14)
		label.visible = true


func _paint_next_slot() -> void:
	if _next_card.is_empty():
		return
	var np: Dictionary = _next_card["parts"]
	var ns: Dictionary = _army.get("next_slot", {})
	var unlocked := bool(ns.get("unlocked", false))
	if bool(ns.get("free", false)):
		np["price"].text = "FREE"
	elif unlocked:
		np["price"].text = UI.short_number(int(ns.get("cost", 0)))
	else:
		np["price"].text = "LV %d" % int(ns.get("level_gate", 1))
	np["unlock"].modulate = Color.WHITE if unlocked else Color(0.5, 0.5, 0.5)


func _paint_selected() -> void:
	var s := _slot(_selected)
	var soldier: Variant = s.get("soldier", null) if not s.is_empty() else null
	var has := soldier is Dictionary
	for id in ["sel_numeral", "sel_tier_chip", "dismiss", "sel_troop_bar"]:
		_ui[id].visible = has
	# REROLL stays: its plate covers where HUNT was painted. It dims when there
	# is nobody to roll.
	_ui["reroll"].modulate = Color.WHITE if has else Color(0.5, 0.5, 0.5)
	var portrait: TextureRect = _ui["sel_portrait"]
	if not has:
		_ui["sel_name"].text = "EMPTY SLOT"
		_ui["sel_tier_text"].text = ""
		_ui["sel_description"].text = "Recruit a soldier below into this slot."
		for k in ["sel_attack", "sel_defence", "sel_power"]:
			_ui[k].text = "-"
		_ui["sel_troop_text"].text = ""
		_sel_numeral_label.visible = false
		# The villager's painting, dimmed: the panel has it baked under the
		# portrait, so hiding the portrait would show it undimmed.
		portrait.visible = true
		portrait.texture = Art.tex("portraits/soldier_villager_large")
		portrait.modulate = Color(0.25, 0.25, 0.3)
		_sel_small.visible = false
		# Empty tiles, not hidden ones: the panel behind has the painting's own
		# gear baked into it, so hiding the tiles showed a spear, a jerkin and a
		# horse on a slot that holds nobody.
		for t in _gear_tiles:
			t["node"].visible = true
			t["parts"]["painting"].visible = false
			t["parts"]["art"].modulate = Color(0.4, 0.4, 0.45)
			t["parts"]["level"].text = ""
		return
	var type := str(soldier.get("type", "peasant"))
	var tier := int(TIER_INDEX.get(str(soldier.get("tier", "common")), 1))
	portrait.modulate = Color.WHITE
	if type == "peasant":
		# Only the villager has a large painting, frame and all.
		portrait.visible = true
		portrait.texture = Art.tex("portraits/soldier_villager_large")
		_sel_small.visible = false
	else:
		portrait.visible = false
		_sel_small.texture = Art.tex(PORTRAIT.get(type, PORTRAIT["peasant"]))
		_sel_small.visible = true
	# Only tier I exists as a large painted numeral; the rest use the blank plate.
	if tier == 1:
		_ui["sel_numeral"].texture = Art.tex("army/numeral_large_1")
		_sel_numeral_label.visible = false
	else:
		_ui["sel_numeral"].texture = Art.tex("army/numeral_large_blank")
		_sel_numeral_label.text = ROMAN[clampi(tier, 1, 7)]
		UI.fit_label(_sel_numeral_label, 30, 18)
		_sel_numeral_label.visible = true
	_ui["sel_name"].text = DISPLAY_NAME.get(type, type.to_upper())
	UI.fit_label(_ui["sel_name"], 34, 20)
	_ui["sel_tier_text"].text = "TIER " + ROMAN[clampi(tier, 1, 7)]
	_ui["sel_description"].text = BLURB.get(type, "")
	_ui["sel_description"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ui["sel_description"].label_settings.font_size = 21
	_ui["sel_description"].label_settings.line_spacing = -4
	_ui["sel_attack"].text = UI.grouped(int(soldier.get("attack", 0)))
	_ui["sel_defence"].text = UI.grouped(int(soldier.get("defense", 0)))
	_ui["sel_power"].text = UI.grouped(int(soldier.get("ehp", 0)))
	var hp := int(soldier.get("hp", 0))
	_ui["sel_troop_text"].text = "%s / %s" % [UI.grouped(hp), UI.grouped(hp)]
	Layout.set_fill(_ui["sel_troop_bar"], 1.0)
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
		if item is Dictionary:
			painting.texture = Art.item(str(item.get("art", "")))
			t["parts"]["art"].modulate = Color.WHITE
			t["parts"]["level"].text = "Lv. %d" % int(item.get("ilvl", 1))
		else:
			t["parts"]["art"].modulate = Color(0.4, 0.4, 0.45)
			t["parts"]["level"].text = "none"


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


## The lowest and highest tier a type can be drawn at, by the server's odds.
func _tier_span(type: String) -> Vector2i:
	var lo := 7
	var hi := 0
	for o in _odds_for(type):
		if int(o.get("bp", 0)) > 0:
			var ti := int(TIER_INDEX.get(str(o.get("tier", "common")), 1))
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
	var lines: Array = []
	for type in RECRUIT_TYPES:
		var parts: Array = []
		for o in _odds_for(type):
			var bp := int(o.get("bp", 0))
			if bp <= 0:
				continue
			var ti := int(TIER_INDEX.get(str(o.get("tier", "common")), 1))
			parts.append("%s %s" % [ROMAN[ti], _percent(bp)])
		lines.append("%s\n%s" % [DISPLAY_NAME.get(type, type.to_upper()), "   ".join(parts)])
	await Dialog.ask(self, {"title": "Recruit odds",
		"body": "The tier a soldier is drawn at, recruited or rerolled, at your level.\n\n%s" % "\n\n".join(lines),
		"confirm_text": "OK"})


## 7179 basis points as "71.8%", 17 as "0.17%": a rare tier's chance is the
## number a player most wants to read, and rounding it to 0% hides it.
static func _percent(bp: int) -> String:
	if bp >= 1000:
		return "%.0f%%" % (bp / 100.0)
	if bp >= 100:
		return "%.1f%%" % (bp / 100.0)
	return "%.2f%%" % (bp / 100.0)


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
	_busy = false
	if res.ok:
		var s: Dictionary = res.data.get("soldier", {})
		GameState.action_failed.emit("Recruited a %s %s" % [str(s.get("tier", "")).capitalize(), str(s.get("name", ""))])
		_selected = target
		await _load()


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
	_busy = false
	if res.ok:
		await _load()


func _dismiss() -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		return
	if not await Dialog.ask(self, {"title": "Dismiss this %s?" % str(soldier.get("name", "soldier")).to_lower(),
			"body": "Their gear returns to your inventory. The soldier is gone for good.", "confirm_text": "Dismiss", "danger": true}):
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/dismiss", {"soldier_id": str(soldier.get("id", ""))})
	_busy = false
	if res.ok:
		await _load()


## Opens the reroll panel on the selected soldier. The Army screen stops
## loading underneath it, and loads once when it closes: the panel has changed
## the soldier, perhaps a hundred times.
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
		"portrait": PORTRAIT.get(type, PORTRAIT["peasant"]),
	})
	_reroll.closed.connect(func() -> void:
		_reroll = null
		_load())


func _auto_equip() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/autoequip", {"scope": "army"})
	_busy = false
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.action_failed.emit("Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])
		await _load()


func _choose_gear(slot: String) -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		return
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	if not inv.ok:
		return
	var options: Array = []
	for it in inv.data.get("items", []):
		if str(it.get("slot", "")) != slot or bool(it.get("equipped", false)):
			continue
		options.append({"id": str(it.get("id", "")), "label": str(it.get("name", "")), "sub": "%s · Power %s" % [str(it.get("tier", "")).to_upper(), UI.grouped(int(it.get("power", 0)))]})
	if options.is_empty():
		GameState.action_failed.emit("No spare %s in your inventory" % slot)
		return
	var pick := await Dialog.choose(self, {"title": "%s for this soldier" % slot.capitalize(), "options": options.slice(0, 8)})
	if pick == "":
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/equip", {"soldier_id": str(soldier.get("id", "")), "item_id": pick})
	_busy = false
	if res.ok:
		await _load()
