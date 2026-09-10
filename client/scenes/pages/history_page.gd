extends RefCounted
## BATTLE HISTORY — every raid the player made and every raid on them, the last
## fifty, each one a tap from its replay.
##
## "View All" opened a dialog with twelve lines of text in it and no way to
## watch any of them. The rows here say it from the player's side -- a victory,
## a defeat, held off, raided by -- with the gold that moved and when, and a tap
## plays the fight.

const ROW_H := 104.0


## `entries` is /v1/attack/history's list; `replay` is called with an entry to
## play it back.
static func open(host: Node, entries: Array, replay: Callable) -> Sheet:
	var s := Sheet.open(host, "BATTLE HISTORY", "Your raids and the raids on you. Tap one to watch it.")
	if entries.is_empty():
		s.paragraph("No battles yet. Every raid you make, and every raid on you, is written here.", 24, UI.DIM,
			HORIZONTAL_ALIGNMENT_CENTER)
	for e in entries:
		_row(s, e, replay)
	s.add_close()
	return s


static func words(e: Dictionary) -> Array:
	var won := bool(e.get("won", false))
	var name := str(e.get("opponent_name", ""))
	if bool(e.get("raided", false)):
		return ["Held off" if won else "Raided by", name, UI.GREEN if won else UI.RED]
	return ["Victory" if won else "Defeat", "vs. " + name, UI.GREEN if won else UI.RED]


static func _row(s: Sheet, e: Dictionary, replay: Callable) -> void:
	var row := s.slot(ROW_H)
	var won := bool(e.get("won", false))
	row.add_child(UI.image("icons/sword_victory" if won else "icons/sword_defeat", Rect2(18, 30, 46, 42)))
	var w := words(e)
	var word := Sheet.put(row, str(w[0]), Rect2(78, 12, 220, 40), 26, w[2], "body", 700)
	var gap := word.label_settings.font.get_string_size(word.text + " ", HORIZONTAL_ALIGNMENT_LEFT, -1,
		word.label_settings.font_size).x
	Sheet.put(row, str(w[1]), Rect2(78 + gap, 12, s.inner_w - 360 - gap, 40), 26, UI.INK, "body", 600)
	var lvl := int(e.get("opponent_level", 0))
	Sheet.put(row, ("Level %d  ·  " % lvl if lvl > 0 else "") + UI.ago(_seconds_since(str(e.get("at", "")))),
		Rect2(78, 54, s.inner_w - 360, 34), 20, UI.DIM)
	var gold := int(str(e.get("gold", "0")))
	var coin := UI.image("icons/coin_small", Rect2(s.inner_w - 250, 33, 38, 37))
	coin.visible = gold != 0
	row.add_child(coin)
	Sheet.put(row, (("+" if gold > 0 else "") + UI.grouped(gold)) if gold != 0 else "-",
		Rect2(s.inner_w - 206, 0, 150, ROW_H), 26, Color("#EFC53A") if gold >= 0 else UI.RED, "body", 700)
	row.add_child(UI.image("icons/chevron_gold", Rect2(s.inner_w - 44, 37, 24, 30)))
	var hit := UI.hotspot(Rect2(0, 0, s.inner_w, ROW_H), true)
	hit.pressed.connect(func() -> void: replay.call(e))
	row.add_child(hit)


static func _seconds_since(iso: String) -> int:
	if iso == "":
		return 0
	var then := Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))
	return maxi(0, int(Time.get_unix_time_from_system()) - int(then))
