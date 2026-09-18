extends SceneTree
## A kingdom's name stays on its plate, clear of the quill.
##
## A name may be 24 characters. The header shrank it only to 30 points, and a
## Label grows to its text, so "WWWW..." ran on under the rename quill to x 900.
## The name now shrinks to 26 points and past that is cut with an ellipsis; a
## real long name still fits whole.
##
## Run: godot --headless --path client --script tests/kingdom_name_fit.gd

var _fails := 0
var _checked := 0


func _initialize() -> void:
	await process_frame
	var gs: Node = root.get_node("GameState")
	gs.set("snapshot", {"player": {"username": "Wwwwwwwwwwwwwwww", "level": 30, "gold": "1", "action_seq": 1,
		"kingdom_id": "k"}, "energy": {"current": 1, "max": 2}, "sections": []})
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	var tab: Control = (load("res://scenes/tabs/kingdom.gd") as GDScript).new()
	tab.size = host.size
	host.add_child(tab)
	for i in 3:
		await process_frame
	var ui: Dictionary = tab.get("_ui")
	var quill: Control = ui["edit_name"]
	var quill_tex: Texture2D = (quill as TextureButton).texture_normal
	# keep_texture_size: the quill's ink sits centred in its tap target.
	var ink_left: float = quill.position.x + (quill.size.x - float(quill_tex.get_width())) / 2.0

	for case in [
		["WWWWWWWWWWWWWWWWWWWWWWWW", false],  # 24, the widest letters: cut
		["The Iron Brotherhood", true],       # a long real name: whole
		["Lion Banner", true],
	]:
		var name: String = case[0]
		var whole: bool = case[1]
		tab.set("_data", {"in_kingdom": true, "kingdom": {"name": name, "tag": "WWWW", "members": 1,
			"member_cap": 10, "level": 1, "xp": 0, "xp_to_next": 100, "reputation": 0, "treasury": "0"},
			"upgrades": [], "members": []})
		tab.call("_paint")
		await process_frame
		var l: Label = ui["kingdom_name"]
		var s := l.label_settings
		var drawn := s.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s.font_size).x
		var right: float = l.position.x + (minf(drawn, l.size.x) if l.clip_text else drawn)
		_checked += 1
		_expect(right <= ink_left - 4.0, "%s ends at x %.0f, under the quill (ink from %.0f)" % [name, right, ink_left])
		_expect(s.font_size >= 26, "%s set at %d points, below the floor of 26" % [name, s.font_size])
		if whole:
			_expect(drawn <= l.size.x, "%s is cut although it fits at %d points" % [name, s.font_size])
			_expect(l.text == name.to_upper(), "%s reads %s" % [name, l.text])

	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d kingdom names stay on the plate, clear of the quill" % _checked)
	quit()


func _expect(ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
		printerr("  ", why)
