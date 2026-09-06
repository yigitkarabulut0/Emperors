class_name SafeArea
extends MarginContainer
## Keeps content out of the notch, the Dynamic Island and the home indicator.
##
## get_display_safe_area() speaks physical screen pixels; the UI speaks 720-wide
## stretch units, and the factor between them is different on every device. So
## the inset is computed as a *fraction of the screen* and then multiplied by the
## viewport rect -- the units cancel and the same code is right on a 19.5:9
## iPhone and a 4:3 iPad. Converting through a single hardcoded scale is how you
## end up 9-22% over-padded on the devices you did not measure.
##
## Only content is inset. Background art and panel fills deliberately run
## full-bleed behind this node: a letterboxed strip above the notch is the single
## most obvious "this is a port" tell on iOS. That is why the shell insets the
## top bar's *padding* rather than the top bar itself.
##
## Three ways to use it:
##
##   * as a node, wrapping a content column (the plain case)
##   * SafeArea.apply(margin_container, extra), when a container already exists
##     and only its margins need to change
##   * SafeArea.wrap(canvas_layer, extra), for the modal overlays -- a CanvasLayer
##     is not a Control and cannot inherit a MarginContainer, so each one needs
##     the insets applied to a container of its own

@export var extra := Vector4(24, 8, 24, 8)   ## left, top, right, bottom (units)

## No real device insets more than this fraction of the screen on any edge.
const MAX_INSET := 0.2

## Clearance for a rounded display corner.
##
## get_display_safe_area() covers the notch and the home indicator and says
## nothing whatever about the screen's RADIUS, so in portrait it reports zero on
## both sides while the corners themselves still cut the corner off anything
## drawn out to the edge. On a real phone that shows up as a card whose top
## corner is sliced away -- which is exactly what it looks like, a bug in the
## card rather than in the screen.
##
## A device that reports a top inset has a rounded display; that is what the
## inset is there for. So this applies on precisely those devices and adds
## nothing on a square screen or a desktop.
## 12, not 18. It is charged at both edges; the cards it protects sit between the
## banner and the action strip, so they are never in the corner where the radius
## actually bites. The number lives on UI so that tests can reach it.
const CORNER := float(UI.CORNER)

## The most recent computed insets, for the loading screen's debug readout. On a
## device this is the only way to see what the platform actually reported.
static var last := Vector4.ZERO


## The safe-area insets in stretch units: (left, top, right, bottom).
##
## Static, because the four CanvasLayer overlays need the same numbers and none
## of them is a Control. Reading the viewport off the root is valid from inside a
## CanvasLayer too, as long as the layer sets no transform of its own -- none of
## ours do.
static func insets() -> Vector4:
	if Env.fake_safe_area_on:
		return _round_corners(Env.fake_safe_area)

	# get_display_safe_area() is implemented on macOS as well, where it reports
	# the desktop work area minus the menu bar. Honouring that would push the UI
	# down by the height of a menu bar that is not over the game at all.
	if not OS.has_feature("mobile"):
		return Vector4.ZERO

	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return Vector4.ZERO
	var vp: Vector2 = (loop as SceneTree).root.get_visible_rect().size

	# Measured against the WINDOW, not the screen.
	#
	# get_display_safe_area() and window_get_size() are both DisplayServer APIs
	# reporting the same surface in the same units, so the fraction between them
	# is right whatever those units turn out to be. screen_get_size() is a
	# different measurement of a different thing, and if the platform ever reports
	# one in points and the other in pixels the mismatch is a silent factor of
	# three -- which on a phone means a third of the screen given away to a margin
	# that should have been a sixteenth.
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		win = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	if win.x <= 0 or win.y <= 0:
		return Vector4.ZERO

	var safe := DisplayServer.get_display_safe_area()
	if safe.size.x <= 0 or safe.size.y <= 0:
		return Vector4.ZERO

	var i := Vector4(
		(float(safe.position.x) / float(win.x)) * vp.x,
		(float(safe.position.y) / float(win.y)) * vp.y,
		(float(win.x - safe.end.x) / float(win.x)) * vp.x,
		(float(win.y - safe.end.y) / float(win.y)) * vp.y)

	# A last line of defence against exactly that unit mismatch.
	#
	# No shipping device has a safe-area inset anywhere near a fifth of the
	# screen. If the arithmetic says otherwise the inputs disagreed about units,
	# and under-insetting -- a status bar slightly overlapping a panel edge -- is
	# vastly better than a layout squeezed into half its screen with the buttons
	# pushed off the bottom. The reason is logged rather than swallowed.
	var cap := Vector4(vp.x * MAX_INSET, vp.y * MAX_INSET, vp.x * MAX_INSET, vp.y * MAX_INSET)
	if i.x > cap.x or i.y > cap.y or i.z > cap.z or i.w > cap.w:
		push_warning("[safe_area] implausible insets %s for window %s / viewport %s — clamped"
			% [str(i), str(win), str(vp)])
		i = Vector4(minf(i.x, cap.x), minf(i.y, cap.y), minf(i.z, cap.z), minf(i.w, cap.w))
	i = _round_corners(i)
	last = i
	return i


