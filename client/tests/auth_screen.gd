extends SceneTree
## The sign-in screen is its painting, and it works on every phone.
##
## art/reference/auth.png: the castle and EMPERORS, and the panel -- ENTER THE
## REALM, a field with a quill and one with a key, SIGN IN, CREATE ACCOUNT, OR
## and the empty plate Sign in with Apple goes in, TERMS and PRIVACY. Until
## Wave 2 brings Apple the OR and its plate are hidden and the rest closes up.
##
## - Every part is on the screen and inside the panel, the fields, buttons and
##   message in one column with nothing overlapping, at 941x1672 and 941x2040.
## - The OR and the Apple plate are hidden, and nothing is left where they were.
## - With the keyboard up, both fields and SIGN IN stay above it.
## - The longest username fits its box; TERMS and PRIVACY open the legal pages
##   and take a thumb.
##
## Run: godot --headless --path client --script tests/auth_screen.gd

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
## The panel's inside, painted: under ENTER THE REALM, above TERMS.
const PANEL_TOP := 910.0
const PANEL_FOOT := 1496.0
const PANEL_X := Vector2(66, 875)
const KEYBOARD := 720.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	for canvas in CANVASES:
		await _check(canvas)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the painted sign-in fits, closes up and clears the keyboard" % _checked)
	quit()


