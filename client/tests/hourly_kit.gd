extends SceneTree
## The hour's art, cut from art/reference/events_kit.png (art/slices/events_kit.json):
##
## - every icon the server can name for an hour (balance/liveops.json's hourly
##   table: icon hourly/<id>) is cut, and Wave 5's Honor Hour with them;
## - every disc is one object at one size: a 290 square, keyed clear at its
##   corners, its navy body opaque, centred on its rim, the rim 137 from the
##   centre across its middle row -- row five's larger discs drawn down to it;
## - the kit's gauges (dark, half-lit, blazing), NEXT, the sheen and the
##   sparkle are cut, each gauge's hourglass opaque at its fitted centre.
##
## Run: godot --headless --path client --script tests/hourly_kit.gd

## Wave 4 cut Honor Hour's disc ahead of the arena; Wave 5 put it in the table,
## so nothing is extra any more.
const EXTRA := []
const RIM := 137.0
const RIM_SLACK := 3.0

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var path := ProjectSettings.globalize_path("res://").path_join("../balance/liveops.json")
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (doc is Dictionary):
		print("FAIL  balance/liveops.json does not read (%s)" % path)
		quit(1)
		return
	var icons: Array = []
	for row in (doc as Dictionary).get("hourly", {}).get("table", []):
		if str(row.get("id", "")) != "none":
			icons.append(str(row.get("icon", "")))
	# Eight since Wave 5: Honor Hour joined the table, its share taken from
	# "none", and its disc was already cut with the other seven.
	_expect(icons.size() == 8, "the hourly table names %d events, not 8" % icons.size())
	for id in EXTRA:
		icons.append("hourly/" + id)
	for icon in icons:
		_disc(icon)
	for g in [["events_kit/gauge_dark", Vector2(300, 300), Vector2(150, 150)],
			["events_kit/gauge_half", Vector2(300, 300), Vector2(150, 150)],
			["events_kit/gauge_blazing", Vector2(318, 360), Vector2(159, 180)]]:
		var img := _image(g[0])
		if img == null:
			continue
		_expect(Vector2(img.get_size()) == g[1], "%s is %s, not %s" % [g[0], img.get_size(), g[1]])
		_expect(img.get_pixelv(Vector2i(g[2])).a > 0.98, "%s's hourglass is not opaque at its centre" % g[0])
		_expect(img.get_pixel(0, 0).a < 0.02 and img.get_pixel(img.get_width() - 1, img.get_height() - 1).a < 0.02,
			"%s is not keyed clear at its corners" % g[0])
	for a in ["events_kit/next_plate", "events_kit/sheen", "events_kit/sparkle"]:
		_expect(_image(a) != null, "%s is not cut" % a)
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: every hour's disc is cut, one size, centred on its rim; the kit's gauges, NEXT, sheen and sparkle are there" % _checked)
	quit()


func _image(asset: String) -> Image:
	var p := "res://assets/%s.png" % asset
	if not ResourceLoader.exists(p):
		_expect(false, "%s is not on disk" % asset)
		return null
	var t: Texture2D = load(p)
	return t.get_image()


func _disc(icon: String) -> void:
	_expect(icon.begins_with("hourly/"), "the server names the hour's art %s, not hourly/<id>" % icon)
	var img := _image(icon)
	if img == null:
		return
	_expect(img.get_size() == Vector2i(290, 290), "%s is %s, not 290x290" % [icon, img.get_size()])
	_expect(img.get_pixel(0, 0).a < 0.02 and img.get_pixel(289, 289).a < 0.02 and img.get_pixel(0, 289).a < 0.02,
		"%s is not keyed clear at its corners" % icon)
	_expect(img.get_pixel(145, 250).a > 0.98 and img.get_pixel(40, 145).a > 0.98, "%s's navy body is not opaque" % icon)
	# The rim across the middle row: the last opaque pixel on either side.
	var l := -1
	var r := -1
	for x in 290:
		if img.get_pixel(x, 145).a > 0.5:
			if l < 0:
				l = x
			r = x
	_expect(absf((l + r) / 2.0 - 145.0) <= 2.0, "%s's rim is centred at %.1f, not 145" % [icon, (l + r) / 2.0])
	_expect(absf((r - l) / 2.0 - RIM) <= RIM_SLACK, "%s's rim is %.1f from its centre, not %d" % [icon, (r - l) / 2.0, RIM])


func _expect(ok: bool, why: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + why)
