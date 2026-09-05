extends VBoxContainer
## The Kingdom: your realm's roster, treasury and shared upgrades.
##
## Opened from the Keep rather than given its own rail slot, because a player
## without a kingdom has almost nothing to look at here, and a rail icon that is
## empty for the first twelve levels teaches the wrong thing about the game.

signal closed

enum Mode { OVERVIEW, MEMBERS, UPGRADES }

var _kv: Dictionary = {}
var _mode: int = Mode.OVERVIEW
var _list: VBoxContainer
var _header: Label
var _tabs: HBoxContainer
var _busy := false


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	add_child(top)

	var back := UI.ghost_button("< Keep", 15)
	back.custom_minimum_size = Vector2(84, 34)
	back.pressed.connect(func() -> void: closed.emit())
	top.add_child(back)

	_header = UI.label("Loading…", 15, Palette.GOLD)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(_header)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 4)
	add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	# Dev-only: land on a specific sub-tab for a capture.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-realm-tab" and i + 1 < args.size():
			match args[i + 1]:
				"members": _mode = Mode.MEMBERS
				"upgrades": _mode = Mode.UPGRADES

	_reload()


func _reload() -> void:
	var res: Api.Response = await Api.get_json("/v1/kingdom")
	if not res.ok:
		_header.text = res.error
		return
	_kv = res.data
	_rebuild()


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	for c in _tabs.get_children():
		c.queue_free()

	if not bool(_kv.get("in_kingdom", false)):
		_build_landless()
		return

	var k: Dictionary = _kv.get("kingdom", {})
	_header.text = "%s  [%s]" % [str(k.get("name", "")), str(k.get("tag", ""))]

	for entry in [[Mode.OVERVIEW, "Realm"], [Mode.MEMBERS, "Lords"], [Mode.UPGRADES, "Works"]]:
		var b := UI.ghost_button(str(entry[1]), 14)
		b.custom_minimum_size = Vector2(0, 32)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var active: bool = _mode == int(entry[0])
		b.add_theme_stylebox_override("normal",
			UI.panel_box(Palette.PANEL_HIGH if active else Palette.PANEL, Color.TRANSPARENT))
		b.add_theme_color_override("font_color", Palette.GOLD if active else Palette.TEXT_DIM)
		var m: int = int(entry[0])
		b.pressed.connect(func() -> void:
			_mode = m
			_rebuild())
		_tabs.add_child(b)

	match _mode:
		Mode.MEMBERS: _build_members()
		Mode.UPGRADES: _build_upgrades()
		_: _build_overview()


func _build_landless() -> void:
	_header.text = "You hold no banner"

	for inv in _kv.get("invites", []):
		var card := _card("%s [%s]" % [str(inv.get("name", "")), str(inv.get("tag", ""))],
			"has invited you to join", Palette.SUCCESS)
		var accept := UI.button("ACCEPT", 15)
		accept.custom_minimum_size = Vector2(110, 40)
		accept.pressed.connect(_accept.bind(str(inv.get("kingdom_id", ""))))
		(card.get_child(0) as HBoxContainer).add_child(accept)
		_list.add_child(card)

	var cost := int(_kv.get("found_cost", 0))
	var need := int(_kv.get("found_level", 0))
	var level := int(GameState.player().get("level", 1))
	var can := level >= need and GameState.display_gold() >= cost
	var found := _card("Found your own kingdom",
		"%s gold and level %d" % [UI.number(cost), need],
		Palette.GOLD if can else Palette.TEXT_FAINT)
	if can:
		var b := UI.button("FOUND", 15)
		b.custom_minimum_size = Vector2(110, 40)
		b.pressed.connect(_found)
		(found.get_child(0) as HBoxContainer).add_child(b)
	_list.add_child(found)

	_list.add_child(UI.spacer(8))
	_list.add_child(UI.label("GREATEST REALMS", 12, Palette.TEXT_FAINT))
	_build_leaderboard()


