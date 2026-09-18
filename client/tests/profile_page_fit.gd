extends SceneTree
## YOUR LORDSHIP (scenes/pages/profile_page.gd) is the owner's painting of it,
## draws the lord as every other lord is drawn, and every row opens its page.
##
## It was a Sheet: the dialogs' plate, a portrait in a square, the name and
## level as text and a column of kit buttons. It is now art/reference/
## profile.png on the painted pages' host. What must hold, on 941x1672 and
## 941x2040, with and without a notch:
##  - it is a painted page; its seven rows are the painting's plates in the
##    painting's order, each with its icon and word, evenly spaced down the
##    frame with no hole under the last;
##  - each row opens its page: ROYAL MAIL, SPLENDOUR and THE CROWN'S FAVOUR
##    the shell's views (the profile giving way to the mail), RANKINGS, REDEEM
##    A CODE and INVITE A FRIEND their painted pages, ACCOUNT the page with SIGN
##    OUT and DELETE ACCOUNT; the portrait opens the faces, CLOSE closes;
##  - the header draws what the lord wears and only that (Look): the title on
##    the ribbon in the colour worn, else the level in gold; the name in the
##    colour worn; Royal Favour's seal only when held, beside the name and
##    clear of it; the frame only when worn, the face then inside its window;
##    the crest worn, else the one the id picks;
##  - the figures: the level, the might as the paintings write a big figure,
##    the kingdom's name -- or its tag when the name will not go at a size that
##    reads -- and "No kingdom" for a lord without one;
##  - every figure sits right of its plate's icon and inside its plate, and
##    the ribbon's words inside its face however long the title (a sample
##    title once stretched the ribbon's label past its folds);
##  - ROYAL MAIL's badge carries the waiting count, 9+ past nine;
##  - nothing leaves the screen or goes under the notch, every button takes a
##    thumb.
##
## Run: godot --headless --path client --script tests/profile_page_fit.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0
const LONG := "Wwwwwwwwwwwwwwww"
const ID := "e1df1ac8-f117-41f9-a476-69049fc98ee2"
## Measured off art/reference/profile.png: where each plate's icon ink ends
## and where the plate's inside ends (x), the plates' inside (y), and the
## ribbon's face between its gold edges.
const PLATES := {"level": [308.0, 385.0], "might": [453.0, 540.0], "kingdom": [616.0, 686.0]}
const PLATE_Y := [430.0, 486.0]
const RIBBON_FACE := [322.0, 621.0]
## The painting's own seven words, in its own order (profile.png). The mail
## and the Crown's Favour are the COURT's, where their cards are; the hub's
## rows are the seven the painter wrote on them.
const ROWS := [
	["friends", "FRIENDS", "profile/icon_friends"],
	["splendour", "WARDROBE", "profile/icon_wardrobe"],
	["rankings", "RANKINGS", "profile/icon_rankings"],
	["settings", "SETTINGS", "profile/icon_settings"],
	["account", "ACCOUNT", "profile/icon_account"],
	["redeem", "REDEEM A CODE", "profile/icon_redeem"],
	["invite", "INVITE A FRIEND", "profile/icon_invite"],
]

var _fails := 0
var _checked := 0
var _P: GDScript
var _UI: GDScript
var _Look: GDScript
var _Layout: GDScript
var _Art  # the Art autoload, called by name
var _shell: Node


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_P = load("res://scenes/pages/profile_page.gd")
	_UI = load("res://scripts/ui/ui.gd")
	_Look = load("res://scripts/ui/look.gd")
	_Layout = load("res://scripts/ui/layout.gd")
	_Art = root.get_node("Art")
	if _P == null:
		print("FAIL  there is no profile page")
		quit(1)
		return
	# The shell, as far as the rows need it: the views they ask it for.
	var fake := GDScript.new()
	fake.source_code = "extends Node\nvar opened: Array = []\n" \
		+ "func open_view(id: String, data: Dictionary = {}) -> Control:\n\topened.append(id)\n\treturn null\n"
	fake.reload()
	_shell = Node.new()
	_shell.set_script(fake)
	_shell.add_to_group("shell")
	root.add_child(_shell)

	for canvas in CANVASES:
		for inset in INSETS:
			await _page(canvas, inset, "plain")
			await _page(canvas, inset, "worn")
	await _page(Vector2i(941, 1672), 0.0, "long")
	await _page(Vector2i(941, 2040), 141.0, "long")
	await _figures()
	for row in ROWS:
		await _opens(str(row[0]))
	await _opens("face")
	await _opens("close")
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: YOUR LORDSHIP is its painting, draws the lord's look, opens every page, and fits the phone" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _expect(cond: bool, msg: String) -> void:
	_checked += 1
	if not cond:
		_fail(msg)


