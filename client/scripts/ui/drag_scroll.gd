class_name DragScroll
extends Node
## Makes a ScrollContainer follow your finger, on every platform, exactly once.
##
## Godot's own touch scrolling is gated behind
## DisplayServer.is_touchscreen_available() AND is consumed by whatever is under
## the finger -- which in this game is always a Button, because every list is a
## list of buttons. So a phone could only scroll by dragging the hairline
## scrollbar. This does it from _input(), which runs before the GUI and therefore
## sees the drag whether or not a Button would have eaten it.
##
## Two things make the difference between working and "scrolls strangely":
##
##   * ONE event family, never both. With emulate_mouse_from_touch on -- which is
##     the engine default -- a single finger drag arrives twice, as a ScreenDrag
##     and again as a synthesised MouseMotion. Handling both moved the list at
##     double speed and fought itself.
##   * the container's own gui_input is turned off, so the engine's native touch
##     scrolling cannot also run. It activated only when a press happened to miss
##     a button, which made the behaviour differ depending on where you started
##     the drag. The wheel is handled here instead so desktop keeps working.

## How far the finger must travel before this is a scroll and not a tap.
const THRESHOLD := 10.0

## Flick inertia: how fast the throw decays, and when to stop bothering.
const FRICTION := 7.0
const MIN_VELOCITY := 12.0
const MAX_VELOCITY := 4200.0

## One wheel notch, in units.
const WHEEL_STEP := 90.0

var _scroll: ScrollContainer
var _touch: bool = false      ## which event family this device speaks
var _pressed := false
var _dragging := false
var _start := Vector2.ZERO
var _last := Vector2.ZERO
var _last_ms := 0
var _velocity := 0.0


static func install(scroll: ScrollContainer) -> DragScroll:
	var d := DragScroll.new()
	d._scroll = scroll
	# The container must not also scroll itself. Children -- the rows, and the
	# scrollbar -- are unaffected: mouse_filter is per-control.
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(d)
	return d


func _ready() -> void:
	_touch = DisplayServer.is_touchscreen_available()
	set_process(true)


func _usable() -> bool:
	return _scroll != null and is_instance_valid(_scroll) and _scroll.is_visible_in_tree()


func _input(event: InputEvent) -> void:
	if not _usable():
		return

	# Exactly one family. On a touch device the emulated mouse events describing
	# the same finger are ignored, and vice versa.
	if _touch:
		if event is InputEventScreenTouch:
			_begin_or_end((event as InputEventScreenTouch).pressed,
				(event as InputEventScreenTouch).position)
		elif event is InputEventScreenDrag:
			_move((event as InputEventScreenDrag).position)
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if _scroll.get_global_rect().has_point(mb.position):
				_apply(-WHEEL_STEP)
				get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if _scroll.get_global_rect().has_point(mb.position):
				_apply(WHEEL_STEP)
				get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_begin_or_end(mb.pressed, mb.position)
	elif event is InputEventMouseMotion:
		_move((event as InputEventMouseMotion).position)


func _begin_or_end(pressed: bool, pos: Vector2) -> void:
	if pressed:
		if not _scroll.get_global_rect().has_point(pos):
			return
		# The scrollbar is its own gesture. Taking over would move the list twice
		# as fast as the thumb the player is holding.
		var bar := _scroll.get_v_scroll_bar()
		if bar != null and bar.visible and bar.get_global_rect().has_point(pos):
			return
		_pressed = true
		_dragging = false
		_start = pos
		_last = pos
		_last_ms = Time.get_ticks_msec()
		_velocity = 0.0
		return

	if _dragging:
		# Swallow the release so the row under the finger does not fire. Without
		# this every flick is also a tap on whatever it started on.
		get_viewport().set_input_as_handled()
	_pressed = false
	_dragging = false


func _move(pos: Vector2) -> void:
	if not _pressed:
		return
	var delta := pos - _last
	var now := Time.get_ticks_msec()
	var dt := float(maxi(now - _last_ms, 1)) / 1000.0
	_last = pos
	_last_ms = now

	if not _dragging:
		if absf(pos.y - _start.y) < THRESHOLD:
			return
		_dragging = true

	_apply(-delta.y)
	# Smoothed, so one stuttery frame near the end of a gesture does not decide
	# how far the flick travels.
	_velocity = clampf(lerpf(_velocity, -delta.y / dt, 0.4), -MAX_VELOCITY, MAX_VELOCITY)
	get_viewport().set_input_as_handled()


func _process(dt: float) -> void:
	if _dragging or absf(_velocity) < MIN_VELOCITY or not _usable():
		return
	_apply(_velocity * dt)
	_velocity = move_toward(_velocity, 0.0, absf(_velocity) * FRICTION * dt)


func _apply(by: float) -> void:
	var before := _scroll.scroll_vertical
	_scroll.scroll_vertical = int(round(float(before) + by))
	# Hitting either end kills the flick rather than letting it keep trying to
	# travel past a list that has already stopped.
	if _scroll.scroll_vertical == before and absf(by) >= 1.0:
		_velocity = 0.0
