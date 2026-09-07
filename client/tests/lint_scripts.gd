extends SceneTree
## Loads every script in the project so a compile error fails the lint.
## Run: godot --headless --path client --script res://tests/lint_scripts.gd

## Autoloads are registered after _init, so the loading waits for the tree.
func _initialize() -> void:
	await process_frame
	var bad := 0
	var n := 0
	for path in _scripts("res://"):
		n += 1
		var s: Variant = load(path)
		if s == null:
			bad += 1
			printerr("LINT FAIL " + path)
	print("LINT scripts=%d failed=%d" % [n, bad])
	quit(1 if bad > 0 else 0)


func _scripts(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var p := dir.path_join(name)
		if d.current_is_dir():
			if not name.begins_with("."):
				out.append_array(_scripts(p))
		elif name.ends_with(".gd") and not p.contains("/tests/"):
			out.append(p)
		name = d.get_next()
	return out
