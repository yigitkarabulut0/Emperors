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


## A generic button in the section: one of the dialogs' painted plates
## (Dialog.CONFIRM_PLATE, QUIET_PLATE, DANGER_PLATE, from plates_sheet.png) at
## their own edge; the Kingdom painting's own buttons are its crops instead.
func _plate_button(word: String, plate: String, col: Color) -> Button:
	var b := UI.plate_face(plate, Dialog.PLATE_EDGE)
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
## proportions: a portrait's painted ring is not quite round, and forced into
## another box it came out squashed. Works have their own, framed
## (_work_picture).
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
## The server's ranks are king, marshal and member; the painting calls them
## KING, CAPTAIN and LORD, and the painting is what a player reads.
const ROLE_ICON := {"king": "icons/role_king", "marshal": "icons/role_captain",
	"member": "icons/role_lord"}
const ROLE_WORD := {"king": "KING", "marshal": "CAPTAIN", "member": "LORD"}
const ROW_H := 156.0
const FACE := 122.0
## A request row's face is smaller: the row carries two buttons, and the name
## between them needs the room more than the portrait does.
const ASK_FACE := 96.0
const ACCEPT_W := 150.0
const REFUSE_W := 140.0
const BUTTON_GAP := 12.0
const POLICY_H := 150.0
const CHIP_W := 170.0


func _fill_lords() -> void:
	var my_role := str(me.get("role", ""))
	var king := my_role == "king"
	var leads := king or my_role == "marshal"

	# Who is asking to join comes first: it is the one thing on this tab that is
	# waiting for somebody.
	var asking: Array = data.get("requests", [])
	if leads and not asking.is_empty():
		_heading("JOIN REQUESTS (%d)" % asking.size())
		for r in asking:
			_request_row(r)
		_heading("THE LORDS")

	var members: Array = data.get("members", [])
	for i in members.size():
		var m: Dictionary = members[i]
		var row := _row(ROW_H)
		# The portraits carry their own gold ring, painted. An item tier frame
		# was drawn over them as well, so every lord wore a rarity around his
		# face -- two rings, and the wrong vocabulary for a person.
		paint_lord_face(_picture(row, MEDALLION, Vector2(FACE, FACE), ROW_H), m)

		var them := str(m.get("player_id", ""))
		var role := str(m.get("role", "member"))
		var mine := them == Session.player_id
		# The king manages everyone but himself; a captain may only remove the
		# lords below him. Everyone else just reads the roster.
		var action := ""
		if king and not mine:
			action = "MANAGE"
		elif my_role == "marshal" and role == "member" and not mine:
			action = "REMOVE"
		var button_w := 200.0
		var text_x := PAD + FACE + GUTTER
		var text_w := _text_span(text_x, button_w if action != "" else 0.0)

		# The lord as everyone sees them: their colour, their seal, and the
		# title they wear on the rank's line, after the rank.
		var name_label := _text(row, "", Rect2(text_x, 24, text_w, 44), 34, UI.INK, "title", 700)
		Look.paint_name(name_label, m, str(m.get("name", "")), Rect2(text_x, 24, text_w, 44), 34, 22)
		row.add_child(UI.image(str(ROLE_ICON.get(role, ROLE_ICON["member"])),
			Rect2(text_x, 74, 32, 32)))
		var word := str(ROLE_WORD.get(role, "LORD"))
		var rank := _text(row, word, Rect2(text_x + 42, 76, text_w - 42, 30), 25, UI.GOLD_DIM, "title", 600)
		var after := text_x + 42 + rank.label_settings.font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, 25).x + 16
		var worn_title := _text(row, "", Rect2(after, 76, text_x + text_w - after, 30), 23, UI.DIM, "body", 600)
		Look.paint_title(worn_title, m, Rect2(after, 76, text_x + text_w - after, 30), 23, 14)
		_text(row, "Level %d  ·  %s given" % [int(m.get("level", 1)),
			UI.short_number(int(str(m.get("donated", "0"))))],
			Rect2(text_x, 112, text_w, 30), 24, UI.DIM)

		match action:
			"MANAGE":
				_action(row, "MANAGE", Dialog.QUIET_PLATE, UI.INK, button_w, ROW_H) \
					.pressed.connect(_manage.bind(them, str(m.get("name", "")), role))
			"REMOVE":
				_action(row, "REMOVE", Dialog.DANGER_PLATE, Color("#FBEDED"), button_w, ROW_H) \
					.pressed.connect(_remove.bind(them, str(m.get("name", ""))))

	if king:
		_policy_row()

	# Only a king or captain can invite, so only they are offered the button.
	# Everyone saw it, and a lord who pressed it was told his rank forbade it.
	if leads:
		var invite := _plate_button("INVITE A PLAYER", Dialog.CONFIRM_PLATE, Color("#F3FBF3"))
		invite.custom_minimum_size = Vector2(WIDTH, BUTTON_H)
		invite.pressed.connect(_invite)
		_list.add_child(invite)

	var leave := _plate_button("LEAVE THE KINGDOM", Dialog.DANGER_PLATE, Color("#FBEDED"))
	leave.custom_minimum_size = Vector2(WIDTH, BUTTON_H)
	leave.pressed.connect(_leave)
	_list.add_child(leave)


