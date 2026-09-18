extends SceneTree
## The rail's seal in its three states (LiveEvents.seal):
##
## - ablaze while an event runs -- the hour's first, else an operator's or a
##   festival, the one ending soonest: the kit's burning hour
##   (events_kit/gauge_blazing) behind the seal, centred on its wreath, its
##   flames clear of the COURT cell above; the plate says the time left;
## - lit, as painted, while an event is only announced -- the next hour's
##   among them: "in 12m 40s" to the soonest start, no fire;
## - dark with neither: dimmed, the plate empty, no fire.
##
## And the COURT's rail badge counts what live ops leave waiting there: the
## courier's gift (one), the festival's tasks and milestones, the Charter's tiers.
##
## Run: godot --headless --path client --script tests/hourly_seal.gd

## The flames' ink starts 15 units into the blazing gauge's crop (ink y 47 on
## events_kit.png, the crop from 32), drawn at the seal's 0.40.
const FIRE_INK_TOP := 15.0 * 0.40
const HOUR := {"id": "gold_rush", "name": "Gold Rush", "kind": "boost", "bucket": "collect_income_bp", "bp": 10000,
	"effective_bp": 10000, "active": true, "ends_in": 840, "next_in": 2640, "next": null, "icon": "hourly/gold_rush"}
const BOOST := {"bucket": "xp_bp", "bp": 5000, "effective_bp": 5000, "ends_in": 12000}

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var gs := root.get_node("GameState")
	var shell_script: GDScript = load("res://scenes/shell/shell.gd")
	# The COURT's badge.
	_expect(int(shell_script.call("court_count", {"hourly": true, "events": 2, "season": 3})) == 6,
		"the COURT's badge does not count the courier's gift, the festival and the Charter")
	_expect(int(shell_script.call("court_count", {"hourly": false, "mail": 1})) == 1, "a taken gift still counts")
	for size in [Vector2(941, 1672), Vector2(941, 2040)]:
		for inset in [0.0, 141.0]:
			await _rail(gs, size, inset)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the seal burns while an event runs, is lit while one is announced, dims with neither; the COURT counts the hour's gift, the festival and the Charter" % _checked)
	quit()


func _rail(gs: Node, size: Vector2, inset: float) -> void:
	var parent := Control.new()
	parent.size = size
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	shell.call("apply_inset", inset)
	await process_frame
	var tag := "%dx%d inset %d" % [size.x, size.y, inset]
	var seal: TextureRect = shell.get("_seal")
	var fire: TextureRect = shell.get("_seal_fire")
	var time: Label = shell.get("_seal_time")
	if fire == null:
		_expect(false, "%s: the seal has no fire to burn" % tag)
		parent.queue_free()
		return
	_expect(fire.texture != null and fire.texture.resource_path.ends_with("events_kit/gauge_blazing.png"),
		"%s: the seal's fire is not the kit's burning hour" % tag)
	# Ablaze: the hour's event, beside an operator's that ends later.
	_live(gs, {"hourly": HOUR, "boosts": [BOOST]})
	shell.call("_paint_seal")
	_expect(fire.visible and seal.modulate == Color.WHITE and time.text == "14m 00s",
		"%s: the hour's event: fire %s, seal %s, plate \"%s\"" % [tag, fire.visible, seal.modulate, time.text])
	# The fire stands on the wreath's middle, behind the seal, clear of the COURT cell.
	var mid := seal.position + Vector2(57.5, 52.5)
	var fire_mid := fire.position + Vector2(159, 180) * 0.40
	_expect(fire_mid.distance_to(mid) <= 1.0, "%s: the fire's middle %s is not the wreath's %s" % [tag, fire_mid, mid])
	_expect(fire.get_index() < seal.get_index(), "%s: the fire is drawn over the seal" % tag)
	var geo: Dictionary = shell.get("_geo")
	_expect(fire.position.y + FIRE_INK_TOP >= float(geo["cells_end"]) - 1.0,
		"%s: the flames reach %.0f, into the COURT cell ending at %.0f" % [tag, fire.position.y + FIRE_INK_TOP, float(geo["cells_end"])])
	# Its minutes over, the operator's event still runs: still ablaze, its time.
	var over := HOUR.duplicate()
	over.merge({"active": false, "ends_in": 0}, true)
	_live(gs, {"hourly": over, "boosts": [BOOST]})
	shell.call("_paint_seal")
	_expect(fire.visible and time.text == "3h 20m", "%s: an operator's event: fire %s, plate \"%s\"" % [tag, fire.visible, time.text])
	# A festival running: ablaze, its time.
	_live(gs, {"hourly": over, "festival": {"name": "Harvest Festival", "running": true, "ends_in": 190800}})
	shell.call("_paint_seal")
	_expect(fire.visible and time.text == "2d 05h", "%s: a festival: fire %s, plate \"%s\"" % [tag, fire.visible, time.text])
	# Only the next hour's announced: lit, no fire.
	var quiet := {"id": "", "active": false, "ends_in": 0, "next_in": 760,
		"next": {"id": "gold_rush", "name": "Gold Rush", "icon": "hourly/gold_rush"}}
	_live(gs, {"hourly": quiet})
	shell.call("_paint_seal")
	_expect(not fire.visible and seal.modulate == Color.WHITE and time.text == "in 12m 40s",
		"%s: the next hour: fire %s, seal %s, plate \"%s\"" % [tag, fire.visible, seal.modulate, time.text])
	# Nothing running or announced: dark.
	quiet["next"] = null
	_live(gs, {"hourly": quiet})
	shell.call("_paint_seal")
	_expect(not fire.visible and seal.modulate.r < 0.6 and time.text == "",
		"%s: nothing: fire %s, seal %s, plate \"%s\"" % [tag, fire.visible, seal.modulate, time.text])
	parent.queue_free()
	await process_frame


func _live(gs: Node, live: Dictionary) -> void:
	var snap: Dictionary = {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1", "diamonds": 12,
		"action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": [], "live": live}
	gs.set("snapshot", snap)
	gs.set("_energy_at_ms", Time.get_ticks_msec())


func _expect(ok: bool, why: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + why)
