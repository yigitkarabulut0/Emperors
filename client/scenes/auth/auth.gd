extends Control
## Sign in / create account. Painted: art/reference/auth.png, cut by
## art/slices/auth.json -- the castle, EMPERORS over its banners, and the panel
## with ENTER THE REALM, a field with a quill and a field with a key, SIGN IN,
## CREATE ACCOUNT, OR, the plate Sign in with Apple goes in, and TERMS / PRIVACY.
##
## It was set on the splash painting with the form in the dialogs' plate; before
## that, a navy ground, two flat boxes and two flat-coloured buttons.
##
## Sign in with Apple arrives in Wave 2. Until then the painting's OR and its
## empty plate are hidden, and what is left closes up: the fields and buttons sit
## CLOSE_UP lower than painted, centred between the title and TERMS with the
## message under them, so the panel has no hole where the slot was. APPLE puts
## everything back where the painting has it.
##
## The painting fills the screen with its foot on the screen's foot. A taller
## phone has room over its sky, and the scene carries on up into it: each column
## takes the colour of the painting's top rows, so the banners' red and the
## stone run on up, and across the sky window between the inner pillars the
## colours are smoothed so the sky rises as sky -- a cloud's bright spot
## stretched up read as a bar of light -- darkening into the ground toward the
## notch.
##
## While a field has the keyboard the whole painting rises until SIGN IN clears
## it -- the keyboard covers whatever the rise leaves at the bottom -- and
## settles back when the keyboard goes.

const DESIGN := Vector2(941, 1672)
const APPLE := false
const CLOSE_UP := 46.0

## Where the painting has each, before closing up.
const FIELD_USER := Rect2(108, 920, 724, 94)
const FIELD_PASS := Rect2(108, 1017, 724, 94)
## The typing, right of the quill and the key, in each box.
const USER_TEXT := Rect2(210, 936, 598, 62)
const PASS_TEXT := Rect2(210, 1033, 598, 62)
const SIGN_IN := Rect2(104, 1114, 734, 114)
## CREATE ACCOUNT is painted 94 tall; its tap area is a thumb's 96, the plate
## centred in it.
const CREATE := Rect2(106, 1230, 730, 96)
const OR_LINE := Rect2(104, 1338, 734, 34)
const APPLE_SLOT := Rect2(108, 1383, 724, 96)
## The message under the buttons: errors, "Entering the realm...", why the
## session ended.
const MESSAGE := Rect2(104, 1335, 734, 60)
const MESSAGE_APPLE := Rect2(104, 1474, 734, 26)
## TERMS and PRIVACY, painted in the panel's foot; each a thumb's tap area.
const TERMS := Rect2(282, 1465, 136, 95)
const PRIVACY := Rect2(492, 1465, 156, 95)
const TERMS_URL := "https://91-107-215-32.sslip.io/legal/terms"
const PRIVACY_URL := "https://91-107-215-32.sslip.io/legal/privacy"
## The rows of the painting's top each column's colour is taken from.
const CARRY_ROWS := 6
## The sky between the inner pillars at the painting's top (x 290..657,
## measured), and how far across it a column's colour is smoothed.
const SKY_WINDOW := Vector2i(290, 658)
const SKY_BLUR := 90
## Where the carried-up band meets the painting, it runs this far down over the
## painting's top, fading out, so the clouds dissolve into the sky above them
## instead of stopping on a line.
const SEAM := 48.0
## SIGN IN stays this far above the keyboard.
const KEYBOARD_GAP := 20.0

