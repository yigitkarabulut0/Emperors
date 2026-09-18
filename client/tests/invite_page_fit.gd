extends SceneTree
## INVITE A FRIEND (scenes/pages/invite_page.gd) says the server's terms,
## lists the friends, offers a friend's code only while one may be entered,
## and fits the phone.
##
## What must hold, on 941x1672 and 941x2040, with and without a notch:
##  - every number in the terms is the server's (reward level, both sides'
##    diamonds, how many more friends), one more friend is said as one, and a
##    code that has brought every friend it can says so;
##  - FRIENDS lists one row a friend -- the tick seal only on a rewarded one --
##    and scrolls when they run past it (twenty), and says so when there are
##    none; the longest name fits its box; each friend is drawn as every list
##    of lords draws one -- their face in the ring (inside a worn frame), the
##    name in the colour worn, the Favour's seal only when held;
##  - ENTER A FRIEND'S CODE shows only while can_claim, with the time left (30
##    seconds reads as 30s); once a code was entered, one line names whose;
##  - a friend's code refused is said in the page's own words;
##  - it is a painted page; nothing leaves the screen or goes under the notch,
##    and every button takes a thumb.
##
## Run: godot --headless --path client --script tests/invite_page_fit.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0
const LONG := "Wwwwwwwwwwwwwwww"
const FACES := ["knight", "queen", "monk", "witch", "king"]
## The friend row's ring window, measured on profile/friend_row: the gold rim's
## inside at x 33..120, y 14..100.
const RING := Vector2(76.5, 57.0)
const RING_D := 88.0
var _fails := 0
var _checked := 0
var _P: GDScript


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_P = load("res://scenes/pages/invite_page.gd")
	if _P == null:
		print("FAIL  there is no INVITE A FRIEND page")
		quit(1)
		return
	_words()
	for canvas in CANVASES:
		for inset in INSETS:
			await _page(canvas, inset, 20, true, "")
	await _page(Vector2i(941, 1672), 0.0, 0, true, "")
	await _page(Vector2i(941, 1672), 0.0, 1, false, "Sir Aldric of the Vale")
	await _page(Vector2i(941, 2040), 141.0, 1, false, "")
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: INVITE A FRIEND says the server's terms, lists friends, and fits the phone" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


static func _view(friends: int, can: bool, by: String, left: int = 13) -> Dictionary:
	var list: Array = []
	for i in friends:
		# Every look a lord can wear, in turn: none; a frame, a colour and the
		# seal; the seal alone; a colour alone.
		var f := {"name": LONG if i % 2 == 0 else "Lady Mereth", "level": 3 + i, "rewarded": i % 3 == 0,
			"avatar": FACES[i % FACES.size()], "worn": {}, "vip_seal": i % 4 == 1 or i % 4 == 2}
		if i % 4 == 1:
			f["worn"] = {"frame": "frames/aureole", "color": "#8FB8FF"}
		elif i % 4 == 3:
			f["worn"] = {"color": "#6FD28A"}
		list.append(f)
	var v := {"code": "WXQRTZ", "reward_level": 12, "inviter_diamonds": 70, "invitee_diamonds": 35,
		"friends": list, "rewarded": 7, "rewards_left": left, "can_claim": can}
	if can:
		v["claim_in"] = 30
	if by != "":
		v["claimed_by"] = by
	return v


func _words() -> void:
	var t: String = _P.terms(_view(0, false, "", 3))
	_checked += 1
	for want in ["level 12", "70 diamonds", "35", "3 more friends"]:
		if not t.contains(want):
			_fail("the terms \"%s\" do not say \"%s\"" % [t, want])
	_checked += 1
	if not str(_P.terms(_view(0, false, "", 1))).contains("one more friend"):
		_fail("one more friend is not said as one: \"%s\"" % _P.terms(_view(0, false, "", 1)))
	_checked += 1
	var none: String = _P.terms(_view(0, false, "", 0))
	if none.contains("diamonds") or none.contains("0 more"):
		_fail("a code with no friends left to reward still offers them: \"%s\"" % none)
	for c in ["referral_invalid", "referral_self", "referral_closed", "referral_limit"]:
		_checked += 1
		var w: String = _P.refusal(c)
		if w == "" or w == _P.TRY_AGAIN or w.contains("_"):
			_fail("the refusal %s has no words of its own: \"%s\"" % [c, w])
	_checked += 1
	if _P.refusal("anything_else") != _P.TRY_AGAIN:
		_fail("a refusal the page does not know is not said as a try-again")
	if _P.normalise("wx-qr tz") != "WXQRTZ":
		_fail("a friend's code is not kept as the server keeps it")


