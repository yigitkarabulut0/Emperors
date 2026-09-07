extends Control
## FAMILY — the hero: identity, stats, gear, and the upgrade ledger.
## Layout: layout/family.json. Estates (holdings), the Treasury and the Legacy
## fold into the upgrade list below the GRANARY card, in the same card.

const SCREEN := "family"
const PITCH := 262.0
const BUCKET_LABEL := {
	"collect_income_bp": "COLLECT INCOME", "tax_income_bp": "ESTATE INCOME", "xp_bp": "HERO XP",
	"energy_regen_bp": "ENERGY REGEN", "max_energy_flat": "MAX ENERGY", "soldier_atk_bp": "SOLDIER ATTACK",
	"soldier_def_bp": "SOLDIER DEFENCE", "soldier_spd_bp": "SOLDIER SPEED", "shop_discount_bp": "SHOP DISCOUNT",
	"steal_cap_bp": "RAID STEAL CAP", "ransom_bp": "RANSOM",
}
const SLOT_ART := {"weapon": "items/family_sword", "armor": "items/family_armor", "horse": "items/family_horse"}

var _scroll: ScrollContainer
var _content: Control
var _ui: Dictionary = {}
var _identity: Dictionary
var _stats: Dictionary
var _gear: Dictionary
var _cards: Array = []            ## [{node, parts, kind, data}]
var _footer: Control
var _ground: Control
var _points_label: Label

var _inventory: Dictionary = {}
var _estates: Dictionary = {}
var _legacy: Dictionary = {}
var _loaded_ms := -100000
var _busy := false


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 14
	add_child(_scroll)
	_content = Control.new()
	_content.custom_minimum_size = Vector2(941, 1672)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)

	_ui = Layout.build(SCREEN, _content)
	# The measured layout carries a nested scroll for the upgrades and a portrait
	# source; the page itself scrolls, and cards are laid out below.
	for drop in ["upgrades", "portrait_source"]:
		if _ui.has(drop):
			_ui[drop].queue_free()
			_ui.erase(drop)
	_identity = _ui["identity"][0]["parts"]
	_stats = _ui["stats"][0]["parts"]
	_gear = _ui["gear"][0]["parts"]
	_footer = _ui["footer"]
	_ground = _ui["ground_bottom"]

	_identity["edit"].pressed.connect(_rename)
	_gear["equip_best"].pressed.connect(_equip_best)
	for slot in ["weapon", "armor", "horse"]:
		var tile: Control = _gear_tile(slot)["node"]
		var hit := UI.hotspot(Rect2(Vector2.ZERO, tile.size))
		hit.pressed.connect(_choose_gear.bind(slot))
		tile.add_child(hit)
	# Stat points: tapping a cell spends one there once the server has granted any.
	var strip: Control = _ui["stats"][0]["node"]
	for entry in [["attack", Rect2(0, 0, 250, 190)], ["defense", Rect2(250, 0, 250, 190)], ["energy", Rect2(500, 0, 252, 190)]]:
		var hit := UI.hotspot(entry[1])
		hit.pressed.connect(_spend_point.bind(entry[0]))
		strip.add_child(hit)
	_points_label = UI.label("", 22, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_points_label, Rect2(0, -2, 752, 30))
	_points_label.visible = false
	strip.add_child(_points_label)


func refresh() -> void:
	_paint_identity()
	if Time.get_ticks_msec() - _loaded_ms > 3000:
		_load()
	else:
		_paint_all()


func _load() -> void:
	_loaded_ms = Time.get_ticks_msec()
	var inv: Api.Response = await Api.get_json("/v1/inventory")
	if inv.ok:
		_inventory = inv.data
	var est: Api.Response = await Api.get_json("/v1/estates")
	if est.ok:
		_estates = est.data
	var leg: Api.Response = await Api.get_json("/v1/legacy")
	if leg.ok:
		_legacy = leg.data
	_paint_all()


func _paint_all() -> void:
	_paint_identity()
	_paint_stats()
	_paint_gear()
	_paint_cards()


# --- identity -----------------------------------------------------------------------

