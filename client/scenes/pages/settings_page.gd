extends RefCounted
## SETTINGS -- what the realm may send and when it may not, who may look, the
## Rules of the Hall, the lords this one will not hear from, and where a person
## answers.
##
## Drawn on YOUR LORDSHIP's own page (profile.png) from the pieces the painting
## already has: its row plate, and the switch it stands at its foot. Every
## yes-or-no in the realm is that switch, at the row's right end, where GIFT
## stands on a friend's row.
##
## Nothing here is remembered on the phone. Each switch is a call
## (/v1/settings/notify, /v1/settings/privacy) and the page paints the answer:
## a preference that lives in two places is a preference that disagrees with
## itself on the second device.
##
## App Review 1.2 wants three things where there is talking: the rules, a way
## to report, and a way to reach a person. The hall's rows carry the report;
## the last two rows here carry the other two.

const PAGE := "settings"
const SCREEN := "page:settings"
## The three ways a lord may be looked at, and what each says.
const WHO := [["all", "Everybody"], ["friends", "Friends only"], ["kingdom", "My kingdom"]]
## The hours quiet hours may be set to, as the picker offers them.
const HOURS := [0, 6, 7, 8, 9, 10, 20, 21, 22, 23]


static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	p.on("close", func() -> void: p.close())
	if opts.get("view", null) is Dictionary:
		paint(p, opts["view"])
	else:
		paint(p, {})
		_load(p)
	return p


static func _load(p: PaintedPage) -> void:
	var res: Api.Response = await Api.get_json("/v1/settings")
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if res.ok:
		paint(p, res.data)


## Paints with a /v1/settings answer. Public for the tests and the captures.
static func paint(p: PaintedPage, v: Dictionary) -> void:
	p.set_meta("view", v)
	var content := p.content("body")
	if content == null:
		return
	for c in content.get_children():
		c.queue_free()
	if v.is_empty():
		return
	var notify: Dictionary = v.get("notify", {}) if v.get("notify") is Dictionary else {}
	var privacy: Dictionary = v.get("privacy", {}) if v.get("privacy") is Dictionary else {}
	var blocked: Array = v.get("blocked", []) if v.get("blocked") is Array else []
	var y := 0.0
	y = _head(p, content, y, "WHAT THE REALM MAY SEND")
	for r in [["raid", "When another lord raids me"], ["chat", "When my kingdom speaks"],
			["mail", "When a letter arrives"], ["events", "When an event begins"],
			["friends", "When a friend asks or gives"]]:
		var key := str(r[0])
		y = _switch_row(p, content, y, str(r[1]), bool(notify.get(key, true)),
			func(on: bool) -> void: await _notify(p, {key: on}))
	y = _words_row(p, content, y, "Quiet hours", _quiet_words(notify),
		func() -> void: await _quiet(p, notify))

	y = _head(p, content, y, "WHO MAY LOOK")
	y = _words_row(p, content, y, "My page is open to", _who_words(str(privacy.get("profile", "all"))),
		func() -> void: await _who(p, privacy))
	y = _switch_row(p, content, y, "Show that I am here", bool(privacy.get("online", true)),
		func(on: bool) -> void: await _privacy(p, {"online": on}))
	y = _switch_row(p, content, y, "Let lords ask to be friends", bool(privacy.get("requests", true)),
		func(on: bool) -> void: await _privacy(p, {"requests": on}))

	y = _head(p, content, y, "THE HALL")
	y = _words_row(p, content, y, "Rules of the Hall", "read", func() -> void:
		load("res://scenes/pages/rules_of_the_hall.gd").call("open", p, {"rules": v.get("rules", {})}))
	y = _words_row(p, content, y, "Lords I will not hear from",
		"%d" % blocked.size(), func() -> void: await _blocked(p, blocked))
	y = _words_row(p, content, y, "Write to the crown", str(v.get("support", "")), func() -> void:
		DisplayServer.clipboard_set(str(v.get("support", "")))
		GameState.toast("The crown's address is on your clipboard."))

	var sc := content.get_parent() as Control
	content.custom_minimum_size.y = maxf(sc.size.y if sc != null else 0.0, y)


# --- the rows ---------------------------------------------------------------------------

static func _head(p: PaintedPage, content: Control, y: float, word: String) -> float:
	var tpl := Layout.element(PAGE, "head")
	var built := Layout.instantiate(tpl)
	built["node"].position = Vector2(0, y + 18.0)
	var l := built["parts"]["word"] as Label
	l.text = word
	UI.fit_line(l, 30, 20)
	built["node"].set_meta("head", true)
	content.add_child(built["node"])
	return y + 18.0 + Layout.rect_of(tpl).size.y + 6.0


