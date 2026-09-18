extends RefCounted
## THE ROLL OF FRIENDS -- who a lord knows, who has asked for them, and the
## day's draught.
##
## Drawn on YOUR LORDSHIP's own page (profile.png, cut by art/slices/profile.json,
## laid out by client/layout/friends.json): the painted friend's row, its ring,
## its boxes and its GIFT plate, given the whole page instead of the four rows
## the profile's foot had room for.
##
## What a gift is, and is not. A draught is the flask the realm sends (a token
## with `energy_pct`, drunk through the flask path): the client never adds
## energy, it asks and paints what came back. One a day per friend, and the day
## is the SERVER's -- GET /v1/friends says how many are left and what one is
## worth to this lord right now, which is what the row's gold box shows, because
## "+18 energy" is a thing a lord can picture and "+4%" is not.
##
## An ask is answered where the gift would be: YES and NO stand in GIFT's place,
## because it is the same question in a different tense.

const PAGE := "friends"
const SCREEN := "page:friends"
## A face inside a worn frame fills the frame's own window, as every list of
## lords draws one.
const FACE_IN_FRAME := 0.78
## How long a refusal or an answer stands under the ask box.
const NOTICE_FOR := 3.0


static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	var field := p.field("ask_name", "A LORD'S NAME")
	field.max_length = 16
	p.set_meta("field", field)
	field.text_submitted.connect(func(_t: String) -> void: _ask(p))
	p.on("ask", func() -> void: await _ask(p))
	p.on("close", func() -> void: p.close())
	p.set_text("notice", "", 14)
	if opts.get("view", null) is Dictionary:
		paint(p, opts["view"])
	else:
		paint(p, {})
		_load(p)
	return p


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/friends")
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		paint(p, res.data)


## Paints with a /v1/friends answer. Public for the tests and the captures.
static func paint(p: PaintedPage, v: Dictionary) -> void:
	p.set_meta("view", v)
	var loaded := not v.is_empty()
	var friends: Array = v.get("friends", []) if v.get("friends") is Array else []
	var asks: Array = v.get("requests", []) if v.get("requests") is Array else []
	var unlocked := bool(v.get("unlocked", true))
	if not loaded:
		p.set_text("subtitle", "Reading the roll…", 16)
	elif not unlocked:
		p.set_text("subtitle", "The roll opens at level %d." % int(v.get("unlock_level", 3)), 16)
	else:
		var gifts := int(v.get("gifts_left", 0))
		p.set_text("subtitle", "%d of %d lords  ·  %s" % [friends.size(), int(v.get("max_friends", 0)),
			("%d draughts left today" % gifts) if gifts != 1 else "1 draught left today"], 16)
	p.set_enabled("ask", unlocked)
	_rows(p, asks, friends, v)
	var empty := loaded and asks.is_empty() and friends.is_empty()
	p.set_shown("empty", empty)
	p.set_shown("heading", not empty)
	if empty:
		p.set_text("empty", ("Nobody yet. Ask for a lord by name above -- or send them your own code "
			+ "from INVITE A FRIEND, and the Crown pays you both."), 18)


## The asks first, because they are what is waiting on you; then the roll.
static func _rows(p: PaintedPage, asks: Array, friends: Array, v: Dictionary) -> void:
	var content := p.content("list")
	if content == null:
		return
	for c in content.get_children():
		c.queue_free()
	var tpl := Layout.element(PAGE, "row")
	var pitch := float(tpl.get("pitch", 121))
	var name_box := _part_rect(tpl, "name")
	var i := 0
	for a in asks:
		_row(p, content, tpl, i, a, name_box, true, v)
		i += 1
	for f in friends:
		_row(p, content, tpl, i, f, name_box, false, v)
		i += 1
	var sc := content.get_parent() as Control
	content.custom_minimum_size.y = maxf(sc.size.y if sc != null else 0.0, i * pitch)


