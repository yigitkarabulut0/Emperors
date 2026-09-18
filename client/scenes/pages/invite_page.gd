extends RefCounted
## INVITE A FRIEND — the lord's own code, the friends it brought, and a
## friend's code entered while a new lord still may.
##
## Drawn on YOUR LORDSHIP's own page (art/reference/profile.png, cut by
## art/slices/profile.json, laid out by client/layout/invite.json) on the
## painted pages' host: the trumpet from the profile's INVITE A FRIEND row,
## the code large in the painting's empty box, the painted FRIENDS heading, a
## friend's row cut from the painting -- their face in its ring and their name
## in the look they wear, as every list of lords draws one -- and CLOSE.
##
## GET /v1/referral is the whole page: the code, what the Crown pays and at
## which level (every number in the terms is the server's), the friends, how
## many more it will reward, and -- for a new lord -- whether a friend's code
## may still be entered and for how long. POST /v1/referral/claim answers with
## the same view. COPY puts the code on the clipboard; there is no share sheet
## without a plugin, and none is pretended.

const PAGE := "invite"
const SCREEN := "page:invite"
const MIN_LEN := 4
const MAX_LEN := 20
const COPIED_FOR := 1.6
const READING := "Reading your code…"
## The refusals of a friend's code, by the server's code (httpx/promo.go).
const REFUSALS := {
	"referral_invalid": "No lord has that code, or that lord cannot bring friends yet.",
	"referral_self": "That is your own code, or one from this phone.",
	"referral_closed": "The week to enter a friend's code has passed.",
	"referral_limit": "That lord has brought all the friends they can for now.",
	"no_device": "This phone cannot enter a friend's code.",
}
const TRY_AGAIN := "The code could not be sent. Try again in a moment."
const RED := Color("#F0524F")
const CLAIM_BLOCK := ["claim_label", "claim_time", "claim_box", "claim", "claim_status"]
## Between the list and the line under it when the list takes the block's room.
const LIST_GAP := 14.0
## A face inside a worn frame fills the frame's own window (as the profile's).
const FACE_IN_FRAME := 0.78


## Opens the page over `host` and reads the lord's code. `opts` goes to
## PaintedPage.open (a test's "inset"); a test passes "view" to paint one
## without the server.
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	var field := p.field("friend_code", "CODE")
	field.max_length = 64
	p.set_meta("field", field)
	field.text_changed.connect(func(t: String) -> void: _typed(p, field, t))
	field.text_submitted.connect(func(_t: String) -> void: _claim(p))
	p.on("copy", func() -> void: _copy(p))
	p.on("claim", func() -> void: _claim(p))
	if opts.get("view", null) is Dictionary:
		paint(p, opts["view"])
	else:
		paint(p, {})
		_load(p)
	return p


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/referral")
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		paint(p, res.data)
	else:
		p.set_text("terms", "Your code could not be read. " + TRY_AGAIN, 16).label_settings.font_color = RED


## A code as the server keeps it (service.NormalizePromo).
static func normalise(t: String) -> String:
	var out := ""
	for ch in t.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out.left(MAX_LEN)


static func refusal(res_code: String) -> String:
	return str(REFUSALS.get(res_code, TRY_AGAIN))


## The terms, in the server's numbers.
static func terms(v: Dictionary) -> String:
	var left := int(v.get("rewards_left", 0))
	var level := int(v.get("reward_level", 0))
	if left <= 0:
		return "Your code has brought every friend the Crown rewards. Well done, my lord."
	return "When a friend who joined with your code reaches level %d, you get %s diamonds and they get %s, for up to %s." % [
		level, UI.grouped(int(v.get("inviter_diamonds", 0))), UI.grouped(int(v.get("invitee_diamonds", 0))),
		"one more friend" if left == 1 else "%s more friends" % UI.grouped(left)]


## What the right of a friend's row says.
static func state_words(f: Dictionary, reward_level: int) -> String:
	return "REWARDED" if bool(f.get("rewarded", false)) else "AT LEVEL %d" % reward_level


## Paints a referral view (GET /v1/referral or a claim's answer). An empty
## view is the page while it reads.
static func paint(p: PaintedPage, v: Dictionary) -> void:
	p.set_meta("view", v)
	var loaded := not v.is_empty()
	var can := loaded and bool(v.get("can_claim", false))
	var by := str(v.get("claimed_by", ""))
	p.set_text("code", str(v.get("code", "")), 32)
	p.set_enabled("copy", loaded and str(v.get("code", "")) != "")
	var t := p.set_text("terms", terms(v) if loaded else READING, 16)
	if t != null:
		t.label_settings.font_color = UI.INK if loaded else UI.DIM

	# With no code to enter, the list takes the room the block had: down to
	# the line naming whose code it was, or to where the block ended.
	var sc := p.node("friends")
	if sc != null:
		if not sc.has_meta("painted_h"):
			sc.set_meta("painted_h", sc.size.y)
		var foot := sc.position.y + float(sc.get_meta("painted_h"))
		if loaded and not can:
			var r := p.map_rect(Layout.rect_of(Layout.element(PAGE, "claimed" if by != "" else "claim_status")))
			foot = (r.position.y - LIST_GAP) if by != "" else r.end.y
		sc.size.y = foot - sc.position.y
	_friends(p, v.get("friends", []) if loaded else [], int(v.get("reward_level", 0)))
	p.set_shown("empty", loaded and (v.get("friends", []) as Array).is_empty())
	if loaded:
		p.set_text("empty", "No friend has joined with your code yet.", 18)

	# A friend's code: only while this lord may still enter one.
	for id in CLAIM_BLOCK:
		p.set_shown(id, can)
	var field: LineEdit = p.get_meta("field")
	field.visible = can
	if can:
		p.set_text("claim_time", "You can enter one for another %s." % UI.time_left(maxi(0, int(v.get("claim_in", 0)))), 16)
		_say(p, "", false)
	p.set_shown("claimed", loaded and by != "")
	if by != "":
		p.set_text("claimed", "You joined the realm with the code of %s." % by, 18)
	_refresh(p)


