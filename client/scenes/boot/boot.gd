extends Control
## The loading screen, and the decision about where the player lands.
##
## Built in code rather than as a scene tree so it can share the palette, the
## type scale and the safe-area helper with everything else -- it used to be a
## .tscn with its own hardcoded colours and font sizes, drifting from the rest of
## the client every time the rest of the client changed.
##
## What it deliberately does NOT show any more is the server address. That was on
## screen under the title, which tells a player nothing and tells everyone else
## where to point a load generator. The build version replaces it: a player can
## quote a version in a bug report, and it is the thing worth knowing. The host
## comes back in debug builds only, where it is genuinely useful.

## How long to wait before trying again after a network failure, per attempt.
## Backs off so a phone that has genuinely lost signal is not hammered, but
## recovers within seconds when it was one dropped packet.
const RETRY_DELAYS := [2.0, 4.0, 8.0, 15.0]

const STAGES := {
	"reach": [0.25, "Reaching the realm…"],
	"restore": [0.5, "Restoring your realm…"],
	"gather": [0.75, "Gathering your holdings…"],
	"banners": [1.0, "Raising the banners…"],
}

## The sign-in screen, while it is up. Boot outlives it deliberately.
var _auth: Node = null

var _mark: TextureRect
var _motto: Label
var _stage: Label
var _detail: Label
var _bar: ProgressBar
var _retry: Button
var _bar_tween: Tween
var _attempt := 0


