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
## How tall the section turned out. Ranks fetches three boards over HTTP and
## fills in as they land, so its height is not known on the frame it is built:
## the page measured it once, a frame after it appeared, and the boards that
## arrived afterwards hung below the end of the scroll where nothing could
## reach them.
signal grew(height: float)

## The rail runs down x 0..160 and the screen ends at 941, so a section lives
## between them with a margin either side. It was 800 wide starting at 70,
## which put the first ninety units of every row behind the rail.
const WIDTH := 762.0
## Every row is measured from WIDTH, never from a number that happens to match
## it. The rows were written for 800 and the section was later narrowed to 762
## to clear the rail; the buttons on their right ran off the screen for a
## fortnight because nothing tied the two together.
const PAD := 24.0
const INNER := WIDTH - PAD * 2.0
const ROW_GAP := 16.0
const PLATE := "inventory/card_frame"
const PLATE_MARGIN := 26
## Every row's action is the same object in the same place: a plate of this size
## against the row's right edge, centred in the row's height. A row whose button
## sat two units higher than the row above it is the whole reason the column
## looked hand-placed.
const BUTTON_H := 96.0
## The gutter between the text column and the button, and between the picture
## and the text. Both are this, so the three columns breathe evenly.
const GUTTER := 22.0

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
	var head := UI.label(_subtitle(), 28, UI.GOLD_DIM, "title", 600,
		HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(head, Rect2(0, 0, WIDTH, 44))
	add_child(head)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", int(ROW_GAP))
	_list.position = Vector2(0, 60)
	_list.custom_minimum_size.x = WIDTH
	add_child(_list)
	_list.minimum_size_changed.connect(_measure)
	_fill()
	# The page scrolls, so the section only has to say how tall it turned out --
	# every time it turns out to be a different height.
	await get_tree().process_frame
	_measure()


func _measure() -> void:
	var h := 60.0 + _list.get_combined_minimum_size().y + 40.0
	if absf(h - size.y) < 1.0:
		return
	custom_minimum_size = Vector2(WIDTH, h)
	size = custom_minimum_size
	grew.emit(h)


func _subtitle() -> String:
	match mode:
		"lords":
			var k: Dictionary = data.get("kingdom", {}) if data.get("kingdom", null) is Dictionary else {}
			return "%d OF %d LORDS" % [int(k.get("members", 0)), int(k.get("member_cap", 0))]
		"works":
			return "%s FAVOUR TO SPEND" % UI.grouped(int(shop.get("favour", 0)))
		"ranks":
			return "WHERE THE REALM STANDS"
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


## The row's action, seated against the right edge and centred in the height.
func _action(row: Control, word: String, plate: String, col: Color,
		button_w: float, row_h: float) -> Button:
	var b := _plate_button(word, plate, col)
	UI.place(b, Rect2(WIDTH - PAD - button_w, (row_h - BUTTON_H) / 2.0, button_w, BUTTON_H))
	row.add_child(b)
	return b


## How wide the text column is once the picture on the left and the button on
## the right have taken theirs. Nothing in a row is given a width by hand.
func _text_span(text_x: float, button_w: float) -> float:
	return WIDTH - PAD - button_w - GUTTER - text_x


## A row is a plate with things laid on it. Everything in the list is one.
func _row(height: float) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(WIDTH, height)
	# A plain Control stops mouse input, and a row covers the whole width of the
	# list: seven of them across the Works tab swallowed every drag before the
	# scroll could see one, so the tab would not scroll at all. Ignoring input
	# here does not deafen the children -- the row's own button still answers.
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := NinePatchRect.new()
	plate.texture = Art.tex(PLATE)
	for m in ["left", "top", "right", "bottom"]:
		plate.set("patch_margin_" + m, PLATE_MARGIN)
	UI.place(plate, Rect2(0, 0, WIDTH, height))
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(plate)
	_list.add_child(holder)
	return holder


## A picture on the left of a row, centred in its height, drawn at its own
## proportions. The portraits are near square and the works are 86x69, and a
## work forced into a square box came out a squashed building.
func _picture(row: Control, asset: String, box: Vector2, row_h: float) -> TextureRect:
	var t := UI.image(asset, Rect2(PAD, (row_h - box.y) / 2.0, box.x, box.y))
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(t)
	return t


func _text(host: Control, s: String, rect: Rect2, size: int, col: Color,
		role: String = "body", weight: int = 500,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, wrap: bool = false) -> Label:
	var l := UI.label(s, size, col, role, weight, align)
	if wrap:
		# Before the rect is set, not after. A Label without wrapping asks for
		# the width of its whole string, and a Control cannot be smaller than
		# what it asks for -- so turning wrapping on afterwards left the label
		# at the width it had already claimed. The Favour goods' blurbs ran a
		# hundred units past the card they were on.
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(rect.size.x, 0)
	UI.place(l, rect)
	host.add_child(l)
	return l


func _act(path: String, body: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	acted.emit(path, body)


## What a list says when it has nothing to show. A tab that draws an empty
## column reads as a tab that failed to load, and one of these did.
func _notice(text: String) -> void:
	var row := _row(110.0)
	_text(row, text, Rect2(PAD, 0, INNER, 110), 25, UI.DIM, "body", 500,
		HORIZONTAL_ALIGNMENT_CENTER, true)


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
## Four faces are painted and a kingdom holds fifty lords, so a face is a
## stand-in until players have their own. It is still chosen, not cycled: the
## crowned portrait belongs to the king and to nobody else -- rotating the list
## by row put a crown on the fifth lord in the roster -- and the rest are picked
## by a hash of the player's id, so a lord keeps the same face every visit.
const KING_PORTRAIT := "portraits/lord_yigit"
const LORD_PORTRAITS := ["portraits/lord_aldric", "portraits/lord_seraphine",
	"portraits/lord_darian"]
const ROLE_ICON := {"king": "icons/role_king", "captain": "icons/role_captain",
	"lord": "icons/role_lord"}
const ROW_H := 156.0
const FACE := 122.0


func _fill_lords() -> void:
	var members: Array = data.get("members", [])
	var king := str(me.get("role", "")) == "king"
	for i in members.size():
		var m: Dictionary = members[i]
		var row := _row(ROW_H)
		# The portraits carry their own gold ring, painted. An item tier frame
		# was drawn over them as well, so every lord wore a rarity around his
		# face -- two rings, and the wrong vocabulary for a person.
		_picture(row, face_for(str(m.get("player_id", "")),
			str(m.get("role", ""))), Vector2(FACE, FACE), ROW_H)

		var them := str(m.get("player_id", ""))
		var can_rank := king and them != Session.player_id
		var button_w := 200.0
		var text_x := PAD + FACE + GUTTER
		var text_w := _text_span(text_x, button_w if can_rank else 0.0)

		_text(row, str(m.get("name", "")), Rect2(text_x, 24, text_w, 44), 34, UI.INK,
			"title", 700)
		var role := str(m.get("role", "lord"))
		row.add_child(UI.image(str(ROLE_ICON.get(role, ROLE_ICON["lord"])),
			Rect2(text_x, 74, 32, 32)))
		_text(row, role.to_upper(), Rect2(text_x + 42, 76, text_w - 42, 30), 25, UI.GOLD_DIM,
			"title", 600)
		_text(row, "Level %d  ·  %s given" % [int(m.get("level", 1)),
			UI.short_number(int(str(m.get("donated", "0"))))],
			Rect2(text_x, 112, text_w, 30), 24, UI.DIM)

		if can_rank:
			_action(row, "RANK", "inventory/btn_sell_plate", UI.INK, button_w, ROW_H) \
				.pressed.connect(_set_role.bind(them, str(m.get("name", ""))))

	var invite := _plate_button("INVITE A PLAYER", "shop/buy_plate", Color("#F3FBF3"))
	invite.custom_minimum_size = Vector2(WIDTH, BUTTON_H)
	invite.pressed.connect(_invite)
	_list.add_child(invite)

	var leave := _plate_button("LEAVE THE KINGDOM", "shop/danger_plate", Color("#FBEDED"))
	leave.custom_minimum_size = Vector2(WIDTH, BUTTON_H)
	leave.pressed.connect(_leave)
	_list.add_child(leave)


## Static so the Realm tab's painted ROYAL LORDS panel picks the same face for
## the same lord. Two rules for one roster put a crown on a different man in
## each of the two places he appears.
static func face_for(player_id: String, role: String) -> String:
	if role == "king":
		return KING_PORTRAIT
	return LORD_PORTRAITS[absi(player_id.hash()) % LORD_PORTRAITS.size()]


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
const WORK_H := 176.0
## The work paintings are 86x69, so the box they are drawn in is too.
const WORK_PIC := Vector2(152, 122)


func _fill_works() -> void:
	var ups: Array = data.get("upgrades", [])
	for i in ups.size():
		var u: Dictionary = ups[i]
		var row := _row(WORK_H)
		_picture(row, WORK_ART[i % WORK_ART.size()], WORK_PIC, WORK_H)

		var button_w := 216.0
		var text_x := PAD + WORK_PIC.x + GUTTER
		var text_w := _text_span(text_x, button_w)

		_text(row, str(u.get("name", "")), Rect2(text_x, 26, text_w, 44), 32, UI.INK,
			"title", 700)
		_text(row, "Level %d" % int(u.get("level", 0)), Rect2(text_x, 74, text_w, 32), 26,
			UI.GOLD_DIM, "body", 600)
		_text(row, _bonus_text(u), Rect2(text_x, 110, text_w, 46), 24, UI.DIM,
			"body", 500, HORIZONTAL_ALIGNMENT_LEFT, true)

		# The cost sits under the button, inside the row, so the right column
		# reads as one object. It used to hang two units off the row's bottom
		# edge, which looked like a caption that had come loose.
		if bool(u.get("maxed", false)):
			# A maxed work keeps the column: the same plate, spent, rather than
			# a word floating where every other row has a button.
			var done := _action(row, "MAX LEVEL", "inventory/btn_sell_plate", UI.GOLD_DIM,
				button_w, WORK_H - 34.0)
			done.disabled = true
			done.modulate = Color(0.62, 0.62, 0.62)
			continue
		_action(row, "UPGRADE", "shop/buy_plate", Color("#F3FBF3"), button_w, WORK_H - 34.0) \
			.pressed.connect(_upgrade.bind(str(u.get("id", "")), str(u.get("name", "")),
				int(u.get("next_cost", 0))))
		_text(row, "%s gold" % UI.short_number(int(u.get("next_cost", 0))),
			Rect2(WIDTH - PAD - button_w, WORK_H - 52.0, button_w, 32), 24, UI.GOLD_DIM,
			"body", 600, HORIZONTAL_ALIGNMENT_CENTER)

	var goods: Array = shop.get("goods", [])
	if goods.is_empty():
		return
	_heading("THE FAVOUR SHOP")
	_favour_cards(goods)


## The three goods, side by side, the way the Royal Market lays out what it
## sells. They were three full-width rows of type with a price on the right --
## a potion, a market and a scholar's draught all looking exactly alike, which
## is what a list of names looks like when the game has a painting for each.
const GOOD_ART := {
	"energy_potion": "icons/good_energy",
	"shop_refresh": "icons/market_tent",
	"xp_boost": "icons/quest_scroll",
}
const GOOD_FALLBACK := "icons/quest_scroll"
const CARD_GAP := 16.0
## 16 of air, a 100 picture, a name of up to two lines, a blurb of up to three,
## the word FAVOUR, and a button a thumb can hit. Every band is measured, so a
## longer blurb pushes nothing off the card.
const CARD_H := 398.0
## The picture band. Each good is drawn into it at its own proportions: the
## flask is 98x136, the tent 136x110 and the scroll 70x66, so nothing but a
## common box makes them read as one set.
const PIC := Vector2(132, 100)


func _favour_cards(goods: Array) -> void:
	var shelf := Control.new()
	var wide := (INNER - CARD_GAP * 2.0) / 3.0
	shelf.custom_minimum_size = Vector2(WIDTH, CARD_H)
	shelf.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_child(shelf)
	var purse := int(shop.get("favour", 0))
	for i in mini(goods.size(), 3):
		var g: Dictionary = goods[i]
		var card := Control.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UI.place(card, Rect2(PAD + (wide + CARD_GAP) * i, 0, wide, CARD_H))
		shelf.add_child(card)

		var plate := NinePatchRect.new()
		plate.texture = Art.tex(PLATE)
		for m in ["left", "top", "right", "bottom"]:
			plate.set("patch_margin_" + m, PLATE_MARGIN)
		UI.place(plate, Rect2(0, 0, wide, CARD_H))
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(plate)

		var art := UI.image(str(GOOD_ART.get(str(g.get("id", "")), GOOD_FALLBACK)),
			Rect2((wide - PIC.x) / 2.0, 16, PIC.x, PIC.y))
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		card.add_child(art)

		_text(card, str(g.get("name", "")), Rect2(8, 126, wide - 16, 52), 24,
			UI.INK, "title", 700, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text(card, str(g.get("blurb", "")), Rect2(10, 186, wide - 20, 66), 20, UI.DIM,
			"body", 500, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text(card, "FAVOUR", Rect2(14, 258, wide - 28, 24), 18,
			UI.GOLD_DIM, "title", 600, HORIZONTAL_ALIGNMENT_CENTER)

		var cost := int(g.get("cost", 0))
		var b := _plate_button("%d" % cost, "inventory/btn_sell_plate", UI.GOLD)
		UI.place(b, Rect2(14, 286, wide - 28, BUTTON_H))
		b.disabled = cost > purse
		if b.disabled:
			b.modulate = Color(0.6, 0.6, 0.6)
		b.pressed.connect(func() -> void:
			_act("/v1/kingdom/shop/buy", {"good": str(g.get("id", ""))}))
		card.add_child(b)


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
const RANK_H := 84.0
const PLACE_W := 92.0
const VALUE_W := 240.0


func _fill_ranks() -> void:
	var top: Array = data.get("leaderboard", [])
	var mine := str((data.get("kingdom", {}) as Dictionary).get("id", ""))
	if not top.is_empty():
		_heading("KINGDOMS")
		for i in mini(top.size(), 10):
			var k: Dictionary = top[i]
			var is_mine := str(k.get("id", "")) == mine
			_rank_row(i + 1, str(k.get("name", "")),
				"[%s]  Lv %d" % [str(k.get("tag", "")), int(k.get("level", 1))], is_mine)

	var boards := 0
	for board in BOARDS:
		var res: Api.Response = await Api.get_json("/v1/leaderboards/" + str(board[0]))
		# Three round trips, and a tap on another tab frees this section during
		# any of them.
		if not is_inside_tree():
			return
		if not res.ok:
			continue
		boards += 1
		_heading("%s  ·  you are #%d" % [str(board[1]), int(res.data.get("my_rank", 0))])
		for r in (res.data.get("rows", []) as Array).slice(0, 5):
			_rank_row(int(r.get("rank", 0)), str(r.get("name", "")),
				UI.short_number(int(str(r.get("value", "0")))),
				str(r.get("player_id", r.get("id", ""))) == Session.player_id)
	if boards == 0:
		_notice("The heralds have not counted the players yet.\nCome back shortly.")


## One line of a table: place, who, and the one number the board is about. The
## player's own line is lit; the rest are quiet, so a table can be read down
## its left edge.
func _rank_row(place: int, who: String, value: String, is_mine: bool) -> void:
	var row := _row(RANK_H)
	# Gold type alone did not read as "this line is you" at arm's length on a
	# phone, so the plate under it is warmed as well.
	if is_mine:
		row.get_child(0).modulate = Color(1.24, 1.10, 0.82)
	_text(row, "#%d" % place, Rect2(PAD, 0, PLACE_W, RANK_H), 32,
		UI.GOLD if is_mine else UI.GOLD_DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	var name_x := PAD + PLACE_W + GUTTER
	_text(row, who, Rect2(name_x, 0, WIDTH - PAD - VALUE_W - GUTTER - name_x, RANK_H), 30,
		UI.INK if is_mine else UI.DIM, "title", 600)
	_text(row, value, Rect2(WIDTH - PAD - VALUE_W, 0, VALUE_W, RANK_H), 26,
		UI.GOLD if is_mine else UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_RIGHT)


func _heading(text: String) -> void:
	var l := UI.label(text, 28, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size = Vector2(WIDTH, 64)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_list.add_child(l)