## One lord asking to join: who, how long they have waited, and the answer.
func _request_row(r: Dictionary) -> void:
	var row := _row(ROW_H)
	var who := str(r.get("player_id", ""))
	# Drawn as a lord of the kingdom is: their own face in the medallion, the
	# frame they wear, their colour and seal, and their title under the rest.
	paint_lord_face(_picture(row, MEDALLION, Vector2(ASK_FACE, ASK_FACE), ROW_H), r)
	var buttons_w := ACCEPT_W + BUTTON_GAP + REFUSE_W
	var text_x := PAD + ASK_FACE + GUTTER
	var text_w := WIDTH - PAD - buttons_w - GUTTER - text_x
	var name_label := _text(row, "", Rect2(text_x, 26, text_w, 44), 32, UI.INK, "title", 700)
	Look.paint_name(name_label, r, str(r.get("name", "")), Rect2(text_x, 26, text_w, 44), 32, 20)
	_text(row, "Level %d  ·  asked %s" % [int(r.get("level", 1)), UI.ago(int(r.get("waiting", 0)))],
		Rect2(text_x, 74, text_w, 32), 23, UI.DIM)
	var worn_title := _text(row, "", Rect2(text_x, 108, text_w, 30), 22, UI.DIM, "body", 600)
	Look.paint_title(worn_title, r, Rect2(text_x, 108, text_w, 30), 22, 14)
	var y := (ROW_H - BUTTON_H) / 2.0
	var yes := _plate_button("ACCEPT", Dialog.CONFIRM_PLATE, Color("#F3FBF3"))
	yes.add_theme_font_size_override("font_size", 24)
	UI.place(yes, Rect2(WIDTH - PAD - buttons_w, y, ACCEPT_W, BUTTON_H))
	yes.pressed.connect(func() -> void:
		_act("/v1/kingdom/requests/answer", {"player_id": who, "accept": true}))
	row.add_child(yes)
	var no := _plate_button("REFUSE", Dialog.QUIET_PLATE, UI.DIM)
	no.add_theme_font_size_override("font_size", 24)
	UI.place(no, Rect2(WIDTH - PAD - REFUSE_W, y, REFUSE_W, BUTTON_H))
	no.pressed.connect(func() -> void:
		_act("/v1/kingdom/requests/answer", {"player_id": who, "accept": false}))
	row.add_child(no)