## The lord: plain (nothing worn, no seal), worn (everything), or long (the
## longest name and a title longer than any the game gives).
func _lord(which: String) -> void:
	var player := {"id": ID, "username": LONG, "avatar": "knight", "level": 30, "gold": "987654321",
		"diamonds": 12, "action_seq": 1, "vip_seal": false, "worn": {}}
	if which == "worn":
		player["username"] = "Aldric"
		player["avatar"] = "queen"
		player["level"] = 87
		player["vip_seal"] = true
		player["worn"] = {"frame": "frames/aureole", "title": "the Generous", "color": "#8FB8FF",
			"crest": "icons/crest_dragon"}
	elif which == "long":
		player["vip_seal"] = true
		player["worn"] = {"title": "The Warden of the Western March", "color": "#F08A8E"}
	root.get_node("GameState").set("snapshot", {"player": player, "energy": {"current": 1, "max": 2},
		"prices": {"rename_diamonds": 100}})
	root.get_node("GameState").call("set_badges", {"friends": 3})


func _host(canvas: Vector2i) -> Control:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = canvas
	var host := Control.new()
	host.size = Vector2(canvas)
	root.add_child(host)
	return host


func _open(host: Control, inset: float) -> Control:
	var p: Control = _P.open(host, {"inset": inset})
	# /v1/army and /v1/kingdom fail at once against no server; let them, so
	# what the test puts in their place is not painted over.
	await create_timer(0.4).timeout
	return p


