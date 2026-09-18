extends SceneTree
## The painted Royal Mail (scenes/court/mail_view.gd, mail_letter.gd) fits the
## phone with the longest letters the server allows, and draws each letter the
## way the painting does.
##
## A title may be eighty characters and a sender forty, a letter may carry five
## rewards and a long body. What must hold at both canvases:
##  - every row's words stay on their painted plates (cut with an ellipsis past
##    the smallest size) and clear of the tiles; on the second plate the sender
##    gives way, so when the letter came -- or how long is left -- is read whole;
##  - a reward's picture is an object in the tile's window, never a card;
##  - the envelope is the painting's for the letter: sealed with the crown, the
##    lion banner or clasped hands by kind while unread, open once read;
##  - a letter going soon wears the short plate and the hourglass and says it
##    in red; up to three rewards sit in the tiles, a bubble counts the rest;
##  - CLAIM ALL only with two or more to claim: where the painting has it, just
##    under the last row, while the rows end above its pin; pinned above the
##    footer, with the list ending over it, once they run past; the empty inbox
##    is the painted desk;
##  - the letter card keeps the painting's width, grows only in height, stays
##    on the screen with CLOSE under it, and shows CLAIM only when there is
##    something to claim (THROW AWAY over it otherwise);
##  - every button takes a thumb.
## The profile's ROYAL MAIL still carries the count of letters waiting.
##
## Run: godot --headless --path client --script tests/mail_view_fit.gd
##
## Scripts are loaded at run time, never named as a class here: a class named
## in this script compiles before the autoloads exist.

const MIN_H := 95.0
const CARD_W := 447.0
var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "avatar": "knight", "level": 30,
		"gold": "987654321", "diamonds": 12, "action_seq": 1}, "energy": {"current": 185, "max": 236},
		"prices": {"rename_diamonds": 20}})
	var view_script: GDScript = load("res://scenes/court/mail_view.gd")
	_words(view_script)
	for canvas in [Vector2(941, 1672), Vector2(941, 2040)]:
		await _inbox(view_script, canvas, 2)
		await _inbox(view_script, canvas, 1)
		await _overflow(view_script, canvas)
		await _reader(view_script, canvas, true)
		await _reader(view_script, canvas, false)
	await _empty(view_script)
	await _profile_count(gs)
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the painted Royal Mail fits the phone with the longest letters" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


static func _five() -> Array:
	return [
		{"kind": "diamonds", "amount": 8500, "text": "8,500 diamonds", "icon": "diamond"},
		{"kind": "gold", "amount": 9876543210, "text": "9,876,543,210 gold", "icon": "gold"},
		{"kind": "token", "id": "energy_potion", "amount": 3, "text": "3 Energy Potions", "icon": "energy_potion"},
		{"kind": "item", "id": "legendary", "amount": 2, "text": "2 × Legendary weapon", "icon": "item:legendary"},
		{"kind": "token", "id": "shield_8h", "amount": 1, "text": "Protection Charter", "icon": "city_shield"},
	]


static func _letters(claimable: int) -> Array:
	return [
		{"id": 1, "kind": "compensation", "sender": "W".repeat(40), "title": "W".repeat(80),
			"body": "For the night the roads were closed. ".repeat(30), "created_at": "2026-09-13T10:00:00Z",
			"expires_in": 5 * 3600, "read": false, "claimed": false, "claimable": true, "lines": _five()},
		{"id": 2, "kind": "kingdom", "sender": "The Crown", "title": "The realm thanks its lords",
			"body": "", "created_at": "2026-09-12T10:00:00Z", "expires_in": 20 * 86400, "read": false,
			"claimed": false, "claimable": claimable >= 2,
			"lines": [{"kind": "boost", "id": "xp", "amount": 5000, "text": "+50% experience for 24 hours", "icon": "boost:xp"}]},
		{"id": 3, "kind": "gift", "sender": "Wulfric the Bold", "title": "A horse for a friend", "body": "Ride well.",
			"created_at": "2026-09-11T10:00:00Z", "expires_in": 0, "read": true, "claimed": true, "claimable": false,
			"lines": [{"kind": "item", "id": "rare", "amount": 1, "text": "Rare horse", "icon": "item:rare"}]},
		{"id": 4, "kind": "system", "sender": "The Crown", "title": "News from the Crown", "body": "The roads are open.",
			"created_at": "2026-09-14T08:00:00Z", "expires_in": 30 * 86400, "read": false, "claimed": false,
			"claimable": false, "lines": []},
	]


