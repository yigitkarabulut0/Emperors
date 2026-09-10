extends Control
## INVENTORY — equipped gear, rarity filters and the item grid.
## Layout: layout/inventory.json. Equip and sell go through the server;
## the Collection (donate) lives behind the sliders button.

const SCREEN := "inventory"
const TIERS := ["all", "common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const CHIP_COLOR := {"all": "#FFFFFF", "common": "#FFFFFF", "uncommon": "#BCFF7D", "rare": "#B1ECFF",
	"epic": "#FFD4FF", "legendary": "#FFFFEA", "mystic": "#EFD6FF", "special": "#FFDAD0"}
## Each slot's own stat, as the server counts it. A horse's is a flat speed
## score that decides who strikes first; it was printed "Move Speed +12%", a
## unit the game has never had.
const STAT_LINE := {"weapon": ["attack", "ATK", "inventory/icon_attack"], "armor": ["defense", "DEF", "inventory/icon_defence"],
	"horse": ["speed", "SPEED", "inventory/icon_speed"]}

var _ui: Dictionary = {}
var _equipped: Array = []
var _cards: Array = []
var _chips: Dictionary = {}
var _chip_labels: Dictionary = {}
var _filter := "all"
var _inventory: Dictionary = {}
var _bag_label: Label
var _empty_label: Label
var _loaded_ms := -100000
var _busy := false


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	_equipped = _ui["equipped_slot"]
	for i in _equipped.size():
		var slot: String = ["weapon", "armor", "horse"][i]
		var hit := UI.hotspot(Rect2(Vector2.ZERO, _equipped[i]["node"].size))
		hit.pressed.connect(_unequip.bind(slot))
		_equipped[i]["node"].add_child(hit)
	for t in TIERS:
		var b: TextureButton = _ui["chip_" + t]
		_chips[t] = b
		b.pressed.connect(_set_filter.bind(t))
		# The chips keep their painted labels; the active state repaints frame + label.
		var l := UI.label(t.to_upper(), 18, Color(CHIP_COLOR[t]), "title", 600, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(l, Rect2(b.position, b.size))
		l.visible = false
		add_child(l)
		_chip_labels[t] = l
	_ui["sliders"].pressed.connect(_open_collection)
	var sc: ScrollContainer = _ui["list"]
	sc.scroll_deadzone = 14
	_ui["list"].set_meta("origin", Layout.rect_of(Layout.element(SCREEN, "list")).position)
	# How full the bags are, on the right of the EQUIPPED GEAR banner: the cap
	# is what makes selling a decision, and it was never on the screen.
	_bag_label = UI.label("", 22, UI.DIM, "title", 600, HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(_bag_label, Rect2(600, 234, 300, 34))
	add_child(_bag_label)
	_empty_label = UI.label("", 26, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.place(_empty_label, Rect2(60, 90, 666, 160))
	(sc.get_meta("content") as Control).add_child(_empty_label)


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var res: Api.Response = await Api.get_json("/v1/inventory")
	if res.ok:
		_inventory = res.data
		_paint()


func _paint() -> void:
	_paint_equipped()
	_paint_chips()
	_paint_grid()
	if not _inventory.is_empty():
		var worn := 0
		for it in _inventory.get("items", []):
			if str(it.get("equipped_on", "")) != "":
				worn += 1
		_bag_label.text = "BAG  %d / %d%s" % [int(_inventory.get("used", 0)), int(_inventory.get("cap", 0)),
			"  ·  %d WORN" % worn if worn > 0 else ""]
		_bag_label.label_settings.font_color = UI.RED if int(_inventory.get("used", 0)) >= int(_inventory.get("cap", 1)) else UI.DIM


func _paint_equipped() -> void:
	var eq: Dictionary = _inventory.get("equipped", {})
	for i in _equipped.size():
		var slot: String = ["weapon", "armor", "horse"][i]
		var p: Dictionary = _equipped[i]["parts"]
		var item: Variant = eq.get(slot, null)
		var painting: TextureRect = p["painting"]
		painting.visible = item is Dictionary
		p["gem"].texture = Art.gem(str(item.get("tier", "")) if item is Dictionary else "")
		if item is Dictionary:
			painting.texture = Art.item(str(item.get("art", "")))
			p["tile"].modulate = Color.WHITE
			p["level"].text = "Lv. %d" % int(item.get("ilvl", 1))
			p["name"].text = str(item.get("name", ""))
			UI.fit_label(p["name"], 21, 14)
			var line: Array = STAT_LINE[slot]
			p["stat"].text = "%s +%s" % [line[1], UI.grouped(int(item.get(line[0], 0)))]
		else:
			p["tile"].modulate = Color(0.55, 0.55, 0.55)
			p["level"].text = ""
			p["name"].text = "Empty"
			p["stat"].text = "Tap an item to equip"


func _paint_chips() -> void:
	for t in TIERS:
		var b: TextureButton = _chips[t]
		var active: bool = (t == _filter)
		var l: Label = _chip_labels[t]
		if t == "all":
			b.texture_normal = Art.tex("inventory/chip_all_active" if active else "inventory/chip_frame_idle")
			l.visible = not active
		else:
			b.texture_normal = Art.tex("inventory/chip_frame_active" if active else "inventory/chip_" + t)
			l.visible = active
			l.label_settings.font_color = Color.WHITE if active else Color(CHIP_COLOR[t])


## What is in the bag, which is everything that is not being worn.
##
## Worn gear used to head this list as well, greyed out, so the three pieces the
## player has on were shown twice on one screen -- once in EQUIPPED GEAR at the
## top and again below it, with an EQUIP button that did nothing. The panel is
## where a worn piece lives; taking it off puts it back here.
##
## "Worn" is by anyone. Only the hero's gear was left out, so a soldier's sword
## sat in the bag looking free: EQUIP stripped the soldier and SELL was refused.
## A soldier's gear lives on the Army screen.
func _items_shown() -> Array:
	var out: Array = []
	for it in _inventory.get("items", []):
		if str(it.get("equipped_on", "")) != "" or bool(it.get("equipped", false)):
			continue
		if _filter == "all" or str(it.get("tier", "")) == _filter:
			out.append(it)
	# Rarity first, best at the top, and power inside a rarity.
	#
	# Sorting on power alone looked shuffled, because power is not rarity: an
	# item's numbers come from its level as well as its tier, so a common at
	# level 40 outranks a legendary at level 12 and the list read common,
	# legendary, mystic, common. What a player scans this list for is the
	# rarity, so that is what orders it.
	out.sort_custom(func(a, b):
		var ra := TIERS.find(str(a.get("tier", "common")))
		var rb := TIERS.find(str(b.get("tier", "common")))
		if ra != rb:
			return ra > rb
		return int(a.get("power", 0)) > int(b.get("power", 0)))
	return out


func _paint_grid() -> void:
	var items := _items_shown()
	var sc: ScrollContainer = _ui["list"]
	var content: Control = sc.get_meta("content")
	var tpl := Layout.find(SCREEN, "item_card")
	var origin: Vector2 = sc.get_meta("origin")
	var cols: Array = tpl.get("columns", [160, 546])
	var pitch := float(tpl.get("pitch", 210))
	var top := Layout.rect_of(tpl).position.y - origin.y
	while _cards.size() < items.size():
		var built := Layout.instantiate(tpl)
		content.add_child(built["node"])
		var i := _cards.size()
		built["parts"]["btn_equip"].pressed.connect(_equip.bind(i))
		built["parts"]["btn_sell"].pressed.connect(_sell.bind(i))
		# Tier frame overlay, drawn over the empty tile (parts[1]) with the item
		# design inside it.
		#
		# It used to be a nine-patch with its centre off, because the frames were
		# cut as whole painted tiles: the item was still in them and the centre
		# had to be hidden. That only holds at the size they were painted -- on
		# the bigger tile the edge slices stretched and dragged the item out with
		# them, a ghost down each side and the level plate along the bottom. The
		# frames are cut hollow now, so the border simply scales with the tile.
		var frame := UI.image("", Layout.rect_of(tpl["parts"][1]))
		built["node"].add_child(frame)
		built["node"].move_child(frame, 2)
		built["frame"] = frame
		_cards.append(built)
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		if i >= items.size():
			c["node"].visible = false
			continue
		c["node"].visible = true
		var it: Dictionary = items[i]
		c["item"] = it
		c["node"].position = Vector2(float(cols[i % cols.size()]) - origin.x, top + (i / cols.size()) * pitch)
		var p: Dictionary = c["parts"]
		var slot := str(it.get("slot", "weapon"))
		var tier := str(it.get("tier", "common"))
		p["painting"].texture = Art.item(str(it.get("art", "")))
		var frame: TextureRect = c["frame"]
		frame.texture = Art.tex("inventory/frame_" + tier)
		p["level"].text = "Lv. %d" % int(it.get("ilvl", 1))
		p["name"].text = str(it.get("name", ""))
		UI.fit_wrapped(p["name"], 31, 20)
		p["type"].text = slot.to_upper()
		var badge: TextureRect = p["badge"]
		badge.texture = Art.tex("inventory/badge_" + tier)
		badge.size = badge.texture.get_size()
		var line: Array = STAT_LINE[slot]
		p["icon1"].texture = Art.tex(line[2])
		p["stat1"].text = "%s +%s" % [line[1], UI.grouped(int(it.get(line[0], 0)))]
		p["icon2"].texture = Art.tex("inventory/icon_power")
		p["stat2"].text = "Power +%s" % UI.grouped(int(it.get("power", 0)))
		UI.fit_label(p["stat1"], 28, 18)
		UI.fit_label(p["stat2"], 28, 18)
	var rows := int(ceil(items.size() / float(cols.size())))
	content.custom_minimum_size = Vector2(sc.size.x, top + rows * pitch + 20)
	_empty_label.visible = items.is_empty() and not _inventory.is_empty()
	if items.is_empty():
		content.custom_minimum_size = Vector2(sc.size.x, sc.size.y)
		if _filter != "all":
			_empty_label.text = "Nothing %s in your bags." % _filter.to_upper()
		else:
			_empty_label.text = "Your bags are empty.\nThe Royal Market in the Shop sells new gear every few minutes."


# --- actions ------------------------------------------------------------------------

func _set_filter(t: String) -> void:
	_filter = t
	_paint_chips()
	_paint_grid()


func _item_at(i: int) -> Dictionary:
	if i < _cards.size() and _cards[i].has("item"):
		return _cards[i]["item"]
	return {}


func _equip(i: int) -> void:
	var it := _item_at(i)
	if _busy or it.is_empty():
		return
	if str(it.get("equipped_on", "")) == "hero":
		return
	await _post("/v1/inventory/equip", {"item_id": str(it.get("id", ""))})


func _unequip(slot: String) -> void:
	var item: Variant = _inventory.get("equipped", {}).get(slot, null)
	if _busy or not (item is Dictionary):
		return
	if not await Dialog.ask(self, {"title": "Unequip %s?" % str(item.get("name", "")), "confirm_text": "Unequip"}):
		return
	await _post("/v1/inventory/unequip", {"item_id": str(item.get("id", ""))})


func _sell(i: int) -> void:
	var it := _item_at(i)
	if _busy or it.is_empty():
		return
	if not await Dialog.ask(self, {"title": "Sell %s?" % str(it.get("name", "")),
			"body": "For %s gold. This cannot be undone." % UI.grouped(int(it.get("sell_price", 0))), "confirm_text": "Sell", "danger": true}):
		return
	await _post("/v1/inventory/sell", {"item_id": str(it.get("id", ""))})


## Held until the reload is in, so a second tap lands on the new list.
func _post(path: String, body: Dictionary) -> Api.Response:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	if res.ok:
		await _load()
	_busy = false
	return res


## The Collection takes one of each design, for good, and pays in luck.
##
## Offers only what the server would take: an item nobody is wearing, of a
## design not already on the wall. It used to offer the first eight items of
## any kind -- worn ones the server refuses, duplicates it refuses -- and no
## more than eight, in no order.
func _open_collection() -> void:
	if _busy:
		return
	var res: Api.Response = await Api.get_json("/v1/collection")
	if not res.ok:
		return
	var held_ids := {}
	for set in res.data.get("sets", []):
		for e in set.get("entries", []):
			if bool(e.get("held", false)):
				held_ids[str(e.get("def_id", ""))] = true
	var items: Array = []
	var seen := {}
	for it in _inventory.get("items", []):
		var def := str(it.get("def_id", ""))
		if str(it.get("equipped_on", "")) != "" or held_ids.has(def) or seen.has(def):
			continue
		seen[def] = true
		items.append(it)
	items.sort_custom(func(a, b):
		var ra := TIERS.find(str(a.get("tier", "common")))
		var rb := TIERS.find(str(b.get("tier", "common")))
		return ra > rb if ra != rb else str(a.get("name", "")) < str(b.get("name", "")))
	var held := int(res.data.get("held", 0))
	var total := int(res.data.get("total", 0))
	var luck := int(res.data.get("luck_bp", 0))
	var intro := "%d of %d designs on the wall, +%s luck on every roll.\nA donated item is gone for good; its design stays." % [
		held, total, ("%d%%" % (luck / 100)) if luck % 100 == 0 else ("%.1f%%" % (luck / 100.0))]
	if items.is_empty():
		await Dialog.ask(self, {"title": "The Collection", "body": intro + "\n\nNothing in your bags is new to the wall.", "confirm_text": "OK"})
		return
	var options: Array = []
	for it in items:
		options.append({"id": str(it.get("id", "")), "label": str(it.get("name", "")),
			"sub": "%s %s · new to the wall" % [str(it.get("tier", "")).to_upper(), str(it.get("slot", "")).to_upper()]})
	var pick := await Dialog.choose(self, {"title": "The Collection  %d / %d" % [held, total],
		"body": intro, "options": options})
	if pick == "":
		return
	var res2 := await _post("/v1/collection/donate", {"item_id": pick})
	if res2.ok:
		GameState.toast("Added to the Collection")