## The king's choice of who may join, as two plates: the lit one is the rule in
## force, and pressing the other changes it.
func _policy_row() -> void:
	var k: Dictionary = data.get("kingdom", {}) if data.get("kingdom", null) is Dictionary else {}
	var open := str(k.get("join_policy", "open")) != "request"
	var row := _row(POLICY_H)
	var chips_w := CHIP_W * 2.0 + BUTTON_GAP
	var text_w := WIDTH - PAD - chips_w - GUTTER - PAD
	_text(row, "WHO MAY JOIN", Rect2(PAD, 26, text_w, 36), 26, UI.GOLD, "title", 700)
	_text(row, "Anyone, while there is room." if open
			else "Only lords you or a captain accept.",
		Rect2(PAD, 66, text_w, 60), 23, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_LEFT, true)
	var y := (POLICY_H - BUTTON_H) / 2.0
	for i in 2:
		var is_open := i == 0
		var lit := is_open == open
		var chip := _plate_button("OPEN" if is_open else "BY REQUEST",
			"inventory/chip_frame_active" if lit else "inventory/chip_frame_idle",
			UI.INK if lit else UI.DIM)
		chip.add_theme_font_size_override("font_size", 22)
		UI.place(chip, Rect2(WIDTH - PAD - chips_w + (CHIP_W + BUTTON_GAP) * i, y, CHIP_W, BUTTON_H))
		if not lit:
			var want := "open" if is_open else "request"
			chip.pressed.connect(func() -> void:
				_act("/v1/kingdom/policy", {"policy": want}))
		row.add_child(chip)


## Static so the Realm tab's painted ROYAL LORDS panel picks the same face for
## the same lord. Two rules for one roster put a crown on a different man in
## each of the two places he appears. The stand-in for a lord whose view does
## not say their face (a server from before MemberView carried `avatar`).
static func face_for(player_id: String, role: String) -> String:
	if role == "king":
		return KING_PORTRAIT
	return LORD_PORTRAITS[absi(player_id.hash()) % LORD_PORTRAITS.size()]


## A lord's own face in the painted gold medallion -- the crowned one for the
## king -- and the frame they wear over it (scripts/ui/look.gd). The medallion
## is the painting's, its painted face covered by the lord's own portrait
## (Art.avatar_ring) in its window: centre in the crop, the face's size, and
## the rim's outer size, measured.
const MEDALLION := "portraits/lord_aldric"
const MEDALLION_WINDOW := {"portraits/lord_aldric": Vector2(35.5, 33.5),
	"portraits/lord_yigit": Vector2(35.5, 41.5)}
const MEDALLION_FACE := 60.0
const MEDALLION_RIM := 66.0


## Paints `m` into `medallion`, a TextureRect laid out for the medallion crop
## (scaled, or kept to aspect and centred): the crop, the face over its window
## and the worn ring over that, both kept on the medallion for the next paint.
static func paint_lord_face(medallion: TextureRect, m: Dictionary) -> void:
	var role := str(m.get("role", "member"))
	var avatar := str(m.get("avatar", ""))
	var key := KING_PORTRAIT if role == "king" else MEDALLION
	medallion.texture = Art.tex(key if avatar != "" else face_for(str(m.get("player_id", "")), role))
	var face: TextureRect = medallion.get_meta("lord_face") if medallion.has_meta("lord_face") else null
	if face == null or not is_instance_valid(face):
		face = UI.image("", Rect2())
		medallion.get_parent().add_child(face)
		medallion.get_parent().move_child(face, medallion.get_index() + 1)
		medallion.set_meta("lord_face", face)
	face.visible = avatar != "" and medallion.visible
	var tex := medallion.texture.get_size()
	var s := medallion.size.x / tex.x
	var origin := medallion.position
	if medallion.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
		s = minf(medallion.size.x / tex.x, medallion.size.y / tex.y)
		origin += (medallion.size - tex * s) / 2.0
	if avatar == "":
		Look.paint_frame(face, {}, "ring", 0.0)
		return
	face.texture = Art.tex(Art.avatar_ring(avatar))
	var c: Vector2 = origin + (MEDALLION_WINDOW[key] as Vector2) * s
	var d := MEDALLION_FACE * s
	UI.place(face, Rect2(c - Vector2(d, d) / 2.0, Vector2(d, d)))
	Look.paint_frame(face, m, "ring", MEDALLION_RIM * s)