func _ready() -> void:
	var bg := ColorRect.new()
	# Parchment, the same ground the game itself is on -- so the launch runs
	# splash, sign-in and shell without a single change of surface.
	#
	# This was briefly the imperial red instead, on the argument that the gold
	# wordmark needs a dark field. It does, and the answer is not to darken the
	# whole screen: every other line here is ink, and ink on red is unreadable.
	# The wordmark is set in red on parchment now, which is what the reference
	# does with a title and measures 6.57:1.
	bg.color = Palette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	SafeArea.apply(margin, Vector4(UI.GUTTER, UI.GAP_XL, UI.GUTTER, UI.GAP_XL))
	get_tree().root.size_changed.connect(
		func() -> void: SafeArea.apply(margin, Vector4(UI.GUTTER, UI.GAP_XL, UI.GUTTER, UI.GAP_XL)))
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	margin.add_child(col)

	# --- the middle: who made it, and what it is --------------------------
	var centre := VBoxContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_theme_constant_override("separation", UI.GAP_L)
	col.add_child(centre)

	_mark = TextureRect.new()
	_mark.texture = ArtRegistry.branding("miav_splash")
	_mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mark.custom_minimum_size = Vector2(0, 200)
	centre.add_child(_mark)

	centre.add_child(UI.spacer(UI.GAP_XL))
	centre.add_child(UI.caps("EMPERORS", UI.F_DISPLAY, Palette.BANNER, HORIZONTAL_ALIGNMENT_CENTER))

	# The motto comes from the server, so its presence is itself the proof that
	# the realm answered. Worth keeping: it is the first flavour anyone reads.
	_motto = UI.label("", UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_motto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_motto.custom_minimum_size = Vector2(0, 80)
	centre.add_child(_motto)

	# --- the bottom: what is happening, and how far along -----------------
	var foot := VBoxContainer.new()
	foot.add_theme_constant_override("separation", UI.GAP_S)
	col.add_child(foot)

	_stage = UI.label("", UI.F_CAPTION, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	foot.add_child(_stage)

	var bar_row := HBoxContainer.new()
	bar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_child(bar_row)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.custom_minimum_size = Vector2(360, 10)
	_bar.add_theme_stylebox_override("background",
		UI.panel_box(Palette.PANEL_HIGH, Palette.LINE, 5))
	_bar.add_theme_stylebox_override("fill",
		UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 5))
	bar_row.add_child(_bar)

	_retry = UI.ghost_button("Try again", UI.F_BODY)
	_retry.custom_minimum_size = Vector2(0, UI.TAP_MIN)
	_retry.visible = false
	_retry.pressed.connect(func() -> void:
		_attempt = 0
		_start())
	foot.add_child(_retry)

	_detail = UI.label(_footer_text(), UI.F_MICRO, Palette.TEXT_FAINT,
		HORIZONTAL_ALIGNMENT_CENTER)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	foot.add_child(_detail)

	_start()


## What goes where the server address used to be.
##
## A version string is what makes a bug report actionable; a hostname is what
## makes an attack convenient. In a debug build the host comes back, because
## during development knowing which server you are pointed at is the whole
## question.
func _footer_text() -> String:
	if not OS.has_feature("debug"):
		return Env.build_version
	# On a device this line is the only window into what the platform actually
	# reported. Screen, viewport and the insets derived from them: if the layout
	# looks wrong on a phone, these three numbers say why without a rebuild.
	var i := SafeArea.insets()
	var vp := get_viewport_rect().size
	return "%s  ·  %s\nwin %s  vp %.0fx%.0f  safe %s\ninset l%.0f t%.0f r%.0f b%.0f" % [
		Env.build_version, Env.api_base_url,
		str(DisplayServer.window_get_size()), vp.x, vp.y,
		str(DisplayServer.get_display_safe_area()),
		i.x, i.y, i.z, i.w]


func _stage_to(key: String) -> void:
	var s: Array = STAGES[key]
	_stage.text = str(s[1])
	_stage.add_theme_color_override("font_color", Palette.TEXT_DIM)
	if _bar_tween != null and _bar_tween.is_valid():
		_bar_tween.kill()
	# Tweened rather than snapped so the bar always reads as movement. A bar that
	# jumps between two long pauses looks stuck; one that creeps looks alive.
	_bar_tween = create_tween()
	_bar_tween.tween_property(_bar, "value", float(s[0]), 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _start() -> void:
	_retry.visible = false
	_stage_to("reach")
	_motto.text = ""

	var res: Api.Response = await Api.get_json("/v1/ping", false, Api.REACHABILITY_TIMEOUT)
	if not res.ok:
		_failed(res)
		return

	_attempt = 0
	_motto.text = str(res.data.get("motto", ""))

	# Checked BEFORE the saved session: a proof capture must land on the account
	# it names, not on whoever signed in last on this machine.
	var dev := _dev_login_args()
	if not dev.is_empty():
		_stage_to("restore")
		Session.sign_out()
		var err := await Session.login(dev[0], dev[1])
		if err != "":
			err = await Session.register(dev[0], dev[1])
		if err == "":
			_enter_game()
			return
		print("[boot] dev login failed: ", err)

	if Session.is_signed_in():
		_stage_to("restore")
		if await Session.try_refresh():
			_enter_game()
			return
		# A refresh that failed because the network is down must NOT drop the
		# player at the sign-in screen. They are still signed in -- the token is
		# still on disk -- and asking someone to type their password because a
		# packet went missing is how an app teaches people not to trust it.
		if Session.refresh_failed_offline:
			_failed(res)
			return

	_enter_auth()


## Shows a failure the way a player can act on, and keeps trying.
##
## Dead-ending behind a manual button after one failure is the worst outcome on a
## flaky mobile link, where the next attempt usually works. The screen keeps its
## shape -- one that rearranges itself on failure reads as a crash -- and the raw
## transport string never becomes the headline, because "The connection dropped
## (5)" is not something a player can do anything with.
func _failed(res: Api.Response) -> void:
	print("[boot] failed: ", res.error)
	_stage.text = "Cannot reach the realm"
	_stage.add_theme_color_override("font_color", Palette.DANGER)
	_motto.text = _explain(res)

	if _attempt >= RETRY_DELAYS.size():
		_retry.visible = true
		_detail.text = _footer_text()
		return

	var wait: float = RETRY_DELAYS[_attempt]
	_attempt += 1
	_retry.visible = _attempt > 1
	var left := int(wait)
	while left > 0:
		_detail.text = "Retrying in %ds…" % left
		await get_tree().create_timer(1.0).timeout
		if not is_instance_valid(self):
			return
		left -= 1
	_detail.text = _footer_text()
	_start()


## Turns a transport failure into a sentence about the player's situation.
func _explain(res: Api.Response) -> String:
	if res.status >= 500:
		return "The realm is resting. It will be back shortly."
	if res.error.contains("too long"):
		return "The realm is slow to answer."
	return "Check your connection — we will keep trying."


## Shows the sign-in screen. Boot stays ALIVE behind it, just hidden.
##
## It used to _swap() here, and _swap frees this node. Godot then dropped the
## authenticated -> _enter_game connection, because a connection to a freed
## object is not a connection -- so signing in did nothing at all. The server
## returned 200, the client never asked for state, and pressing the button again
## just signed in again. Every screenshot in development looked fine because
## --dev-login calls _enter_game directly and never goes near this screen.
##
## Boot owns the whole handoff now and does not let go until the shell is up.
func _enter_auth() -> void:
	_auth = preload("res://scenes/auth/auth.tscn").instantiate()
	_auth.authenticated.connect(_enter_game)
	get_tree().root.add_child(_auth)
	get_tree().current_scene = _auth
	visible = false


func _enter_game() -> void:
	visible = true
	_stage_to("gather")
	await GameState.refresh()
	await _dev_collect()
	_stage_to("banners")

	var shell := preload("res://scenes/shell/shell.tscn").instantiate()
	get_tree().root.add_child(shell)
	get_tree().current_scene = shell
	if _auth != null and is_instance_valid(_auth):
		_auth.queue_free()
	# Last statement: nothing may touch self after this.
	queue_free()


## Dev-only: performs N collects so a proof capture can show a played state
## rather than a fresh account. Goes through GameState, so it exercises the real
## optimistic queue rather than a shortcut.
func _dev_collect() -> void:
	var n := 0
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-collect" and i + 1 < args.size():
			n = int(args[i + 1])
	if n <= 0 or OS.has_feature("release"):
		return

	var jobs := GameState.jobs()
	for i in n:
		var best := {}
		for j in jobs:
			if bool(j.get("unlocked", false)) and GameState.display_energy() >= int(j.get("energy_cost", 0)):
				best = j
		if best.is_empty() or not GameState.collect(best):
			break
		await get_tree().create_timer(0.05).timeout
		jobs = GameState.jobs()
	print("[boot] dev-collect done: gold=", GameState.display_gold(),
		" energy=", GameState.display_energy(), " pending=", GameState.pending_count())


## Reads `--dev-login <username> <password>` from the command line.
## Release builds simply never receive these arguments.
func _dev_login_args() -> Array:
	if OS.has_feature("release"):
		return []
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dev-login" and i + 2 < args.size():
			return [args[i + 1], args[i + 2]]
	return []
