extends Control
## ARMY — might, hero support, the soldier row, the selected soldier and the
## recruit menu. Layout: layout/army.json. Soldiers have no level: their tier is
## their rank, rolled at recruitment.

const SCREEN := "army"
const PORTRAIT := {"peasant": "portraits/soldier_villager", "mercenary": "portraits/soldier_mercenary", "gladiator": "portraits/soldier_gladiator"}
const DISPLAY_NAME := {"peasant": "VILLAGER", "mercenary": "MERCENARY", "gladiator": "GLADIATOR"}
const BLURB := {"peasant": "Humble but reliable. The backbone of every army.",
	"mercenary": "Fights for coin, and fights well. Loyal while paid.",
	"gladiator": "Bred for the arena. Deadly, proud and expensive."}
const TIER_INDEX := {"common": 1, "uncommon": 2, "rare": 3, "epic": 4, "legendary": 5, "mystic": 6, "special": 7}
const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII"]
const RECRUIT_TYPES := ["peasant", "mercenary", "gladiator"]

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
var _sel_numeral_label: Label


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_cards = _ui["soldier_card"]
	for i in _cards.size():
		var p: Dictionary = _cards[i]["parts"]
		p["tap"].pressed.connect(_select.bind(i + 1))
		var np: Control = p["selected_frame"]
		if np is NinePatchRect:
			np.draw_center = false
			np.patch_margin_left = 8; np.patch_margin_top = 14; np.patch_margin_right = 10; np.patch_margin_bottom = 14
		var l := UI.label("", 22, Color("#F2E6C8"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Layout.rect_of(Layout.find(SCREEN, "numeral")))
		l.visible = false
		_cards[i]["node"].add_child(l)
		_numeral_labels[i] = l
	_ui["auto_equip"].pressed.connect(_auto_equip)
	_ui["unlock"].pressed.connect(_buy_slot)
	_ui["hunt"].pressed.connect(_hunt)
	_ui["dismiss"].pressed.connect(_dismiss)
	_ui["support_info"].pressed.connect(func() -> void:
		Dialog.ask(self, {"title": "Hero support", "body": "Your Family upgrades (Armoury, Bulwark, Stables) lift every soldier's attack, defence and speed.", "confirm_text": "OK"}))
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
	_sel_numeral_label = UI.label("", 30, Color("#F2E6C8"), "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_sel_numeral_label, Layout.rect_of(Layout.element(SCREEN, "sel_numeral")))
	_sel_numeral_label.visible = false
	add_child(_sel_numeral_label)


func refresh() -> void:
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
	for i in _cards.size():
		_paint_card(i)
	_paint_next_slot()
	_paint_selected()
	_paint_recruits()


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
		label.visible = true


func _paint_next_slot() -> void:
	var ns: Dictionary = _army.get("next_slot", {})
	var unlocked := bool(ns.get("unlocked", false))
	if bool(ns.get("free", false)):
		_ui["next_slot_price"].text = "FREE"
	elif unlocked:
		_ui["next_slot_price"].text = UI.short_number(int(ns.get("cost", 0)))
	else:
		_ui["next_slot_price"].text = "LV %d" % int(ns.get("level_gate", 1))
	_ui["unlock"].modulate = Color.WHITE if unlocked else Color(0.5, 0.5, 0.5)


func _paint_selected() -> void:
	var s := _slot(_selected)
	var soldier: Variant = s.get("soldier", null) if not s.is_empty() else null
	var has := soldier is Dictionary
	for id in ["sel_portrait", "sel_numeral", "sel_tier_chip", "hunt", "dismiss", "sel_troop_bar"]:
		_ui[id].visible = has
	if not has:
		_ui["sel_name"].text = "EMPTY SLOT"
		_ui["sel_tier_text"].text = ""
		_ui["sel_description"].text = "Recruit a soldier below into this slot."
		for k in ["sel_attack", "sel_defence", "sel_power"]:
			_ui[k].text = "-"
		_ui["sel_troop_text"].text = ""
		_sel_numeral_label.visible = false
		for t in _gear_tiles:
			t["node"].visible = false
		return
	var type := str(soldier.get("type", "peasant"))
	var tier := int(TIER_INDEX.get(str(soldier.get("tier", "common")), 1))
	var portrait: TextureRect = _ui["sel_portrait"]
	if type == "peasant":
		portrait.texture = Art.tex("portraits/soldier_villager_large")
	else:
		# Only the villager exists as a large painting; the small one is scaled into the tile.
		portrait.texture = Art.tex(PORTRAIT.get(type, PORTRAIT["peasant"]))
	# Only tier I exists as a large painted numeral; the rest use the blank plate.
	if tier == 1:
		_ui["sel_numeral"].texture = Art.tex("army/numeral_large_1")
		_sel_numeral_label.visible = false
	else:
		_ui["sel_numeral"].texture = Art.tex("army/numeral_large_blank")
		_sel_numeral_label.text = ROMAN[clampi(tier, 1, 7)]
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
		t["parts"]["art"].texture = Art.item("%s_00" % slot, "soldier")
		if item is Dictionary:
			t["parts"]["art"].modulate = Color.WHITE
			t["parts"]["level"].text = "Lv. %d" % int(item.get("ilvl", 1))
		else:
			t["parts"]["art"].modulate = Color(0.4, 0.4, 0.45)
			t["parts"]["level"].text = "none"


func _paint_recruits() -> void:
	var recruits: Array = _army.get("recruits", [])
	var types: Array = _odds.get("types", [])
	for i in _recruit_cards.size():
		var type: String = RECRUIT_TYPES[i]
		var p: Dictionary = _recruit_cards[i]["parts"]
		var odds: Array = []
		for t in types:
			if str(t.get("type_id", "")) == type:
				odds = t.get("odds", [])
		var lo := 7
		var hi := 1
		var top: Array = []
		for o in odds:
			var bp := int(o.get("bp", 0))
			if bp > 0:
				var ti := int(TIER_INDEX.get(str(o.get("tier", "common")), 1))
				lo = mini(lo, ti)
				hi = maxi(hi, ti)
				top.append([bp, ti])
		top.sort_custom(func(a, b): return a[0] > b[0])
		p["chip_text"].text = "TIER %s - %s" % [ROMAN[lo], ROMAN[hi]] if not top.is_empty() else ""
		var parts: Array = []
		for k in mini(2, top.size()):
			parts.append("%d%% T%d" % [int(round(top[k][0] / 100.0)), top[k][1]])
		p["odds"].text = "    ".join(parts)
		var cost := 0
		var free := false
		for r in recruits:
			if str(r.get("type_id", "")) == type:
				cost = int(r.get("cost", 0))
				free = bool(r.get("free", false))
		p["price"].text = "FREE" if free else UI.grouped(cost)


# --- actions ------------------------------------------------------------------------

func _select(index: int) -> void:
	_selected = index
	_paint()


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


func _hunt() -> void:
	var soldier: Variant = _slot(_selected).get("soldier", null)
	if _busy or not (soldier is Dictionary):
		return
	var type := str(soldier.get("type", "peasant"))
	var options: Array = []
	for t in ["uncommon", "rare", "epic", "legendary"]:
		options.append({"id": t, "label": "Hunt for %s" % t.capitalize(), "sub": "Re-recruit until a %s or better lands" % t})
	var target := await Dialog.choose(self, {"title": "Hunt a tier", "body": "Keeps recruiting %ss into this slot until the target tier drops, up to your budget." % type, "options": options})
	if target == "":
		return
	var budget := await Dialog.prompt_amount(self, {"title": "Gold budget", "placeholder": "Max gold to spend", "preset": str(mini(GameState.display_gold(), 200000)), "confirm_text": "Hunt"})
	if budget["action"] != "confirm" or int(budget["value"]) <= 0:
		return
	_busy = true
	var res: Api.Response = await GameState.act("/v1/army/autoroll", {"slot": _selected, "type_id": type, "target_tier": target, "max_gold": int(budget["value"])})
	_busy = false
	if res.ok:
		GameState.action_failed.emit("%d rolls, %s gold: %s" % [int(res.data.get("rolls", 0)), UI.grouped(int(res.data.get("gold_spent", 0))),
			("got a %s" % str(res.data.get("final_tier", ""))) if bool(res.data.get("hit_target", false)) else "stopped (%s)" % str(res.data.get("stopped_because", ""))])
		await _load()


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