## The king's choices for one lord, in one list. Their current rank is left
## out: offering to make a captain a captain is a button that does nothing.
func _manage(player_id: String, name: String, role: String) -> void:
	var options: Array = []
	if role != "marshal":
		options.append({"id": "marshal", "label": "Make them a captain",
			"sub": "May invite, answer requests and remove lords"})
	if role != "member":
		options.append({"id": "member", "label": "Make them a lord", "sub": "A member of the kingdom"})
	options.append({"id": "king", "label": "Hand them the crown", "sub": "You become their captain"})
	options.append({"id": "kick", "label": "Remove from the kingdom",
		"sub": "They must wait before joining any kingdom"})
	var pick := await Dialog.choose(self, {"title": name, "body": "What becomes of them?",
		"options": options})
	match pick:
		"":
			return
		"kick":
			_remove(player_id, name)
		"king":
			if await Dialog.ask(self, {"title": "Hand the crown to %s?" % name,
					"body": "They become king, and you their captain. Only they can hand it back.",
					"confirm_text": "Hand it over", "danger": true}):
				_act("/v1/kingdom/role", {"player_id": player_id, "role": "king"})
		_:
			_act("/v1/kingdom/role", {"player_id": player_id, "role": pick})


func _remove(player_id: String, name: String) -> void:
	if await Dialog.ask(self, {"title": "Remove %s?" % name,
			"body": "They leave the kingdom at once, and must wait before joining any kingdom again.",
			"confirm_text": "Remove", "danger": true}):
		_act("/v1/kingdom/kick", {"player_id": player_id})


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
const WORK_H := 176.0
## Each work's scene is 152x122 (art/slices/works_sheet.json), the box it is
## drawn in; the Realm panel draws the same scene at 86x69.
const WORK_PIC := Vector2(152, 122)
## The painted thin gold frame round a work's scene, a nine-patch: its corners
## keep their brackets whatever the box, and only the straight bars stretch.
const WORK_FRAME := "kingdom/work_frame"
const WORK_FRAME_MARGIN := 8
## Where the scene sits inside the frame: under the frame's inner edge.
const WORK_INSET := 2.0


## A Kingdom Work's own scene, by its id. Until the works were painted there
## were four pictures for eight works, handed out by position.
static func work_art(id: String) -> String:
	return "kingdom/work_" + id


## A work's scene in its frame, centred in the row's height.
func _work_picture(row: Control, id: String) -> void:
	var box := Rect2(PAD, (WORK_H - WORK_PIC.y) / 2.0, WORK_PIC.x, WORK_PIC.y)
	var scene := UI.image(work_art(id), box.grow(-WORK_INSET))
	row.add_child(scene)
	var frame := NinePatchRect.new()
	frame.texture = Art.tex(WORK_FRAME)
	for m in ["left", "top", "right", "bottom"]:
		frame.set("patch_margin_" + m, WORK_FRAME_MARGIN)
	frame.draw_center = false
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.place(frame, box)
	row.add_child(frame)


func _fill_works() -> void:
	var ups: Array = data.get("upgrades", [])
	for i in ups.size():
		var u: Dictionary = ups[i]
		var row := _row(WORK_H)
		_work_picture(row, str(u.get("id", "")))

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
			var done := _action(row, "MAX LEVEL", Dialog.QUIET_PLATE, UI.GOLD_DIM,
				button_w, WORK_H - 34.0)
			done.disabled = true
			done.modulate = Color(0.62, 0.62, 0.62)
			continue
		_action(row, "UPGRADE", Dialog.CONFIRM_PLATE, Color("#F3FBF3"), button_w, WORK_H - 34.0) \
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
		var b := _plate_button("%d" % cost, Dialog.QUIET_PLATE, UI.GOLD)
		UI.place(b, Rect2(14, 286, wide - 28, BUTTON_H))
		b.disabled = cost > purse
		if b.disabled:
			b.modulate = Color(0.6, 0.6, 0.6)
		b.pressed.connect(func() -> void:
			_act("/v1/kingdom/shop/buy", {"good_id": str(g.get("id", ""))}))
		card.add_child(b)


