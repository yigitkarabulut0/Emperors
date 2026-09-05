extends SceneTree
## The confirmation modal has to survive the accident it exists to prevent.
##
## Selling an item and dismissing a soldier destroy things on one tap. A dialog
## that is tappable the instant it appears does not fix that: a double-tap on the
## row underneath lands on Confirm one frame later and the thing is still gone.
## So the commit button is disabled for a moment after it opens.
##
## Also pinned: the backdrop does NOT dismiss. Tap-to-close is right for the
## portrait picker and wrong here -- an accidental tap must not resolve a spend
## in either direction.


func _fail(msg: String) -> void:
	print("FAIL  ", msg)
	quit(1)


func _initialize() -> void:
	_run()


func _find(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for c in node.get_children():
		var hit := _find(c, text)
		if hit != null:
			return hit
	return null


func _run() -> void:
	await process_frame

	# --- the commit button is not live on the frame it appears ---------------
	var dialog: CanvasLayer = load("res://scripts/ui/confirm.gd").new(
		{"title": "Sell this?", "confirm_text": "Sell", "danger": true})
	root.add_child(dialog)
	await process_frame

	var commit := _find(dialog, "Sell")
	var cancel := _find(dialog, "Cancel")
	if commit == null or cancel == null:
		_fail("the dialog did not build its buttons")
		return
	if not commit.disabled:
		_fail("the commit button was live on the frame the dialog opened")
		return

	# A backdrop tap must change nothing.
	var answered := [false]
	dialog.answered.connect(func(_yes: bool) -> void: answered[0] = true)
	for child in dialog.get_children():
		if child is ColorRect:
			(child as ColorRect).gui_input.emit(InputEventMouseButton.new())
	await process_frame
	if answered[0]:
		_fail("tapping the backdrop resolved the question")
		return

	await create_timer(0.45).timeout
	if commit.disabled:
		_fail("the commit button never armed")
		return
	dialog.queue_free()
	await process_frame

	# --- cancel says no, confirm says yes ------------------------------------
	for want in [false, true]:
		var d: CanvasLayer = load("res://scripts/ui/confirm.gd").new(
			{"title": "?", "confirm_text": "Yes", "cancel_text": "No"})
		root.add_child(d)
		await create_timer(0.45).timeout
		var b := _find(d, "Yes" if want else "No")
		if b == null:
			_fail("could not find the %s button" % ("Yes" if want else "No"))
			return
		var got: Array[bool] = []
		d.answered.connect(func(yes: bool) -> void: got.append(yes))
		b.pressed.emit()
		await process_frame
		if got.size() != 1 or got[0] != want:
			_fail("pressing %s answered %s" % ["Yes" if want else "No", str(got)])
			return
		d.queue_free()
		await process_frame

	print("PASS  the dialog arms late, ignores the backdrop, and answers correctly")
	quit(0)