## A row with the painting's switch at its end. `set_to` is called with what the
## switch would become; the page repaints from the realm's answer.
static func _switch_row(p: PaintedPage, content: Control, y: float, word: String, on: bool,
		set_to: Callable) -> float:
	var built := _row(p, content, y, word, "")
	var sw := built["parts"]["switch"] as TextureRect
	sw.texture = Art.tex("profile/toggle_on" if on else "profile/toggle_off")
	(built["parts"]["hit"] as BaseButton).pressed.connect(func() -> void: await set_to.call(not on))
	return y + float(Layout.element(PAGE, "row").get("pitch", 121))


## A row that says a word rather than a yes or a no: it opens something.
static func _words_row(p: PaintedPage, content: Control, y: float, word: String, value: String,
		tapped: Callable) -> float:
	var built := _row(p, content, y, word, value)
	(built["parts"]["switch"] as Control).visible = false
	(built["parts"]["hit"] as BaseButton).pressed.connect(func() -> void: await tapped.call())
	return y + float(Layout.element(PAGE, "row").get("pitch", 121))


static func _row(p: PaintedPage, content: Control, y: float, word: String, value: String) -> Dictionary:
	var tpl := Layout.element(PAGE, "row")
	var built := Layout.instantiate(tpl)
	built["node"].position = Vector2(0, y)
	var l := built["parts"]["word"] as Label
	l.text = word
	UI.fit_line(l, 30, 20)
	var val := built["parts"]["value"] as Label
	val.text = value
	val.visible = value != ""
	UI.fit_line(val, 26, 17)
	built["node"].set_meta("parts", built["parts"])
	content.add_child(built["node"])
	return built


# --- what a row does --------------------------------------------------------------------

## The two calls answer with the block they changed, not the whole page: the
## page keeps what it had and takes the realm's word for that block.
static func _notify(p: PaintedPage, change: Dictionary) -> void:
	await _put(p, "/v1/settings/notify", "notify", change)


static func _privacy(p: PaintedPage, change: Dictionary) -> void:
	await _put(p, "/v1/settings/privacy", "privacy", change)


static func _put(p: PaintedPage, path: String, key: String, change: Dictionary) -> void:
	var v: Dictionary = p.get_meta("view", {})
	var body: Dictionary = (v.get(key, {}) as Dictionary).duplicate()
	body.merge(change, true)
	var res: Api.Response = await Api.post_json(path, body)
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	if not res.ok:
		GameState.toast(res.error if res.error != "" else "The realm did not take that.")
		return
	var next: Dictionary = v.duplicate(true)
	next[key] = res.data
	paint(p, next)


static func _who_words(who: String) -> String:
	for w in WHO:
		if str(w[0]) == who:
			return str(w[1])
	return str(WHO[0][1])


static func _who(p: PaintedPage, privacy: Dictionary) -> void:
	var options: Array = []
	for w in WHO:
		options.append({"id": str(w[0]), "label": str(w[1]).to_upper()})
	var picked := await Dialog.choose(p, {"title": "WHO MAY OPEN MY PAGE",
		"body": "A lord who may not open it is told there is no such lord -- never that they were shut out.",
		"options": options})
	if picked != "" and is_instance_valid(p):
		await _privacy(p, {"profile": picked})


static func _quiet_words(notify: Dictionary) -> String:
	var from := int(notify.get("quiet_from", 0))
	var to := int(notify.get("quiet_to", 0))
	if from == to:
		return "none"
	return "%02d:00 - %02d:00" % [from, to]


static func _quiet(p: PaintedPage, notify: Dictionary) -> void:
	var options: Array = [{"id": "none", "label": "NONE"}]
	for h in HOURS:
		options.append({"id": "%d" % h, "label": "%02d:00" % h})
	var from := await Dialog.choose(p, {"title": "QUIET FROM",
		"body": "The realm sends nothing between these hours, in your own day.", "options": options})
	if from == "" or not is_instance_valid(p):
		return
	if from == "none":
		await _notify(p, {"quiet_from": 0, "quiet_to": 0})
		return
	var to := await Dialog.choose(p, {"title": "QUIET UNTIL",
		"body": "Quiet from %02d:00 until…" % int(from), "options": options.slice(1)})
	if to == "" or not is_instance_valid(p):
		return
	await _notify(p, {"quiet_from": int(from), "quiet_to": int(to)})


## The lords this one will not hear from: named, and let back in one at a time.
static func _blocked(p: PaintedPage, blocked: Array) -> void:
	if blocked.is_empty():
		GameState.toast("You are not blocking anybody.")
		return
	var options: Array = []
	for b in blocked:
		var d: Dictionary = b
		options.append({"id": str(d.get("player_id", "")), "label": str(d.get("name", "")).to_upper()})
	var picked := await Dialog.choose(p, {"title": "LORDS I WILL NOT HEAR FROM",
		"body": "Choose a lord to hear from again.", "options": options})
	if picked == "" or not is_instance_valid(p):
		return
	var res: Api.Response = await Api.post_json("/v1/blocks/remove", {"player_id": picked})
	if is_instance_valid(p) and p.is_inside_tree():
		GameState.toast("You will hear from them again." if res.ok else res.error)
		_load(p)