func _build(view_script: GDScript, canvas: Vector2) -> Control:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var v: Control = view_script.new()
	v.size = canvas
	host.add_child(v)
	return v


func _inbox(view_script: GDScript, canvas: Vector2, claimable: int) -> void:
	var tag := "%dx%d (%d to claim)" % [int(canvas.x), int(canvas.y), claimable]
	var v := _build(view_script, canvas)
	await process_frame
	var letters := _letters(claimable)
	v.call("paint", {"mail": letters, "waiting": 3})
	for i in 3:
		await process_frame
	var rows: Array = v.get("_rows")
	_checked += 1
	if rows.size() != letters.size():
		_fail("%s: %d rows for %d letters" % [tag, rows.size(), letters.size()])
		v.get_parent().queue_free()
		return
	var want_env := ["mail/envelope_crown", "mail/envelope_banner", "mail/envelope_open", "mail/envelope_crown"]
	for i in rows.size():
		var p: Dictionary = rows[i]["parts"]
		var m: Dictionary = letters[i]
		_checked += 1
		var env := (p["envelope"] as TextureRect).texture.resource_path.get_file().get_basename()
		if "mail/" + env != want_env[i]:
			_fail("%s row %d: envelope %s, want %s" % [tag, i, env, want_env[i]])
		var plate := (p["plate"] as TextureRect).texture.resource_path.get_file().get_basename()
		var soon := i == 0
		if (plate == "row_soon") != soon or (p["hourglass"] as Control).visible != soon:
			_fail("%s row %d: plate %s, hourglass %s; going soon: %s" % [tag, i, plate, (p["hourglass"] as Control).visible, soon])
		var lc := (p["line"] as Label).label_settings.font_color
		if soon != (lc.r > 0.8 and lc.g < 0.5):
			_fail("%s row %d: the line is %s; red only for a letter going soon" % [tag, i, lc.to_html(false)])
		# Words on their plates, clear of the tiles.
		for id in ["title", "line"]:
			var l: Label = p[id]
			_checked += 1
			var w := l.label_settings.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.label_settings.font_size).x
			if w > l.size.x + 1.0 and l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
				_fail("%s row %d: %s runs out of its plate" % [tag, i, id])
			if l.position.x + l.size.x > 544.0 - 20.0:
				_fail("%s row %d: %s reaches the tiles (ends at %.0f)" % [tag, i, id, l.position.x + l.size.x])
		# How long is left is read in full: the sender gives way to it, and the
		# line is never left for the plate's edge to cut.
		var line: Label = p["line"]
		var tail: String = view_script.line_tail(m)
		var lw := line.label_settings.font.get_string_size(line.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			line.label_settings.font_size).x
		_checked += 1
		if not line.text.ends_with(tail) or lw > float(line.get_meta("box_w", line.size.x)) + 1.0:
			_fail("%s row %d: the line \"%s\" is %.0f wide on a %.0f plate; \"%s\" must be read in full" % [
				tag, i, line.text, lw, float(line.get_meta("box_w", line.size.x)), tail.strip_edges()])
		# Rewards in the tiles, the rest counted.
		var shown := 0
		for id in ["icon_1", "icon_2", "icon_3"]:
			if (p[id] as Control).visible:
				shown += 1
		var lines: Array = m.get("lines", [])
		_checked += 1
		if shown != mini(lines.size(), 3):
			_fail("%s row %d: %d rewards in the tiles for %d" % [tag, i, shown, lines.size()])
		if (p["more"] as Control).visible != (lines.size() > 3) or (lines.size() > 3 and (p["more_text"] as Label).text != "+%d" % (lines.size() - 3)):
			_fail("%s row %d: the count of rewards past three is wrong" % [tag, i])
		if bool(m.get("claimed", false)) and shown > 0 and (p["icon_1"] as Control).modulate == Color.WHITE:
			_fail("%s row %d: a claimed letter's rewards are still bright" % [tag, i])
		# The row's own target takes a thumb.
		_checked += 1
		if (p["hit"] as Control).size.y < MIN_H:
			_fail("%s row %d: the row is %.0f tall to a thumb" % [tag, i, (p["hit"] as Control).size.y])
	# CLAIM ALL: only with two to claim; a thumb tall; clear of the list; on the screen.
	var ca: Control = (v.get("_ui") as Dictionary)["claim_all"]
	_checked += 1
	if ca.visible != (claimable >= 2):
		_fail("%s: CLAIM ALL shown %s with %d to claim" % [tag, ca.visible, claimable])
	var car := Rect2(ca.global_position, ca.size)
	if car.size.y < MIN_H:
		_fail("%s: CLAIM ALL is %.0f tall to a thumb" % [tag, car.size.y])
	# Four rows end far above the pin: CLAIM ALL is where the painting has it,
	# its painted button 12 under the last row's plate.
	var last: Control = rows[rows.size() - 1]["parts"]["plate"]
	var last_end := last.global_position.y + last.size.y
	var painted_top := car.position.y + (car.size.y - float((ca as TextureButton).texture_normal.get_height())) / 2.0
	_checked += 1
	if car.end.y > canvas.y + 0.5 or absf(painted_top - (last_end + 12.0)) > 1.0:
		_fail("%s: CLAIM ALL's button is at y %.1f, %.1f under the last row; the painting has it 12 under" % [
			tag, painted_top, painted_top - last_end])
	var back: Control = (v.get("_ui") as Dictionary)["back_hit"]
	if back.size.y < MIN_H or back.position.y < 100.0:
		_fail("%s: the COURT button's target is %.0f tall from y %.0f" % [tag, back.size.y, back.position.y])
	v.get_parent().queue_free()
	await process_frame