func _page(canvas: Vector2i, inset: float, which: String) -> void:
	var tag := "%dx%d inset %d, %s" % [canvas.x, canvas.y, int(inset), which]
	_lord(which)
	var host := _host(canvas)
	var p: Control = await _open(host, inset)
	_expect(p != null and p.get_script().resource_path.ends_with("painted_page.gd"), "%s: the profile is not a painted page" % tag)
	if p == null or not p.get_script().resource_path.ends_with("painted_page.gd"):
		host.queue_free()
		return
	p.set_meta("realm", {"might": 9999999999, "kingdom": "Iron Wolves", "tag": "IRW"} if which == "worn"
		else {"might": 5484, "kingdom": ""})
	_P.paint(p)
	await process_frame
	var look: Dictionary = root.get_node("GameState").call("player").get("worn", {})
	var worn := which != "plain"

	# The rows: the painting's plates, in its order, evenly down the frame.
	var rows: Array = p.get("parts").get("row", [])
	_expect(rows.size() == ROWS.size(), "%s: %d rows, want %d" % [tag, rows.size(), ROWS.size()])
	var tops: Array = []
	for i in mini(rows.size(), ROWS.size()):
		var parts: Dictionary = rows[i]["parts"]
		var node: Control = rows[i]["node"]
		_expect((parts["label"] as Label).text == ROWS[i][1], "%s: row %d reads \"%s\", want %s" % [tag, i, (parts["label"] as Label).text, ROWS[i][1]])
		_expect((parts["icon"] as TextureRect).texture == _Art.tex(str(ROWS[i][2])), "%s: %s has not its icon" % [tag, ROWS[i][1]])
		_expect((parts["plate"] as TextureRect).texture == _Art.tex("profile/row"), "%s: %s is not on the painting's row plate" % [tag, ROWS[i][1]])
		tops.append(node.get_global_rect())
		var hit := p.call("node", "row_" + str(ROWS[i][0])) as Control
		_expect(hit != null and hit.get_global_rect().grow(1.0).encloses(Rect2(node.get_global_rect().position + Vector2(0, 4) * node.get_global_transform().get_scale(),
			Vector2(node.get_global_rect().size.x, node.get_global_rect().size.y - 8.0 * node.get_global_transform().get_scale().y))),
			"%s: %s's tap target does not cover its plate" % [tag, ROWS[i][1]])
	var gaps: Array = []
	for i in range(1, tops.size()):
		gaps.append((tops[i] as Rect2).position.y - (tops[i - 1] as Rect2).end.y)
	for g in gaps:
		_expect(g > 0.0 and absf(float(g) - float(gaps[0])) <= 2.0, "%s: the rows are not evenly spaced: %s" % [tag, str(gaps)])
	var build := p.call("node", "build") as Control
	var under: float = build.get_global_rect().position.y - (tops[tops.size() - 1] as Rect2).end.y
	_expect(under > 0.0 and under <= float(gaps[0]) * 3.0 + 40.0,
		"%s: a hole of %.0f under the last row (rows %.0f apart)" % [tag, under, float(gaps[0])])

	# The header, as worn.
	var ribbon := p.call("node", "ribbon") as Label
	var want_title := str(look.get("title", "")) if worn else "Level 30"
	_expect(ribbon.text == want_title, "%s: the ribbon reads \"%s\", want \"%s\"" % [tag, ribbon.text, want_title])
	var want_colour: Color = Color(str(look.get("color", ""))) if worn else _UI.GOLD
	_expect(ribbon.label_settings.font_color.is_equal_approx(want_colour), "%s: the ribbon's words are %s, want %s" % [tag, ribbon.label_settings.font_color, want_colour])
	var name := p.call("node", "name") as Label
	var name_colour: Color = Color(str(look.get("color", ""))) if worn else _UI.INK
	_expect(name.label_settings.font_color.is_equal_approx(name_colour), "%s: the name is %s, want %s" % [tag, name.label_settings.font_color, name_colour])
	var seal: Variant = name.get_meta("look_seal") if name.has_meta("look_seal") else null
	var sealed := which != "plain"
	_expect((seal is TextureRect and (seal as TextureRect).visible) == sealed, "%s: the seal is %s" % [tag, "missing" if sealed else "drawn without Royal Favour"])
	if sealed and seal is TextureRect:
		var sr := (seal as TextureRect).get_global_rect()
		var words := _drawn(name)
		_expect(sr.position.x >= words.end.x - 0.5, "%s: the seal %s sits on the name %s" % [tag, sr, words])
		var quill := (p.call("node", "quill") as Control).get_global_rect()
		_expect(sr.end.x <= quill.position.x + 0.5, "%s: the seal %s runs under the quill %s" % [tag, sr, quill])
	var face: Variant = p.get_meta("face") if p.has_meta("face") else null
	_expect(face is TextureRect, "%s: no face in the ring" % tag)
	if face is TextureRect:
		var win: Rect2 = _Layout.rect_of(_Layout.element("profile", "ring_window"))
		var framed := which == "worn"
		var ring: Variant = (face as TextureRect).get_meta("look_frame") if (face as TextureRect).has_meta("look_frame") else null
		_expect((ring is TextureRect and (ring as TextureRect).visible) == framed, "%s: the frame is %s" % [tag, "missing" if framed else "drawn unworn"])
		var want_d: float = win.size.x * float(_P.FACE_IN_FRAME) if framed else win.size.x + 2.0
		_expect(absf((face as TextureRect).size.x - want_d) <= 1.0, "%s: the face is %.0f across, want %.0f" % [tag, (face as TextureRect).size.x, want_d])
		_expect(absf(((face as TextureRect).position + (face as TextureRect).size / 2.0).distance_to(win.get_center())) <= 1.0,
			"%s: the face is off the ring's window" % tag)
		if framed and ring is TextureRect:
			_expect((ring as TextureRect).texture == _Art.tex(_Look.frame_art(_Look.mine(), "ring", win.size.x)), "%s: the frame is not the one worn" % tag)
	var crest := p.call("node", "crest") as TextureRect
	var want_crest: String = "icons/crest_dragon" if which == "worn" else str(_Art.crest(ID))
	_expect(crest.texture == _Art.tex(want_crest), "%s: the crest is not %s" % [tag, want_crest])

	# The figures, each right of its icon and inside its plate; the ribbon's
	# words inside its face.
	_expect((p.call("node", "level") as Label).text == ("87" if which == "worn" else "30"), "%s: the level reads %s" % [tag, (p.call("node", "level") as Label).text])
	_expect((p.call("node", "might") as Label).text == _UI.short_number(9999999999 if which == "worn" else 5484), "%s: the might reads %s" % [tag, (p.call("node", "might") as Label).text])
	_expect((p.call("node", "kingdom") as Label).text == ("Iron Wolves" if which == "worn" else _P.NO_KINGDOM), "%s: the kingdom reads %s" % [tag, (p.call("node", "kingdom") as Label).text])
	_plates(p, tag)
	_ribbon(p, tag)
	_centred(p, tag, seal if sealed else null)

	# FRIENDS' count: the lords waiting for an answer, 9+ past nine.
	var friends: Dictionary = rows[0]["parts"] if rows.size() > 0 else {}
	if not friends.is_empty():
		_expect((friends["badge_text"] as Label).text == "3" and (friends["badge"] as Control).is_visible_in_tree(), "%s: FRIENDS does not say 3 wait" % tag)
		root.get_node("GameState").call("set_badges", {"friends": 12})
		await process_frame
		_expect((friends["badge_text"] as Label).text == "9+", "%s: twelve asks read %s, want 9+" % [tag, (friends["badge_text"] as Label).text])
		for i in range(1, rows.size()):
			_expect(not (rows[i]["parts"]["badge"] as Control).visible, "%s: %s carries a badge" % [tag, ROWS[i][1]])

	# Nothing off the screen or under the notch; every button a thumb.
	var screen := Rect2(Vector2(0, inset), Vector2(canvas) - Vector2(0, inset))
	var small: bool = float(p.get("page_scale")) < 1.0
	for n in _all(p):
		if not (n is Control) or not (n as Control).is_visible_in_tree():
			continue
		var c := n as Control
		if c is Label and (c as Label).text != "":
			_expect(screen.grow(0.5).encloses(c.get_global_rect()), "%s: \"%s\" %s is off the screen" % [tag, (c as Label).text.substr(0, 24), c.get_global_rect()])
			_expect(_fits(c as Label), "%s: \"%s\" runs out of its box" % [tag, (c as Label).text.substr(0, 24)])
		if c is BaseButton:
			_expect((c.get_global_rect().size.y >= MIN_H or small) and screen.grow(0.5).encloses(c.get_global_rect()),
				"%s: a button %s is off the screen or too small for a thumb" % [tag, c.get_global_rect()])
	p.call("close")
	for k in 12:
		await process_frame
	host.queue_free()
	await process_frame


