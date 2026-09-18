extends SceneTree
## A mail row draws a reward frame under each reward its letter carries, and
## none where it carries nothing.
##
## The row was cut with the painting's three frames in it and only the icons
## lifted, so a letter with no gift -- "Welcome back, my lord" -- showed three
## empty boxes, and one with a single gift two, as if something were missing.
## The rows are cut without their frames now (art/slices/mail.json), and one
## frame (mail/slot) is drawn under each reward icon.
##
## - A row's plate carries no frame of its own: no gold rim left where the three
##   stood.
## - Letters with 0, 1, 2, 3 and 5 rewards show 0, 1, 2, 3 and 3 frames, each
##   under its own icon.
##
## Run: godot --headless --path client --script tests/mail_row_frames.gd

## Where the three frames stood, in the row plate's own pixels (x 696..908,
## y 387..451 on the painting; the row is cut from 161, 365).
const FRAMES := Rect2i(535, 22, 213, 65)

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_no_frames_baked()
	await _frames_follow_rewards()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: a mail row frames what its letter carries, and nothing else" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _no_frames_baked() -> void:
	for key in ["mail/row", "mail/row_soon"]:
		var img := Image.load_from_file("res://assets/%s.png" % key)
		_checked += 1
		if img == null:
			_fail("%s does not exist" % key)
			continue
		var gold := 0
		for y in range(FRAMES.position.y, FRAMES.end.y):
			for x in range(FRAMES.position.x, FRAMES.end.x):
				var c := img.get_pixel(x, y)
				if c.r > 0.55 and c.g > 0.42 and c.b < 0.45 and c.r - c.b > 0.2:
					gold += 1
		if gold > 20:
			_fail("%s still carries its painted frames (%d rim pixels where they stood)" % [key, gold])


func _line(n: int) -> Dictionary:
	return {"kind": "diamonds", "amount": n, "text": "%d diamonds" % n, "icon": "diamond"}


func _frames_follow_rewards() -> void:
	var counts := [0, 1, 2, 3, 5]
	var letters: Array = []
	for i in counts.size():
		var lines: Array = []
		for k in counts[i]:
			lines.append(_line(k + 1))
		letters.append({"id": i + 1, "kind": "gift", "sender": "The Crown", "title": "Letter %d" % i,
			"body": "", "created_at": "2026-09-14T08:00:00Z", "expires_in": 20 * 86400, "read": false,
			"claimed": false, "claimable": not lines.is_empty(), "lines": lines})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var v: Control = load("res://scenes/court/mail_view.gd").new()
	v.size = host.size
	host.add_child(v)
	await process_frame
	v.call("paint", {"mail": letters, "waiting": 4})
	for i in 3:
		await process_frame
	var rows: Array = v.get("_rows")
	_checked += 1
	if rows.size() != letters.size():
		_fail("%d rows for %d letters" % [rows.size(), letters.size()])
		host.queue_free()
		return
	for i in rows.size():
		var p: Dictionary = rows[i]["parts"]
		var want := mini(counts[i], 3)
		var shown := 0
		for k in 3:
			if not p.has("slot_%d" % (k + 1)):
				_fail("row %d has no frame %d to draw" % [i, k + 1])
				continue
			var frame: Control = p["slot_%d" % (k + 1)]
			var icon: Control = p["icon_%d" % (k + 1)]
			if frame.visible:
				shown += 1
				if not Rect2(frame.position, frame.size).encloses(Rect2(icon.position, icon.size)):
					_fail("row %d: frame %d is not under its icon" % [i, k + 1])
			if frame.visible != icon.visible:
				_fail("row %d: frame %d is %s and its icon %s" % [i, k + 1,
					"shown" if frame.visible else "hidden", "shown" if icon.visible else "hidden"])
		_checked += 1
		if shown != want:
			_fail("a letter with %d rewards draws %d frames, want %d" % [counts[i], shown, want])
	host.queue_free()
	await process_frame
