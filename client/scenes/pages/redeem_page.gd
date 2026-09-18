extends RefCounted
## REDEEM A CODE — a code the Crown gave out, typed in, and its reward sent.
##
## Drawn on YOUR LORDSHIP's own page (art/reference/profile.png, cut by
## art/slices/profile.json, laid out by client/layout/redeem.json) on the
## painted pages' host: the sealed envelope from the profile's REDEEM A CODE
## row, the painting's empty box for the code, REDEEM, and CLOSE.
##
## The code is kept as the server keeps it (service.NormalizePromo): upper
## case, letters and digits only -- a space, a dash or anything else typed is
## dropped as it is typed, so what the box shows is what is sent. REDEEM stays
## dimmed until the code is 4 to 20 of them, and takes one request at a time.
##
## POST /v1/promo/redeem {code, device} answers with the letter it sent: its
## title and what it carries (rewards.Line). The reward is not here -- it is a
## Royal Mail letter -- so the page says a letter is waiting, shows what it
## carries as the mail rows do (Art.reward_line_icon), and offers the way to it.
## A refusal is said in the page's own words, never the server's error.

const PAGE := "redeem"
const SCREEN := "page:redeem"
const MIN_LEN := 4
const MAX_LEN := 20
## Reward lines shown under the letter's title; the rest are counted.
const SHOWN := 5
const SENDING := "Sending the code to the Crown…"
## The refusals, by the server's code (httpx/promo.go promoProblem).
const REFUSALS := {
	"promo_invalid": "There is no such code, or its time has passed.",
	"promo_used": "That code has already been redeemed, on this account or on this phone.",
	"too_many_attempts": "Too many wrong codes. Try again in an hour.",
	"no_device": "This phone cannot redeem codes.",
}
const TRY_AGAIN := "The code could not be sent. Try again in a moment."
## What the status line says while nothing has been sent.
const HOW := "Each code is taken once on an account and once on a phone, and its reward comes as a letter in the Royal Mail."
const RED := Color("#F0524F")


## Opens the page over `host`. `opts` goes to PaintedPage.open (a test's
## "inset"), and "open_mail" may be a Callable the opener runs instead of
## simply opening the Royal Mail -- the profile closes itself first.
static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	if opts.get("open_mail", null) is Callable:
		p.set_meta("open_mail", opts["open_mail"])
	var field := p.field("code", "CODE")
	field.max_length = 64
	field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	p.set_meta("field", field)
	field.text_changed.connect(func(t: String) -> void: _typed(p, field, t))
	field.text_submitted.connect(func(_t: String) -> void: _redeem(p))
	p.on("redeem", func() -> void: _redeem(p))
	p.on("open_mail", func() -> void: _open_mail(p))
	_show_result(p, {})
	_say(p, HOW, false)
	_refresh(p)
	return p


## A code as the server keeps it: upper case, letters and digits only, at
## most MAX_LEN of them.
static func normalise(t: String) -> String:
	var out := ""
	for ch in t.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out.left(MAX_LEN)


## The page's words for a refusal.
static func refusal(res_code: String) -> String:
	return str(REFUSALS.get(res_code, TRY_AGAIN))


static func can_send(code: String) -> bool:
	return code.length() >= MIN_LEN and code.length() <= MAX_LEN


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
	p.set_enabled("redeem", can_send(normalise(field.text)) and not bool(p.get_meta("busy", false)))


static func _redeem(p: PaintedPage) -> void:
	var field: LineEdit = p.get_meta("field")
	var code := normalise(field.text)
	if bool(p.get_meta("busy", false)) or not can_send(code):
		return
	p.set_meta("busy", true)
	_refresh(p)
	_show_result(p, {})
	_say(p, SENDING, false)
	var res: Api.Response = await Api.post_json("/v1/promo/redeem", {"code": code, "device": Session.device_id()})
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	p.set_meta("busy", false)
	if res.ok:
		field.text = ""
		_say(p, "", false)
		_show_result(p, res.data)
	else:
		_say(p, refusal(res.code), true)
	_refresh(p)


static func _say(p: PaintedPage, words: String, refused: bool) -> void:
	var l := p.set_text("status", words, 18)
	if l != null:
		l.label_settings.font_color = RED if refused else UI.DIM
	p.set_shown("status", words != "")


## The letter the code sent: its title, what it carries, and the way to it.
## An empty answer hides the block.
static func _show_result(p: PaintedPage, data: Dictionary) -> void:
	var shown := not data.is_empty()
	for id in ["result_title", "result_note", "open_mail"]:
		p.set_shown(id, shown)
	for n in p.get_meta("lines", []):
		if is_instance_valid(n):
			n.queue_free()
	p.set_meta("lines", [])
	if not shown:
		return
	var title := str(data.get("title", ""))
	p.set_text("result_note", ("“%s” is in your Royal Mail." % title) if title != "" else "It is in your Royal Mail.", 16)
	var lines: Array = data.get("lines", [])
	var tpl := Layout.element(PAGE, "reward_line")
	var at := Layout.rect_of(tpl)
	var pitch := float(tpl.get("pitch", 62))
	var made: Array = []
	var rows := mini(lines.size(), SHOWN)
	var built_rows: Array = []
	var widest := 0.0
	for i in rows:
		var built := Layout.instantiate(tpl)
		var parts: Dictionary = built["parts"]
		(parts["icon"] as TextureRect).texture = Art.reward_line_icon(lines[i])
		var l: Label = parts["text"]
		l.text = str(lines[i].get("text", ""))
		UI.fit_line(l, 26, 18)
		widest = maxf(widest, minf(l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			l.label_settings.font_size).x, l.size.x))
		built_rows.append(built)
	# The lines are one block, icons in a column, centred on the page by the
	# widest of them -- short lines under a centred heading otherwise sat to
	# its left.
	var text_x := 72.0
	for part in tpl.get("parts", []):
		if str((part as Dictionary).get("id", "")) == "text":
			text_x = Layout.rect_of(part).position.x
	var shift := floorf((at.size.x - (text_x + widest)) / 2.0) if rows > 0 else 0.0
	for i in built_rows.size():
		p.place(built_rows[i]["node"], Rect2(at.position + Vector2(shift, i * pitch), at.size))
		made.append(built_rows[i]["node"])
	if lines.size() > SHOWN:
		var more := UI.label("and %d more" % (lines.size() - SHOWN), 22, UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_LEFT)
		p.place(more, Rect2(at.position + Vector2(shift + text_x, SHOWN * pitch), Vector2(at.size.x - text_x, 40)))
		made.append(more)
	p.set_meta("lines", made)


static func _open_mail(p: PaintedPage) -> void:
	var then: Variant = p.get_meta("open_mail") if p.has_meta("open_mail") else null
	var shell := p.get_tree().get_first_node_in_group("shell") if p.is_inside_tree() else null
	p.close()
	if then is Callable:
		(then as Callable).call()
	elif shell != null:
		shell.open_view("mail")
