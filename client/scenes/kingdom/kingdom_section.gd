extends Control
## One of the Kingdom's sections, drawn into the Kingdom page itself.
##
## Lords, Works and Ranks each used to open a Dialog.choose with up to twelve
## options in it: a roster, a build list and three leaderboards, all squeezed
## into a modal built for asking one question. A roster is not a question.
##
## They are not a separate screen either. The page already has a header, a crest
## and a tab strip; tapping a tab should change what is under it, which is what
## a tab is for. So this is a Control the page puts in that space and throws
## away when the tab changes -- the page keeps scrolling, the header stays put.
##
## The painted panels the reference draws for Lords and Works are half-width,
## meant to sit beside each other under one long page. Alone under a tab they
## read as a column with a hole beside it, so what a tab shows is built here at
## the full width instead: a lord with a face and a rank, a work with its
## painting and what it costs, a table that is a table.
##
## One script for all three, because the rows differ and nothing else does.

signal acted(path: String, body: Dictionary)

## The rail runs down x 0..160 and the screen ends at 941, so a section lives
## between them with a margin either side. It was 800 wide starting at 70,
## which put the first ninety units of every row behind the rail.
const WIDTH := 762.0
const ROW_GAP := 14.0
const PLATE := "inventory/card_frame"
const PLATE_MARGIN := 26

var mode := "lords"           ## lords | works | ranks
var data: Dictionary = {}
var shop: Dictionary = {}
var me: Dictionary = {}

var _list: VBoxContainer
var _busy := false