## What a work gives now and what a level adds. Percentages are basis points;
## the Royal Court's bucket is flat -- seats, not a percentage -- and read as one
## it printed "+0.0% a level" under a work that adds two lords a level.
func _bonus_text(u: Dictionary) -> String:
	var now := int(u.get("effect_now", 0))
	var per := int(u.get("per_level", 0))
	if now == 0 and per == 0:
		return str(u.get("blurb", ""))
	if str(u.get("bucket", "")).ends_with("_flat"):
		return "+%d now  ·  +%d a level" % [now, per]
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
## The Throne's own line is a tap, so it is a thumb tall (95 units is 44 pt).
const THRONE_H := 96.0
const PLACE_W := 92.0
const VALUE_W := 240.0


func _fill_ranks() -> void:
	_throne_row()
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
		var my_rank := int(res.data.get("my_rank", 0))
		_heading("%s  ·  you are #%d" % [str(board[1]), my_rank])
		# A board's rows carry a rank and a name, not a player id, so the
		# player's own line is the one at their rank.
		for r in (res.data.get("rows", []) as Array).slice(0, 5):
			_rank_row(int(r.get("rank", 0)), str(r.get("name", "")),
				UI.short_number(int(str(r.get("value", "0")))),
				my_rank > 0 and int(r.get("rank", 0)) == my_rank)
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


## THE THRONE, the first line of WHERE THE REALM STANDS.
##
## Realm news, and the only standing in the game that is not a board: the
## kingdom that gained the most renown last week wears the crown, and its
## emperor's decree is felt by every lord in the realm -- a lord with no
## kingdom included. Its words come from snapshot.live.throne, so it costs no
## request of its own.
##
## It is here rather than on the kingdom's own page because kingdom.png is
## full: the largest gap anywhere on it is ten units, and a banner laid along
## the page's foot fell below the fold on a 1672 screen. Standings are what a
## lord opens RANKS for.
func _throne_row() -> void:
	_heading("THE THRONE")
	# Taller than a rank row: the whole line is one tap, and a tap area is 95
	# units (44 pt) or it is not a thumb's.
	var row := _row(THRONE_H)
	var crown := UI.image("throne/crown_small", Rect2(PAD, (THRONE_H - 42.0) / 2.0, 56, 42))
	crown.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(crown)
	var l := UI.label(throne_line(GameState.live(), GameState.live_age_s()), 25, UI.INK, "body", 500)
	UI.place(l, Rect2(PAD + 74, 0, WIDTH - PAD * 2 - 74 - 32, THRONE_H))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	UI.fit_label(l, 25, 16)
	row.add_child(UI.image("icons/chevron_gold", Rect2(WIDTH - PAD - 26, (THRONE_H - 30.0) / 2.0, 24, 30)))
	var hit := UI.hotspot(Rect2(0, 0, WIDTH, THRONE_H))
	hit.pressed.connect(func() -> void:
		var shell := get_tree().get_first_node_in_group("shell")
		if shell != null:
			shell.call("open_view", "throne"))
	row.add_child(hit)


## What the Throne's line says, in every state. Pure, so a test can ask it.
##
## Nobody reigning says so in as many words: it is the one state a line like
## this must never leave blank.
static func throne_line(live: Dictionary, age: int) -> String:
	var th: Variant = live.get("throne")
	if not (th is Dictionary):
		return "The throne stands empty"
	var t: Dictionary = th
	var name := str(t.get("kingdom_name", ""))
	if name == "":
		var crowns := maxi(0, int(t.get("crowns_in", 0)) - age)
		if crowns <= 0:
			return "The throne stands empty"
		return "The throne stands empty  ·  crowned in " + UI.time_left(crowns)
	var dec: Variant = t.get("decree")
	if dec is Dictionary:
		var d: Dictionary = dec
		return "%s reigns  ·  %s, %s left" % [name, str(d.get("name", "")),
			UI.time_left(maxi(0, int(d.get("ends_in", 0)) - age))]
	return "%s reigns  ·  %s left" % [name,
		UI.time_left(maxi(0, int(t.get("reign_ends_in", 0)) - age))]
