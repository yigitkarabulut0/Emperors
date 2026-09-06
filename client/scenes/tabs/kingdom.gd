extends VBoxContainer
## The Kingdom: your realm's roster, treasury and shared upgrades.
##
## Opened from the Keep rather than given its own rail slot, because a player
## without a kingdom has almost nothing to look at here, and a rail icon that is
## empty for the first twelve levels teaches the wrong thing about the game.


enum Mode { OVERVIEW, MEMBERS, UPGRADES, RANKS }

## Which board is showing under Ranks.
const BOARDS := [["might", "Might"], ["level", "Level"], ["wealth", "Wealth"]]
var _board := "might"
var _ranks: Dictionary = {}

var _kv: Dictionary = {}
var _mode: int = Mode.OVERVIEW
var _list: VBoxContainer
var _header: Label
var _tabs: HBoxContainer
var _busy := false
var _action_hint: Label


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	add_child(top)

	_header = UI.label("Loading…", UI.F_CAPTION, Palette.GOLD_INK)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(_header)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 4)
	add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Lists follow your finger. Godot's own touch scrolling is gated behind

	# is_touchscreen_available() and is eaten by the buttons the list is made of.

	DragScroll.install(scroll)
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

	_refresh_hint()

	# Ranks is the one sub-tab a landless player can use, and the one that gives
	# them something to want. Built before the in_kingdom check so it is reachable
	# from the forty levels somebody may spend without a banner.
	var entries: Array = []
	if bool(_kv.get("in_kingdom", false)):
		entries = [[Mode.OVERVIEW, "Realm"], [Mode.MEMBERS, "Lords"],
			[Mode.UPGRADES, "Works"], [Mode.RANKS, "Ranks"]]
	else:
		entries = [[Mode.RANKS, "Ranks"]]
		if _mode != Mode.RANKS:
			_build_tabs(entries)
			_build_landless()
			return

	if not bool(_kv.get("in_kingdom", false)):
		_build_tabs(entries)
		_build_ranks()
		return

	var k: Dictionary = _kv.get("kingdom", {})
	_header.text = "%s  [%s]" % [str(k.get("name", "")), str(k.get("tag", ""))]

	for entry in entries:
		var b := UI.ghost_button(str(entry[1]), UI.F_BODY)
		b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var active: bool = _mode == int(entry[0])
		b.add_theme_stylebox_override("normal",
			UI.card_box(active))
		b.add_theme_color_override("font_color", Palette.GOLD_INK if active else Palette.TEXT_DIM)
		var m: int = int(entry[0])
		b.pressed.connect(func() -> void:
			_mode = m
			_rebuild())
		_tabs.add_child(b)

	match _mode:
		Mode.RANKS: _build_ranks()
		Mode.MEMBERS: _build_members()
		Mode.UPGRADES: _build_upgrades()
		_: _build_overview()


func _build_landless() -> void:
	_header.text = "You hold no banner"

	for inv in _kv.get("invites", []):
		var card := _card("%s [%s]" % [str(inv.get("name", "")), str(inv.get("tag", ""))],
			"has invited you to join", Palette.SUCCESS)
		var accept := UI.button("ACCEPT", UI.F_BODY)
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
		Palette.GOLD_INK if can else Palette.TEXT_FAINT)
	if can:
		var b := UI.button("FOUND", UI.F_BODY)
		b.custom_minimum_size = Vector2(110, 40)
		b.pressed.connect(_found)
		(found.get_child(0) as HBoxContainer).add_child(b)
	_list.add_child(found)

	_list.add_child(UI.spacer(8))
	_list.add_child(UI.label("GREATEST REALMS", UI.F_MICRO, Palette.TEXT_FAINT))
	_build_leaderboard()


