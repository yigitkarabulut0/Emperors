extends SceneTree
## Every Court view's way back is the one shared plate: it says COURT when the
## view was opened from the COURT tab, and BACK over any other.
##
## The rule: a Court view with a back plate builds it with CourtBack; a painted
## page closes with its painted CLOSE.
##
## The paintings of the views the shell hosts over the tabs (the mail, the
## store) say COURT on their back plate, and before the COURT tab the plate
## named a place that did not exist. It is one piece (CourtBack: the painted
## plate with its word lifted, the word set in type). Every such view is built
## and read: the plate is chrome/court_back, the word is CourtBack.WORD built
## on its own, and no painted COURT plate is drawn anywhere. Then each is
## opened in a live shell, over the COURT tab (COURT) and over Collect (BACK).
##
## THE CROWN'S FAVOUR and SPLENDOUR are whole-page paintings (PaintedPage, their
## scripts declare PAGE) with the painting's own CLOSE, and neither painting has
## a COURT or BACK plate: they close with that CLOSE, and must not grow a second
## way out.
##
## Run: godot --headless --path client --script tests/court_back.gd

var _fails := 0


func _initialize() -> void:
	await process_frame
	root.get_node("GameState").set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1",
		"diamonds": 12, "action_seq": 1}, "energy": {"current": 1, "max": 2}, "sections": []})
	var cb: GDScript = load("res://scripts/ui/court_back.gd")
	if cb == null:
		print("FAIL  there is no shared back plate (scripts/ui/court_back.gd)")
		quit(1)
		return
	var word := str(cb.get("WORD"))
	_expect(word == "BACK", "the Court views' way back over another tab says %s" % word)
	_expect(str(cb.get("COURT_WORD")) == "COURT", "opened from the COURT tab, the way back says %s" % cb.get("COURT_WORD"))
	var views: Dictionary = (load("res://scenes/shell/shell.gd") as GDScript).get_script_constant_map().get("VIEWS", {})
	_expect(views.size() >= 2, "the shell hosts %d Court view(s)" % views.size())
	var spec: Dictionary = (load("res://scripts/ui/layout.gd") as GDScript).call("element", "court_back", "back_word")
	var r: Array = spec.get("rect", [0, 0, 0, 0])
	var word_rect := Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
	var checked := 0
	var pages: Array = []
	for id in views:
		var src := FileAccess.get_file_as_string(str(views[id]))
		if (load(str(views[id])) as GDScript).get_script_constant_map().has("PAGE"):
			# A painted page: its painting's CLOSE is its way out.
			_expect(not src.contains("CourtBack.build"), "%s is a painted page with its own CLOSE, and builds a back plate too" % id)
			pages.append(id)
			continue
		_expect(src.contains("CourtBack.build"), "%s does not build its way back with CourtBack" % id)
		checked += 1
		var host := Control.new()
		host.size = Vector2(941, 1672)
		root.add_child(host)
		var v: Node = (load(str(views[id])) as GDScript).new()
		if v is Control:
			(v as Control).size = host.size
		host.add_child(v)
		for i in 3:
			await process_frame
		var words: Array = []
		var plates := 0
		var painted_court := false
		var stack: Array = [v]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is Label and (n as Label).text != "":
				var l := n as Label
				if l.text.to_upper() == "COURT" or l.text.to_upper() == word:
					words.append(l)
			if n is TextureRect and (n as TextureRect).texture != null:
				var path := (n as TextureRect).texture.resource_path
				if path.ends_with("chrome/court_back.png"):
					plates += 1
				if path.ends_with("mail/back.png"):
					painted_court = true
		_expect(plates == 1, "%s draws %d shared back plate(s)" % [id, plates])
		_expect(not painted_court, "%s still draws a plate with COURT painted on it" % id)
		_expect(words.size() == 1, "%s has %d back word(s)" % [id, words.size()])
		if words.size() == 1:
			var l: Label = words[0]
			_expect(l.text == word, "%s's back plate says %s, not %s" % [id, l.text, word])
			_expect(Rect2(l.position, Vector2(float(l.get_meta("box_w", l.size.x)), l.size.y)).get_center().distance_to(word_rect.get_center()) < 1.0,
				"%s's back word is not where the painting set its own" % id)
		host.queue_free()
		await process_frame
	# In a live shell: over the COURT the plate names it, over Collect it says
	# BACK, and either way it closes back to the tab it lay over.
	var parent := Control.new()
	parent.size = Vector2(941, 1672)
	root.add_child(parent)
	var shell: Control = (load("res://scenes/shell/shell.tscn") as PackedScene).instantiate()
	parent.add_child(shell)
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame
	var live_checked := 0
	for tab in ["court", "collect"]:
		for id in views:
			if pages.has(id):
				continue
			shell.call("open", tab)
			await process_frame
			var v: Control = shell.call("open_view", id)
			for i in 2:
				await process_frame
			var want := "COURT" if tab == "court" else word
			var said := ""
			var stack: Array = [v]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				for c in n.get_children():
					stack.append(c)
				if n is Label and ((n as Label).text == "COURT" or (n as Label).text == word):
					said = (n as Label).text
			_expect(said == want, "%s opened over %s says %s on its way back, not %s" % [id, tab, said, want])
			shell.call("close_view")
			await process_frame
			_expect(str(shell.call("current_tab")) == tab, "%s closed back to %s, not %s" % [id, shell.call("current_tab"), tab])
			live_checked += 1
	parent.queue_free()
	await process_frame
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	_expect(checked >= 2, "only %d Court view(s) carry a back plate" % checked)
	print("PASS  %d Court view(s) go back through the one plate: COURT over the COURT tab, %s over another (%d opened live); %d painted page(s) close by their CLOSE (%s)" % [
		checked, word, live_checked, pages.size(), ", ".join(pages)])
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
