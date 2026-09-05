class_name DragScroll
extends Node
## Makes a ScrollContainer follow your finger, on every platform.
##
## Godot's own touch scrolling is gated behind
## DisplayServer.is_touchscreen_available(), and the events it needs are consumed
## by whatever is under the finger -- which in this game is always a Button,
## because every list is a list of buttons. The result on a phone was a list that
## only moved by dragging the hairline scrollbar at the right edge, which is not a
## gesture anybody uses.
##
## So this does it directly, from _input(), which runs before the GUI and
## therefore sees the drag whether or not a Button would have eaten it. The same
## code path serves mouse and touch, which also means it can be tested on a
## desktop rather than only discovered on a device.
##
## Attach with DragScroll.install(scroll_container).

## How far the finger must travel before this is a scroll and not a tap. Below
## it, taps must keep working exactly as they did.
const THRESHOLD := 10.0

## Flick inertia. Decays fast enough to feel controlled rather than slippery.
const FRICTION := 6.0
const MIN_VELOCITY := 8.0

var _scroll: ScrollContainer
var _pressed := false
var _dragging := false
var _start := Vector2.ZERO
var _last := Vector2.ZERO
var _velocity := 0.0


static func install(scroll: ScrollContainer) -> DragScroll:
	var d := DragScroll.new()
	d._scroll = scroll
	scroll.add_child(d)
	return d


func _ready() -> void:
	set_process(true)


func _position_of(event: InputEvent) -> Variant:
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).position
	if event is InputEventScreenDrag:
		return (event as InputEventScreenDrag).position
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).position
	if event is InputEventMouseMotion:
		return (event as InputEventMouseMotion).position
	return null


func _input(event: InputEvent) -> void:
	if _scroll == null or not is_instance_valid(_scroll) or not _scroll.is_visible_in_tree():
		return

	var pos_v: Variant = _position_of(event)
	if pos_v == null:
		return
	var pos: Vector2 = pos_v

	# --- press ---------------------------------------------------------------
	var press := false
	var release := false
	if event is InputEventScreenTouch:
		press = (event as InputEventScreenTouch).pressed
		release = not press
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		press = mb.pressed
		release = not press

	if press:
		if not _scroll.get_global_rect().has_point(pos):
			return
		# The scrollbar is its own gesture. Taking over here would move the list
		# twice as fast as the thumb the player is holding.
		var bar := _scroll.get_v_scroll_bar()
		if bar != null and bar.visible and bar.get_global_rect().has_point(pos):
			return
		_pressed = true
		_dragging = false
		_start = pos
		_last = pos
		_velocity = 0.0
		return

	if release:
		if _dragging:
			# Swallow the release so the button under the finger does not fire.
			# Without this, every flick also presses whatever it started on.
			get_viewport().set_input_as_handled()
		_pressed = false
		_dragging = false
		return

	# --- movement ------------------------------------------------------------
	if not _pressed:
		return
	var delta := pos - _last
	_last = pos

	if not _dragging:
		if absf(pos.y - _start.y) < THRESHOLD:
			return
		_dragging = true

	_apply(-delta.y)
	_velocity = -delta.y / maxf(get_process_delta_time(), 0.0001)
	get_viewport().set_input_as_handled()


func _process(dt: float) -> void:
	if _dragging or absf(_velocity) < MIN_VELOCITY:
		return
	if _scroll == null or not is_instance_valid(_scroll):
		return
	_apply(_velocity * dt)
	_velocity = move_toward(_velocity, 0.0, absf(_velocity) * FRICTION * dt)


func _apply(by: float) -> void:
	var before := _scroll.scroll_vertical
	_scroll.scroll_vertical = int(round(float(before) + by))
	# Hitting either end kills the flick, so it does not keep trying to travel
	# past a list that has already stopped.
	if _scroll.scroll_vertical == before and absf(by) >= 1.0:
		_velocity = 0.0