func _paint_identity() -> void:
	var p := GameState.player()
	var name_label: Label = _identity["name"]
	var uname := str(p.get("username", "")).to_upper()
	name_label.text = uname
	# The plate's name slot fits about eight letters at the painting's size.
	name_label.label_settings.font_size = 60 if uname.length() <= 8 else (46 if uname.length() <= 11 else 34)
	_identity["level"].text = "LEVEL %d" % int(p.get("level", 1))
	var need := GameState.xp_to_next()
	var xp := GameState.display_xp()
	if need > 0:
		_identity["xp_text"].text = "%s / %s XP" % [UI.grouped(xp), UI.grouped(need)]
		Layout.set_fill(_identity["xp_fill"], float(xp) / float(need))
	else:
		_identity["xp_text"].text = "LEVEL CAP"
		Layout.set_fill(_identity["xp_fill"], 1.0)
	var pts := int(p.get("stat_points_unspent", 0))
	_points_label.visible = pts > 0
	_points_label.text = "%d POINT%s TO SPEND · TAP A STAT" % [pts, "" if pts == 1 else "S"]


func _paint_stats() -> void:
	var hero: Dictionary = _inventory.get("hero", {})
	_stats["attack"].text = UI.grouped(int(hero.get("attack", 0)))
	_stats["defence"].text = UI.grouped(int(hero.get("defense", 0)))
	_stats["power"].text = UI.grouped(int(hero.get("power", 0)))


func _paint_gear() -> void:
	var eq: Dictionary = _inventory.get("equipped", {})
	for slot in ["weapon", "armor", "horse"]:
		var parts: Dictionary = _gear_tile(slot)["parts"]
		var item: Variant = eq.get(slot, null)
		if item is Dictionary:
			parts["art"].texture = Art.tex(SLOT_ART[slot])
			parts["lv"].text = "Lv. %d" % int(item.get("ilvl", 1))
			parts["art"].modulate = Color.WHITE
		else:
			parts["art"].texture = Art.tex("family/gear_tile_empty")
			parts["lv"].text = ""
			parts["art"].modulate = Color(0.8, 0.8, 0.8)


## The gear tiles are nested templates with one instance each.
func _gear_tile(slot: String) -> Dictionary:
	var wrap: Control = _gear["tile_" + slot]
	if wrap.has_meta("instances"):
		return wrap.get_meta("instances")[0]
	return {"node": wrap, "parts": wrap.get_meta("parts", {})}


# --- the card ledger --------------------------------------------------------------------

func _card_specs() -> Array:
	var out: Array = []
	for u in _estates.get("upgrades", []):
		out.append({"kind": "upgrade", "data": u})
	out.append({"kind": "treasury", "data": {}})
	for h in _estates.get("holdings", []):
		out.append({"kind": "holding", "data": h})
	out.append({"kind": "legacy", "data": _legacy})
	return out


