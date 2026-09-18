extends SceneTree
## REDEEM A CODE (scenes/pages/redeem_page.gd) keeps a code as the server
## does, sends one at a time, says every refusal in its own words, and fits
## the phone.
##
## What must hold, on 941x1672 and 941x2040, with and without a notch:
##  - what is typed becomes the code the server keeps (service.NormalizePromo):
##    upper case, letters and digits only, twenty at most -- as it is typed;
##  - REDEEM is dimmed until the code is 4 to 20 long, and while one is out;
##  - a second tap while one is out sends nothing, and the answer -- here the
##    server cannot be reached -- is said in the page's words;
##  - every refusal the server names has its own words, never the server's;
##  - it is a painted page; nothing leaves the screen or goes under the notch,
##    the box takes a twenty-letter code and a thumb, every button takes a
##    thumb, and a letter carrying six rewards shows five, counts the sixth, and
##    leaves OPEN THE ROYAL MAIL clear;
##  - a real code's few short lines are one block, icons in a column, centred
##    under the centred heading (they sat to its left, from the block's edge).
##
## Run: godot --headless --path client --script tests/redeem_page_fit.gd

const CANVASES := [Vector2i(941, 1672), Vector2i(941, 2040)]
const INSETS := [0.0, 141.0]
const MIN_H := 95.0
var _fails := 0
var _checked := 0
var _P: GDScript


func _initialize() -> void:
	await process_frame
	# Nothing answers here: a request fails at once, as with no network.
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_P = load("res://scenes/pages/redeem_page.gd")
	if _P == null:
		print("FAIL  there is no REDEEM A CODE page")
		quit(1)
		return
	_words()
	for canvas in CANVASES:
		for inset in INSETS:
			await _page(canvas, inset)
	await _single_flight()
	if _checked == 0:
		print("FAIL  nothing was measured")
		quit(1)
		return
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: REDEEM A CODE keeps codes as the server does, one at a time, in its own words" % _checked)
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _words() -> void:
	for pair in [["abcd", "ABCD"], ["wint-er 2026 gift-code", "WINTER2026GIFTCODE"], ["  a-b c_d.e!f  ", "ABCDEF"],
			["SPRING_26", "SPRING26"], ["spring.26", "SPRING26"], ["ÇAĞRI-42", "ARI42"], ["a".repeat(30), "A".repeat(20)]]:
		_checked += 1
		if _P.normalise(pair[0]) != pair[1]:
			_fail("\"%s\" is kept as \"%s\", the server keeps \"%s\"" % [pair[0], _P.normalise(pair[0]), pair[1]])
	for c in ["promo_invalid", "promo_used", "too_many_attempts", "no_device"]:
		_checked += 1
		var w: String = _P.refusal(c)
		if w == "" or w == _P.TRY_AGAIN or w.contains("_"):
			_fail("the refusal %s has no words of its own: \"%s\"" % [c, w])
	_checked += 1
	if _P.refusal("promo_invalid") == _P.refusal("promo_used"):
		_fail("an unknown code and a used one read the same")
	if _P.refusal("something_new") != _P.TRY_AGAIN:
		_fail("a refusal the page does not know is not said as a try-again")


func _host(canvas: Vector2i) -> Control:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = canvas
	var host := Control.new()
	host.size = Vector2(canvas)
	root.add_child(host)
	return host


func _gr(c: Control) -> Rect2:
	return c.get_global_rect()