## Each figure right of its plate's icon and inside the plate, in the
## painting's units (the header is above every stretch band).
func _plates(p: Control, tag: String) -> void:
	var body := (p.call("node", "level") as Control).get_parent() as Control
	for id in PLATES:
		var l := p.call("node", id) as Label
		var words := _drawn(l)
		var local := Rect2(body.get_global_transform().affine_inverse() * words.position,
			words.size / body.get_global_transform().get_scale())
		var at := (p.call("map_rect", Rect2(PLATES[id][0], PLATE_Y[0], PLATES[id][1] - PLATES[id][0], PLATE_Y[1] - PLATE_Y[0])) as Rect2)
		_expect(local.position.x >= at.position.x + 2.0 and local.end.x <= at.end.x + 0.5,
			"%s: %s's words %s leave the room beside its icon %s" % [tag, id, local, at])
		_expect(local.position.y >= at.position.y - 0.5 and local.end.y <= at.end.y + 0.5,
			"%s: %s's words %s leave its plate %s" % [tag, id, local, at])


func _ribbon(p: Control, tag: String) -> void:
	var l := p.call("node", "ribbon") as Label
	var body := l.get_parent() as Control
	var words := _drawn(l)
	var local := Rect2(body.get_global_transform().affine_inverse() * words.position,
		words.size / body.get_global_transform().get_scale())
	_expect(local.position.x >= RIBBON_FACE[0] and local.end.x <= RIBBON_FACE[1],
		"%s: the ribbon's words %s run past its face %s" % [tag, local, str(RIBBON_FACE)])
	_expect(l.label_settings.font_size >= int(_P.RIBBON_MIN), "%s: the ribbon's words are set at %d" % [tag, l.label_settings.font_size])