static func _row(p: PaintedPage, content: Control, tpl: Dictionary, i: int, d: Dictionary,
		name_box: Rect2, asking: bool, v: Dictionary) -> void:
	var built := Layout.instantiate(tpl)
	var parts: Dictionary = built["parts"]
	built["node"].position = Vector2(0, i * float(tpl.get("pitch", 121)))
	_face(parts["face"] as TextureRect, d, _part_rect(tpl, "face"))
	(parts["online"] as Control).visible = bool(d.get("online", false))
	Look.paint_name(parts["name"] as Label, d, str(d.get("name", "")), name_box, 28, 18)
	var small := parts["small"] as Label
	var pid := str(d.get("player_id", ""))

	# An ask is answered where the gift would be.
	(parts["gift"] as Control).visible = not asking
	(parts["yes"] as Control).visible = asking
	(parts["no"] as Control).visible = asking
	if asking:
		# YES and NO need a thumb each, which is the gold box's room as well as
		# the gift's: an ask says nothing in it.
		small.visible = false
		(parts["yes"] as BaseButton).pressed.connect(func() -> void: await _answer(p, pid, true))
		(parts["no"] as BaseButton).pressed.connect(func() -> void: await _answer(p, pid, false))
	else:
		# What a draught is worth to THIS lord, which the realm works out.
		var gave := bool(d.get("gave_today", false))
		small.text = "sent" if gave else "+%d" % int(v.get("gift_energy", 0))
		small.label_settings.font_color = UI.DIM if gave else UI.GOLD
		UI.fit_line(small, 24, 15)
		var gift := parts["gift"] as BaseButton
		gift.disabled = gave or int(v.get("gifts_left", 0)) <= 0
		(gift as CanvasItem).self_modulate = Color.WHITE if not gift.disabled else Color(0.5, 0.5, 0.5, 0.85)
		gift.pressed.connect(func() -> void: await _gift(p, pid, str(d.get("name", ""))))
		# A draught of theirs waiting is worth saying where the gift's own
		# figure goes: it is the same object, coming the other way.
		if bool(d.get("gift_waiting", false)):
			small.text = "waiting"
			small.label_settings.font_color = UI.GREEN
	(parts["hit"] as BaseButton).pressed.connect(func() -> void:
		load("res://scenes/pages/rival_page.gd").open(p, {"player_id": pid}))
	built["node"].set_meta("parts", parts)
	content.add_child(built["node"])


static func _face(face: TextureRect, d: Dictionary, win: Rect2) -> void:
	var band := win.size.x
	var framed := Look.frame_art(d, "ring", band) != ""
	var size := band * FACE_IN_FRAME if framed else band + 2.0
	face.texture = Art.tex(Art.avatar_ring(str(d.get("avatar", ""))))
	face.stretch_mode = TextureRect.STRETCH_SCALE
	UI.place(face, Rect2(win.get_center() - Vector2(size, size) / 2.0, Vector2(size, size)))
	Look.paint_frame(face, d, "ring", band)


static func _part_rect(tpl: Dictionary, part_id: String) -> Rect2:
	for q in tpl.get("parts", []):
		if str((q as Dictionary).get("id", "")) == part_id:
			return Layout.rect_of(q)
	return Rect2()


static func _ask(p: PaintedPage) -> void:
	var field: LineEdit = p.get_meta("field")
	var name := field.text.strip_edges()
	if name == "":
		return
	var res: Api.Response = await Api.post_json("/v1/friends/request", {"username": name})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		field.text = ""
		_notice(p, "Asked. %s will find it on their own page." % name)
		_load(p)
	else:
		_notice(p, res.error if res.error != "" else "That lord could not be asked.")


static func _answer(p: PaintedPage, pid: String, yes: bool) -> void:
	var res: Api.Response = await Api.post_json("/v1/friends/answer",
		{"player_id": pid, "accept": yes})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		_load(p)
	else:
		_notice(p, res.error)


## A draught is the lord's own sequenced action: it is a token given away, and
## the purse and the day's count are counting on the number.
static func _gift(p: PaintedPage, pid: String, name: String) -> void:
	var res: Api.Response = await GameState.act("/v1/friends/gift", {"player_id": pid})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		GameState.toast("A draught is on its way to %s." % name)
		_load(p)
	else:
		_notice(p, res.error if res.error != "" else "That draught did not go.")


static func _notice(p: PaintedPage, words: String) -> void:
	p.set_text("notice", words, 14)
	var at := Time.get_ticks_msec()
	p.set_meta("notice_at", at)
	await p.get_tree().create_timer(NOTICE_FOR).timeout
	if is_instance_valid(p) and p.is_inside_tree() and int(p.get_meta("notice_at", 0)) == at:
		p.set_text("notice", "", 14)