func _paint_cards() -> void:
	var specs := _card_specs()
	var tpl := Layout.find(SCREEN, "upgrade_card")
	var origin := Layout.rect_of(tpl).position
	while _cards.size() < specs.size():
		var built := Layout.instantiate(tpl)
		_content.add_child(built["node"])
		var i := _cards.size()
		built["node"].position = origin + Vector2(0, i * PITCH)
		built["parts"]["button"].pressed.connect(_on_card_button.bind(i))
		# Live button text over the erased plate (the MAX LEVEL plate keeps its label).
		var btxt := UI.label("", 26, UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(btxt, Rect2(Layout.rect_of(Layout.find(SCREEN, "button")).position, Vector2(326, 90)))
		btxt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		built["node"].add_child(btxt)
		built["btxt"] = btxt
		_cards.append(built)
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		if i >= specs.size():
			c["node"].visible = false
			continue
		c["node"].visible = true
		c["kind"] = specs[i]["kind"]
		c["data"] = specs[i]["data"]
		_paint_card(c)
	var bottom := origin.y + specs.size() * PITCH
	_ground.position.y = bottom - 10
	_footer.position.y = bottom + 8
	_content.custom_minimum_size = Vector2(941, maxf(1672, bottom + 120))


func _paint_card(c: Dictionary) -> void:
	var p: Dictionary = c["parts"]
	var d: Dictionary = c["data"]
	var level := int(GameState.player().get("level", 1))
	p["art"].texture = Art.tex("family/granary_art")
	p["icon"].texture = Art.tex("icons/gold_stack")
	match c["kind"]:
		"upgrade":
			p["name"].text = str(d.get("name", "")).to_upper()
			p["level"].text = "LEVEL %d" % int(d.get("level", 0))
			var bucket := str(d.get("bucket", ""))
			var effect := int(d.get("effect_now", 0))
			var label: String = BUCKET_LABEL.get(bucket, bucket.replace("_bp", "").replace("_", " ").to_upper())
			if bucket.ends_with("_flat"):
				p["bonus"].text = "+%d %s" % [effect, label]
			else:
				p["bonus"].text = "+%s%% %s" % [_pct(effect), label]
			_set_button(c, bool(d.get("maxed", false)), "UPGRADE   %s" % UI.short_number(int(d.get("next_cost", 0))), false)
		"holding":
			p["name"].text = str(d.get("name", "")).to_upper()
			p["level"].text = "LEVEL %d" % int(d.get("level", 0))
			var per_hour := int(d.get("yield_per_hour_milli", 0)) / 1000
			var next_add := int(d.get("yield_per_level_milli", 0)) / 1000
			if int(d.get("level", 0)) > 0:
				p["bonus"].text = "+%s GOLD / HOUR" % UI.grouped(per_hour)
			else:
				p["bonus"].text = "NEXT: +%s GOLD / HOUR" % UI.grouped(next_add)
			var locked := level < int(d.get("unlock_level", 1))
			if locked:
				_set_button(c, false, "UNLOCKS AT LEVEL %d" % int(d.get("unlock_level", 1)), true)
			else:
				_set_button(c, bool(d.get("maxed", false)), "UPGRADE   %s" % UI.short_number(int(d.get("next_cost", 0))), false)
		"treasury":
			p["name"].text = "ROYAL TREASURY"
			p["level"].text = "VAULT  %s" % UI.short_number(int(str(GameState.player().get("treasury", "0"))))
			var tax := int(_estates.get("tax", {}).get("per_hour_milli", 0)) / 1000
			p["bonus"].text = "+%s GOLD / HOUR · 10%% DEPOSIT FEE" % UI.grouped(tax)
			_set_button(c, false, "DEPOSIT / WITHDRAW", false)
		"legacy":
			p["name"].text = "LEGACY"
			p["level"].text = "STACKS %d / %d" % [int(d.get("stacks", 0)), int(d.get("max_stacks", 0))]
			p["bonus"].text = "+%s%% INCOME · NEXT +%s%%" % [_pct(int(d.get("income_bp", 0))), _pct(int(d.get("next_bp", 0)))]
			if bool(d.get("available", false)):
				_set_button(c, false, "BEGIN A LEGACY", false)
			else:
				_set_button(c, false, "AT LEVEL %d" % int(d.get("level_cap", 60)), true)


func _set_button(c: Dictionary, maxed: bool, text: String, disabled: bool) -> void:
	var b: TextureButton = c["parts"]["button"]
	var t: Label = c["btxt"]
	if maxed:
		b.texture_normal = Art.tex("family/btn_max_level")
		t.text = ""
		b.disabled = true
		b.modulate = Color.WHITE
	else:
		b.texture_normal = Art.tex("family/btn_upgrade_plate")
		t.text = text
		b.disabled = disabled
		b.modulate = Color(0.6, 0.6, 0.6) if disabled else Color.WHITE
	t.label_settings.font_size = 26 if text.length() <= 18 else 21


func _pct(bp: int) -> String:
	if bp % 100 == 0:
		return str(bp / 100)
	return "%.1f" % (bp / 100.0)


func _on_card_button(i: int) -> void:
	if _busy or i >= _cards.size():
		return
	var c: Dictionary = _cards[i]
	var d: Dictionary = c["data"]
	match c["kind"]:
		"upgrade":
			if not await Dialog.ask(self, {"title": "Upgrade %s?" % str(d.get("name", "")),
					"body": "Level %d → %d for %s gold." % [int(d.get("level", 0)), int(d.get("level", 0)) + 1, UI.grouped(int(d.get("next_cost", 0)))],
					"confirm_text": "Upgrade"}):
				return
			await _act("/v1/estates/upgrade", {"id": str(d.get("id", ""))})
		"holding":
			if not await Dialog.ask(self, {"title": "Expand %s?" % str(d.get("name", "")),
					"body": "Level %d → %d for %s gold." % [int(d.get("level", 0)), int(d.get("level", 0)) + 1, UI.grouped(int(d.get("next_cost", 0)))],
					"confirm_text": "Expand"}):
				return
			await _act("/v1/estates/holding", {"id": str(d.get("id", ""))})
		"treasury":
			var r := await Dialog.prompt_amount(self, {"title": "Royal Treasury",
				"body": "On hand: %s   Vault: %s\nDeposits cost 10%%. Vault gold cannot be stolen." % [
					UI.grouped(GameState.display_gold()), UI.grouped(int(str(GameState.player().get("treasury", "0"))))],
				"placeholder": "Amount of gold", "confirm_text": "Deposit", "second_text": "Withdraw"})
			if r["action"] == "" or int(r["value"]) <= 0:
				return
			await _act("/v1/treasury/" + ("deposit" if r["action"] == "confirm" else "withdraw"), {"amount": int(r["value"])})
		"legacy":
			if not await Dialog.ask(self, {"title": "Begin a Legacy?",
					"body": "Your level, gold and gear are set aside for a permanent +%s%% income. This cannot be undone." % _pct(int(d.get("next_bp", 0))),
					"confirm_text": "Begin", "danger": true}):
				return
			await _act("/v1/legacy/begin", {})


func _act(path: String, body: Dictionary) -> void:
	_busy = true
	var res: Api.Response = await GameState.act(path, body)
	_busy = false
	if res.ok:
		await _load()


# --- stats, gear, name ---------------------------------------------------------------------

func _spend_point(stat: String) -> void:
	if _busy or int(GameState.player().get("stat_points_unspent", 0)) <= 0:
		return
	var names := {"attack": "Attack", "defense": "Defence", "energy": "Max Energy"}
	if not await Dialog.ask(self, {"title": "Spend a point on %s?" % names[stat],
			"body": "Stat points cannot be moved once they are spent.", "confirm_text": "Spend"}):
		return
	var body := {"energy": 0, "attack": 0, "defense": 0}
	body[stat] = 1
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/stats/spend", _with_seq(body))
	_busy = false
	if res.ok:
		GameState.adopt(res.data)
		GameState.changed.emit()
		await _load()
	else:
		GameState.action_failed.emit(res.error)


func _with_seq(body: Dictionary) -> Dictionary:
	var b := body.duplicate()
	b["action_seq"] = int(GameState.player().get("action_seq", 0)) + 1
	return b


func _equip_best() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/army/autoequip", _with_seq({"scope": "hero"}))
	_busy = false
	if res.ok:
		var n := int(res.data.get("equipped", 0))
		GameState.action_failed.emit("Nothing better to wear" if n == 0 else "Equipped %d item%s" % [n, "" if n == 1 else "s"])
		await GameState.refresh()
		await _load()
	else:
		GameState.action_failed.emit(res.error)


func _choose_gear(slot: String) -> void:
	if _busy:
		return
	var options: Array = []
	for it in _inventory.get("items", []):
		if str(it.get("slot", "")) != slot or it.get("equipped_by", null) != null:
			continue
		options.append({"id": str(it.get("id", "")), "label": str(it.get("name", "")),
			"sub": "%s · Power %s" % [str(it.get("tier", "")).to_upper(), UI.grouped(int(it.get("power", 0)))]})
	var worn: Variant = _inventory.get("equipped", {}).get(slot, null)
	if worn is Dictionary:
		options.append({"id": "__unequip", "label": "Unequip %s" % str(worn.get("name", ""))})
	if options.is_empty():
		GameState.action_failed.emit("Nothing to equip in this slot")
		return
	var pick := await Dialog.choose(self, {"title": slot.capitalize(), "options": options})
	if pick == "":
		return
	_busy = true
	var res: Api.Response
	if pick == "__unequip":
		res = await Api.post_json("/v1/inventory/unequip", _with_seq({"item_id": str(worn.get("id", ""))}))
	else:
		res = await Api.post_json("/v1/inventory/equip", _with_seq({"item_id": pick}))
	_busy = false
	if res.ok:
		await GameState.refresh()
		await _load()
	else:
		GameState.action_failed.emit(res.error)


## The quill beside the name. A new name costs diamonds; the price is the
## server's (snapshot.prices) and the rules for what a name may be are the
## server's too -- this screen only asks and shows the answer.
func _rename() -> void:
	if _busy:
		return
	var price := int(GameState.snapshot.get("prices", {}).get("rename_diamonds", 0))
	var have := int(GameState.player().get("diamonds", 0))
	var r: Dictionary = await Dialog.prompt_text(self, {
		"title": "Change your name",
		"body": "3 to 16 letters, digits or underscore.\nCosts %d diamonds. You have %d." % [price, have],
		"placeholder": str(GameState.player().get("username", "")),
		"max_length": 16,
		"confirm_text": "Rename for %d diamonds" % price,
	})
	if str(r.get("action", "")) != "confirm":
		return
	var name := str(r.get("text", ""))
	if name == "":
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/profile/rename", _with_seq({"name": name}))
	_busy = false
	if res.ok:
		GameState.adopt(res.data)
		GameState.changed.emit()
	else:
		GameState.action_failed.emit(res.error)