## Widens the sides to clear the display's own corner radius, on devices that
## have one.
##
## maxf rather than +: a device that genuinely reports a side inset -- a
## landscape notch, an Android cutout -- already has more than this.
##
## Applied to the FAKE insets as well as the real ones. The whole point of
## --fake-safe-area is that the device's layout can be seen on a desktop, and a
## preview that skips this would show corners the phone does not.
static func _round_corners(i: Vector4) -> Vector4:
	if i.y <= 0.0:
		return i
	return Vector4(maxf(i.x, CORNER), i.y, maxf(i.z, CORNER), i.w)


## Writes insets + extra onto a MarginContainer's four margin constants.
static func apply(mc: MarginContainer, extra_units: Vector4 = Vector4.ZERO) -> void:
	var i := insets() + extra_units
	mc.add_theme_constant_override("margin_left", int(i.x))
	mc.add_theme_constant_override("margin_top", int(i.y))
	mc.add_theme_constant_override("margin_right", int(i.z))
	mc.add_theme_constant_override("margin_bottom", int(i.w))


## Builds a full-rect MarginContainer inside a CanvasLayer, already inset, and
## keeps it inset across rotation. Returns it for the caller to fill.
static func wrap(layer: CanvasLayer, extra_units: Vector4 = Vector4.ZERO) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.set_anchors_preset(Control.PRESET_FULL_RECT)
	apply(mc, extra_units)
	layer.add_child(mc)

	# Deferred to entering the tree: an overlay is usually built before it is
	# added to the root, so get_tree() is null right here.
	var relayout := func() -> void: apply(mc, extra_units)
	mc.tree_entered.connect(func() -> void:
		mc.get_tree().root.size_changed.connect(relayout)
		relayout.call())
	# ...and the connection has to die with the container, or a freed overlay
	# leaves a callable pointing at a dead node on a signal that fires on every
	# rotation for the rest of the session.
	mc.tree_exiting.connect(func() -> void:
		var tree := mc.get_tree()
		if tree != null and tree.root.size_changed.is_connected(relayout):
			tree.root.size_changed.disconnect(relayout))
	return mc


func _ready() -> void:
	get_tree().root.size_changed.connect(_apply)
	_apply()


func _notification(what: int) -> void:
	# Orientation and safe area can both change while backgrounded -- rotating
	# the phone on the home screen is the everyday case.
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_apply.call_deferred()


func _apply() -> void:
	apply(self, extra)


## A translucent overlay showing where the insets are, for eyeballing layout on
## a desktop that has none. Only ever added when --fake-safe-area is on.
static func debug_overlay() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 200
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(host)

	var i := insets()
	# Anchors and offsets are set by hand rather than through a preset: a preset
	# zeroes the offsets on the axis it stretches, so a band sized afterwards is
	# immediately flattened again by the layout pass.
	var band := func(ax: float, ay: float, bx: float, by: float,
			ol: float, ot: float, orr: float, ob: float) -> void:
		if absf(orr - ol) < 0.5 and absf(ob - ot) < 0.5 and ax == bx and ay == by:
			return
		var r := ColorRect.new()
		r.color = Color(Palette.DANGER.r, Palette.DANGER.g, Palette.DANGER.b, 0.28)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.anchor_left = ax
		r.anchor_top = ay
		r.anchor_right = bx
		r.anchor_bottom = by
		r.offset_left = ol
		r.offset_top = ot
		r.offset_right = orr
		r.offset_bottom = ob
		host.add_child(r)

	if i.y > 0.0:
		band.call(0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, i.y)
	if i.w > 0.0:
		band.call(0.0, 1.0, 1.0, 1.0, 0.0, -i.w, 0.0, 0.0)
	if i.x > 0.0:
		band.call(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, i.x, 0.0)
	if i.z > 0.0:
		band.call(1.0, 0.0, 1.0, 1.0, -i.z, 0.0, 0.0, 0.0)

	# One TAP_MIN swatch, bottom-left of the safe region: the minimum touch
	# target, so "is that button big enough" is a comparison, not a guess.
	var swatch := ColorRect.new()
	swatch.color = Color(Palette.GOLD.r, Palette.GOLD.g, Palette.GOLD.b, 0.35)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	swatch.anchor_left = 0.0
	swatch.anchor_top = 1.0
	swatch.anchor_right = 0.0
	swatch.anchor_bottom = 1.0
	swatch.offset_left = i.x
	swatch.offset_top = -i.w - float(UI.TAP_MIN)
	swatch.offset_right = i.x + float(UI.TAP_MIN)
	swatch.offset_bottom = -i.w
	host.add_child(swatch)
	return layer
