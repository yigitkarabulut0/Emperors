extends Node
## Screenshot capture for the milestone proof ritual.
##
## The build plan requires evidence from a running build at every milestone, not
## a claim that it works. Rather than depend on OS screenshot tools (which need
## permissions on macOS and do not exist on a device), the game captures its own
## viewport.
##
## Usage:
##   godot --path client -- --capture proof/M0/boot.png [--capture-after 2.0]
##
## Runs on desktop and on device. On device the file lands in user://, which
## `xcrun devicectl` can pull back.

const DEFAULT_DELAY := 2.0
## Longest we will wait for a drawn frame before capturing anyway. macOS stops
## delivering draw callbacks to an occluded window, so awaiting
## RenderingServer.frame_post_draw unconditionally hangs forever whenever the
## terminal is in front — which is exactly how this gets run.
const DRAW_WAIT_TIMEOUT := 2.0

var _path := ""
var _delay := DEFAULT_DELAY

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--capture":
				if i + 1 < args.size():
					_path = args[i + 1]
			"--capture-after":
				if i + 1 < args.size():
					_delay = float(args[i + 1])
	if _path.is_empty():
		return
	# Keep the window drawing even when the terminal has focus. ALWAYS_ON_TOP is
	# enough; do NOT call window_move_to_foreground() — raising the window under
	# the mouse pointer makes macOS deliver a click-through, which lands on
	# whatever button is under the cursor and fires a phantom press.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	# A capture run is non-interactive by definition. Ignoring input also stops
	# the pointer, which now sits over an always-on-top window, from pressing
	# whatever button happens to be under it.
	get_viewport().set_disable_input(true)
	_run()

func _run() -> void:
	# Wait in wall-clock time, not frames: what we are proving is usually a
	# network round trip, and a frame count says nothing about whether it landed.
	await get_tree().create_timer(_delay).timeout
	await _next_drawn_frame()

	var image := get_viewport().get_texture().get_image()
	var dir := _path.get_base_dir()
	if not dir.is_empty() and not dir.begins_with("user://") and not dir.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(dir)

	var err := image.save_png(_path)
	if err == OK:
		print("[proof] captured %dx%d -> %s" % [image.get_width(), image.get_height(), _path])
	else:
		push_error("[proof] save failed (%d) -> %s" % [err, _path])
	get_tree().quit(0 if err == OK else 1)

## Waits for one fully drawn frame, but never longer than DRAW_WAIT_TIMEOUT.
## A slightly stale capture beats a hung CI job.
func _next_drawn_frame() -> void:
	var guard := get_tree().create_timer(DRAW_WAIT_TIMEOUT)
	var drawn := false
	var on_draw := func() -> void: drawn = true
	RenderingServer.frame_post_draw.connect(on_draw, CONNECT_ONE_SHOT)

	while not drawn and guard.time_left > 0.0:
		await get_tree().process_frame

	if not drawn:
		if RenderingServer.frame_post_draw.is_connected(on_draw):
			RenderingServer.frame_post_draw.disconnect(on_draw)
		# Expected on macOS whenever the terminal has focus. The viewport texture
		# still holds the last drawn frame and has been verified current, so this
		# is a note, not a problem.
		print("[proof] no fresh frame within %.1fs; using last drawn frame" % DRAW_WAIT_TIMEOUT)
