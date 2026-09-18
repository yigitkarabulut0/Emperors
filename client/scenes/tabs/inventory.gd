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
## The bag's count on the EQUIPPED GEAR banner, alone and beside MORE ROOM.
## The banner's row runs y 234..280 between the panel's top border and the
## slot boxes'; the count's caps sit on its middle (257). MORE ROOM is the screen's own green EQUIP plate at its painted
## height (43), 16 units in from the panel's right border (x 929), its word in
## the plate's own type (the painted EQUIP's caps are 12 tall: Cinzel 18); its
## thumb-sized tap area runs into the header above and the slot names below,
## where nothing else takes a tap.
const BAG_RECT := Rect2(600, 241, 300, 34)
const MORE_PLATE := "inventory/btn_equip_plate"
const MORE_WORD := "MORE ROOM"
const MORE_SIZE := 18
const MORE_COLOR := Color("#EFFCEF")
const MORE_RIGHT := 913.0
const MORE_Y := 236.0
const MORE_H := 43.0
const MORE_PAD := 21.0
const MORE_GAP := 14.0
const STAT_LINE := {"weapon": ["attack", "ATK", "inventory/icon_attack"], "armor": ["defense", "DEF", "inventory/icon_defence"],
	"horse": ["speed", "SPEED", "inventory/icon_speed"]}
const ForgePage := preload("res://scenes/pages/forge_page.gd")