var _scene: Control
var _carry: TextureRect
var _seam: TextureRect
var _sky: TextureRect
var _user: LineEdit
var _pass: LineEdit
var _sign_in: TextureButton
var _create: TextureButton
var _msg: Label
var _busy := false
var _rest_y := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# The painting and everything on it, moved as one: over the keyboard, and
	# down on a taller phone.
	_scene = Control.new()
	_scene.size = DESIGN
	_scene.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scene)
	var page := UI.image("auth/page", Rect2(Vector2.ZERO, DESIGN))
	_scene.add_child(page)
	_carry = TextureRect.new()
	var band := _carried_band(page.texture)
	_carry.texture = band
	_carry.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_carry.stretch_mode = TextureRect.STRETCH_SCALE
	_carry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_carry)
	_seam = TextureRect.new()
	_seam.texture = _fading(band)
	_seam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_seam.stretch_mode = TextureRect.STRETCH_SCALE
	_seam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_seam)
	_sky = _fade()
	add_child(_sky)

	var dy := 0.0 if APPLE else CLOSE_UP
	_scene.add_child(UI.image("auth/field_user", _down(FIELD_USER, dy)))
	_scene.add_child(UI.image("auth/field_pass", _down(FIELD_PASS, dy)))
	_user = _field("Username", _down(USER_TEXT, dy), false)
	_user.max_length = 16
	_pass = _field("Password", _down(PASS_TEXT, dy), true)
	_user.text_submitted.connect(func(_t: String) -> void: _pass.grab_focus())
	_pass.text_submitted.connect(func(_t: String) -> void: _sign_in_pressed())

	_sign_in = UI.tex_button("auth/btn_sign_in", _down(SIGN_IN, dy))
	_sign_in.pressed.connect(_sign_in_pressed)
	_scene.add_child(_sign_in)
	_create = UI.tex_button("auth/btn_create", _down(CREATE, dy))
	_create.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
	_create.pressed.connect(_create_pressed)
	_scene.add_child(_create)

	var or_line := UI.image("auth/or", OR_LINE)
	or_line.visible = APPLE
	_scene.add_child(or_line)
	var slot := UI.image("auth/apple_slot", APPLE_SLOT)
	slot.visible = APPLE
	_scene.add_child(slot)

	_msg = UI.label("", 25, UI.RED, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var mr := MESSAGE_APPLE if APPLE else _down(MESSAGE, dy)
	_msg.custom_minimum_size = Vector2(mr.size.x, 0)
	UI.place(_msg, mr)
	_scene.add_child(_msg)
	# Arriving here because the server ended the session: say so, rather than
	# dropping a player who was mid-game onto an empty form.
	if Session.ended_reason != "":
		_msg.text = Session.ended_reason
		_msg.label_settings.font_color = UI.GOLD

	for link in [[TERMS, TERMS_URL], [PRIVACY, PRIVACY_URL]]:
		var hit := UI.hotspot(link[0])
		hit.set_meta("url", link[1])
		hit.pressed.connect(func() -> void: OS.shell_open(str(link[1])))
		_scene.add_child(hit)

	resized.connect(_lay_out)
	_lay_out.call_deferred()


func _down(r: Rect2, dy: float) -> Rect2:
	return Rect2(r.position + Vector2(0, dy), r.size)


## A field over a painted box: the painting is its plate, so it draws none.
func _field(placeholder: String, rect: Rect2, secret: bool) -> LineEdit:
	var e := UI.field(placeholder, 30, secret)
	for st in ["normal", "focus", "read_only"]:
		e.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	UI.place(e, rect)
	_scene.add_child(e)
	return e


## The painting's top, one row: each column the mean of the top CARRY_ROWS, and
## across the sky window the mean of its neighbours within SKY_BLUR (kept inside
## the window, so the pillars' edges stay where they are). Stretched up, it is
## the scene going on, not the top row smeared.
static func _carried_band(tex: Texture2D) -> Texture2D:
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var cols: Array[Color] = []
	for x in w:
		var c := Color(0, 0, 0, 0)
		for y in CARRY_ROWS:
			c += img.get_pixel(x, y)
		cols.append(c / float(CARRY_ROWS))
	var band := Image.create(w, 1, false, Image.FORMAT_RGBA8)
	for x in w:
		var c: Color = cols[x]
		if x >= SKY_WINDOW.x and x < SKY_WINDOW.y:
			var a := maxi(SKY_WINDOW.x, x - SKY_BLUR)
			var b := mini(SKY_WINDOW.y - 1, x + SKY_BLUR)
			c = Color(0, 0, 0, 0)
			for i in range(a, b + 1):
				c += cols[i]
			c /= float(b - a + 1)
		c.a = 1.0
		band.set_pixel(x, 0, c)
	return ImageTexture.create_from_image(band)


## The band again, opaque at its top and gone at its foot, for the seam.
static func _fading(band: Texture2D) -> Texture2D:
	var src := band.get_image()
	var h := 32
	var img := Image.create(src.get_width(), h, false, Image.FORMAT_RGBA8)
	for y in h:
		var a := 1.0 - smoothstep(0.0, 1.0, float(y) / float(h - 1))
		for x in src.get_width():
			var c := src.get_pixel(x, 0)
			c.a = a
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


## The dark over the carried-up sky: the ground at the top of the screen, gone
## by the painting's own top.
func _fade() -> TextureRect:
	var t := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, UI.GROUND)
	g.set_color(1, Color(UI.GROUND, 0.0))
	g.add_point(0.45, Color(UI.GROUND, 0.55))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	t.texture = gt
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## The painting's foot on the screen's foot: a taller phone has its sky carried
## up above it, a shorter one loses sky.
func _lay_out() -> void:
	var h := size.y if size.y > 1.0 else DESIGN.y
	_rest_y = h - DESIGN.y
	_scene.position = Vector2((size.x - DESIGN.x) / 2.0 if size.x > DESIGN.x else 0.0, _rest_y)
	_place_sky()


