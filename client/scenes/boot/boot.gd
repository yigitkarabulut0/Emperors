extends Control
## The loading screen, and the boot it reports on.
##
## The painting fills the screen; nothing is drawn over it except the bar's
## gold, which grows as each step of the boot finishes rather than on a timer.
## The frame around that bar, the word Loading and the studio mark are all in
## the painting, so there is one of each and they cannot drift apart.
##
## art/branding/ holds the two paintings and scripts/make-branding.py prepares
## them: the loading one has its track emptied so the bar can be filled for
## real, and the splash one -- the same picture without a bar, because iOS shows
## it before the app is running and nothing on it should look busy -- becomes
## the launch images.
##
## The paintings are 941x1672 and a phone is much taller, so covering the screen
## with one crops a fifth of its width -- which cut the E and the S off
## EMPERORS. make-branding.py first extends each to 941x2200 by stretching its
## own top and bottom rows (sky between pillars above, carpet and stone below,
## so neither shows), and the covering crop then takes a little off the top and
## bottom and nothing off the sides. The bar is placed through that same
## transform, which is what keeps the gold inside its painted frame on a screen
## of any shape.

const ART := Vector2(941.0, 2200.0)
## The track inside the painted frame, in the painting's own pixels.
## scripts/make-branding.py carries the same numbers.
const FILL_RECT := Rect2(205, 1791, 514, 21)

var _art: TextureRect
var _clip: Control
var _fill: TextureRect
var _status: Label
var _at := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_art = UI.image("branding/loading", Rect2())
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.clip_contents = true
	add_child(_art)

	# The gold is clipped to however much is done, so it grows from the left
	# edge of its frame instead of scaling from the middle.
	_clip = Control.new()
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)
	_fill = UI.image("branding/loading_fill", Rect2())
	_fill.stretch_mode = TextureRect.STRETCH_SCALE
	_clip.add_child(_fill)

	_status = UI.label("", 26, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_status)

	resized.connect(_lay_out)
	_lay_out()
	_boot.call_deferred()


## Where the painting lands on this screen, and the same for anything on it.
func _cover() -> Transform2D:
	var w := size.x if size.x > 1.0 else ART.x
	var h := size.y if size.y > 1.0 else ART.y
	var s := maxf(w / ART.x, h / ART.y)
	return Transform2D(0.0, Vector2(s, s), 0.0,
		Vector2((w - ART.x * s) / 2.0, (h - ART.y * s) / 2.0))


func _lay_out() -> void:
	var w := size.x if size.x > 1.0 else ART.x
	var h := size.y if size.y > 1.0 else ART.y
	UI.place(_art, Rect2(0, 0, w, h))

	var t := _cover()
	var bar := Rect2(t * FILL_RECT.position, FILL_RECT.size * t.get_scale())
	UI.place(_clip, bar)
	UI.place(_fill, Rect2(0, 0, bar.size.x, bar.size.y))
	_clip.size.x = bar.size.x * _at

	var s := t.get_scale().x
	_status.label_settings.font_size = int(26.0 * s)
	UI.place(_status, Rect2(0, bar.end.y + 18.0 * s, w, 44.0 * s))


## Moves the bar to `at` (0..1). `note` is for anything the painting cannot say
## -- an error, a retry -- and is empty on the ordinary path, because the
## painting already says Loading.
func _step_to(at: float, note: String = "") -> void:
	_at = clampf(at, 0.0, 1.0)
	_status.text = note
	var full := _cover().get_scale().x * FILL_RECT.size.x
	var tw := create_tween()
	tw.tween_property(_clip, "size:x", full * _at, 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _boot() -> void:
	_step_to(0.12)
	# Dev auto sign-in, so capture runs (which disable input) can reach a screen.
	if Env.args.has("dev_login"):
		var creds: Array = Env.args["dev_login"]
		Session.sign_out()
		var err: String = await Session.login(str(creds[0]), str(creds[1]))
		if err != "":
			err = await Session.register(str(creds[0]), str(creds[1]))
		if err != "":
			_status.text = err
			return
	if Session.is_signed_in():
		_step_to(0.45)
		var ok: bool = await Session.try_refresh()
		if not ok and Session.refresh_failed_offline:
			_step_to(0.12, "Cannot reach the server. Retrying...")
			await get_tree().create_timer(3.0).timeout
			_boot()
			return
	if Session.is_signed_in():
		_step_to(0.78)
		await GameState.refresh()
		if GameState.has_state():
			_step_to(1.0)
			Nav.go("res://scenes/shell/shell.tscn")
			return
	_step_to(1.0)
	Nav.go("res://scenes/auth/auth.tscn")