## One row a friend, in the scroll under FRIENDS.
static func _friends(p: PaintedPage, friends: Array, reward_level: int) -> void:
	var content := p.content("friends")
	if content == null:
		return
	for c in content.get_children():
		c.queue_free()
	var tpl := Layout.element(PAGE, "friend_row")
	var pitch := float(tpl.get("pitch", 121))
	var origin := Layout.rect_of(tpl).position - Layout.rect_of(Layout.element(PAGE, "friends")).position
	var name_box := _part_rect(tpl, "name")
	for i in friends.size():
		var f: Dictionary = friends[i]
		var built := Layout.instantiate(tpl)
		var parts: Dictionary = built["parts"]
		built["node"].position = origin + Vector2(0, i * pitch)
		_friend_face(parts["face"] as TextureRect, f, _part_rect(tpl, "face"))
		# The name as every list of lords writes it: in the colour they wear,
		# Royal Favour's seal beside it.
		Look.paint_name(parts["name"] as Label, f, str(f.get("name", "")), name_box, 26, 18)
		var level: Label = parts["level"]
		level.text = "Lv %d" % int(f.get("level", 0))
		UI.fit_line(level, 24, 16)
		var rewarded := bool(f.get("rewarded", false))
		(parts["mark"] as Control).visible = rewarded
		var state: Label = parts["state"]
		state.text = state_words(f, reward_level)
		state.label_settings.font_color = UI.GOLD if rewarded else UI.DIM
		UI.fit_line(state, 20, 14)
		built["node"].set_meta("parts", parts)
		content.add_child(built["node"])
	var sc := content.get_parent() as Control
	content.custom_minimum_size.y = maxf(sc.size.y if sc != null else 0.0, origin.y + friends.size() * pitch)


## A friend's face, round, in the painted ring's window -- or, when they wear
## a frame, in the frame's own window inside it, as the profile draws the lord.
static func _friend_face(face: TextureRect, f: Dictionary, win: Rect2) -> void:
	var band := win.size.x
	var framed := Look.frame_art(f, "ring", band) != ""
	var d := band * FACE_IN_FRAME if framed else band + 2.0
	face.texture = Art.tex(Art.avatar_ring(str(f.get("avatar", ""))))
	face.stretch_mode = TextureRect.STRETCH_SCALE
	UI.place(face, Rect2(win.get_center() - Vector2(d, d) / 2.0, Vector2(d, d)))
	Look.paint_frame(face, f, "ring", band)


static func _part_rect(tpl: Dictionary, part_id: String) -> Rect2:
	for q in tpl.get("parts", []):
		if str((q as Dictionary).get("id", "")) == part_id:
			return Layout.rect_of(q)
	return Rect2()


static func _copy(p: PaintedPage) -> void:
	var v: Dictionary = p.get_meta("view", {})
	var code := str(v.get("code", ""))
	if code == "":
		return
	DisplayServer.clipboard_set(code)
	var b := p.node("copy") as Button
	if b == null:
		return
	b.text = "COPIED"
	p.get_tree().create_timer(COPIED_FOR).timeout.connect(func() -> void:
		if is_instance_valid(b):
			b.text = "COPY")


static func _typed(p: PaintedPage, field: LineEdit, t: String) -> void:
	var n := normalise(t)
	if n != t:
		field.text = n
		field.caret_column = n.length()
	fit_field(field)
	_refresh(p)


## The box's type at its painted size, smaller as the code grows past what
## the box holds -- twenty of the widest letter still fit it.
static func fit_field(field: LineEdit, min_size: int = 22) -> void:
	var painted := int(field.get_meta("painted_size", field.get_theme_font_size("font_size")))
	field.set_meta("painted_size", painted)
	var f: Font = field.get_theme_font("font")
	var room := field.size.x - 16.0
	var size := painted
	while size > min_size and f.get_string_size(field.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > room:
		size -= 1
	field.add_theme_font_size_override("font_size", size)


static func _refresh(p: PaintedPage) -> void:
	var field: LineEdit = p.get_meta("field")
	var n := normalise(field.text).length()
	p.set_enabled("claim", n >= MIN_LEN and n <= MAX_LEN and not bool(p.get_meta("busy", false)))


static func _claim(p: PaintedPage) -> void:
	var field: LineEdit = p.get_meta("field")
	var code := normalise(field.text)
	if bool(p.get_meta("busy", false)) or code.length() < MIN_LEN:
		return
	p.set_meta("busy", true)
	_refresh(p)
	_say(p, "Sending the code…", false)
	var res: Api.Response = await Api.post_json("/v1/referral/claim", {"code": code, "device": Session.device_id()})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	p.set_meta("busy", false)
	if res.ok:
		field.text = ""
		paint(p, res.data)
	else:
		_say(p, refusal(res.code), true)
		_refresh(p)


static func _say(p: PaintedPage, words: String, refused: bool) -> void:
	var l := p.set_text("claim_status", words, 16)
	if l != null:
		l.label_settings.font_color = RED if refused else UI.DIM
		l.visible = words != "" and bool((p.get_meta("view", {}) as Dictionary).get("can_claim", false))
