extends SceneTree
## The treasury, the stat points and the away report are their paintings, on
## the painted pages' host, and hold on every phone.
##
## They were Sheets: the dialogs' plate, a title in type and rows of kit parts.
## Each now opens its own painting (art/reference/treasury.png, stats.png,
## away.png) through PaintedPage. What must hold, for the hard cases -- ten
## billion gold on hand and in the vault, nothing on hand with deposits still
## closed, 99 points to place and none, a report of everything at once and of
## a single raid -- on 941x1672 and 941x2040, with and without a Dynamic
## Island:
##  - the page is a PaintedPage, and its painting is drawn whole: its slices
##    run from its top to its foot without a gap, however it stretched;
##  - nothing leaves the screen or goes under the notch, every figure fits its
##    box, and every button takes a thumb;
##  - the figures are the ones given, and the buttons do what they did: the
##    quick amounts fill the field, DEPOSIT dims while deposits are closed,
##    ALL places every point and SPEND then says how many, TAKE REVENGE only
##    when someone is left to answer and it leaves for the Attack tab (without
##    it CONTINUE stands in the middle), CLOSE and CONTINUE close.
##
## Run: godot --headless --path client --script tests/painted_pages.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	for canvas in CANVASES:
		for inset in INSETS:
			var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
			await _treasury(tag, canvas, inset, {"gold": "9999999999", "treasury": "9999999999"},
				{"vault": "9999999999", "deposit_fee_bp": 1000, "unlock_level": 8, "unlocked": true},
				["9,999,999,999", "9,999,999,999", "10%"], true)
			await _treasury(tag, canvas, inset, {"gold": "0", "treasury": "0"},
				{"vault": "0", "deposit_fee_bp": 1250, "unlock_level": 8, "unlocked": false},
				["0", "0", "level 8"], false)
			await _stats(tag, canvas, inset, 99)
			await _stats(tag, canvas, inset, 0)
			await _away(tag, canvas, inset, {"raids": 1234, "gold_lost": 9999999999, "ransom_earned": 9999999999,
				"revenge": 99}, ["1,234", "-9,999,999,999", "+9,999,999,999", "99"])
			await _away(tag, canvas, inset, {"raids": 1, "gold_lost": 0, "ransom_earned": 0, "revenge": 0},
				["1", "0", "0", "0"])
	# Nothing to report: no page.
	var host := _host(Vector2i(941, 1672))
	await (load("res://scenes/pages/away_page.gd") as GDScript).check(host, 0, func() -> void: pass)
	await process_frame
	if _open_pages(host) > 0:
		_fail("the away report opened with nothing to report")
	# Six pages at each of four canvases, one of them measured twice.
	if _checked < 28:
		_fail("only %d of 28 pages were measured: a page did not open as a painted page" % _checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d painted pages hold on both canvases, under the notch, with their hard cases" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _snapshot(player: Dictionary) -> void:
	var p := {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "987654321", "treasury": "0", "diamonds": 12,
		"stat_points_unspent": 3, "stat_attack": 10, "stat_defense": 6, "stat_energy": 12}
	p.merge(player, true)
	root.get_node("GameState").set("snapshot", {"player": p, "energy": {"current": 185, "max": 236},
		"prices": {"stat_gains": {"attack": 4, "defense": 4, "energy": 5}}})


func _host(canvas: Vector2i) -> Control:
	var vp := SubViewport.new()
	vp.size = canvas
	root.add_child(vp)
	root.get_node("Nav").set("host", vp)
	var host := Control.new()
	host.size = Vector2(canvas)
	vp.add_child(host)
	return host


func _open_pages(host: Control) -> int:
	var n := 0
	for c in host.get_parent().get_children():
		if c is CanvasLayer and not c.is_queued_for_deletion():
			n += 1
	return n


## The page opened, settled; or null with a failure if it is not a PaintedPage.
func _settle(page: Variant, what: String) -> Control:
	var s: Script = (page as Object).get_script() if page is Object else null
	if s == null or not s.resource_path.ends_with("scripts/ui/painted_page.gd"):
		_fail("%s is not a painted page (%s)" % [what, s.resource_path if s != null else "nothing"])
		return null
	await create_timer(0.4).timeout
	return page


func _treasury(tag: String, canvas: Vector2i, inset: float, player: Dictionary, t: Dictionary,
		want: Array, open: bool) -> void:
	_snapshot(player)
	var host := _host(canvas)
	var what := "treasury (%s) %s" % ["open" if open else "closed", tag]
	var p: Control = await _settle(load("res://scenes/pages/treasury_page.gd").open(host, t, {"inset": inset}), what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	_want_text(p, "on_hand", want[0], what)
	_want_text(p, "vault", want[1], what)
	var note := p.call("node", "note") as Label
	if note == null or not note.text.contains(want[2]):
		_fail("%s: the fee note says \"%s\", not %s" % [what, note.text if note != null else "", want[2]])
	var dep := p.call("node", "deposit") as BaseButton
	if dep == null or dep.disabled == open:
		_fail("%s: DEPOSIT is %s" % [what, "missing" if dep == null else ("off" if dep.disabled else "on")])
	# ALL IN VAULT fills the field with what is banked.
	_press(p, "all_vault")
	var field: LineEdit = p.get_meta("field")
	if field.text != str(int(str(player.get("treasury", "0")))):
		_fail("%s: ALL IN VAULT put \"%s\" in the field" % [what, field.text])
	await _closes(p, "close", what)
	host.get_parent().queue_free()
	await process_frame


func _stats(tag: String, canvas: Vector2i, inset: float, points: int) -> void:
	_snapshot({"stat_points_unspent": points, "stat_attack": 12345, "stat_defense": 999})
	var host := _host(canvas)
	var what := "stats (%d points) %s" % [points, tag]
	var p: Control = await _settle(load("res://scenes/pages/stats_page.gd").open(host, {"inset": inset}), what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	_want_text(p, "points", "%s POINT%s TO PLACE" % [str(points) if points > 0 else "NO", "" if points == 1 else "S"], what)
	_want_text(p, "now_attack", "12,345 in it now", what)
	_want_text(p, "gain_energy", "+5 max energy a point", what)
	_want_enabled(p, "plus_attack", points > 0, what)
	_want_enabled(p, "minus_attack", false, what)
	_want_enabled(p, "confirm", false, what)
	if points > 0:
		_press(p, "all_attack")
		_want_text(p, "plan_attack", "+%d" % points, what)
		_want_text(p, "points", "NO POINTS TO PLACE", what)
		_want_text(p, "confirm_word", "SPEND %d POINTS" % points, what)
		_want_enabled(p, "confirm", true, what)
		_want_enabled(p, "plus_defense", false, what)
		_want_enabled(p, "minus_attack", true, what)
		_measure(p, what + " all placed", canvas, inset)
	await _closes(p, "close", what)
	host.get_parent().queue_free()
	await process_frame


func _away(tag: String, canvas: Vector2i, inset: float, d: Dictionary, want: Array) -> void:
	_snapshot({})
	var host := _host(canvas)
	var what := "away (%d raids) %s" % [int(d["raids"]), tag]
	var went := [false]
	var p: Control = await _settle(load("res://scenes/pages/away_page.gd").open(host, d,
		func() -> void: went[0] = true, {"inset": inset}), what)
	if p == null:
		host.get_parent().queue_free()
		return
	_measure(p, what, canvas, inset)
	for i in 4:
		_want_text(p, ["raids", "lost", "ransom", "avenge"][i], want[i], what)
	var rev := p.call("node", "revenge") as Control
	var waiting := int(d.get("revenge", 0)) > 0
	if rev == null or rev.visible != waiting:
		_fail("%s: TAKE REVENGE is %s with %d to avenge" % [what, "missing" if rev == null else
			("shown" if rev.visible else "hidden"), int(d.get("revenge", 0))])
	if waiting:
		_press(p, "revenge")
		await create_timer(0.3).timeout
		if not went[0]:
			_fail("%s: TAKE REVENGE did not go to the Attack tab" % what)
		if _open_pages(host) > 0:
			_fail("%s: the page stayed open after TAKE REVENGE" % what)
	else:
		# Alone, CONTINUE stands in the middle of the foot.
		var go := p.call("node", "continue") as Control
		if go == null or absf(go.position.x + go.size.x / 2.0 - 941.0 / 2.0) > 1.0:
			_fail("%s: CONTINUE is not in the middle with TAKE REVENGE gone" % what)
		await _closes(p, "continue", what)
	host.get_parent().queue_free()
	await process_frame


## Everything on the screen and under the notch; the painting whole; figures
## in their boxes; buttons a thumb tall.
func _measure(p: Control, what: String, canvas: Vector2i, inset: float) -> void:
	_checked += 1
	var W := float(canvas.x)
	var H := float(canvas.y)
	var scale: float = p.get("page_scale")
	var slices: Array = []
	for n in _all(p):
		var c := n as Control
		if c == null or not c.is_visible_in_tree():
			continue
		if c.has_meta("page_slice"):
			slices.append(c)
		# The notch's fill and its fade are the page's own ground, meant to be
		# under the notch.
		if c is ColorRect or (c is TextureRect and (c as TextureRect).texture is GradientTexture2D):
			continue
		if c == p or c.get_parent() == p:
			continue
		var r := c.get_global_rect()
		if r.position.x < -0.5 or r.end.x > W + 0.5 or r.position.y < inset - 0.5 or r.end.y > H + 0.5:
			_fail("%s: %s is at %s, off the screen or under the notch" % [what, c.get_class(), r])
		if c is Label and (c as Label).text != "":
			var l := c as Label
			var s := l.label_settings
			var box := float(l.get_meta("box_w", l.size.x))
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
				var m := s.font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, box, s.font_size)
				if m.y > l.size.y + 1.0:
					_fail("%s: \"%s\" runs %d tall in a %d box" % [what, l.text, int(m.y), int(l.size.y)])
			elif s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > box + 1.0:
				_fail("%s: \"%s\" is wider than its %d box" % [what, l.text, int(box)])
		if c is BaseButton and scale >= 1.0 and r.size.y < MIN_H:
			_fail("%s: a button is %.0f tall, under a thumb" % [what, r.size.y])
	# The painting's slices, top to foot, without a gap.
	slices.sort_custom(func(a: Control, b: Control) -> bool: return a.position.y < b.position.y)
	var y := 0.0
	for s in slices:
		if s.position.y > y + 0.01:
			_fail("%s: the painting has a gap from %.1f to %.1f" % [what, y, s.position.y])
		y = maxf(y, s.position.y + s.size.y)
	var want_h := 1672.0 + float(p.get("extra"))
	if slices.is_empty() or absf(y - want_h) > 1.01:
		_fail("%s: the painting runs to %.1f of %.1f" % [what, y, want_h])


func _want_text(p: Control, id: String, want: String, what: String) -> void:
	var l := p.call("node", id) as Label
	if l == null or l.text != want:
		_fail("%s: %s says \"%s\", want \"%s\"" % [what, id, l.text if l != null else "(no part)", want])


func _want_enabled(p: Control, id: String, on: bool, what: String) -> void:
	var b := p.call("node", id) as BaseButton
	if b == null or b.disabled == on:
		_fail("%s: %s is %s, want %s" % [what, id, "missing" if b == null else ("off" if b.disabled else "on"),
			"on" if on else "off"])


func _press(p: Control, id: String) -> void:
	var b := p.call("node", id) as BaseButton
	if b == null:
		_fail("%s has no %s" % [p.get("id"), id])
		return
	b.pressed.emit()


func _closes(p: Control, id: String, what: String) -> void:
	var closed := [false]
	p.connect("closed", func() -> void: closed[0] = true)
	_press(p, id)
	await create_timer(0.3).timeout
	if not closed[0]:
		_fail("%s: %s did not close the page" % [what, id.to_upper()])


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