## A long inbox: the list scrolls, and CLAIM ALL is pinned above the footer with
## the list ending over it.
func _overflow(view_script: GDScript, canvas: Vector2) -> void:
	var tag := "%dx%d (fourteen letters)" % [int(canvas.x), int(canvas.y)]
	var v := _build(view_script, canvas)
	await process_frame
	var letters: Array = []
	for i in 14:
		var m: Dictionary = (_letters(2)[i % 2] as Dictionary).duplicate(true)
		m["id"] = i + 1
		letters.append(m)
	v.call("paint", {"mail": letters, "waiting": 14})
	for i in 3:
		await process_frame
	var ui: Dictionary = v.get("_ui")
	var ca: Control = ui["claim_all"]
	var list: ScrollContainer = ui["list"]
	var footer: Control = ui["footer"]
	var car := Rect2(ca.global_position, ca.size)
	var lr := Rect2(list.global_position, list.size)
	var pinned := canvas.y - (1672.0 - 1449.0)
	_checked += 1
	if not ca.visible or absf(car.position.y - pinned) > 0.5 or lr.end.y > car.position.y + 0.5 \
			or car.end.y > footer.global_position.y + 0.5:
		_fail("%s: CLAIM ALL %s is not pinned at y %.0f between the list %s and the footer (y %.0f)" % [
			tag, str(car), pinned, str(lr), footer.global_position.y])
	var content: Control = list.get_meta("content")
	if content.custom_minimum_size.y <= lr.size.y:
		_fail("%s: fourteen rows do not scroll" % tag)
	v.get_parent().queue_free()
	await process_frame


