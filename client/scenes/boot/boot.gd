extends Control
## The first screen: the app's own picture while it reaches the realm.
##
## What it replaces was a flat navy field with EMPERORS on it, and the word was
## cut in half. set_anchors_preset(CENTER_TOP) puts the anchor at the middle of
## the screen and the position that followed was read from there, so a 941-wide
## box began at 470 and ran 470 units off the right edge, with its centred text
## sitting at the screen's own edge. Every other screen places a rect with
## UI.place, measured from the corner.
##
## The picture is the game's own: branding/vista is the castle and the banners
## cut out of the Kingdom painting and branding/foot is the foliage every screen
## stands on. scripts/make-branding.py builds the iOS launch image from the same
## pieces at the same fractions, so the frame iOS shows while the engine starts
## and the first frame the engine draws are one picture and nothing jumps.
##
## Laid out in fractions of the screen rather than of the 941x1672 design grid:
## a 19.5:9 phone runs a long way past the grid's foot, and a composition
## measured on the grid leaves the bottom third of the phone empty.

const VISTA_F := 0.235
const FADE_F := 0.105
const MED_MID_F := 0.345
const MED_W_F := 0.60
const TITLE_MID_F := 0.545
const TITLE_SIZE_F := 0.0625
const RULE_F := 0.605
const RULE_W_F := 0.32
const SUB_MID_F := 0.634
const SUB_SIZE_F := 0.018
const BAR_F := 0.795
const STATUS_MID_F := 0.837
const FOOT_F := 0.062

var _vista: TextureRect
var _fade: TextureRect
var _foot: TextureRect
var _medallion: TextureRect
var _title: Label
var _rule: ColorRect
var _sub: Label
var _track: ColorRect
var _bar: ColorRect
var _status: Label
var _at := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_vista = UI.image("branding/vista", Rect2())
	_vista.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_vista.clip_contents = true
	add_child(_vista)

	_fade = TextureRect.new()
	_fade.texture = _fade_texture()
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

	_foot = UI.image("branding/foot", Rect2())
	_foot.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_foot)

	_medallion = UI.image("branding/medallion", Rect2())
	add_child(_medallion)

	_title = UI.label("EMPERORS", 104, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_title)
	_rule = ColorRect.new()
	_rule.color = Color(UI.GOLD_DIM, 0.6)
	add_child(_rule)
	_sub = UI.label("RULE YOUR REALM", 30, UI.DIM, "title", 500, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_sub)

	# A real bar: it moves when a step finishes, not on a timer.
	_track = ColorRect.new()
	_track.color = Color(0.10, 0.16, 0.22, 1.0)
	add_child(_track)
	_bar = ColorRect.new()
	_bar.color = UI.GOLD_DIM
	add_child(_bar)
	_status = UI.label("Reaching the realm", 28, UI.DIM, "body", 500, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_status)

	resized.connect(_lay_out)
	_lay_out()
	_boot.call_deferred()


func _lay_out() -> void:
	var w := size.x if size.x > 1.0 else 941.0
	var h := size.y if size.y > 1.0 else 1672.0
	var vh := VISTA_F * h
	UI.place(_vista, Rect2(0, 0, w, vh))
	UI.place(_fade, Rect2(0, vh - FADE_F * h, w, FADE_F * h))
	UI.place(_foot, Rect2(0, h - FOOT_F * h, w, FOOT_F * h))

	var ms := MED_W_F * w
	UI.place(_medallion, Rect2((w - ms) / 2.0, MED_MID_F * h - ms / 2.0, ms, ms))

	var ts := TITLE_SIZE_F * h
	_title.label_settings.font_size = int(ts)
	UI.place(_title, Rect2(0, TITLE_MID_F * h - ts, w, ts * 2.0))
	UI.place(_rule, Rect2((w - RULE_W_F * w) / 2.0, RULE_F * h, RULE_W_F * w, maxf(2.0, h / 1000.0)))
	var ss := SUB_SIZE_F * h
	_sub.label_settings.font_size = int(ss)
	UI.place(_sub, Rect2(0, SUB_MID_F * h - ss, w, ss * 2.0))

	var bw := 0.44 * w
	UI.place(_track, Rect2((w - bw) / 2.0, BAR_F * h, bw, 6))
	UI.place(_bar, Rect2((w - bw) / 2.0, BAR_F * h, bw * _at, 6))
	UI.place(_status, Rect2(0, STATUS_MID_F * h - 22, w, 44))


## A vertical ramp from nothing to the ground colour, so the picture's lower
## edge is not a line drawn across the screen.
func _fade_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(UI.GROUND, 0.0))
	g.set_color(1, Color(UI.GROUND, 1.0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	t.width = 8
	t.height = 128
	return t


## Moves the bar to `at` (0..1) and says what is happening.
func _step_to(at: float, what: String) -> void:
	_at = clampf(at, 0.0, 1.0)
	_status.text = what
	var bw := 0.44 * (size.x if size.x > 1.0 else 941.0)
	var tw := create_tween()
	tw.tween_property(_bar, "size:x", bw * _at, 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _boot() -> void:
	_step_to(0.15, "Reaching the realm")
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
		_step_to(0.45, "Presenting your seal")
		var ok: bool = await Session.try_refresh()
		if not ok and Session.refresh_failed_offline:
			_step_to(0.15, "Cannot reach the server. Retrying...")
			await get_tree().create_timer(3.0).timeout
			_boot()
			return
	if Session.is_signed_in():
		_step_to(0.75, "Gathering your holdings")
		await GameState.refresh()
		if GameState.has_state():
			_step_to(1.0, "Ready")
			Nav.go("res://scenes/shell/shell.tscn")
			return
	_step_to(1.0, "Ready")
	Nav.go("res://scenes/auth/auth.tscn")