var _ui: Dictionary = {}
var _equipped: Array = []
var _cards: Array = []
var _chips: Dictionary = {}
var _chip_labels: Dictionary = {}
var _filter := "all"
var _inventory: Dictionary = {}
var _bag_label: Label
## MORE ROOM, beside the count while the bag is full and the Quartermaster can
## be bought (Armory); asked of the Store once per load, not per paint.
var _more_room: Button
var _asked_store := false
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
	# The painted button is a set of sliders, which reads as a filter; it opens
	# the Collection's wall, and says so under the mark.
	var wall := UI.label("WALL", 18, UI.GOLD_DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	var sl: Control = _ui["sliders"]
	UI.place(wall, Rect2(sl.position.x, sl.position.y + sl.size.y - 58, sl.size.x, 28))
	add_child(wall)
	var sc: ScrollContainer = _ui["list"]
	sc.scroll_deadzone = 14
	_ui["list"].set_meta("origin", Layout.rect_of(Layout.element(SCREEN, "list")).position)
	# How full the bags are, on the right of the EQUIPPED GEAR banner: the cap
	# is what makes selling a decision, and it was never on the screen.
	_bag_label = UI.label("", 22, UI.DIM, "title", 600, HORIZONTAL_ALIGNMENT_RIGHT)
	UI.place(_bag_label, BAG_RECT)
	add_child(_bag_label)
	var font := UI.settings(MORE_SIZE, MORE_COLOR, "title", 600).font
	var w := ceilf(font.get_string_size(MORE_WORD, HORIZONTAL_ALIGNMENT_LEFT, -1, MORE_SIZE).x) + 2.0 * MORE_PAD
	var paint := Rect2(MORE_RIGHT - w, MORE_Y, w, MORE_H)
	var tap := Rect2(paint.position.x - 10.0, paint.get_center().y - 48.0, w + 20.0, 96.0)
	_more_room = UI.plate_button(MORE_PLATE, MORE_WORD, tap, MORE_SIZE, MORE_COLOR, 600)
	UI.inset_plate(_more_room, tap, paint)
	_more_room.visible = false
	_more_room.pressed.connect(func() -> void: Armory.open_store(self))
	add_child(_more_room)
	_empty_label = UI.label("", 26, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.place(_empty_label, Rect2(60, 90, 666, 160))
	(sc.get_meta("content") as Control).add_child(_empty_label)


func refresh() -> void:
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint()


## Reloads the bag and waits for it: a page that changed what the lord owns
## (the anvil) holds its own close until the list behind it is the new one.
func reload_now() -> void:
	await _load()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	_asked_store = false
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
		_paint_more_room()


## MORE ROOM while the bag is full and the Quartermaster can be bought; the
## count moves over to make room for it, and shrinks to fit if it must.
func _paint_more_room() -> void:
	var full := Armory.is_full(_inventory)
	if full and Armory.quartermaster().is_empty() and not _asked_store:
		_asked_store = true
		await Armory.ask()
		if not is_inside_tree():
			return
	var offer := full and Armory.can_offer()
	_more_room.visible = offer
	var right := (_more_room.position.x + 10.0 - MORE_GAP) if offer else BAG_RECT.end.x
	UI.place(_bag_label, Rect2(right - 300.0, BAG_RECT.position.y, 300.0, BAG_RECT.size.y))
	UI.fit_label(_bag_label, 22, 16)


func _paint_equipped() -> void:
	var eq: Dictionary = _inventory.get("equipped", {})
	for i in _equipped.size():
		var slot: String = ["weapon", "armor", "horse"][i]
		var p: Dictionary = _equipped[i]["parts"]
		var item: Variant = eq.get(slot, null)
		var painting: TextureRect = p["painting"]
		painting.visible = item is Dictionary
		p["gem"].texture = Art.gem(str(item.get("tier", "")) if item is Dictionary else "")
		# The worn piece on its rarity's velvet; a bare slot keeps its empty tile.
		ItemGround.in_gear_tile(painting, p["tile"], "family/gear_tile_empty",
			str(item.get("tier", "common")) if item is Dictionary else "")
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
		built["parts"]["btn_forge"].pressed.connect(_forge.bind(i))
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
		_paint_forge(p["btn_forge"], it)
		var frame: TextureRect = c["frame"]
		frame.texture = Art.tex("inventory/frame_" + tier)
		ItemGround.in_ringed_tile(p["painting"], frame, Rect2(frame.position, frame.size), tier)
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


## THE FORGE -- three pieces of one slot and one rank, and gold, make one of the
## rank above (forge.json).
##
## Which three is the SERVER'S offer, ids and all (ItemView.forge): the fee
## follows the best MARK of the three, so choosing them is part of pricing the
## work, and the two the lord gives up are always the plainest they have. The
## odds are the server's too, and they are on the screen before the tap --
## every one of them.
##
## The tap opens the owner's painted anvil (scenes/pages/forge_page.gd,
## art/reference/forge.png), which shows all of that instead of writing it out:
## the three pieces on their sockets, the rank that comes out in its own light,
## the fee beside the coin and the chance on its plate. What this does is refuse
## the tap when the anvil has nothing to offer -- the page never opens on an
## empty socket.
func _forge(i: int) -> void:
	var it := _item_at(i)
	if _busy or it.is_empty():
		return
	var offer: Variant = it.get("forge", null)
	var f: Dictionary = _inventory.get("forge", {})
	if not (offer is Dictionary):
		GameState.action_failed.emit("This piece cannot be forged into anything better.")
		return
	var o: Dictionary = offer
	var ids: Array = o.get("items", [])
	var need := int(f.get("pieces", 3))
	if ids.size() < need:
		GameState.action_failed.emit("The anvil takes %d free %s %s. You have %d." % [
			need, str(it.get("tier", "")), str(it.get("slot", "")), int(o.get("have", 0))])
		return
	ForgePage.open(self, self, it, o, f, _inventory.get("items", []))


func _sell(i: int) -> void:
	var it := _item_at(i)
	if _busy or it.is_empty():
		return
	if not await Dialog.ask(self, {"title": "Sell %s?" % str(it.get("name", "")),
			"body": "For %s gold. This cannot be undone." % UI.grouped(int(it.get("sell_price", 0))), "confirm_text": "Sell", "danger": true}):
		return
	await _post("/v1/inventory/sell", {"item_id": str(it.get("id", ""))})


## FORGE on a card: lit when the bag holds enough of that slot and rank to make
## one, dim when it does not -- and gone entirely on a piece at the top of the
## ladder, where there is nothing above it to forge into.
func _paint_forge(b: BaseButton, it: Dictionary) -> void:
	var offer: Variant = it.get("forge", null)
	var can := offer is Dictionary and (offer as Dictionary).get("items", []) != null \
		and ((offer as Dictionary).get("items", []) as Array).size() > 0
	var worn := bool(it.get("equipped", false)) or str(it.get("equipped_on", "")) != ""
	b.visible = offer is Dictionary and not worn
	b.modulate = Color.WHITE if can else Color(0.55, 0.55, 0.55)
	# The button is never made unpressable: a dim FORGE that says what is
	# missing teaches the rule, and one that swallows the tap teaches nothing.


## Held until the reload is in, so a second tap lands on the new list.
func _post(path: String, body: Dictionary) -> Api.Response:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	if res.ok:
		await _load()
	_busy = false
	return res


## The Collection: the wall of every design, and what in the bags it would take.
func _open_collection() -> void:
	if _busy:
		return
	var page: GDScript = load("res://scenes/pages/collection_page.gd")
	var sheet: Control = page.open(self, _inventory)
	sheet.closed.connect(func() -> void: _load())
