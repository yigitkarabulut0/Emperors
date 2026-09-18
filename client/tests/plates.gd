extends SceneTree
## One kind of plate looks the same everywhere: the painter's.
##
## The dialogs, the Sheets' feet and the pages' own buttons wore three plates
## the paintings never had: the danger red was the Shop's green BUY plate with
## its red and green channels swapped, the quiet one the Inventory's SELL with
## its word baked out, and the Collect button's NO ENERGY face the COLLECT
## picture with its word inpainted and its hue rotated. R9
## (art/reference/plates_sheet.png) paints them: green, red and navy in five
## sizes and a brick-red NO ENERGY plate, cut by art/slices/plates.json.
##
## - Every generic plate -- the Dialog's three, the red the kingdom rows still
##   name as shop/danger_plate, the NO ENERGY face -- is a crop of plates_sheet,
##   and nothing bakes a plate by recolouring any more.
## - Each is cut to its rim: its four corners clear, its face solid.
## - The three a dialog sets side by side are one family, one height.
## - The nine-patch margin the dialogs and Sheets draw them with keeps each
##   plate's whole corner cut in the corner slice, so no chamfer is stretched.
## - A Collect row short of energy wears the painted face over the whole COLLECT
##   plate, and loses it when the energy comes back.
##
## Run: godot --headless --path client --script tests/plates.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	var D: GDScript = load("res://scripts/ui/dialog.gd")
	var generic := {"confirm": D.CONFIRM_PLATE, "danger": D.DANGER_PLATE, "quiet": D.QUIET_PLATE,
		"kingdom danger": "shop/danger_plate", "no energy": "collect/no_energy_plate"}
	var sources := _manifest_sources()
	for k in generic:
		_checked += 1
		var key: String = generic[k]
		if str(sources.get(key, "")) != "plates_sheet.png":
			_fail("the %s plate (%s) is %s, not a crop of plates_sheet.png" % [k, key,
				("cut from " + str(sources[key])) if sources.has(key) else "in no manifest -- a baked file"])
		_cut_to_its_rim(key)
	_nothing_bakes_plates()
	_one_family(D)
	_corners_stay_whole(D)
	await _collect_wears_the_face()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every plate is the painter's, cut to its rim, drawn whole" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


## crop name -> the reference it is cut from, over every manifest.
func _manifest_sources() -> Dictionary:
	var out := {}
	var dir := ProjectSettings.globalize_path("res://").path_join("../art/slices").simplify_path()
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json") or f.ends_with(".layout.json"):
			continue
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f)))
		if not (doc is Dictionary):
			continue
		for c in doc.get("crops", []):
			out[str(c.get("name", ""))] = str(c.get("src", doc.get("source", "")))
	return out


func _cut_to_its_rim(key: String) -> void:
	var img := Image.load_from_file("res://assets/%s.png" % key)
	if img == null:
		_fail("%s does not exist" % key)
		return
	var w := img.get_width()
	var h := img.get_height()
	for p in [Vector2i(0, 0), Vector2i(w - 1, 0), Vector2i(0, h - 1), Vector2i(w - 1, h - 1)]:
		if img.get_pixelv(p).a > 0.05:
			_fail("%s's corner %s is not clear: a square of ground would show round its chamfer" % [key, p])
	if img.get_pixel(w / 2, h / 2).a < 0.99:
		_fail("%s's face is see-through" % key)


func _nothing_bakes_plates() -> void:
	_checked += 1
	var tool := FileAccess.get_file_as_string("res://tools/make_button_plates.gd")
	if tool.contains("RECOLOURS :=") or tool.contains("set_pixel(x, y, Color(c.g, c.r"):
		_fail("tools/make_button_plates.gd still recolours a plate")
	if FileAccess.file_exists("res://tools/make_empty_button.gd"):
		_fail("tools/make_empty_button.gd still bakes a red COLLECT")
	if FileAccess.file_exists("res://assets/collect/collect_button_empty.png"):
		_fail("the baked red COLLECT is still shipped")


