extends Node
## Dev-only screenshot capture: --capture <path> --capture-after <seconds>
## [--capture-size WxH] [--scroll <pixels>].
##
## The game screenshots itself, so this works on the desktop and on the device
## without OS screenshot permissions. In a capture run the scenes are mounted in
## a 941x1672 SubViewport (Nav.host), so the saved image is the design grid 1:1
## no matter how the window was clamped. Input is disabled so a stray click
## cannot fire a button under an always-on-top window.

var _path := ""
var _after := 2.0
## --scroll <pixels> runs the screen's own scroll down before the shot, so a
## section further down a long screen (the store's herald, say) can be looked at
## beside its painting without a hand on the phone.
var _scroll := 0.0
const SCROLL_SETTLE := 0.4


func _ready() -> void:
	if not Env.is_dev() or not Env.args.has("capture"):
		return
	_path = Env.args["capture"]
	_after = float(Env.args.get("capture_after", 2.0))
	_scroll = float(Env.args.get("scroll", 0.0))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	get_viewport().gui_disable_input = true
	_mount_viewport.call_deferred()
	print("[proof] capture in %.1fs -> %s" % [_after, _path])
	get_tree().create_timer(_after).timeout.connect(_capture)


func _mount_viewport() -> void:
	var container := SubViewportContainer.new()
	# With stretch on, the container resizes the viewport to the window, which
	# is the design grid. A --capture-size run wants the viewport at its own
	# size instead, so the container shows it 1:1 (clipped by the window).
	container.stretch = not Env.args.has("capture_size")
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	# The design grid by default; --capture-size 941x2040 shows what a taller
	# phone shows, extra canvas and all.
	vp.size = Env.args.get("capture_size", Vector2i(941, 1672))
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.gui_disable_input = true
	container.add_child(vp)
	get_tree().root.add_child(container)
	Nav.host = vp
	# The boot scene is already running under the root; move it in so it is drawn
	# at the grid size too.
	var cur := get_tree().current_scene
	if cur != null:
		cur.get_parent().remove_child(cur)
		vp.add_child(cur)


## The scroll a thumb would be on: the one with the most to scroll THROUGH.
##
## Comparing content height alone picked a tall list that already fits its own
## window -- the Kingdom tab's help body ran past the page and the flag moved a
## section's inner room instead. What matters is the OVERFLOW.
func _tallest_scroll(n: Node) -> ScrollContainer:
	var best: ScrollContainer = null
	if n is ScrollContainer and (n as ScrollContainer).is_visible_in_tree() \
			and _overflow(n as ScrollContainer) > 1.0:
		best = n as ScrollContainer
	for c in n.get_children():
		var found := _tallest_scroll(c)
		if found != null and (best == null or _overflow(found) > _overflow(best)):
			best = found
	return best


## Every scroll on the screen and how far each can travel, for the line above.
func _list_scrolls(n: Node, out: Array) -> void:
	if n is ScrollContainer:
		var sc := n as ScrollContainer
		out.append("%s %.0f in %.0f%s" % [sc.name, _content_height(sc), sc.size.y,
			"" if sc.is_visible_in_tree() else " (hidden)"])
	for c in n.get_children():
		_list_scrolls(c, out)


## How far this scroll can travel.
func _overflow(sc: ScrollContainer) -> float:
	return maxf(0.0, _content_height(sc) - sc.size.y)


func _content_height(sc: ScrollContainer) -> float:
	var h := 0.0
	for c in sc.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			h = maxf(h, (c as Control).size.y)
	return h


func _capture() -> void:
	if _scroll > 0.0:
		var sc := _tallest_scroll(Nav.host if Nav.host != null else get_tree().root)
		if sc != null:
			sc.scroll_vertical = int(_scroll)
			print("[proof] scrolled %s to %d" % [sc.name, sc.scroll_vertical])
			await get_tree().create_timer(SCROLL_SETTLE).timeout
		else:
			# Say WHAT was found, not just that nothing moved: a screen whose
			# body runs past the page with no scroll behind it is a bug, and a
			# silent flag hides it.
			var seen: Array = []
			_list_scrolls(Nav.host if Nav.host != null else get_tree().root, seen)
			print("[proof] nothing on this screen scrolls; %d scroll(s): %s"
				% [seen.size(), ", ".join(PackedStringArray(seen))])
	await RenderingServer.frame_post_draw
	var img: Image = Nav.host.get_texture().get_image() if Nav.host != null else get_viewport().get_texture().get_image()
	var err := img.save_png(_path)
	print("[proof] saved %s (%dx%d) err=%d" % [_path, img.get_width(), img.get_height(), err])
	get_tree().quit()