func _reader(view_script: GDScript, canvas: Vector2, claimable: bool) -> void:
	var tag := "%dx%d letter (%s)" % [int(canvas.x), int(canvas.y), "to claim" if claimable else "claimed"]
	# The reader measures its canvas from its host's top Control; the window is
	# the canvas in the game.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(int(canvas.x), int(canvas.y))
	var v := _build(view_script, canvas)
	await process_frame
	var letters := _letters(2)
	var m: Dictionary = letters[0] if claimable else letters[2]
	m["read"] = true  # no /v1/mail/read without a server
	v.call("paint", {"mail": letters, "waiting": 3})
	await process_frame
	v.call("read_letter", m)
	for i in 4:
		await process_frame
	var reader: CanvasLayer = null
	for c in root.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == 66:
			reader = c
	_checked += 1
	if reader == null:
		_fail("%s: the letter did not open" % tag)
		v.get_parent().queue_free()
		return
	var card: NinePatchRect = reader.get("_card")
	var cr := Rect2(card.global_position, card.size)
	if absf(card.size.x - CARD_W) > 0.5:
		_fail("%s: the card is %.0f wide, the painting's is %.0f" % [tag, card.size.x, CARD_W])
	if card.size.y < 431.0 - 0.5:
		_fail("%s: the card is shorter than its painting (%.0f)" % [tag, card.size.y])
	var close_b: Control = reader.get_node("Close")
	var close_r := Rect2(close_b.global_position, close_b.size)
	if cr.position.y < 0 or cr.end.y > canvas.y or close_r.end.y > canvas.y + 0.5:
		_fail("%s: the card %s or its CLOSE %s is off a %s screen" % [tag, str(cr), str(close_r), str(canvas)])
	if close_r.size.y < MIN_H:
		_fail("%s: CLOSE is %.0f tall" % [tag, close_r.size.y])
	var parts: Dictionary = reader.get("_parts")
	var title: Label = parts["title"]
	_checked += 1
	if title.autowrap_mode == TextServer.AUTOWRAP_OFF or title.size.x > 359.5:
		_fail("%s: the title does not wrap on the parchment" % tag)
	# The words stack down the parchment, each as tall as its own lines: none
	# cut short, none wider than the parchment, none over the next, and all of
	# them clear of the painted tiles.
	var body_scroll := reader.find_child("BodyScroll", true, false) as ScrollContainer
	var foot := 0.0
	var blocks := {"title": parts["title"], "meta": parts["meta"], "body": body_scroll,
		"enclosed": parts["enclosed"], "deadline": parts["deadline"]}
	for id in blocks:
		var c := blocks[id] as Control
		if c == null or not c.visible or c.size.y <= 0.0 or (c is Label and (c as Label).text == ""):
			continue
		var r := Rect2(c.global_position, c.size)
		_checked += 1
		if c is Label and c.size.y + 0.5 < c.get_minimum_size().y:
			_fail("%s: the %s is %.0f tall for %.0f of lines" % [tag, id, c.size.y, c.get_minimum_size().y])
		if c.size.x > 359.5:
			_fail("%s: the %s is %.0f wide, past the parchment" % [tag, id, c.size.x])
		if r.position.y + 0.5 < foot:
			_fail("%s: the %s starts at %.0f, over the words above it (to %.0f)" % [tag, id, r.position.y, foot])
		foot = r.end.y
	if foot > cr.end.y - 210.0 + 0.5:
		_fail("%s: the words run to %.0f, into the tiles (from %.0f)" % [tag, foot, cr.end.y - 210.0])
	# A letter too long for the screen scrolls, and shows whole lines.
	var body: Label = parts["body"]
	if body_scroll != null and body.size.y > body_scroll.size.y + 0.5:
		var s := body.label_settings
		var pitch := s.font.get_height(s.font_size) + s.line_spacing
		var lines := (body_scroll.size.y + s.line_spacing) / pitch
		_checked += 1
		if absf(lines - roundf(lines)) > 0.05:
			_fail("%s: the letter's window shows %.2f lines; the last is cut through" % [tag, lines])
	# What it carries breaks between rewards, never inside one.
	var enc_text := (parts["enclosed"] as Label).text
	for l in m.get("lines", []):
		_checked += 1
		if not enc_text.contains(str(l.get("text", "")).replace(" ", "\u00a0")):
			_fail("%s: \"%s\" can be broken across two lines" % [tag, str(l.get("text", ""))])
	# Until when: its own line, red only for a letter going soon.
	var deadline: Label = parts["deadline"]
	var soon: bool = claimable and int(m.get("expires_in", 0)) < 2 * 86400
	_checked += 1
	if deadline.visible != claimable or (claimable and not deadline.text.begins_with("Claim it within")):
		_fail("%s: the deadline is \"%s\" (shown %s)" % [tag, deadline.text, deadline.visible])
	var dc := deadline.label_settings.font_color
	var ec := (parts["enclosed"] as Label).label_settings.font_color
	if soon != (dc.r > 0.5 and dc.g < 0.2) or (ec.r > 0.5 and ec.g < 0.2):
		_fail("%s: the deadline is %s and what it carries %s; red is the deadline's, only when going soon" % [
			tag, dc.to_html(false), ec.to_html(false)])
	var claim_b: Control = parts["claim_b"]
	var throw := reader.find_child("ThrowAway", true, false) as Control
	_checked += 1
	if claimable:
		if not claim_b.visible or claim_b.size.y < MIN_H or throw != null:
			_fail("%s: CLAIM is not the way to take what it carries" % tag)
	else:
		if claim_b.visible or throw == null or throw.size.y < MIN_H:
			_fail("%s: a claimed letter does not offer THROW AWAY over CLAIM" % tag)
		else:
			# Its plate covers the painted CLAIM (78 tall) and no more; the target
			# round it is a thumb's.
			var sb: StyleBox = throw.get_theme_stylebox("normal")
			var drawn: float = throw.size.y + float(sb.get("expand_margin_top")) + float(sb.get("expand_margin_bottom"))
			_checked += 1
			if absf(drawn - 78.0) > 0.5:
				_fail("%s: THROW AWAY's plate is drawn %.0f tall over a painted CLAIM of 78" % [tag, drawn])
	# The painted tiles hold three rewards; the bubble counts the rest.
	var n := 0
	for id in ["icon_1_b", "icon_2_b", "icon_3_b"]:
		if (parts[id] as Control).visible:
			n += 1
	var lines: Array = m.get("lines", [])
	_checked += 1
	if n != mini(lines.size(), 3) or (parts["more_b"] as Control).visible != (lines.size() > 3):
		_fail("%s: %d rewards in the tiles for %d" % [tag, n, lines.size()])
	# The tiles are where the painting has them relative to the card's foot.
	var ic: Control = parts["icon_1_b"]
	var from_foot := cr.end.y - ic.global_position.y
	if absf(from_foot - (431.0 - 246.0)) > 1.0:
		_fail("%s: the first tile's reward sits %.0f above the card's foot, want %.0f" % [tag, from_foot, 431.0 - 246.0])
	# A long letter scrolls inside the parchment rather than off the screen.
	var scroll := reader.find_child("BodyScroll", true, false) as Control
	if scroll != null and Rect2(scroll.global_position, scroll.size).end.y > cr.end.y - 210.0 + 0.5:
		_fail("%s: the letter's text runs into the tiles" % tag)
	reader.call("close")
	await process_frame
	v.get_parent().queue_free()
	await process_frame


