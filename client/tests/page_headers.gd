extends SceneTree
## The information pages that stay Sheets wear their painted header scenes,
## and every other Sheet is laid out exactly as it was.
##
## The page headers (art/reference/page_headers_sheet.png) are a desk for the
## rules of raiding, the recruiting tent for the recruit odds, the armoury for
## the gear picker and the training yard for the reroll panel. Sheet draws one
## only when a page asks, inside the plate's frame, at the width it was cut for
## (so never drawn up), with the title rising into its painted fade.
##
## A Sheet that does not ask must not move by a unit: its title, rule, body and
## foot are held to the numbers the Sheet has always used.
##
## Run: godot --headless --path client --script tests/page_headers.gd
##
## The Sheet is loaded at run time, never named as a class here: a class named
## in this script is compiled before the autoloads it uses exist.

const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]
const PAGES := {
	"res://scenes/pages/rules_page.gd": "pages/header_rules",
	"res://scenes/pages/odds_page.gd": "pages/header_recruit_odds",
	"res://scenes/pages/item_picker.gd": "pages/header_gear",
	"res://scenes/army/reroll_panel.gd": "pages/header_reroll",
}

var _fails := 0
var _checked := 0
var _S: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_S = load("res://scripts/ui/sheet.gd")
	for canvas in CANVASES:
		await _a_sheet_without_a_header_is_unchanged(canvas)
		await _a_sheet_with_a_header_draws_it(canvas)
		await _the_four_pages_wear_theirs(canvas)
	_only_the_four_ask()
	# A call that fails -- a Sheet that takes no header -- ends its check
	# without a verdict, so the count is part of the verdict.
	var want := CANVASES.size() * (2 + 1 + PAGES.size()) + 1
	if _checked != want:
		_fail("%d of %d checks ran: a page or the Sheet failed before it could be measured" % [_checked, want])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: four pages wear their painted headers, every other Sheet unmoved" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _host(canvas: Vector2) -> Control:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	return host


func _plate(s: Node) -> NinePatchRect:
	return s.get("_plate") as NinePatchRect


func _header_of(plate: Node) -> TextureRect:
	return plate.get_node_or_null("Header") as TextureRect if plate != null else null


