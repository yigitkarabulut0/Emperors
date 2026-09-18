extends SceneTree
## No screen says diamonds cannot be bought.
##
## Until the Royal Store, the game said "Diamonds are earned, never bought" and
## "Diamonds come with every level and with the daily reward" wherever a purse
## ran short. Both stopped being true the day the store opened. The copy that
## replaced them says where diamonds come from in one sentence (Goods.
## WHERE_DIAMONDS), and nothing in the client may say the old thing again.
##
## Run: godot --headless --path client --script tests/no_earned_copy.gd

## About diamonds, not about a product that cannot be bought today.
const BANNED := ["never bought", "earned, never", "diamonds are earned", "diamonds cannot be bought",
	"diamonds can't be bought", "diamonds are never sold"]

var _fails := 0


func _initialize() -> void:
	await process_frame
	var files := _scripts("res://scenes") + _scripts("res://scripts")
	var checked := 0
	for f in files:
		var text := FileAccess.get_file_as_string(f).to_lower()
		checked += 1
		for b in BANNED:
			if text.contains(b):
				_fails += 1
				printerr("  %s says \"%s\"" % [f, b])
	var goods: GDScript = load("res://scripts/ui/goods.gd")
	var where := str(goods.get("WHERE_DIAMONDS"))
	if not where.contains("Royal Store"):
		_fails += 1
		printerr("  where diamonds come from does not name the Royal Store: " + where)
	if checked < 20:
		_fails += 1
		printerr("  only %d scripts were read" % checked)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d scripts, none says diamonds cannot be bought" % checked)
	quit()


func _scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_scripts(dir.path_join(sub)))
	return out