func _empty(view_script: GDScript) -> void:
	var v := _build(view_script, Vector2(941, 1672))
	await process_frame
	v.call("paint", {"mail": [], "waiting": 0})
	await process_frame
	var ui: Dictionary = v.get("_ui")
	_checked += 1
	if not (ui["empty_desk"] as Control).visible or not (ui["empty_text"] as Control).visible:
		_fail("an empty inbox does not show the painted desk and its words")
	if (ui["claim_all"] as Control).visible:
		_fail("an empty inbox offers CLAIM ALL")
	v.get_parent().queue_free()
	await process_frame


func _words(view_script: GDScript) -> void:
	_checked += 1
	var five := _five()
	if view_script.claimed_words(five) != "Claimed 8,500 diamonds, 9,876,543,210 gold, 3 Energy Potions and 2 more":
		_fail("claimed words: \"%s\"" % view_script.claimed_words(five))
	var letters := _letters(2)
	if view_script.envelope_for(letters[1]) != "mail/envelope_banner" or view_script.envelope_for(letters[2]) != "mail/envelope_open":
		_fail("envelopes are not chosen by kind and read state")
	if not view_script.going_soon(letters[0]) or view_script.going_soon(letters[1]) or view_script.going_soon(letters[2]):
		_fail("only a letter still to claim with under two days left is going soon")
	if not str(view_script.line_words(letters[0])).ends_with("5h 00m left"):
		_fail("a letter going soon does not say how long is left: %s" % view_script.line_words(letters[0]))
	# How long is left, in days past a day: never "720h 00m".
	var ui_script: GDScript = load("res://scripts/ui/ui.gd")
	for pair in [[30 * 86400, "30d 00h"], [36 * 3600 + 1800, "1d 12h"], [5 * 3600 + 38 * 60, "5h 38m"], [125, "2m 05s"]]:
		_checked += 1
		if ui_script.time_left(pair[0]) != pair[1]:
			_fail("%d seconds left reads \"%s\", want \"%s\"" % [pair[0], ui_script.time_left(pair[0]), pair[1]])
	var later: Dictionary = (letters[0] as Dictionary).duplicate(true)
	later["expires_in"] = 36 * 3600
	_checked += 1
	if not str(view_script.line_words(later)).ends_with("1d 12h left"):
		_fail("a letter with a day and a half left says \"%s\"" % view_script.line_words(later))
	if view_script.waiting({"mail": letters}) != 3:
		_fail("waiting counts %d, want 3 (two unread, one to claim)" % view_script.waiting({"mail": letters}))
	# A reward's picture is an object laid in the tile's window, not a card of
	# its own: its corners are clear, so the painted window shows round it.
	var art: Node = root.get_node("Art")
	# A rolled item's line names the item's own painting (a crop path): that is
	# what its tile shows, not the rarity gem the tier alone would give.
	_checked += 1
	var item_icon := art.call("reward_icon", "items/painted/weapon_05") as Texture2D
	if item_icon == null or not item_icon.resource_path.ends_with("items/painted/weapon_05.png"):
		_fail("a rolled item's line does not show the item's own painting")
	# Gear not yet rolled shows its tier's stone, cut clean: every tier resolves
	# to its own keyed crop with a see-through border, never to the gear tiles'
	# stone on its steel plate (family/gem_*), and a tier nobody knows to the
	# unlit stone.
	for tier in ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special", "no_such_tier"]:
		var want := "rewards/gem_%s.png" % (tier if tier != "no_such_tier" else "empty")
		var t := art.call("reward_icon", "item:" + tier) as Texture2D
		_checked += 1
		if t == null or not t.resource_path.ends_with(want) or t.resource_path.contains("/family/"):
			_fail("item:%s draws %s, want %s" % [tier, t.resource_path if t != null else "nothing", want])
			continue
		var img := t.get_image()
		if img.is_compressed():
			img.decompress()
		var worst := 0.0
		for x in img.get_width():
			worst = maxf(worst, maxf(img.get_pixel(x, 0).a, img.get_pixel(x, img.get_height() - 1).a))
		for y in img.get_height():
			worst = maxf(worst, maxf(img.get_pixel(0, y).a, img.get_pixel(img.get_width() - 1, y).a))
		if worst > 0.1:
			_fail("item:%s's stone is %.2f opaque at its border: it would carry a square into the tile" % [tier, worst])
	for key in ["diamond", "gold", "energy_potion", "city_shield", "boost:xp", "boost:collect", "favour",
			"items/painted/weapon_05"]:
		var img := (art.call("reward_icon", key) as Texture2D).get_image()
		if img.is_compressed():
			img.decompress()
		var w := img.get_width() - 1
		var h := img.get_height() - 1
		var corner := maxf(maxf(img.get_pixel(0, 0).a, img.get_pixel(w, 0).a), maxf(img.get_pixel(0, h).a, img.get_pixel(w, h).a))
		_checked += 1
		if corner > 0.1:
			_fail("the reward picture for %s is an opaque card (corner alpha %.2f)" % [key, corner])


