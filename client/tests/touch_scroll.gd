extends SceneTree
## A list must follow your finger, not only its scrollbar.
##
## The reported failure: on the Jobs page the list only moved by dragging the
## hairline bar at the right edge. Every row in that list is a Button, and
## Godot's own touch scrolling is BOTH eaten by the button under the finger AND
## gated behind DisplayServer.is_touchscreen_available() -- which is false on a
## desktop, so the engine's implementation cannot even be exercised here. That is
## why this went unnoticed: it is untestable from the machine it was written on.
##
## DragScroll replaces it from _input(), which runs before the GUI and so sees the
## drag regardless. Driven here with MOUSE events, because those work on a desktop
## and take the identical code path.
##
## Run WINDOWED. Headless Godot routes no input at all.

var _scroll: ScrollContainer
var _rows: VBoxContainer
var _clicks := 0


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame

	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	host.add_child(_scroll)
	DragScroll.install(_scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)

	# The shape that actually failed: a tall column of Buttons, like a jobs list.
	# A column of Labels would scroll and prove nothing.
	for i in 40:
		var b := Button.new()
		b.text = "row %d" % i
		b.custom_minimum_size = Vector2(0, 104)
		b.pressed.connect(func() -> void: _clicks += 1)
		_rows.add_child(b)

	for i in 6:
		await process_frame

	# --- a drag scrolls, and does not click ---------------------------------
	_clicks = 0
	var before := _scroll.scroll_vertical
	await _gesture(-40.0, 10)
	var after := _scroll.scroll_vertical
	if after <= before:
		_fail("dragging the list did not move it (%d -> %d); only the scrollbar works"
			% [before, after])
		return
	if _clicks > 0:
		_fail("the drag also pressed %d row(s): a flick must not be a tap" % _clicks)
		return

	# --- a drag the other way goes back -------------------------------------
	var mid := _scroll.scroll_vertical
	await _gesture(40.0, 10)
	if _scroll.scroll_vertical >= mid:
		_fail("dragging back down did not move the list (%d -> %d)"
			% [mid, _scroll.scroll_vertical])
		return

	# --- and a tap is still a tap -------------------------------------------
	_clicks = 0
	await _gesture(0.0, 0)
	if _clicks == 0:
		_fail("a plain tap no longer presses the row under it")
		return

	print("PASS  drag scrolls %d units, does not click; a tap still clicks"
		% (after - before))
	quit(0)


## One press, `steps` moves of `dy` each, one release.
func _gesture(dy: float, steps: int) -> void:
	var at := root.get_visible_rect().size * 0.5
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = at
	down.global_position = at
	Input.parse_input_event(down)
	await process_frame

	var y := at.y
	for i in steps:
		y += dy
		var mm := InputEventMouseMotion.new()
		mm.position = Vector2(at.x, y)
		mm.global_position = mm.position
		mm.relative = Vector2(0, dy)
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(mm)
		await process_frame

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = Vector2(at.x, y)
	up.global_position = up.position
	Input.parse_input_event(up)
	for i in 3:
		await process_frame