func _place_sky() -> void:
	var top := _scene.position.y
	_sky.visible = top > 0.5
	_carry.visible = top > 0.5
	_seam.visible = top > 0.5
	var r := Rect2(_scene.position.x, 0, DESIGN.x, maxf(top, 0.0))
	UI.place(_carry, r)
	UI.place(_sky, r)
	UI.place(_seam, Rect2(_scene.position.x, top, DESIGN.x, SEAM))


## How much of the screen a phone's keyboard covers, in canvas units. A test
## sets meta "keyboard" to stand in for one.
func _keyboard() -> float:
	if has_meta("keyboard"):
		return float(get_meta("keyboard"))
	var win := DisplayServer.window_get_size()
	if win.x <= 0:
		return 0.0
	return float(DisplayServer.virtual_keyboard_get_height()) * maxf(size.x, DESIGN.x) / float(win.x)


## Lifts the painting while a field has the keyboard, until SIGN IN clears it.
func _process(_dt: float) -> void:
	if _scene == null:
		return
	var want := _rest_y
	var kb := _keyboard() if (_user.has_focus() or _pass.has_focus()) else 0.0
	if kb > 0.0:
		var sign_bottom := _sign_in.position.y + _sign_in.size.y
		want = minf(_rest_y, size.y - kb - KEYBOARD_GAP - sign_bottom)
	if absf(_scene.position.y - want) > 0.5:
		_scene.position.y = lerpf(_scene.position.y, want, 0.35)
		_place_sky()


func _sign_in_pressed() -> void:
	await _submit(false)


func _create_pressed() -> void:
	await _submit(true)


func _submit(create: bool) -> void:
	if _busy:
		return
	_busy = true
	_msg.text = ""
	_msg.label_settings.font_color = UI.RED
	var err: String
	if create:
		err = await Session.register(_user.text.strip_edges(), _pass.text)
	else:
		err = await Session.login(_user.text.strip_edges(), _pass.text)
	if err != "":
		_msg.text = err
		_busy = false
		return
	_msg.label_settings.font_color = UI.GOLD
	_msg.text = "Entering the realm..."
	await GameState.refresh()
	_busy = false
	if GameState.has_state():
		Nav.go("res://scenes/shell/shell.tscn")
	else:
		_msg.label_settings.font_color = UI.RED
		_msg.text = "Signed in, but the realm did not answer. Try again in a moment."