## The profile's ROYAL MAIL carries the count, and follows it as it changes.
func _profile_count(gs: Node) -> void:
	gs.call("set_badges", {"mail": 3})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	# YOUR LORDSHIP is a painted page: its ROYAL MAIL row carries the count of
	# letters waiting in the painting's red badge.
	var s: Control = load("res://scenes/pages/profile_page.gd").open(host)
	for i in 3:
		await process_frame
	# The Royal Mail is the COURT's now, where its card and its count are: the
	# hub's seven rows are the seven the painting writes on them, and FRIENDS
	# wears the badge there. What is checked here is that the mail's count is
	# still carried by whichever row asks for it -- and that the hub does not
	# quietly keep a stale one.
	var mail: Dictionary = {}
	for inst in (s.get("parts") as Dictionary).get("row", []):
		var parts: Dictionary = (inst as Dictionary).get("parts", {})
		if parts.has("label") and (parts["label"] as Label).text == "ROYAL MAIL":
			mail = parts
	_checked += 1
	if mail.is_empty():
		var badged := 0
		for inst in (s.get("parts") as Dictionary).get("row", []):
			var parts: Dictionary = (inst as Dictionary).get("parts", {})
			if parts.has("badge") and (parts["badge"] as Control).visible:
				badged += 1
		if badged > 0:
			_fail("the hub has no ROYAL MAIL row, but %d row(s) wear a letter count" % badged)
	else:
		var bubble: Control = mail.get("badge") as Control
		var count: Label = mail.get("badge_text") as Label
		if bubble == null or not bubble.is_visible_in_tree() or count == null \
				or not count.is_visible_in_tree() or count.text != "3":
			_fail("the profile's ROYAL MAIL does not say 3 letters wait (%s)" % (count.text if count != null else "no count"))
		gs.call("set_badges", {"mail": 0})
		await process_frame
		_checked += 1
		if (bubble != null and bubble.visible) or (count != null and count.visible):
			_fail("the count stayed on ROYAL MAIL after the letters were read")
	s.call("close")
	host.queue_free()
	await process_frame
