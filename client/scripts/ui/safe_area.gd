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


## The safe-area insets in stretch units: (left, top, right, bottom).
##
## Static, because the four CanvasLayer overlays need the same numbers and none
## of them is a Control. Reading the viewport off the root is valid from inside a
## CanvasLayer too, as long as the layer sets no transform of its own -- none of
## ours do.
static func insets() -> Vector4:
	if Env.fake_safe_area_on:
		return Env.fake_safe_area

	# get_display_safe_area() is implemented on macOS as well, where it reports
	# the desktop work area minus the menu bar. Honouring that would push the UI
	# down by the height of a menu bar that is not over the game at all.
	if not OS.has_feature("mobile"):
		return Vector4.ZERO

	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return Vector4.ZERO
	var vp: Vector2 = (loop as SceneTree).root.get_visible_rect().size
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	if screen.x <= 0 or screen.y <= 0:
		return Vector4.ZERO

	var safe := DisplayServer.get_display_safe_area()
	return Vector4(
		(float(safe.position.x) / float(screen.x)) * vp.x,
		(float(safe.position.y) / float(screen.y)) * vp.y,
		(float(screen.x - safe.end.x) / float(screen.x)) * vp.x,
		(float(screen.y - safe.end.y) / float(screen.y)) * vp.y)


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

	# One 88x88 swatch, bottom-left of the safe region: the minimum touch target,
	# so "is that button big enough" is a comparison rather than a guess.
	var swatch := ColorRect.new()
	swatch.color = Color(Palette.GOLD.r, Palette.GOLD.g, Palette.GOLD.b, 0.35)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	swatch.anchor_left = 0.0
	swatch.anchor_top = 1.0
	swatch.anchor_right = 0.0
	swatch.anchor_bottom = 1.0
	swatch.offset_left = i.x
	swatch.offset_top = -i.w - 88.0
	swatch.offset_right = i.x + 88.0
	swatch.offset_bottom = -i.w
	host.add_child(swatch)
	return layer