func _check(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	# The scene's root is anchored to its parent's rect: the host gives it the
	# canvas (setting its size before it has a parent would add the two).
	var scr: Control = (load("res://scenes/auth/auth.tscn") as PackedScene).instantiate()
	host.add_child(scr)
	for i in 4:
		await process_frame
	var scene: Control = scr.get("_scene")
	_expect(scene != null, "%s: the screen has no painted scene" % tag)
	if scene == null:
		host.queue_free()
		return
	var page := _find_tex(scene, "auth/page")
	_expect(page != null, "%s: the painting is not drawn" % tag)
	if page != null:
		var pr := Rect2(page.global_position, page.size)
		_expect(absf(pr.end.y - canvas.y) < 1.0, "%s: the painting's foot is at %.0f, not the screen's %.0f" % [tag, pr.end.y, canvas.y])
		_expect(pr.position.y >= -0.5, "%s: the painting starts at %.0f, above the screen" % [tag, pr.position.y])

	# The column: both fields, the two buttons, the message, in order and apart.
	var user: LineEdit = scr.get("_user")
	var pw: LineEdit = scr.get("_pass")
	var sign_in: Control = scr.get("_sign_in")
	var create: Control = scr.get("_create")
	var msg: Label = scr.get("_msg")
	var column := [_find_tex(scene, "auth/field_user"), _find_tex(scene, "auth/field_pass"), sign_in, create, msg]
	var top := scene.global_position.y
	var last_bottom := top + PANEL_TOP
	for i in column.size():
		var c: Control = column[i]
		_checked += 1
		if c == null:
			_fail("%s: part %d of the column is missing" % [tag, i])
			continue
		var r := Rect2(c.global_position, c.size)
		_expect(r.position.y >= last_bottom - 0.5, "%s: part %d starts at %.0f, over the one above (%.0f)" % [tag, i, r.position.y, last_bottom])
		_expect(r.end.y <= top + PANEL_FOOT + 0.5, "%s: part %d runs to %.0f, into TERMS (%.0f)" % [tag, i, r.end.y, top + PANEL_FOOT])
		_expect(r.position.x >= PANEL_X.x and r.end.x <= PANEL_X.y, "%s: part %d leaves the panel sideways" % [tag, i])
		_expect(r.end.y <= canvas.y, "%s: part %d is off the screen" % [tag, i])
		last_bottom = r.end.y
	# Closed up: the stack sits in the middle of the panel, so there is no
	# painted hole under it where the Apple slot was.
	var stack_top: float = (column[0] as Control).global_position.y - (top + PANEL_TOP)
	var stack_foot: float = (top + PANEL_FOOT) - ((column[4] as Control).global_position.y + (column[4] as Control).size.y)
	_expect(absf(stack_top - stack_foot) <= 24.0, "%s: %.0f above the fields and %.0f under the message -- the panel has a hole" % [tag, stack_top, stack_foot])
	# A taller phone: the painting's own top carried up over the extra height,
	# not a band of bare ground above the sky.
	var extra := canvas.y - 1672.0
	var carry: Control = scr.get("_carry")
	if extra > 0.0:
		_expect(carry != null and carry.visible and absf(carry.size.y - extra) < 1.0 and carry.position.y <= 0.5,
			"%s: the %.0f over the painting is not its sky carried up" % [tag, extra])
		if carry != null:
			_no_streaks(tag, (carry as TextureRect).texture)
	else:
		_expect(carry == null or not carry.visible, "%s: a sky is carried up where there is no room" % tag)
	for id in ["auth/or", "auth/apple_slot"]:
		var n := _find_tex(scene, id)
		_expect(n == null or not n.visible, "%s: %s shows before Sign in with Apple exists" % [tag, id])

	# The fields take the longest name, and their typing is inside the box.
	user.text = "Wwwwwwwwwwwwwwww"
	var f: Font = user.get_theme_font("font")
	var w := f.get_string_size(user.text, HORIZONTAL_ALIGNMENT_LEFT, -1, user.get_theme_font_size("font_size")).x
	_expect(w <= user.size.x - 8.0, "%s: a 16-letter name is %.0f wide in a %.0f box" % [tag, w, user.size.x])
	var box := _find_tex(scene, "auth/field_user")
	if box != null:
		_expect(Rect2(box.global_position, box.size).encloses(Rect2(user.global_position, user.size)), "%s: the username's typing leaves its box" % tag)

	# TERMS and PRIVACY open the legal pages, a thumb's tap each.
	var urls := {}
	for n in _all(scene):
		if n is Button and (n as Button).has_meta("url"):
			urls[str(n.get_meta("url"))] = true
			_expect((n as Button).size.y >= 95.0, "%s: a legal link is %.0f tall" % [tag, (n as Button).size.y])
	_expect(urls.has("https://91-107-215-32.sslip.io/legal/terms") and urls.has("https://91-107-215-32.sslip.io/legal/privacy"),
		"%s: TERMS and PRIVACY do not open the legal pages (%s)" % [tag, str(urls.keys())])
	for b in [sign_in, create]:
		_expect((b as Control).size.y >= 95.0, "%s: a button is %.0f tall" % [tag, (b as Control).size.y])

	# The keyboard: both fields and SIGN IN stay above it.
	scr.set_meta("keyboard", KEYBOARD)
	pw.grab_focus()
	for i in 40:
		await process_frame
	var line := canvas.y - KEYBOARD
	for c in [_find_tex(scene, "auth/field_user"), _find_tex(scene, "auth/field_pass"), sign_in]:
		var r := Rect2((c as Control).global_position, (c as Control).size)
		_checked += 1
		_expect(r.end.y <= line + 1.0, "%s: with the keyboard up, a part runs to %.0f under the keyboard at %.0f" % [tag, r.end.y, line])
		_expect(r.position.y >= 0.0, "%s: with the keyboard up, a part is pushed off the top (%.0f)" % [tag, r.position.y])
	pw.release_focus()
	for i in 40:
		await process_frame
	_expect(absf(scene.position.y - float(scr.get("_rest_y"))) < 1.0, "%s: the painting did not settle back when the keyboard went" % tag)
	host.queue_free()
	await process_frame


## Across the sky window of the carried-up band (x 290..657 of the painting),
## neighbouring columns may not differ by more than a few levels: the band is
## drawn tall, so any step between two columns becomes a bar of light. Stretching
## the painting's top rows as they were (clouds and all) fails this by far.
const SKY := Vector2i(290, 658)
const STREAK := 4.0 / 255.0


func _no_streaks(tag: String, t: Texture2D) -> void:
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	var cols: Array[Color] = []
	for x in img.get_width():
		var c := Color(0, 0, 0, 0)
		for y in img.get_height():
			c += img.get_pixel(x, y)
		cols.append(c / float(img.get_height()))
	var worst := 0.0
	for x in range(SKY.x, SKY.y - 1):
		var a: Color = cols[x]
		var b: Color = cols[x + 1]
		worst = maxf(worst, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	_checked += 1
	_expect(worst <= STREAK, "%s: the carried-up sky steps %.0f levels between two columns -- a streak" % [tag, worst * 255.0])


func _find_tex(n: Node, asset: String) -> Control:
	for c in _all(n):
		if c is TextureRect and (c as TextureRect).texture != null \
				and (c as TextureRect).texture.resource_path.ends_with(asset + ".png"):
			return c
	return null


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _fail(what: String) -> void:
	_fails += 1
	print("  FAIL  " + what)


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fail(what)
