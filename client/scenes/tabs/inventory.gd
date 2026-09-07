extends Control
## INVENTORY — equipped gear, rarity filters and the item grid.
## Layout: layout/inventory.json. Equip / sell / reforge go through the server;
## the Collection (donate) lives behind the sliders button.

const SCREEN := "inventory"
const TIERS := ["all", "common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const CHIP_COLOR := {"all": "#FFFFFF", "common": "#FFFFFF", "uncommon": "#BCFF7D", "rare": "#B1ECFF",
	"epic": "#FFD4FF", "legendary": "#FFFFEA", "mystic": "#EFD6FF", "special": "#FFDAD0"}
const STAT_LINE := {"weapon": ["attack", "ATK", "inventory/icon_attack"], "armor": ["defense", "DEF", "inventory/icon_defence"],
	"horse": ["speed", "Move Speed", "inventory/icon_speed"]}

var _ui: Dictionary = {}
var _equipped: Array = []
var _cards: Array = []
var _chips: Dictionary = {}
var _chip_labels: Dictionary = {}
var _filter := "all"
var _inventory: Dictionary = {}
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


func _paint_equipped() -> void:
	var eq: Dictionary = _inventory.get("equipped", {})
	for i in _equipped.size():
		var slot: String = ["weapon", "armor", "horse"][i]
		var p: Dictionary = _equipped[i]["parts"]
		var item: Variant = eq.get(slot, null)
		var painting: TextureRect = p["painting"]
		painting.visible = item is Dictionary
		if item is Dictionary:
			painting.texture = Art.item(str(item.get("art", "")))
			p["tile"].modulate = Color.WHITE
			p["level"].text = "Lv. %d" % int(item.get("ilvl", 1))
			p["name"].text = str(item.get("name", ""))
			UI.fit_label(p["name"], 21, 14)
			var line: Array = STAT_LINE[slot]
			p["stat"].text = "%s +%s" % [line[1] if slot != "horse" else "POWER", UI.grouped(int(item.get(line[0] if slot != "horse" else "power", 0)))]
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


func _items_shown() -> Array:
	var out: Array = []
	for it in _inventory.get("items", []):
		if _filter == "all" or str(it.get("tier", "")) == _filter:
			out.append(it)
	out.sort_custom(func(a, b):
		if bool(a.get("equipped", false)) != bool(b.get("equipped", false)):
			return bool(a.get("equipped", false))
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
		built["parts"]["btn_reforge"].pressed.connect(_reforge.bind(i))
		# Tier frame overlay: nine-patch border drawn over the empty tile's baked
		# common ring (parts[1]); the item design sits inset inside it.
		var frame := NinePatchRect.new()
		frame.draw_center = false
		UI.place(frame, Layout.rect_of(tpl["parts"][1]))
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		var frame: NinePatchRect = c["frame"]
		frame.texture = Art.tex("inventory/frame_" + tier)
		var m := 18 if tier == "legendary" else 10
		frame.patch_margin_left = m; frame.patch_margin_right = m; frame.patch_margin_top = m; frame.patch_margin_bottom = m
		p["level"].text = "Lv. %d" % int(it.get("ilvl", 1))
		p["name"].text = str(it.get("name", ""))
		UI.fit_label(p["name"], 20, 13)
		p["type"].text = slot.to_upper()
		var badge: TextureRect = p["badge"]
		badge.texture = Art.tex("inventory/badge_" + tier)
		badge.size = badge.texture.get_size()
		badge.position.x = 382 - 9 - badge.size.x
		var line: Array = STAT_LINE[slot]
		p["icon1"].texture = Art.tex(line[2])
		p["stat1"].text = "%s +%s" % [line[1], UI.grouped(int(it.get(line[0], 0)))] if slot != "horse" \
			else "POWER +%s" % UI.grouped(int(it.get("power", 0)))
		p["icon2"].texture = Art.tex("inventory/icon_power" if slot != "horse" else "inventory/icon_speed")
		p["stat2"].text = "Power +%s" % UI.grouped(int(it.get("power", 0))) if slot != "horse" \
			else "Move Speed +%s%%" % UI.grouped(int(it.get("speed", 0)))
		var worn := bool(it.get("equipped", false))
		p["btn_equip"].modulate = Color(0.5, 0.5, 0.5) if worn else Color.WHITE
	var rows := int(ceil(items.size() / float(cols.size())))
	content.custom_minimum_size = Vector2(sc.size.x, top + rows * pitch + 20)
	if items.is_empty():
		content.custom_minimum_size = Vector2(sc.size.x, sc.size.y)


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
	if bool(it.get("equipped", false)):
		GameState.action_failed.emit("Already equipped")
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


func _reforge(i: int) -> void:
	var it := _item_at(i)
	if _busy or it.is_empty():
		return
	if not await Dialog.ask(self, {"title": "Reforge %s?" % str(it.get("name", "")),
			"body": "Re-rolls its quality for %s gold. It can get worse." % UI.grouped(int(it.get("reforge_price", 0))), "confirm_text": "Reforge"}):
		return
	var res: Api.Response = await _post("/v1/inventory/reforge", {"item_id": str(it.get("id", ""))})
	if res.ok:
		GameState.action_failed.emit("Reforged: %s" % ("better" if bool(res.data.get("improved", false)) else "worse"))


func _post(path: String, body: Dictionary) -> Api.Response:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	_busy = false
	if res.ok:
		await _load()
	return res


func _open_collection() -> void:
	if _busy:
		return
	var res: Api.Response = await Api.get_json("/v1/collection")
	if not res.ok:
		return
	var held := int(res.data.get("held", 0))
	var total := int(res.data.get("total", 0))
	var options: Array = []
	for it in _inventory.get("items", []):
		if bool(it.get("equipped", false)):
			continue
		options.append({"id": str(it.get("id", "")), "label": str(it.get("name", "")), "sub": "Donate to the Collection"})
	if options.is_empty():
		await Dialog.ask(self, {"title": "The Collection", "body": "%d of %d designs held. Donating an unequipped item you do not yet hold grants a permanent bonus." % [held, total], "confirm_text": "OK"})
		return
	var pick := await Dialog.choose(self, {"title": "The Collection  %d / %d" % [held, total],
		"body": "Donating a design you do not yet hold grants a permanent bonus; a duplicate is refused.", "options": options.slice(0, 8)})
	if pick == "":
		return
	await _post("/v1/collection/donate", {"item_id": pick})
