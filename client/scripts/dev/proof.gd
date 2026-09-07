extends Node
## Dev-only screenshot capture: --capture <path> --capture-after <seconds>.
##
## The game screenshots itself, so this works on the desktop and on the device
## without OS screenshot permissions. In a capture run the scenes are mounted in
## a 941x1672 SubViewport (Nav.host), so the saved image is the design grid 1:1
## no matter how the window was clamped. Input is disabled so a stray click
## cannot fire a button under an always-on-top window.

var _path := ""
var _after := 2.0


func _ready() -> void:
	if not Env.is_dev() or not Env.args.has("capture"):
		return
	_path = Env.args["capture"]
	_after = float(Env.args.get("capture_after", 2.0))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	get_viewport().gui_disable_input = true
	_mount_viewport.call_deferred()
	print("[proof] capture in %.1fs -> %s" % [_after, _path])
	get_tree().create_timer(_after).timeout.connect(_capture)


func _mount_viewport() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	vp.size = Vector2i(941, 1672)
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


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = Nav.host.get_texture().get_image() if Nav.host != null else get_viewport().get_texture().get_image()
	var err := img.save_png(_path)
	print("[proof] saved %s (%dx%d) err=%d" % [_path, img.get_width(), img.get_height(), err])
	get_tree().quit()
