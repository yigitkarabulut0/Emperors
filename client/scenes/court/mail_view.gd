extends Control
## ROYAL MAIL — the Court's mailbox, cut from art/reference/mail.png
## (art/slices/mail.json, layout client/layout/mail.json).
##
## Every reward that arrives outside an action -- a gift from the panel, a
## compensation, and later a purchase, a referral, an event's prize -- is a
## letter here (GET /v1/mail). A row is the painting's: its envelope (sealed with
## the Crown's crown, a kingdom's lion banner, or clasped hands for a gift
## between lords; open once read), the title and who sent it on its two plates,
## and up to three of what it carries in its tiles. A letter going within two
## days wears the painting's short plate and hourglass, and says how long is
## left in red. A tap reads it on the painted letter card (mail_letter.gd).
##
## This is a Court view. The COURT tab does not exist yet, so the shell hosts it
## over the tab host the way it hosts a tab (Shell.open_view): the rail and the
## pills stay, and the back plate (CourtBack) goes back to the tab it was opened
## from. The COURT tab will mount the same view.
##
## No action_seq: a letter is claimed once by its own row on the server, and a
## claim must never move the sequence queued collects are counting on. The
## snapshot it answers with is adopted through GameState.adopt_async.

signal back_requested

const SCREEN := "mail"
## Under this many seconds left, a letter still to claim is said to be going.
const SOON := 2 * 86400
## Which seal a letter's envelope carries, by the kind of letter.
const SEALS := {"kingdom": "mail/envelope_banner", "largesse": "mail/envelope_banner",
	"gift": "mail/envelope_hands", "referral": "mail/envelope_hands", "promo": "mail/envelope_hands"}
const SEAL_CROWN := "mail/envelope_crown"
const ENVELOPE_OPEN := "mail/envelope_open"
const ICONS := ["icon_1", "icon_2", "icon_3"]
const SLOTS := ["slot_1", "slot_2", "slot_3"]

var _ui: Dictionary = {}
var _rows: Array = []            ## [{node, parts, letter}]
var _inbox: Dictionary = {}
var _busy := false
var _built := false
var _reader = null                 ## the letter being read (mail_letter.gd), while it is open
var _claim_pin := 0.0              ## CLAIM ALL's pinned top, from the view's foot


func _ready() -> void:
	_ui = Layout.build(SCREEN, self)
	# The way back, the same plate and word on every Court view.
	_ui["back_hit"] = CourtBack.build(self)
	(_ui["back_hit"] as BaseButton).pressed.connect(func() -> void: back_requested.emit())
	(_ui["claim_all"] as BaseButton).pressed.connect(_claim_all)
	_ui["claim_all"].visible = false
	_claim_pin = (_ui["claim_all"] as Control).offset_top
	resized.connect(_place_claim_all)
	_show_empty(false)
	_built = true


## The shell calls this when the view opens.
func refresh() -> void:
	if _built:
		_load()


func _load() -> void:
	var res: Api.Response = await Api.get_json("/v1/mail")
	if not is_inside_tree():
		return
	if not res.ok:
		GameState.action_failed.emit("The mail could not be read. " + res.error)
		return
	paint(res.data)
	_set_waiting(int(res.data.get("waiting", 0)))


## Paints an inbox (a /v1/mail answer). Public for tests and captures.
func paint(inbox: Dictionary) -> void:
	_inbox = inbox
	var letters: Array = inbox.get("mail", [])
	var sc: ScrollContainer = _ui["list"]
	var content: Control = sc.get_meta("content")
	for r in _rows:
		r["node"].queue_free()
	_rows.clear()
	var tpl := Layout.element(SCREEN, "letter_row")
	var origin := Layout.rect_of(tpl).position - Layout.rect_of(Layout.element(SCREEN, "list")).position
	var pitch := float(tpl.get("pitch", 112))
	for i in letters.size():
		var m: Dictionary = letters[i]
		var built := Layout.instantiate(tpl, _row_overrides(m))
		built["node"].position = origin + Vector2(0, i * pitch)
		built["letter"] = m
		content.add_child(built["node"])
		_dress(built, m)
		_rows.append(built)
	content.custom_minimum_size.y = maxf(sc.size.y, origin.y + letters.size() * pitch + 16.0)
	_show_empty(letters.is_empty())
	var claimable := 0
	for m in letters:
		if bool(m.get("claimable", false)):
			claimable += 1
	_ui["claim_all"].visible = claimable >= 2
	_place_claim_all()