## The layout the Sheet has always had, to the unit: plate 30 in from each side
## and 34 down, the title 30 into it and 56 tall, the rule and the body after it,
## the foot a pad from the bottom.
func _a_sheet_without_a_header_is_unchanged(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	for subtitle in ["", "One line under the title."]:
		var host := _host(canvas)
		var s: Control = _S.open(host, "THE DAILY REWARD", subtitle)
		await process_frame
		var plate := _plate(s)
		_checked += 1
		if _header_of(plate) != null:
			_fail("%s: a Sheet that asked for no header drew one" % tag)
		var want_plate := Rect2(30, 34, canvas.x - 60, canvas.y - 34 - 30)
		if Rect2(plate.position, plate.size) != want_plate:
			_fail("%s: the plate is %s, was %s" % [tag, Rect2(plate.position, plate.size), want_plate])
		var title: Label = s.get("_title")
		if Rect2(title.position, title.size) != Rect2(34, 30, want_plate.size.x - 68, 56):
			_fail("%s: the title moved to %s" % [tag, Rect2(title.position, title.size)])
		var y := 86.0
		if subtitle != "":
			var sub: Label = s.get("_subtitle")
			if sub.position.y != 86.0:
				_fail("%s: the subtitle moved to y %.1f" % [tag, sub.position.y])
			y += sub.get_minimum_size().y + 4.0
		var scroll: ScrollContainer = s.get("_scroll")
		var want_scroll := Rect2(34, y + 20.0, want_plate.size.x - 68, want_plate.size.y - (y + 20.0) - 34 - 96 - 14)
		if not Rect2(scroll.position, scroll.size).is_equal_approx(want_scroll):
			_fail("%s: the body moved to %s, was %s" % [tag, Rect2(scroll.position, scroll.size), want_scroll])
		var f: Control = s.get("foot")
		var foot := Rect2(f.position, f.size)
		if foot != Rect2(34, want_plate.size.y - 34 - 96 + 6, want_plate.size.x - 68, 96):
			_fail("%s: the foot moved to %s" % [tag, foot])
		s.call("close")
		host.queue_free()
		await process_frame


func _a_sheet_with_a_header_draws_it(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var host := _host(canvas)
	var s: Control = _S.open(host, "WEAPON FOR THIS SOLDIER", "Tap a piece to wear it.", 60, "", "pages/header_gear")
	await process_frame
	var plate := _plate(s)
	var h := _header_of(plate)
	_checked += 1
	if h == null:
		_fail("%s: a Sheet that asked for a header drew none" % tag)
	else:
		_held_to_its_cut(h, "pages/header_gear", tag)
		var inset: float = _S.HEADER_INSET
		var inside := Rect2(inset, inset, plate.size.x - inset * 2.0, plate.size.y)
		if not inside.encloses(Rect2(h.position, h.size)):
			_fail("%s: the header %s runs onto the plate's frame" % [tag, Rect2(h.position, h.size)])
		var title: Label = s.get("_title")
		var bottom := h.position.y + h.size.y
		var overlap: float = _S.HEADER_OVERLAP
		if absf(title.position.y - (bottom - overlap)) > 0.5:
			_fail("%s: the title sits at y %.0f, not in the header's fade at %.0f" % [tag, title.position.y, bottom - overlap])
		if h.get_index() > title.get_index():
			_fail("%s: the header is drawn over the title" % tag)
		# The longest title a picker is given still fits beside nothing.
		if title.get_minimum_size().x > title.size.x + 0.5:
			_fail("%s: \"%s\" runs past its box" % [tag, title.text])
		var room: float = s.call("body_height")
		if room < 700.0:
			_fail("%s: with a header the body keeps only %.0f units" % [tag, room])
	s.call("close")
	host.queue_free()
	await process_frame


func _held_to_its_cut(h: TextureRect, asset: String, tag: String) -> void:
	var t := h.texture
	if t == null or t.resource_path != "res://assets/%s.png" % asset:
		_fail("%s: the header is %s, want %s" % [tag, t.resource_path if t != null else "nothing", asset])
		return
	# Drawn at the size it was cut: never drawn up, never stretched.
	if not h.size.is_equal_approx(Vector2(t.get_size())):
		_fail("%s: %s is drawn at %s but cut at %s" % [tag, asset, h.size, t.get_size()])


func _the_four_pages_wear_theirs(canvas: Vector2) -> void:
	var tag := "%dx%d" % [int(canvas.x), int(canvas.y)]
	var odds := {"types": [{"type_id": "peasant", "odds": [{"tier": "common", "bp": 10000}]}]}
	var soldier := {"id": "s1", "type": "gladiator", "tier": "rare", "attack": 844, "defense": 687,
		"ehp": 6950, "hp": 180, "equipped": {}, "reroll_cost": 20835}
	for path in PAGES:
		var host := _host(canvas)
		var page: Variant = null
		match path:
			"res://scenes/pages/rules_page.gd":
				page = load(path).open(host, {})
			"res://scenes/pages/odds_page.gd":
				page = load(path).open(host, odds, ["peasant"], {"peasant": "VILLAGER"})
			"res://scenes/pages/item_picker.gd":
				load(path).pick(host, "WEAPON FOR THIS SOLDIER", [], {})
			"res://scenes/army/reroll_panel.gd":
				page = load(path).open(host, {"soldier": soldier, "odds": [], "name": "GLADIATOR", "type": "gladiator"})
		for i in 2:
			await process_frame
		if page == null:
			page = _open_sheet()
		var plate := _plate(page) if page != null else null
		var h := _header_of(plate)
		_checked += 1
		if h == null:
			_fail("%s: %s wears no header" % [tag, path.get_file()])
		else:
			_held_to_its_cut(h, PAGES[path], tag)
			var r := Rect2(plate.global_position, plate.size)
			if r.position.y < 0.0 or r.end.y > canvas.y:
				_fail("%s: %s's plate runs off the canvas (%s)" % [tag, path.get_file(), r])
		if page != null and page.has_method("close"):
			page.call("close")
		elif page != null:
			page.call("_close")
		host.queue_free()
		for i in 2:
			await process_frame


## The Sheet the picker opened, found where every Sheet mounts.
func _open_sheet() -> Control:
	for layer in root.get_node("Nav").overlay_parent().get_children():
		for c in layer.get_children():
			if c.get_script() == _S:
				return c
	return null


## Only the four pages ask for a header: no other page's code names one.
func _only_the_four_ask() -> void:
	var found := {}
	var stack := ["res://scenes", "res://scripts"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			stack.append(dir.path_join(sub))
		for f in DirAccess.get_files_at(dir):
			if not f.ends_with(".gd"):
				continue
			var p := dir.path_join(f)
			if FileAccess.get_file_as_string(p).contains("\"pages/header_"):
				found[p] = true
	_checked += 1
	for p in found:
		if not PAGES.has(p):
			_fail("%s asks for a page header; only the four information pages wear one" % p)
	for p in PAGES:
		if not found.has(p):
			_fail("%s names no header" % p)