func _build_overview() -> void:
	var k: Dictionary = _kv.get("kingdom", {})
	var me: Dictionary = _kv.get("me", {})

	_list.add_child(_card("Level %d" % int(k.get("level", 1)),
		"%s / %s kingdom xp" % [UI.number(int(k.get("xp", 0))), UI.number(int(k.get("xp_to_next", 0)))],
		Palette.GOLD_INK))
	_list.add_child(_card("Treasury", "%s gold  ·  %d of %d lords" % [
		UI.number(int(str(k.get("treasury", "0")))),
		int(k.get("members", 0)), int(k.get("member_cap", 0))], Palette.GOLD_INK))
	_list.add_child(_card("Renown", "%s  ·  you are %s" % [
		UI.number(int(k.get("reputation", 0))), str(me.get("role", "member"))], Palette.SUCCESS))

	var remaining := int(me.get("remaining_today", 0))
	var donate_card := _card("Donate to the treasury",
		"%s of %s left today  ·  %d favour held" % [
			UI.number(remaining), UI.number(int(me.get("daily_cap", 0))),
			int(me.get("favour", 0))],
		Palette.GOLD_INK if remaining > 0 else Palette.TEXT_FAINT)
	if remaining > 0:
		var b := UI.button("GIVE", UI.F_BODY)
		b.custom_minimum_size = Vector2(100, 40)
		b.disabled = GameState.display_gold() <= 0
		b.pressed.connect(_donate.bind(remaining))
		(donate_card.get_child(0) as HBoxContainer).add_child(b)
	_list.add_child(donate_card)

	_list.add_child(UI.spacer(8))
	_list.add_child(UI.label("GREATEST REALMS", UI.F_MICRO, Palette.TEXT_FAINT))
	_build_leaderboard()


func _build_leaderboard() -> void:
	var rank := 0
	for k in _kv.get("leaderboard", []):
		rank += 1
		var mine: bool = _kv.get("kingdom") != null and str(k.get("id", "")) == str(_kv["kingdom"].get("id", ""))
		var row := _card("%d.  %s [%s]" % [rank, str(k.get("name", "")), str(k.get("tag", ""))],
			"renown %s  ·  level %d  ·  %d lords" % [
				UI.number(int(k.get("reputation", 0))), int(k.get("level", 1)), int(k.get("members", 0))],
			Palette.GOLD_INK if mine else Palette.TEXT_DIM)
		_list.add_child(row)


func _build_members() -> void:
	var my_role := str(_kv.get("me", {}).get("role", "member"))
	var may_invite := my_role == "king" or my_role == "marshal"

	# Kingdoms are invite-only, and Invite needs a player id. Without a way to
	# turn a name into one, a founded kingdom was a dead end: you sat in it alone
	# and no one could ever join.
	if may_invite:
		_list.add_child(_invite_box())

	for m in _kv.get("members", []):
		var role := str(m.get("role", "member"))
		var colour := Palette.GOLD_INK if role == "king" else \
			(Palette.SUCCESS if role == "marshal" else Palette.TEXT_DIM)
		var card := _card(str(m.get("name", "")),
			"%s  ·  level %d  ·  gave %s" % [role, int(m.get("level", 1)),
				UI.number(int(str(m.get("donated", "0"))))],
			colour)
		_list.add_child(card)

		# Only the king may change ranks, and never their own. The button sits in
		# the card's own row, to the right of the name.
		var target := str(m.get("player_id", ""))
		if my_role == "king" and role != "king":
			var next_role := "member" if role == "marshal" else "marshal"
			var promote := UI.ghost_button(
				("Demote" if role == "marshal" else "Raise to marshal"), UI.F_CAPTION)
			promote.custom_minimum_size = Vector2(124, 34)
			promote.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			promote.pressed.connect(_set_role.bind(target, next_role))
			(card.get_child(0) as HBoxContainer).add_child(promote)

	_list.add_child(UI.spacer(8))
	var leave := UI.ghost_button("LEAVE THE KINGDOM", UI.F_CAPTION)
	leave.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	leave.add_theme_color_override("font_color", Palette.DANGER)
	leave.disabled = my_role == "king"
	leave.pressed.connect(_leave)
	_list.add_child(leave)
	if my_role == "king":
		_list.add_child(UI.label("A king cannot walk away. Raise a marshal and pass the crown first.",
			UI.F_MICRO, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))