## CLAIM ALL where the painting has it -- just under the last row -- while the
## rows end above its pin; pinned over the footer, under the list, once they
## run past it and the list scrolls.
func _place_claim_all() -> void:
	if not _built:
		return
	var ca: Control = _ui["claim_all"]
	var tpl := Layout.element(SCREEN, "letter_row")
	var row := Layout.rect_of(tpl)
	var pitch := float(tpl.get("pitch", 112))
	var list := Layout.rect_of(Layout.element(SCREEN, "list"))
	# The painting's own gap: the sixth row's plate ends where its target starts.
	var after := Layout.rect_of(Layout.element(SCREEN, "claim_all_after_rows"))
	var lead := after.position.y - (row.position.y + 5.0 * pitch + row.size.y)
	var rows_end := (_ui["list"] as Control).position.y + row.position.y - list.position.y \
		+ float(maxi(_rows.size(), 1) - 1) * pitch + row.size.y
	var h := ca.offset_bottom - ca.offset_top
	var top := minf(size.y + _claim_pin, rows_end + lead)
	ca.offset_top = top - size.y
	ca.offset_bottom = ca.offset_top + h


## The plate, the envelope and where the envelope sits, for one letter.
static func _row_overrides(m: Dictionary) -> Dictionary:
	var assets := {"plate": "mail/row_soon" if going_soon(m) else "mail/row", "envelope": envelope_for(m)}
	var rects := {}
	if bool(m.get("read", false)):
		rects["envelope"] = Layout.element(SCREEN, "envelope_open").get("rect", [13, 2, 154, 96])
	if going_soon(m):
		rects["line"] = Layout.element(SCREEN, "row_soon_line").get("rect", [194, 52, 192, 25])
	return {"assets": assets, "rects": rects}


## The envelope a letter is drawn with: open once read, else sealed by kind.
static func envelope_for(m: Dictionary) -> String:
	if bool(m.get("read", false)):
		return ENVELOPE_OPEN
	return str(SEALS.get(str(m.get("kind", "")), SEAL_CROWN))


## A letter still to claim with under two days left.
static func going_soon(m: Dictionary) -> bool:
	var left := int(m.get("expires_in", 0))
	return bool(m.get("claimable", false)) and left > 0 and left < SOON


## What the row's second plate says: who sent it and when, or -- for a letter
## going soon -- who sent it and how long is left.
static func line_words(m: Dictionary) -> String:
	return str(m.get("sender", "")) + line_tail(m)


## The part of the line after the sender: when it came, or how long is left.
static func line_tail(m: Dictionary) -> String:
	if going_soon(m):
		return "  ·  %s left" % UI.time_left(int(m.get("expires_in", 0)))
	return "  ·  " + UI.ago(seconds_since(str(m.get("created_at", ""))))


func _dress(built: Dictionary, m: Dictionary) -> void:
	var p: Dictionary = built["parts"]
	var read := bool(m.get("read", false))
	var claimable := bool(m.get("claimable", false))
	var soon := going_soon(m)
	_fit(p["title"], str(m.get("title", "")), UI.INK if read else UI.GOLD)
	_fit_line(p["line"], m, UI.RED if soon else UI.DIM)
	p["hourglass"].visible = soon
	var lines: Array = m.get("lines", [])
	for i in ICONS.size():
		var ic: TextureRect = p[ICONS[i]]
		ic.visible = i < lines.size()
		# A frame under each reward the letter carries and none where it carries
		# nothing: the row is cut without its three, and a letter with no gift
		# showed three empty boxes.
		p[SLOTS[i]].visible = ic.visible
		var slot: Control = p[SLOTS[i]]
		var g := ItemGround.for_line(ic, lines[i] if ic.visible else {},
			ItemGround.inset(Rect2(slot.position, slot.size), 5.0))
		if ic.visible:
			ic.texture = Art.reward_line_icon(lines[i])
			ic.modulate = Color.WHITE if claimable else Color(0.5, 0.5, 0.52)
			g.modulate = ic.modulate
	var extra := lines.size() - ICONS.size()
	p["more"].visible = extra > 0
	p["more_text"].visible = extra > 0
	p["more_text"].text = "+%d" % extra
	(p["hit"] as BaseButton).pressed.connect(func() -> void: read_letter(m))


## A row's words: at the painting's size, two points smaller if they must, and
## past that cut with an ellipsis -- a title may be eighty characters.
static func _fit(l: Label, text: String, col: Color) -> void:
	l.text = text
	l.label_settings.font_color = col
	UI.fit_line(l, l.label_settings.font_size, l.label_settings.font_size - 2)