## The name (with its seal, when held) and the ribbon's words centred on the
## boxes the painting gives them: a label built wider than its box, or left
## at a longer word's width, puts a centred word off its plate's middle.
func _centred(p: Control, tag: String, seal: Variant) -> void:
	for id in ["name", "ribbon"]:
		var l := p.call("node", id) as Label
		var body := l.get_parent() as Control
		var inv := body.get_global_transform().affine_inverse()
		var words := _drawn(l)
		var left: float = (inv * words.position).x
		var right: float = (inv * words.end).x
		if id == "name" and seal is TextureRect:
			right = (inv * (seal as TextureRect).get_global_rect().end).x
		var box: Rect2 = p.call("map_rect", _Layout.rect_of(_Layout.element("profile", id)))
		var off := (left + right) / 2.0 - box.get_center().x
		_expect(absf(off) <= 1.5, "%s: \"%s\" sits %.1f units off its box's middle" % [tag, l.text, off])


## The kingdom's name, its tag, or none; the might in every size.
func _figures() -> void:
	_lord("plain")
	var host := _host(Vector2i(941, 1672))
	var p: Control = await _open(host, 0.0)
	var cases := [
		[{}, "—"],
		[{"kingdom": ""}, _P.NO_KINGDOM],
		[{"kingdom": "Iron Wolves", "tag": "IRW"}, "Iron Wolves"],
		[{"kingdom": "Duskhold", "tag": "DSK"}, "Duskhold"],
		[{"kingdom": "Kingdom of Dusk", "tag": "KOD"}, "Kingdom of Dusk"],
		[{"kingdom": "The Silver Wolves of Tyr", "tag": "SWT"}, "[SWT]"],
		[{"kingdom": "W".repeat(24), "tag": "WWWW"}, "[WWWW]"],
		[{"kingdom": "Iron Wolves", "tag": "IRW"}, "Iron Wolves"],
	]
	for c in cases:
		var realm: Dictionary = (c[0] as Dictionary).duplicate()
		realm["might"] = 0
		p.set_meta("realm", realm)
		_P.paint(p)
		await process_frame
		var l := p.call("node", "kingdom") as Label
		var tag := "kingdom %s" % str(c[0].get("kingdom", "(unread)"))
		_expect(l.text == c[1], "%s reads \"%s\", want \"%s\"" % [tag, l.text, c[1]])
		_expect(l.label_settings.font_size >= (int(_P.KINGDOM_MIN) if not l.text.begins_with("[") else int(_P.TAG_MIN)),
			"%s is set at %d, too small to read" % [tag, l.label_settings.font_size])
		_expect(_P.kingdom_fits(l), "%s does not fit the castle's plate" % tag)
		_plates(p, tag)
	for might in [0, 5484, 123456789, 9999999999, 987654321987]:
		p.set_meta("realm", {"might": might, "kingdom": ""})
		_P.paint(p)
		await process_frame
		var l := p.call("node", "might") as Label
		_expect(l.text == _UI.short_number(might), "might %d reads %s" % [might, l.text])
		_plates(p, "might %d" % might)
	p.call("close")
	for k in 12:
		await process_frame
	host.queue_free()
	await process_frame