## Search by name, then invite. Results say whether someone already holds a
## banner, because inviting them would fail and the reason should be visible
## before the tap rather than after it.
func _invite_box() -> Control:
	var card := _card("Invite a lord", "they must not already hold a banner", Palette.GOLD_DEEP)
	# _card nests a row before the text column, so the body is one level deeper.
	var col: VBoxContainer = card.get_child(0).get_child(0)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	var field := UI.line_edit("name")
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	var go := UI.button("FIND", UI.F_BODY)
	go.custom_minimum_size = Vector2(84, 40)
	row.add_child(go)

	var results := VBoxContainer.new()
	results.add_theme_constant_override("separation", 4)
	col.add_child(results)

	var run := func() -> void:
		for c in results.get_children():
			c.queue_free()
		var term := field.text.strip_edges()
		if term.length() < 2:
			results.add_child(UI.label("Type at least two letters.", UI.F_MICRO, Palette.TEXT_FAINT))
			return
		var res: Api.Response = await Api.get_json("/v1/kingdom/search?q=" + term.uri_encode())
		if not res.ok:
			results.add_child(UI.label(res.error, UI.F_MICRO, Palette.DANGER))
			return
		var found: Array = res.data.get("players", [])
		if found.is_empty():
			results.add_child(UI.label("Nobody by that name.", UI.F_MICRO, Palette.TEXT_FAINT))
			return
		for pl in found:
			results.add_child(_invite_row(pl))

	go.pressed.connect(run)
	field.text_submitted.connect(func(_t: String) -> void: run.call())
	return card


func _invite_row(pl: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var face := TextureRect.new()
	face.texture = ArtRegistry.portrait(str(pl.get("avatar", "knight")))
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.custom_minimum_size = Vector2(34, 34)
	row.add_child(face)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	col.add_child(UI.label(str(pl.get("name", "")), UI.F_CAPTION, Palette.TEXT))
	col.add_child(UI.label("level %d" % int(pl.get("level", 1)), UI.F_MICRO, Palette.TEXT_FAINT))
	row.add_child(col)

	if bool(pl.get("in_kingdom", false)):
		row.add_child(UI.label("already sworn", UI.F_MICRO, Palette.TEXT_FAINT))
	else:
		var b := UI.ghost_button("INVITE", UI.F_CAPTION)
		b.custom_minimum_size = Vector2(84, 34)
		b.pressed.connect(_invite.bind(str(pl.get("player_id", ""))))
		row.add_child(b)
	return row


func _invite(player_id: String) -> void:
	await _post("/v1/kingdom/invite", {"player_id": player_id})


func _set_role(player_id: String, role: String) -> void:
	await _post("/v1/kingdom/role", {"player_id": player_id, "role": role})


func _leave() -> void:
	if not await Confirm.ask(self, {
			"title": "Leave the kingdom?",
			"body": "You keep nothing you donated, and rejoining needs a new invitation.",
			"confirm_text": "Leave", "danger": true}):
		return
	await _post("/v1/kingdom/leave", {})


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
			UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))


func _describe(bucket: String, amount: int) -> String:
	if bucket == "member_cap_flat":
		return "now +%d lords" % amount
	return "now +%.0f%%" % (amount / 100.0)


func _card(title: String, sub: String, accent: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.card_box())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	p.add_child(row)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)
	col.add_child(UI.label(title, 16, accent))
	var s := UI.label(sub, UI.F_MICRO, Palette.TEXT_FAINT)
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
	if not await Confirm.ask(self, {
			"title": "Give to the treasury?",
			"body": "Donated gold belongs to the kingdom. You cannot take it back.",
			"cost": {"amount": give, "currency": "gold"},
			"confirm_text": "Give", "danger": true}):
		return
	await _post("/v1/kingdom/donate",
		{"amount": give, "action_seq": int(GameState.player().get("action_seq", 0)) + 1})


func _buy_upgrade(id: String) -> void:
	var name := id
	for u in _kv.get("upgrades", []):
		if str(u.get("id", "")) == id:
			name = str(u.get("name", id))
	if not await Confirm.ask(self, {
			"title": "Commission %s?" % name,
			"body": "Paid from the kingdom's treasury, on everyone's behalf.",
			"confirm_text": "Commission"}):
		return
	await _post("/v1/kingdom/upgrade", {"id": id})


func _found() -> void:
	# A generated name keeps founding to one tap. Renaming can come later; a text
	# field here would put a keyboard between the player and the moment.
	var n := str(GameState.player().get("username", "Realm"))
	if not await Confirm.ask(self, {
			"title": "Found House %s?" % n,
			"body": "You become its king, and the cost is paid now.",
			"cost": {"amount": int(_kv.get("found_cost", 0)), "currency": "gold"},
			"confirm_text": "Found it"}):
		return
	await _post("/v1/kingdom/found", {
		"name": "House " + n, "tag": n.substr(0, 3).to_upper(),
		"action_seq": int(GameState.player().get("action_seq", 0)) + 1})