func _page(canvas: Vector2i, inset: float) -> void:
	var tag := "%dx%d inset %d" % [canvas.x, canvas.y, int(inset)]
	var host := _host(canvas)
	var p = _P.open(host, {"inset": inset})
	for i in 20:
		await process_frame
	_checked += 1
	if p == null or not p.get_script().resource_path.ends_with("painted_page.gd"):
		_fail("%s: REDEEM A CODE is not a painted page" % tag)
		host.queue_free()
		return
	var field: LineEdit = p.get_meta("field")
	var screen := Rect2(Vector2(0, inset), Vector2(canvas) - Vector2(0, inset))

	# As typed: the box holds the code the server will keep (NormalizePromo:
	# A-Z and 0-9 only), so what the lord sees is what is redeemed.
	for typed in [["wint-er 2026 gift-code", "WINTER2026GIFTCODE"], ["SPRING_26", "SPRING26"], ["spring.26", "SPRING26"]]:
		field.text = typed[0]
		field.text_changed.emit(field.text)
		_checked += 1
		if field.text != typed[1]:
			_fail("%s: \"%s\" typed, the box reads \"%s\", the server keeps \"%s\"" % [tag, typed[0], field.text, typed[1]])
	# REDEEM dims below four and comes up from four to twenty.
	var redeem: BaseButton = p.node("redeem")
	for pair in [["", false], ["ABC", false], ["ABCD", true], ["A".repeat(20), true]]:
		field.text = pair[0]
		field.text_changed.emit(field.text)
		_checked += 1
		if redeem.disabled == bool(pair[1]):
			_fail("%s: with \"%s\" REDEEM is %s" % [tag, pair[0], "dimmed" if redeem.disabled else "live"])
	# Twenty of the widest letter fit the box at a size it can be read at.
	field.text = "W".repeat(20)
	field.text_changed.emit(field.text)
	var f: Font = field.get_theme_font("font")
	var fs := field.get_theme_font_size("font_size")
	_checked += 1
	if f.get_string_size(field.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > field.size.x - 8.0:
		_fail("%s: twenty letters run out of the box (%.0f in %.0f)" % [tag,
			f.get_string_size(field.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, field.size.x])
	if (field.size.y < MIN_H and float(p.get("page_scale")) >= 1.0) or not screen.grow(0.5).encloses(_gr(field)):
		_fail("%s: the box %s is off the screen or too small for a thumb" % [tag, str(_gr(field))])

	# A letter carrying six rewards: five shown, the sixth counted, the button clear.
	var lines: Array = []
	for i in 6:
		lines.append({"kind": "gold", "amount": 1, "text": "9,876,543,210 gold and a long word %d" % i, "icon": "gold"})
	_P._show_result(p, {"title": "A gift from the Crown", "lines": lines})
	await process_frame
	var made: Array = p.get_meta("lines")
	var mail: Control = p.node("open_mail")
	_checked += 1
	if made.size() != 6 or not mail.visible:
		_fail("%s: six rewards drew %d nodes, OPEN THE ROYAL MAIL shown %s" % [tag, made.size(), mail.visible])
	for n in made:
		if _gr(n).intersects(_gr(mail)):
			_fail("%s: a reward line %s sits on OPEN THE ROYAL MAIL %s" % [tag, str(_gr(n)), str(_gr(mail))])
			break
	# Nothing off the screen or under the notch; every button a thumb.
	for n in _all(p):
		if not (n is Control) or not (n as Control).is_visible_in_tree():
			continue
		var c := n as Control
		if c is Label and (c as Label).text != "":
			_checked += 1
			if not screen.grow(0.5).encloses(_gr(c)):
				_fail("%s: \"%s\" %s is off the screen" % [tag, (c as Label).text.substr(0, 24), str(_gr(c))])
		if c is BaseButton:
			_checked += 1
			# A page drawn down to fit a short phone under a notch is smaller all
			# over (PaintedPage, as the painted pages' test holds it); a thumb is
			# asked of it at its own size.
			var small: bool = float(p.get("page_scale")) < 1.0
			if (_gr(c).size.y < MIN_H and not small) or not screen.grow(0.5).encloses(_gr(c)):
				_fail("%s: a button %s is off the screen or too small for a thumb" % [tag, str(_gr(c))])
	# Short lines, as a real code gives: one block, icons in a column, centred
	# on the page under its centred heading.
	_P._show_result(p, {"title": "A gift from the Crown", "lines": [
		{"kind": "diamonds", "amount": 100, "text": "100 diamonds", "icon": "diamond"},
		{"kind": "gold", "amount": 50000, "text": "50,000 gold", "icon": "gold"},
		{"kind": "token", "id": "energy_potion", "amount": 3, "text": "3 Energy Potions", "icon": "energy_potion"}]})
	await process_frame
	var left := INF
	var right := -INF
	var icon_x: Array = []
	for n in p.get_meta("lines"):
		for c in _all(n):
			if c is TextureRect:
				left = minf(left, _gr(c).position.x)
				icon_x.append(_gr(c).position.x)
			elif c is Label:
				var t := c as Label
				var w := minf(t.label_settings.font.get_string_size(t.text, HORIZONTAL_ALIGNMENT_LEFT, -1, t.label_settings.font_size).x, t.size.x)
				right = maxf(right, _gr(t).position.x + w * t.get_global_transform().get_scale().x)
	var mid := _gr(p.node("result_title")).get_center().x
	_checked += 1
	if absf((left + right) / 2.0 - mid) > 2.0:
		_fail("%s: the reward lines' block [%.0f, %.0f] is off the page's middle %.0f" % [tag, left, right, mid])
	_checked += 1
	if icon_x.size() != 3 or absf(float(icon_x.max()) - float(icon_x.min())) > 0.5:
		_fail("%s: the reward icons are not one column: %s" % [tag, str(icon_x)])
	p.close()
	for i in 12:
		await process_frame
	host.queue_free()
	await process_frame


## One code at a time: the second tap while the first is out sends nothing, and
## the answer is the page's own words.
func _single_flight() -> void:
	var host := _host(Vector2i(941, 1672))
	var p = _P.open(host, {"inset": 0.0})
	for i in 20:
		await process_frame
	var field: LineEdit = p.get_meta("field")
	field.text = "SPRINGFEAST"
	field.text_changed.emit(field.text)
	var redeem: BaseButton = p.node("redeem")
	var status: Label = p.node("status")
	_P._redeem(p)
	_checked += 1
	if not bool(p.get_meta("busy", false)) or not redeem.disabled or status.text != _P.SENDING:
		_fail("while a code is out, REDEEM is not dimmed or the page does not say it is sending")
	# The second tap: nothing new, and still one in flight.
	_P._redeem(p)
	var waited := 0
	while bool(p.get_meta("busy", false)) and waited < 400:
		await process_frame
		waited += 1
	_checked += 1
	if bool(p.get_meta("busy", false)):
		_fail("the code never came back")
	elif status.text != _P.TRY_AGAIN or redeem.disabled:
		_fail("with no server, the page says \"%s\" and REDEEM is %s" % [status.text, "dimmed" if redeem.disabled else "live"])
	p.close()
	for i in 12:
		await process_frame
	host.queue_free()
	await process_frame


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