func _build_overview() -> void:
	var k: Dictionary = _kv.get("kingdom", {})
	var me: Dictionary = _kv.get("me", {})

	_list.add_child(_card("Level %d" % int(k.get("level", 1)),
		"%s / %s kingdom xp" % [UI.number(int(k.get("xp", 0))), UI.number(int(k.get("xp_to_next", 0)))],
		Palette.GOLD))
	_list.add_child(_card("Treasury", "%s gold  ·  %d of %d lords" % [
		UI.number(int(str(k.get("treasury", "0")))),
		int(k.get("members", 0)), int(k.get("member_cap", 0))], Palette.GOLD))
	_list.add_child(_card("Renown", "%s  ·  you are %s" % [
		UI.number(int(k.get("reputation", 0))), str(me.get("role", "member"))], Palette.SUCCESS))

	var remaining := int(me.get("remaining_today", 0))
	var donate_card := _card("Donate to the treasury",
		"%s of %s left today  ·  %d favour held" % [
			UI.number(remaining), UI.number(int(me.get("daily_cap", 0))),
			int(me.get("favour", 0))],
		Palette.GOLD if remaining > 0 else Palette.TEXT_FAINT)
	if remaining > 0:
		var b := UI.button("GIVE", 15)
		b.custom_minimum_size = Vector2(100, 40)
		b.disabled = GameState.display_gold() <= 0
		b.pressed.connect(_donate.bind(remaining))
		(donate_card.get_child(0) as HBoxContainer).add_child(b)
	_list.add_child(donate_card)

	_list.add_child(UI.spacer(8))
	_list.add_child(UI.label("GREATEST REALMS", 12, Palette.TEXT_FAINT))
	_build_leaderboard()


func _build_leaderboard() -> void:
	var rank := 0
	for k in _kv.get("leaderboard", []):
		rank += 1
		var mine: bool = _kv.get("kingdom") != null and str(k.get("id", "")) == str(_kv["kingdom"].get("id", ""))
		var row := _card("%d.  %s [%s]" % [rank, str(k.get("name", "")), str(k.get("tag", ""))],
			"renown %s  ·  level %d  ·  %d lords" % [
				UI.number(int(k.get("reputation", 0))), int(k.get("level", 1)), int(k.get("members", 0))],
			Palette.GOLD if mine else Palette.TEXT_DIM)
		_list.add_child(row)


func _build_members() -> void:
	for m in _kv.get("members", []):
		var role := str(m.get("role", "member"))
		var colour := Palette.GOLD if role == "king" else \
			(Palette.SUCCESS if role == "marshal" else Palette.TEXT_DIM)
		_list.add_child(_card(str(m.get("name", "")),
			"%s  ·  level %d  ·  gave %s" % [role, int(m.get("level", 1)),
				UI.number(int(str(m.get("donated", "0"))))],
			colour))


func _build_upgrades() -> void:
	var treasury := int(str(_kv.get("kingdom", {}).get("treasury", "0")))
	var role := str(_kv.get("me", {}).get("role", "member"))
	var may_spend := role == "king" or role == "marshal"

	for u in _kv.get("upgrades", []):
		var row := EstateRow.new(str(u.get("id", "")))
		var lv := int(u.get("level", 0))
		var effect := "" if lv == 0 else _describe(str(u.get("bucket", "")), int(u.get("effect_now", 0)))
		_list.add_child(row)
		row.refresh(str(u.get("name", "")), str(u.get("blurb", "")),
			lv, int(u.get("max_level", 0)), effect, int(u.get("next_cost", 0)),
			false, "", treasury >= int(u.get("next_cost", 0)), false)
		row.disabled = row.disabled or not may_spend or treasury < int(u.get("next_cost", 0))
		if may_spend:
			row.pressed.connect(_buy_upgrade.bind(str(u.get("id", ""))))

	if not may_spend:
		_list.add_child(UI.label("Only the king and marshals may spend the treasury.",
			13, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))


func _describe(bucket: String, amount: int) -> String:
	if bucket == "member_cap_flat":
		return "now +%d lords" % amount
	return "now +%.0f%%" % (amount / 100.0)


func _card(title: String, sub: String, accent: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Color.TRANSPARENT))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	p.add_child(row)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)
	col.add_child(UI.label(title, 16, accent))
	var s := UI.label(sub, 12, Palette.TEXT_FAINT)
	s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(s)
	return p


func _post(path: String, body: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json(path, body)
	_busy = false
	if not res.ok:
		GameState.action_failed.emit(res.error)
	else:
		_kv = res.data
	await GameState.refresh()
	_rebuild()


func _accept(kingdom_id: String) -> void:
	await _post("/v1/kingdom/accept", {"kingdom_id": kingdom_id})


func _donate(amount: int) -> void:
	var give := mini(amount, GameState.display_gold())
	if give <= 0:
		return
	await _post("/v1/kingdom/donate",
		{"amount": give, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})


func _buy_upgrade(id: String) -> void:
	await _post("/v1/kingdom/upgrade", {"id": id})


func _found() -> void:
	# A generated name keeps founding to one tap. Renaming can come later; a text
	# field here would put a keyboard between the player and the moment.
	var n := str(GameState.player().get("username", "Realm"))
	await _post("/v1/kingdom/found", {
		"name": "House " + n, "tag": n.substr(0, 3).to_upper(),
		"action_seq": int(GameState.player().get("action_seq", 0)) + 1})