## A section of its own now, so it needs an action bar like the rest. It stays
## deliberately empty: every action on this screen belongs to the row it acts on
## -- accept THIS invitation, invite THIS person, buy THIS work.
func mount_action_bar(host: Control) -> void:
	var l := UI.label("", UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	host.add_child(l)
	_action_hint = l
	_refresh_hint()


func _refresh_hint() -> void:
	if _action_hint == null:
		return
	if not bool(_kv.get("in_kingdom", false)):
		_action_hint.text = "Found a house, or wait to be invited to one"
	else:
		_action_hint.text = "Realm · Lords · Works"


## The sub-tab strip, extracted so the landless path can draw it too.
func _build_tabs(entries: Array) -> void:
	for entry in entries:
		var b := UI.ghost_button(str(entry[1]), UI.F_BODY)
		b.custom_minimum_size = Vector2(0, UI.TAP_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var active: bool = _mode == int(entry[0])
		b.add_theme_stylebox_override("normal", UI.card_box(active))
		b.add_theme_color_override("font_color",
			Palette.GOLD_INK if active else Palette.TEXT_DIM)
		var m: int = int(entry[0])
		b.pressed.connect(func() -> void:
			_mode = m
			_rebuild())
		_tabs.add_child(b)


## Three boards, because one board makes one build correct.
##
## Might rewards investing in the army, Level rewards playing, Wealth rewards not
## being robbed — and the three top tens are rarely the same people.
func _build_ranks() -> void:
	_header.text = "THE REALM'S RECKONING"

	var picker := HBoxContainer.new()
	picker.add_theme_constant_override("separation", 4)
	_list.add_child(picker)
	for entry in BOARDS:
		var b := UI.ghost_button(str(entry[1]), UI.F_CAPTION)
		b.custom_minimum_size = Vector2(0, 36)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var active: bool = _board == str(entry[0])
		b.add_theme_stylebox_override("normal",
			UI.panel_box(Palette.PANEL_HIGH if active else Palette.PANEL,
				Palette.GOLD_DEEP if active else Palette.LINE))
		b.add_theme_color_override("font_color",
			Palette.GOLD_INK if active else Palette.TEXT_DIM)
		var key: String = str(entry[0])
		b.pressed.connect(func() -> void:
			_board = key
			_load_board())
		picker.add_child(b)

	var rows: Array = _ranks.get("rows", [])
	if rows.is_empty():
		_list.add_child(UI.label("The heralds are still counting.",
			UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
		_load_board()
		return

	var mine := int(_ranks.get("my_rank", 0))
	if mine > 0:
		_list.add_child(UI.label("You stand %d%s with %s" % [
			mine, _ordinal(mine), UI.number(int(_ranks.get("my_value", 0)))],
			UI.F_CAPTION, Palette.GOLD_INK, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		_list.add_child(UI.label("You are not on this roll yet.",
			UI.F_CAPTION, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))

	for r in rows:
		_list.add_child(_rank_row(r, int(r.get("rank", 0)) == mine))


func _rank_row(r: Dictionary, is_me: bool) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.card_box(is_me))

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	p.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var rank := int(r.get("rank", 0))
	row.add_child(UI.label("%d" % rank, UI.F_BODY,
		Palette.GOLD_INK if rank <= 3 else Palette.TEXT_DIM))

	var face := TextureRect.new()
	face.custom_minimum_size = Vector2(32, 32)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.texture = ArtRegistry.portrait(str(r.get("avatar", "")))
	row.add_child(face)

	var name_label := UI.label(str(r.get("name", "")), UI.F_CAPTION, Palette.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	row.add_child(UI.label(UI.number(int(r.get("value", 0))), UI.F_CAPTION, Palette.GOLD_INK))
	return p


func _ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "th"
	match n % 10:
		1: return "st"
		2: return "nd"
		3: return "rd"
	return "th"


func _load_board() -> void:
	var res: Api.Response = await Api.get_json("/v1/leaderboards/%s" % _board)
	if not res.ok:
		return
	_ranks = res.data
	_rebuild()