func _host(canvas: Vector2i) -> Control:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = canvas
	var host := Control.new()
	host.size = Vector2(canvas)
	root.add_child(host)
	return host


func _gr(c: Control) -> Rect2:
	return c.get_global_rect()


func _page(canvas: Vector2i, inset: float, friends: int, can: bool, by: String) -> void:
	var tag := "%dx%d inset %d, %d friends%s%s" % [canvas.x, canvas.y, int(inset), friends,
		", can claim" if can else "", ", claimed by %s" % by if by != "" else ""]
	var host := _host(canvas)
	var v := _view(friends, can, by)
	var p = _P.open(host, {"inset": inset, "view": v})
	for i in 20:
		await process_frame
	_checked += 1
	if p == null or not p.get_script().resource_path.ends_with("painted_page.gd"):
		_fail("%s: INVITE A FRIEND is not a painted page" % tag)
		host.queue_free()
		return
	var screen := Rect2(Vector2(0, inset), Vector2(canvas) - Vector2(0, inset))

	# The code and the terms, as the server gave them.
	_checked += 1
	if (p.node("code") as Label).text != "WXQRTZ":
		_fail("%s: the code reads \"%s\"" % [tag, (p.node("code") as Label).text])
	if (p.node("terms") as Label).text != _P.terms(v):
		_fail("%s: the terms are not the server's" % tag)

	# FRIENDS: a row a friend, the seal only on the rewarded, scrolling past the list.
	var sc := p.node("friends") as ScrollContainer
	var content: Control = p.content("friends")
	var rows := 0
	for c in content.get_children():
		if not c.is_queued_for_deletion():
			rows += 1
	_checked += 1
	if rows != friends:
		_fail("%s: %d rows for %d friends" % [tag, rows, friends])
	if friends > 3 and content.custom_minimum_size.y <= sc.size.y:
		_fail("%s: twenty friends do not scroll (%.0f in %.0f)" % [tag, content.custom_minimum_size.y, sc.size.y])
	_checked += 1
	if (p.node("empty") as Control).visible != (friends == 0):
		_fail("%s: the empty words are %s with %d friends" % [tag, "shown" if (p.node("empty") as Control).visible else "hidden", friends])
	var i := 0
	for c in content.get_children():
		if c.is_queued_for_deletion():
			continue
		var parts: Dictionary = c.get_meta("parts") if c.has_meta("parts") else {}
		if parts.is_empty():
			parts = _parts_of(c)
		var mark: Control = parts.get("mark", null)
		var name: Label = parts.get("name", null)
		_checked += 1
		if mark == null or name == null:
			_fail("%s: a friend's row has no mark or name" % tag)
			break
		if mark.visible != (i % 3 == 0):
			_fail("%s: friend %d's seal is %s" % [tag, i, "shown" if mark.visible else "hidden"])
		var s := name.label_settings
		if s.font.get_string_size(name.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x > float(name.get_meta("box_w", name.size.x)) + 1.0:
			_fail("%s: \"%s\" runs out of its box" % [tag, name.text])
		_friend_look(tag, i, (v["friends"] as Array)[i], parts)
		i += 1

	# A friend's code: only while one may still be entered.
	for id in ["claim_label", "claim_time", "claim_box", "claim"]:
		_checked += 1
		if (p.node(id) as Control).visible != can:
			_fail("%s: %s is %s" % [tag, id, "shown" if (p.node(id) as Control).visible else "hidden"])
	var field: LineEdit = p.get_meta("field")
	_checked += 1
	if field.visible != can:
		_fail("%s: the friend's code box is %s" % [tag, "shown" if field.visible else "hidden"])
	if can and not (p.node("claim_time") as Label).text.contains("30s"):
		_fail("%s: 30 seconds left reads \"%s\"" % [tag, (p.node("claim_time") as Label).text])
	_checked += 1
	var claimed := p.node("claimed") as Label
	if claimed.visible != (by != "") or (by != "" and not claimed.text.contains(by)):
		_fail("%s: whose code it was reads \"%s\" (shown %s)" % [tag, claimed.text, claimed.visible])
	if can:
		# A refused code, in the page's words.
		_P._say(p, _P.refusal("referral_self"), true)
		_checked += 1
		var st := p.node("claim_status") as Label
		if not st.visible or st.text != _P.refusal("referral_self"):
			_fail("%s: a refused code is said as \"%s\"" % [tag, st.text])

	# Nothing off the screen or under the notch; every button a thumb.
	var small: bool = float(p.get("page_scale")) < 1.0
	for n in _all(p):
		if not (n is Control) or not (n as Control).is_visible_in_tree():
			continue
		var c := n as Control
		if c is Label and (c as Label).text != "" and not sc.is_ancestor_of(c):
			_checked += 1
			if not screen.grow(0.5).encloses(_gr(c)):
				_fail("%s: \"%s\" %s is off the screen" % [tag, (c as Label).text.substr(0, 24), str(_gr(c))])
		if c is BaseButton:
			_checked += 1
			if (_gr(c).size.y < MIN_H and not small) or not screen.grow(0.5).encloses(_gr(c)):
				_fail("%s: a button %s is off the screen or too small for a thumb" % [tag, str(_gr(c))])
	_checked += 1
	if not screen.grow(0.5).encloses(_gr(sc)):
		_fail("%s: the friends list %s runs off the screen" % [tag, str(_gr(sc))])
	p.close()
	for k in 12:
		await process_frame
	host.queue_free()
	await process_frame


## A friend drawn as every list of lords draws one: their face in the ring's
## window (inside a worn frame when they wear one), their name in the colour
## they wear, Royal Favour's seal beside it only when they hold it, and the
## rewarded seal on the ring's shoulder, over the face and off its middle.
func _friend_look(tag: String, i: int, f: Dictionary, parts: Dictionary) -> void:
	var what := "%s: friend %d" % [tag, i]
	var face: Variant = parts.get("face", null)
	_checked += 1
	if not (face is TextureRect) or not (face as TextureRect).visible:
		_fail("%s has no face in the ring" % what)
		return
	var fr := face as TextureRect
	var art: Node = root.get_node("Art")
	_checked += 1
	if fr.texture != art.call("tex", art.call("avatar_ring", str(f.get("avatar", "")))):
		_fail("%s's face is not %s's" % [what, f.get("avatar")])
	var framed := str((f.get("worn", {}) as Dictionary).get("frame", "")) != ""
	var d := RING_D * 0.78 if framed else RING_D + 2.0
	_checked += 1
	if (fr.position + fr.size / 2.0).distance_to(RING) > 1.0 or absf(fr.size.x - d) > 1.0:
		_fail("%s's face %s is off the ring's window (centre %s, %.0f across)" % [what, Rect2(fr.position, fr.size), RING, d])
	var ring: Variant = fr.get_meta("look_frame") if fr.has_meta("look_frame") else null
	_checked += 1
	if (ring is TextureRect and (ring as TextureRect).visible) != framed:
		_fail("%s's frame is %s" % [what, "missing" if framed else "drawn unworn"])
	var name: Label = parts["name"]
	var hex := str((f.get("worn", {}) as Dictionary).get("color", ""))
	_checked += 1
	if hex != "" and not name.label_settings.font_color.is_equal_approx(Color(hex)):
		_fail("%s's name is %s, not the %s worn" % [what, name.label_settings.font_color, hex])
	if hex == "" and not name.label_settings.font_color.is_equal_approx(Color("#F1E9DA")):
		_fail("%s's name wears %s without a colour worn" % [what, name.label_settings.font_color])
	var seal: Variant = name.get_meta("look_seal") if name.has_meta("look_seal") else null
	var sealed := bool(f.get("vip_seal", false))
	_checked += 1
	if (seal is TextureRect and (seal as TextureRect).visible) != sealed:
		_fail("%s's Royal Favour seal is %s" % [what, "missing" if sealed else "drawn unheld"])
	var mark: Control = parts["mark"]
	var top := maxi(fr.get_index(), (ring as Node).get_index() if ring is Node else -1)
	_checked += 1
	if mark.get_index() < top or Rect2(mark.position, mark.size).has_point(RING):
		_fail("%s's rewarded seal is under the face or over its middle" % what)


## A template instance keeps its parts on the node Layout.instantiate built.
static func _parts_of(row: Node) -> Dictionary:
	var out := {}
	for c in _all(row):
		if c is Control and str(c.name) != "":
			out[str(c.get_meta("id", c.name))] = c
	return out


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