## A dialog sets confirm and quiet side by side, and a Sheet all three: one
## family, one painted height (within the rim's own two units).
func _one_family(D: GDScript) -> void:
	_checked += 1
	var hs: Array = []
	for key in [D.CONFIRM_PLATE, D.DANGER_PLATE, D.QUIET_PLATE]:
		var t := Image.load_from_file("res://assets/%s.png" % key)
		if t != null:
			hs.append(t.get_height())
	if hs.size() == 3 and (hs.max() - hs.min()) > 2:
		_fail("the dialog's plates are %s tall: not one family" % str(hs))
	# A 96-unit button draws them down or at size, never up by more than a unit or two.
	for h in hs:
		if float(D.BUTTON_H) > float(h) + 2.0:
			_fail("a %d-tall plate is drawn up to a %d-unit button" % [h, int(D.BUTTON_H)])


## The corner cut: from the plate's edge, how far in its rim begins along the
## top row. PLATE_EDGE must hold all of it, and the rim's inner corner too.
func _corners_stay_whole(D: GDScript) -> void:
	_checked += 1
	var edge := int(D.PLATE_EDGE)
	for key in [D.CONFIRM_PLATE, D.DANGER_PLATE, D.QUIET_PLATE]:
		var img := Image.load_from_file("res://assets/%s.png" % key)
		if img == null:
			continue
		var y := 0
		while y < img.get_height() and img.get_pixel(img.get_width() / 2, y).a < 0.5:
			y += 1
		var cut := 0
		while cut < img.get_width() and img.get_pixel(cut, y).a < 0.5:
			cut += 1
		if cut + 4 > edge:
			_fail("%s's corner runs %d in, and the nine-patch keeps only %d: its chamfer would stretch" % [key, cut + 4, edge])
	for path in ["res://scripts/ui/dialog.gd", "res://scripts/ui/sheet.gd"]:
		var src := FileAccess.get_file_as_string(path)
		if src.contains("plate_face(plate, 16)"):
			_fail("%s draws the plates with a 16-unit nine-patch, under their corner cut" % path.get_file())


func _collect_wears_the_face() -> void:
	var jobs: Array = []
	for i in 3:
		jobs.append({"id": ["wheat", "timber", "stone"][i], "name": "Job %d" % i, "order": i, "unlocked": true,
			"energy_cost": [5, 20, 60][i], "gold_payout": 100, "xp_payout": 10, "collects": 0, "next_milestone": 10})
	var gs := root.get_node("GameState")
	gs.set("snapshot", {"player": {"level": 30, "gold": "1", "action_seq": 1}, "energy": {"current": 12, "max": 236},
		"jobs": jobs})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = load("res://scenes/tabs/collect.gd").new()
	tab.size = host.size
	host.add_child(tab)
	for i in 4:
		await process_frame
	if tab.has_method("refresh"):
		tab.call("refresh")
	await process_frame
	var rows: Array = tab.get("_rows")
	_checked += 1
	if rows.size() != 3:
		_fail("three jobs drew %d rows" % rows.size())
		host.queue_free()
		return
	for i in 3:
		var face := rows[i].get("empty") as NinePatchRect
		if face == null:
			_fail("row %d has no NO ENERGY face" % i)
			continue
		var short := int(jobs[i]["energy_cost"]) > 12
		if face.visible != short:
			_fail("row %d (costs %d, 12 in hand) shows its NO ENERGY face: %s" % [i, jobs[i]["energy_cost"], face.visible])
		if face.texture == null or not face.texture.resource_path.ends_with("collect/no_energy_plate.png"):
			_fail("row %d's face is not the painted NO ENERGY plate" % i)
	# The energy comes back: every face goes.
	var snap: Dictionary = gs.get("snapshot")
	snap["energy"] = {"current": 236, "max": 236}
	gs.set("snapshot", snap)
	tab.call("refresh")
	await process_frame
	for i in 3:
		var face := rows[i].get("empty") as NinePatchRect
		if face != null and face.visible:
			_fail("row %d keeps its NO ENERGY face with a full bar" % i)
	host.queue_free()
	await process_frame