## A tap on a row (or the portrait, or CLOSE) opens what it names.
func _opens(what: String) -> void:
	_lord("plain")
	_shell.set("opened", [])
	var host := _host(Vector2i(941, 1672))
	var before: Array = root.get_children()
	var p: Control = await _open(host, 0.0)
	var hit_id := {"face": "face_hit", "close": "close"}.get(what, "row_" + what) as String
	var hit := p.call("node", hit_id) as BaseButton
	_expect(hit != null, "%s: no %s to tap" % [what, hit_id])
	if hit == null:
		host.queue_free()
		return
	hit.pressed.emit()
	for k in 8:
		await process_frame
	var opened: Array = _shell.get("opened")
	match what:
		"friends", "settings":
			# Each opens its own painted page over the hub, on the pages' host.
			var layers := 0
			for c in root.get_children():
				if c is CanvasLayer and not c.is_queued_for_deletion():
					layers += 1
			_expect(layers >= 2, "%s did not open its page (%d layers)" % [what.to_upper(), layers])
		"splendour":
			_expect(opened == ["wardrobe"], "SPLENDOUR asked the shell for %s" % str(opened))
		"favour":
			_expect(opened == ["favour"], "THE CROWN'S FAVOUR asked the shell for %s" % str(opened))
		"rankings", "redeem", "invite":
			var id := "rankings" if what == "rankings" else what
			_expect(_painted(id) != null, "%s opened no %s page" % [what.to_upper(), id])
		"account":
			_expect(_button("SIGN OUT") != null and _button("DELETE ACCOUNT") != null, "ACCOUNT opened no page with SIGN OUT and DELETE ACCOUNT")
		"face":
			var grid := _grid(root)
			_expect(grid != null and grid.get_child_count() == (_Art.get("AVATAR_CHOICES") as Array).size(), "the portrait opened no faces to choose")
		"close":
			_expect(bool(p.get("_closing")) or not is_instance_valid(p) or not p.is_inside_tree(), "CLOSE left the profile open")
	# Everything the tap opened goes with the test.
	for c in root.get_children():
		if not c in before and c is CanvasLayer:
			c.queue_free()
	host.queue_free()
	for k in 4:
		await process_frame


## The words as drawn: a centred line's width, inside its label, or the
## label itself when the words are wrapped or cut.
static func _drawn(l: Label) -> Rect2:
	var r := l.get_global_rect()
	var s := l.label_settings
	var scale: float = l.get_global_transform().get_scale().x
	if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
		var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, l.size.x, s.font_size) * scale
		return Rect2(r.position + (r.size - m) / 2.0, m)
	var w := minf(s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x, l.size.x) * scale
	var x := r.position.x
	if l.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
		x += (r.size.x - w) / 2.0
	elif l.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		x = r.end.x - w
	var h := s.font.get_height(s.font_size) * scale
	return Rect2(x, r.position.y + (r.size.y - h) / 2.0, w, h)


## A one-line label fits when its words do, or when it cuts them with an
## ellipsis inside its box; a wrapped one when its lines do.
static func _fits(l: Label) -> bool:
	var s := l.label_settings
	if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
		var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, l.size.x, s.font_size)
		return m.x <= l.size.x + 1.0 and m.y <= l.size.y + 1.0
	var w := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
	return w <= l.size.x + 1.0 or (l.clip_text and l.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING)


func _painted(id: String) -> Control:
	for n in _all(root):
		if n is Control and n.get_script() != null and (n.get_script() as Script).resource_path.ends_with("painted_page.gd") \
				and str(n.get("id")) == id and not bool(n.get("_closing")):
			return n
	return null


func _button(word: String) -> Button:
	for n in _all(root):
		if n is Button and (n as Button).text == word and (n as Button).is_visible_in_tree():
			return n
	return null


func _grid(n: Node) -> GridContainer:
	if n is GridContainer:
		return n
	for c in n.get_children():
		var g := _grid(c)
		if g != null:
			return g
	return null


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
