extends RefCounted
## STAT POINTS — where a level's points go, chosen before they are spent.
##
## Points were spent one at a time by tapping a stat on the Family strip and
## confirming, with nothing to say what a point was worth. Here all three stats
## stand side by side with what one point buys -- the server's figures
## (snapshot.prices.stat_gains) -- and the points are placed with steppers and
## spent in one request. Spent points cannot be moved, and the page says so.

const ROW_H := 150.0
const STATS := [
	["attack", "ATTACK", "icons/might_swords", "attack"],
	["defense", "DEFENCE", "icons/shield_small", "defence"],
	["energy", "MAX ENERGY", "icons/energy", "max energy"],
]


static func open(host: Node) -> Sheet:
	var s := Sheet.open(host, "STAT POINTS", "Points cannot be moved once they are spent.")
	s.set_meta("plan", {"attack": 0, "defense": 0, "energy": 0})
	_paint(s)
	return s


static func _left(s: Sheet) -> int:
	var plan: Dictionary = s.get_meta("plan")
	return int(GameState.player().get("stat_points_unspent", 0)) - int(plan["attack"]) - int(plan["defense"]) - int(plan["energy"])


static func _paint(s: Sheet) -> void:
	s.clear_body()
	for c in s.foot.get_children():
		c.queue_free()
	var p := GameState.player()
	var gains: Dictionary = GameState.snapshot.get("prices", {}).get("stat_gains", {})
	var plan: Dictionary = s.get_meta("plan")
	var left := _left(s)
	s.paragraph("%d point%s to place" % [left, "" if left == 1 else "s"], 30, UI.GOLD if left > 0 else UI.DIM,
		HORIZONTAL_ALIGNMENT_CENTER)
	for st in STATS:
		var id: String = st[0]
		var row := s.slot(ROW_H)
		var icon := UI.image(str(st[2]), Rect2(22, 36, 70, 78))
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		Sheet.put(row, str(st[1]), Rect2(108, 18, s.inner_w - 540, 40), 28, UI.INK, "title", 700)
		var gain := int(gains.get(id, 0))
		Sheet.put(row, "+%d %s a point" % [gain, str(st[3])] if gain > 0 else "", Rect2(108, 60, s.inner_w - 540, 32), 22, UI.GREEN)
		Sheet.put(row, "%d in it now" % int(p.get("stat_" + id, 0)), Rect2(108, 96, s.inner_w - 540, 32), 21, UI.DIM)
		var n := int(plan[id])
		var minus := Sheet.button("-", Dialog.QUIET_PLATE, UI.INK, 96, 36)
		UI.place(minus, Rect2(s.inner_w - 414, 27, 96, 96))
		minus.disabled = n <= 0
		minus.pressed.connect(func() -> void:
			plan[id] = maxi(0, int(plan[id]) - 1)
			_paint(s))
		row.add_child(minus)
		Sheet.put(row, "+%d" % n, Rect2(s.inner_w - 316, 0, 88, ROW_H), 34, UI.GOLD if n > 0 else UI.DIM,
			"title", 800, HORIZONTAL_ALIGNMENT_CENTER)
		var plus := Sheet.button("+", Dialog.CONFIRM_PLATE, Color("#F3FBF3"), 96, 36)
		UI.place(plus, Rect2(s.inner_w - 224, 27, 96, 96))
		plus.disabled = left <= 0
		plus.pressed.connect(func() -> void:
			if _left(s) > 0:
				plan[id] = int(plan[id]) + 1
				_paint(s))
		row.add_child(plus)
		var all := Sheet.button("ALL", Dialog.QUIET_PLATE, UI.INK, 96, 22)
		UI.place(all, Rect2(s.inner_w - 118, 27, 104, 96))
		all.disabled = left <= 0
		all.pressed.connect(func() -> void:
			plan[id] = int(plan[id]) + _left(s)
			_paint(s))
		row.add_child(all)

	var chosen := int(plan["attack"]) + int(plan["defense"]) + int(plan["energy"])
	if chosen > 0:
		s.add_button("SPEND %d POINT%s" % [chosen, "" if chosen == 1 else "S"], "confirm", func() -> void:
			var res: Api.Response = await GameState.act("/v1/stats/spend",
				{"attack": int(plan["attack"]), "defense": int(plan["defense"]), "energy": int(plan["energy"])})
			if res.ok:
				GameState.toast("Spent %d point%s" % [chosen, "" if chosen == 1 else "s"])
				s.set_meta("plan", {"attack": 0, "defense": 0, "energy": 0})
				if is_instance_valid(s):
					if int(GameState.player().get("stat_points_unspent", 0)) > 0:
						_paint(s)
					else:
						s.close())
	s.add_close("LATER" if chosen > 0 or left > 0 else "CLOSE")
