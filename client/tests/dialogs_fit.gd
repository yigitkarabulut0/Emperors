extends SceneTree
## Every dialog the game opens fits the screen, and can be got out of.
##
## They used to grow to their content with nothing capping them: a choice of
## twelve Kingdom Works is twelve buttons plus a title, and the battle history
## is however many lines the server sent. The plate grew past the screen and
## took its Cancel with it, off the bottom, where no thumb could reach it.
##
## The four shapes below are the real ones, taken from the call sites: a plain
## confirm, a notice with a long body, a choice of twelve, and a prompt.
##
## Run: godot --headless --path client --script tests/dialogs_fit.gd

const PT_PER_UNIT := 440.0 / 941.0
const CANVASES := [Vector2(941, 1672), Vector2(941, 2040)]

var _fails: int = 0
var _checked: int = 0
var _buttons_seen: int = 0


func _initialize() -> void:
	await process_frame
	for canvas in CANVASES:
		await _check("a confirm", canvas, "confirm", {
			"title": "Sell Kingsguard Cuirass?",
			"body": "For 1,240,000 gold. This cannot be undone.",
			"confirm_text": "Sell", "danger": true})
		await _check("a notice with a long body", canvas, "confirm", {
			"title": "Battle history",
			"body": "\n".join(_lines(24)), "confirm_text": "Close"})
		await _check("a choice of twelve", canvas, "choose", {
			"title": "Kingdom Works · 480 Favour",
			"options": _options(12)})
		# A notice has one way out. Calling it Cancel beside an OK made a page of
		# rankings look like a decision to be taken.
		await _check("a notice", canvas, "confirm", {
			"title": "Rankings", "body": "No kingdoms yet.", "confirm_text": "Close"}, 1)
		await _check("a prompt", canvas, "amount", {
			"title": "Donate to the treasury", "body": "Gold goes to the kingdom.",
			"placeholder": "Amount", "confirm_text": "Donate", "second_text": "All of it"})
	if _checked == 0 or _buttons_seen == 0:
		_fail("nothing was measured: %d dialogs, %d buttons" % [_checked, _buttons_seen])
	else:
		print("  measured %d dialogs, %d buttons" % [_checked, _buttons_seen])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  every dialog fits its screen and keeps its buttons on it")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _lines(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append("Raided Aldric of the Ninth Siege for 4,120,000 gold  ·  2h ago")
	return out


func _options(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"id": "w%d" % i, "label": "Training Grounds  Lv. %d" % (i + 1),
			"sub": "-15%% training time  ·  %d Favour" % (40 + i * 20)})
	return out


func _check(what: String, canvas: Vector2, mode: String, cfg: Dictionary,
		want_buttons: int = 0) -> void:
	var host := Control.new()
	host.size = canvas
	root.add_child(host)
	var modal: Object = _open(host, cfg, mode)
	for i in 6:
		await process_frame
	var plate: Control = modal.get("_plate")
	var buttons: Control = modal.get("_buttons")
	var tag := "%dx%d %s" % [int(canvas.x), int(canvas.y), what]
	_checked += 1
	if plate == null or buttons == null:
		_fail("%s: the dialog did not build" % tag)
		host.queue_free()
		return

	var screen := Rect2(Vector2.ZERO, canvas)
	var box := Rect2(plate.position, plate.size)
	if not screen.encloses(box):
		_fail("%s: the plate %s runs off the %s screen" % [tag, str(box), str(canvas)])
	# The buttons are what a dialog is for; they must be on the screen and big.
	for b in buttons.get_children():
		if not (b is Button):
			continue
		_buttons_seen += 1
		var r := Rect2(b.global_position, b.size)
		if not screen.encloses(r):
			_fail("%s: a button %s is off the screen" % [tag, str(r)])
		if r.size.y * PT_PER_UNIT < 44.0:
			_fail("%s: a button is %.0f pt tall, under the 44 a thumb needs"
				% [tag, r.size.y * PT_PER_UNIT])
	if buttons.get_child_count() == 0:
		_fail("%s: no way out of the dialog" % tag)
	if want_buttons > 0 and buttons.get_child_count() != want_buttons:
		_fail("%s: %d buttons, wanted %d" % [tag, buttons.get_child_count(), want_buttons])
	modal.call("_resolve", "")
	host.queue_free()
	await process_frame


## Builds a modal without awaiting the result, which never arrives here.
func _open(host: Control, cfg: Dictionary, mode: String) -> Object:
	var script: GDScript = load("res://scripts/ui/dialog.gd")
	return script.build_for_test(host, cfg, mode)