## The second plate's words, fitted like a title's -- except that the sender is
## what gives way: a forty-letter sender is cut short with an ellipsis so that
## how long is left (the reason the plate is red) is always read in full.
static func _fit_line(l: Label, m: Dictionary, col: Color) -> void:
	var sender := str(m.get("sender", ""))
	var tail := line_tail(m)
	_fit(l, sender + tail, col)
	var box := Vector2(float(l.get_meta("box_w", l.size.x)), l.size.y)
	var s := l.label_settings
	var n := sender.length()
	while n > 1 and s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > box.x:
		n -= 1
		l.text = sender.left(n).strip_edges().rstrip(",;:-·") + "…" + tail
	l.size = box


func _show_empty(empty: bool) -> void:
	_ui["empty_desk"].visible = empty
	_ui["empty_text"].visible = empty


# --- one letter ------------------------------------------------------------------

## Reads a letter on the painted card. Public: the dev page `letter` opens one.
func read_letter(m: Dictionary) -> void:
	if _reader != null and is_instance_valid(_reader):
		return
	_reader = load("res://scenes/court/mail_letter.gd").new()
	_reader.setup(m, self)
	Nav.overlay_parent().add_child(_reader)
	_reader.claim_pressed.connect(func() -> void: _claim(m))
	_reader.throw_pressed.connect(func() -> void: _throw_away(m))
	_reader.closed.connect(func() -> void:
		_reader = null
		if is_inside_tree():
			paint(_inbox))
	if not bool(m.get("read", false)):
		m["read"] = true
		var res: Api.Response = await Api.post_json("/v1/mail/read", {"id": int(m.get("id", 0))})
		if res.ok and is_inside_tree():
			_set_waiting(waiting(_inbox))


func _claim(m: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/mail/claim", {"id": int(m.get("id", 0))})
	if res.ok:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		GameState.toast(claimed_words(res.data.get("granted", {}).get("lines", [])))
		_close_reader()
	elif res.code == "inventory_full":
		# OK, and MORE ROOM beside it while the Quartermaster can be bought.
		await Armory.refused(self, res.error, Armory.sentence(res.error)
			+ " Sell or wear something, then claim the letter.")
	else:
		GameState.action_failed.emit(res.error)
	if is_inside_tree():
		await _load()
	_busy = false


func _claim_all() -> void:
	if _busy:
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/mail/claim-all", {})
	var full := 0
	if not res.ok:
		GameState.action_failed.emit(res.error)
	else:
		if res.data.get("snapshot", null) is Dictionary:
			GameState.adopt_async(res.data["snapshot"])
		var got: Array = res.data.get("claimed", [])
		if not got.is_empty():
			GameState.toast(claimed_words(res.data.get("lines", [])))
		for k in res.data.get("skipped", []):
			if str(k.get("reason", "")) == "inventory_full":
				full += 1
	if full > 0 and is_inside_tree():
		await Armory.refused(self, "", "%d letter%s carry gear your armory has no room for, and wait for you. Sell or wear something, then claim %s." % [
			full, "" if full == 1 else "s", "it" if full == 1 else "them"])
	if is_inside_tree():
		await _load()
	_busy = false


func _throw_away(m: Dictionary) -> void:
	if _busy:
		return
	if not await Dialog.ask(self, {"title": "Throw this letter away?", "body": str(m.get("title", "")),
			"confirm_text": "Throw away", "danger": true}):
		return
	_busy = true
	var res: Api.Response = await Api.post_json("/v1/mail/delete", {"id": int(m.get("id", 0))})
	if res.ok:
		_close_reader()
	else:
		GameState.action_failed.emit(res.error)
	if is_inside_tree():
		await _load()
	_busy = false


func _close_reader() -> void:
	if _reader != null and is_instance_valid(_reader):
		_reader.close()
	_reader = null


func _exit_tree() -> void:
	_close_reader()


# --- words ------------------------------------------------------------------------

## What a claim delivered, in the server's words: the first three, and how
## many more.
static func claimed_words(lines: Array) -> String:
	if lines.is_empty():
		return "Claimed"
	var words: Array[String] = []
	for i in mini(lines.size(), 3):
		words.append(str(lines[i].get("text", "")))
	var out := "Claimed " + ", ".join(words)
	if lines.size() > 3:
		out += " and %d more" % (lines.size() - 3)
	return out


## Letters waiting as the heartbeat counts them: unread, or with something
## still to claim.
static func waiting(inbox: Dictionary) -> int:
	var n := 0
	for m in inbox.get("mail", []):
		if not bool(m.get("read", false)) or bool(m.get("claimable", false)):
			n += 1
	return n


## The portrait's count, moved with the claim rather than on the next beat.
static func _set_waiting(n: int) -> void:
	var b := GameState.badges.duplicate()
	b["mail"] = n
	GameState.set_badges(b)


static func seconds_since(iso: String) -> int:
	if iso == "":
		return 0
	var then := Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))
	return maxi(0, int(Time.get_unix_time_from_system()) - int(then))