func setup(which: String, kingdom_data: Dictionary, favour_shop: Dictionary) -> void:
	mode = which
	data = kingdom_data
	shop = favour_shop
	var m: Variant = kingdom_data.get("me", null)
	me = m if m is Dictionary else {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var head := UI.label(_subtitle(), 26, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(head, Rect2(0, 0, WIDTH, 36))
	add_child(head)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", int(ROW_GAP))
	_list.position = Vector2(0, 46)
	_list.custom_minimum_size.x = WIDTH
	add_child(_list)
	_fill()
	# The page scrolls, so the section only has to say how tall it turned out.
	await get_tree().process_frame
	custom_minimum_size = Vector2(WIDTH, 46.0 + _list.get_combined_minimum_size().y + 40.0)
	size = custom_minimum_size


func _subtitle() -> String:
	match mode:
		"lords":
			var k: Dictionary = data.get("kingdom", {}) if data.get("kingdom", null) is Dictionary else {}
			return "%d of %d lords" % [int(k.get("members", 0)), int(k.get("member_cap", 0))]
		"works":
			return "%s Favour to spend" % UI.grouped(int(shop.get("favour", 0)))
		"ranks":
			return "Where the realm stands"
	return ""


func _plate_button(word: String, plate: String, col: Color) -> Button:
	var b := UI.plate_face(plate, 16)
	b.text = word
	b.add_theme_font_override("font", UI.font("title", 700))
	b.add_theme_font_size_override("font_size", 28)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)
	b.add_theme_constant_override("outline_size", 0)
	return b


## A row is a plate with things laid on it. Everything in the list is one.
func _row(height: float) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(800, height)
	var plate := NinePatchRect.new()
	plate.texture = Art.tex(PLATE)
	for m in ["left", "top", "right", "bottom"]:
		plate.set("patch_margin_" + m, PLATE_MARGIN)
	UI.place(plate, Rect2(0, 0, 800, height))
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(plate)
	_list.add_child(holder)
	return holder


func _text(host: Control, s: String, rect: Rect2, size: int, col: Color,
		role: String = "body", weight: int = 500,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UI.label(s, size, col, role, weight, align)
	UI.place(l, rect)
	host.add_child(l)
	return l


func _act(path: String, body: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	acted.emit(path, body)


func _fill() -> void:
	match mode:
		"lords": _fill_lords()
		"works": _fill_works()
		"ranks": _fill_ranks()


## --- lords -----------------------------------------------------------------
##
## The roster, one lord to a row: face, name, rank, what they have given. The
## king can set a rank by tapping a row; everyone can invite; everyone can
## leave. All three used to be entries in the same list of options, so "Leave
## the kingdom" sat under the members like a thirteenth member.
const LORD_PORTRAITS := ["portraits/lord_yigit", "portraits/lord_aldric",
	"portraits/lord_seraphine", "portraits/lord_darian"]
const ROLE_ICON := {"king": "icons/role_king", "captain": "icons/role_captain",
	"lord": "icons/role_lord"}
const ROW_H := 150.0


func _fill_lords() -> void:
	var members: Array = data.get("members", [])
	var king := str(me.get("role", "")) == "king"
	for i in members.size():
		var m: Dictionary = members[i]
		var row := _row(ROW_H)
		var face := UI.image(LORD_PORTRAITS[i % LORD_PORTRAITS.size()], Rect2(16, 16, 118, 118))
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		face.clip_contents = true
		row.add_child(face)
		var ring := UI.image("inventory/frame_legendary" if str(m.get("role", "")) == "king"
			else "inventory/frame_rare", Rect2(16, 16, 118, 118))
		row.add_child(ring)

		_text(row, str(m.get("name", "")), Rect2(152, 22, 380, 42), 34, UI.INK, "title", 700)
		var role := str(m.get("role", "lord"))
		row.add_child(UI.image(str(ROLE_ICON.get(role, ROLE_ICON["lord"])), Rect2(152, 70, 34, 34)))
		_text(row, role.to_upper(), Rect2(194, 72, 200, 32), 24, UI.GOLD_DIM, "title", 600)
		_text(row, "Level %d" % int(m.get("level", 1)), Rect2(152, 106, 200, 30), 24, UI.DIM)
		_text(row, "%s given" % UI.short_number(int(str(m.get("donated", "0")))),
			Rect2(500, 106, 284, 30), 24, UI.GOLD_DIM, "body", 500, HORIZONTAL_ALIGNMENT_RIGHT)

		# Only the king can change a rank, and never their own.
		var them := str(m.get("player_id", ""))
		if king and them != Session.player_id:
			var b := _plate_button("RANK", "inventory/btn_sell_plate", UI.INK)
			UI.place(b, Rect2(560, 24, 218, 96))
			b.pressed.connect(_set_role.bind(them, str(m.get("name", ""))))
			row.add_child(b)

	var invite := _plate_button("INVITE A PLAYER", "shop/buy_plate", Color("#F3FBF3"))
	UI.place(invite, Rect2(0, 0, 800, 96))
	invite.custom_minimum_size = Vector2(800, 96)
	invite.pressed.connect(_invite)
	_list.add_child(invite)

	var leave := _plate_button("LEAVE THE KINGDOM", "shop/danger_plate", Color("#FBEDED"))
	leave.custom_minimum_size = Vector2(800, 96)
	leave.pressed.connect(_leave)
	_list.add_child(leave)


func _set_role(player_id: String, name: String) -> void:
	var role := await Dialog.choose(self, {"title": name, "body": "What rank do they hold?",
		"options": [{"id": "captain", "label": "Captain", "sub": "May invite and may not be raided by us"},
			{"id": "lord", "label": "Lord", "sub": "A member of the kingdom"}]})
	if role != "":
		_act("/v1/kingdom/role", {"player_id": player_id, "role": role})


func _invite() -> void:
	var r: Dictionary = await Dialog.prompt_text(self, {"title": "Invite a player",
		"body": "Their username, as they signed up.", "placeholder": "Username",
		"max_length": 20, "confirm_text": "Search"})
	if r["action"] != "confirm" or str(r["text"]) == "":
		return
	var name := str(r["text"])
	var found: Api.Response = await Api.get_json("/v1/kingdom/search?q=" + name.uri_encode())
	var target := ""
	for p in (found.data.get("players", []) if found.ok else []):
		if str(p.get("name", "")).to_lower() == name.to_lower():
			target = str(p.get("player_id", p.get("id", "")))
	if target == "":
		GameState.action_failed.emit("No player named %s" % name)
		return
	_act("/v1/kingdom/invite", {"player_id": target})


func _leave() -> void:
	if await Dialog.ask(self, {"title": "Leave the kingdom?",
		"body": "Your favour and your standing here go with it.",
		"confirm_text": "Leave", "danger": true}):
		_act("/v1/kingdom/leave", {})


## --- works -----------------------------------------------------------------
##
## What the kingdom is building, and what Favour buys. Each work shows its art,
## its level, what it gives now and what the next level costs; the Favour goods
## follow under their own heading. In the popup these were sixteen lines of text
## in one list, and a building looked exactly like a potion.
const WORK_ART := ["kingdom/work_banner_hall", "kingdom/work_training_grounds",
	"kingdom/work_granary_law", "kingdom/work_royal_archives"]
const WORK_H := 168.0
const GOOD_H := 132.0


func _fill_works() -> void:
	var ups: Array = data.get("upgrades", [])
	for i in ups.size():
		var u: Dictionary = ups[i]
		var row := _row(WORK_H)
		row.add_child(UI.image(WORK_ART[i % WORK_ART.size()], Rect2(16, 16, 136, 136)))
		_text(row, str(u.get("name", "")), Rect2(168, 20, 380, 42), 32, UI.INK, "title", 700)
		_text(row, "Level %d" % int(u.get("level", 0)), Rect2(168, 66, 200, 32), 26, UI.GOLD_DIM,
			"body", 600)
		_text(row, _bonus_text(u), Rect2(168, 102, 400, 34), 25, UI.DIM)

		if bool(u.get("maxed", false)):
			_text(row, "MAX", Rect2(560, 60, 218, 44), 30, UI.GOLD_DIM, "title", 700,
				HORIZONTAL_ALIGNMENT_CENTER)
			continue
		var b := _plate_button("UPGRADE", "shop/buy_plate", Color("#F3FBF3"))
		UI.place(b, Rect2(556, 20, 226, 96))
		b.pressed.connect(_upgrade.bind(str(u.get("id", "")), str(u.get("name", "")),
			int(u.get("next_cost", 0))))
		row.add_child(b)
		_text(row, "%s gold" % UI.short_number(int(u.get("next_cost", 0))),
			Rect2(556, 120, 226, 32), 24, UI.GOLD_DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)

	var goods: Array = shop.get("goods", [])
	if goods.is_empty():
		return
	var head := UI.label("THE FAVOUR SHOP", 30, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	head.custom_minimum_size = Vector2(800, 60)
	_list.add_child(head)
	for g in goods:
		var row := _row(GOOD_H)
		_text(row, str(g.get("name", "")), Rect2(24, 18, 480, 40), 30, UI.INK, "title", 700)
		_text(row, str(g.get("blurb", "")), Rect2(24, 62, 500, 50), 24, UI.DIM)
		var cost := int(g.get("cost", 0))
		var b := _plate_button("%d FAVOUR" % cost, "inventory/btn_sell_plate", UI.INK)
		UI.place(b, Rect2(546, 18, 236, 96))
		b.disabled = cost > int(shop.get("favour", 0))
		b.pressed.connect(func() -> void:
			_act("/v1/kingdom/shop/buy", {"good": str(g.get("id", ""))}))
		row.add_child(b)


func _bonus_text(u: Dictionary) -> String:
	var now := int(u.get("effect_now", 0))
	var per := int(u.get("effect_per_level", 0))
	if now == 0 and per == 0:
		return str(u.get("blurb", ""))
	return "+%.1f%% now  ·  +%.1f%% a level" % [now / 100.0, per / 100.0]


func _upgrade(id: String, name: String, cost: int) -> void:
	if await Dialog.ask(self, {"title": "Fund %s?" % name,
		"body": "Costs %s from the treasury." % UI.grouped(cost), "confirm_text": "Fund"}):
		_act("/v1/kingdom/upgrade", {"id": id})


## --- ranks -----------------------------------------------------------------
##
## The kingdom table first, then where the player stands on each of the three
## boards. This was a single block of joined-up lines in a notice dialog, which
## is the shape a log has, not a table.
const BOARDS := [["might", "MIGHT"], ["level", "LEVEL"], ["wealth", "WEALTH"]]
const RANK_H := 92.0


func _fill_ranks() -> void:
	var top: Array = data.get("leaderboard", [])
	if not top.is_empty():
		_heading("KINGDOMS")
		var mine := str((data.get("kingdom", {}) as Dictionary).get("id", ""))
		for i in mini(top.size(), 10):
			var k: Dictionary = top[i]
			var row := _row(RANK_H)
			var is_mine := str(k.get("id", "")) == mine
			_text(row, "#%d" % (i + 1), Rect2(20, 24, 90, 44), 32,
				UI.GOLD if is_mine else UI.GOLD_DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
			_text(row, str(k.get("name", "")), Rect2(120, 24, 420, 44), 30,
				UI.INK if is_mine else UI.DIM, "title", 600)
			_text(row, "[%s]  Lv %d" % [str(k.get("tag", "")), int(k.get("level", 1))],
				Rect2(540, 28, 240, 36), 24, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_RIGHT)

	for board in BOARDS:
		var res: Api.Response = await Api.get_json("/v1/leaderboards/" + str(board[0]))
		if not res.ok:
			continue
		_heading("%s  ·  you are #%d" % [str(board[1]), int(res.data.get("my_rank", 0))])
		for r in (res.data.get("rows", []) as Array).slice(0, 5):
			var row := _row(RANK_H)
			_text(row, "#%d" % int(r.get("rank", 0)), Rect2(20, 24, 90, 44), 30, UI.GOLD_DIM,
				"title", 700, HORIZONTAL_ALIGNMENT_CENTER)
			_text(row, str(r.get("name", "")), Rect2(120, 24, 420, 44), 28, UI.INK, "title", 600)
			_text(row, UI.short_number(int(str(r.get("value", "0")))), Rect2(540, 28, 240, 36),
				26, UI.GOLD_DIM, "body", 600, HORIZONTAL_ALIGNMENT_RIGHT)


func _heading(text: String) -> void:
	var l := UI.label(text, 28, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size = Vector2(800, 62)
	_list.add_child(l)
