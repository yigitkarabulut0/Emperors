extends RefCounted
## STAT POINTS — where a level's points go, chosen before they are spent.
##
## Points were spent one at a time by tapping a stat on the Family strip and
## confirming, with nothing to say what a point was worth. Here all three stats
## stand side by side with what one point buys -- the server's figures
## (snapshot.prices.stat_gains) -- and the points are placed with steppers and
## spent in one request. Spent points cannot be moved, and the page says so.
##
## It is its own painting now (art/reference/stats.png, layout
## client/layout/stats.json) on the painted pages' host: each stat's green
## plate says what a point buys, the dark one what is in it now, the box how
## many are placed, and the green plate at the foot spends them.

const SCREEN := "page:stat_points"
const PAGE := "stats"
## Each stat: its id, the word for it, and its row's parts (layout ids).
const STATS := [
	{"id": "attack", "word": "attack", "gain": "gain_attack", "now": "now_attack", "plan": "plan_attack"},
	{"id": "defense", "word": "defence", "gain": "gain_defense", "now": "now_defense", "plan": "plan_defense"},
	{"id": "energy", "word": "max energy", "gain": "gain_energy", "now": "now_energy", "plan": "plan_energy"},
]


static func open(host: Node, opts: Dictionary = {}) -> PaintedPage:
	# The name the analytics has always had for it, from its Sheet days.
	var o := {"screen": SCREEN}
	o.merge(opts, true)
	var p := PaintedPage.open(host, PAGE, o)
	var plan := {"attack": 0, "defense": 0, "energy": 0}
	p.set_meta("plan", plan)
	for st in STATS:
		var id: String = st["id"]
		p.on("minus:" + id, func() -> void:
			plan[id] = maxi(0, int(plan[id]) - 1)
			_paint(p))
		p.on("plus:" + id, func() -> void:
			if _left(p) > 0:
				plan[id] = int(plan[id]) + 1
				_paint(p))
		p.on("all:" + id, func() -> void:
			plan[id] = int(plan[id]) + _left(p)
			_paint(p))
	p.on("spend", func() -> void: await _spend(p))
	_paint(p)
	return p


static func _left(p: PaintedPage) -> int:
	var plan: Dictionary = p.get_meta("plan")
	return int(GameState.player().get("stat_points_unspent", 0)) - int(plan["attack"]) - int(plan["defense"]) - int(plan["energy"])


static func _paint(p: PaintedPage) -> void:
	var pl := GameState.player()
	var gains: Dictionary = GameState.snapshot.get("prices", {}).get("stat_gains", {})
	var plan: Dictionary = p.get_meta("plan")
	var left := _left(p)
	var head := "%s POINT%s TO PLACE" % [UI.grouped(left) if left > 0 else "NO", "" if left == 1 else "S"]
	p.set_text("points", head, 22).label_settings.font_color = UI.GOLD if left > 0 else UI.DIM
	for st in STATS:
		var id: String = st["id"]
		var gain := int(gains.get(id, 0))
		p.set_text(st["gain"], "+%d %s a point" % [gain, str(st["word"])] if gain > 0 else "", 18)
		p.set_text(st["now"], "%s in it now" % UI.grouped(int(pl.get("stat_" + id, 0))), 16)
		var n := int(plan[id])
		p.set_text(st["plan"], "+%d" % n, 24).label_settings.font_color = UI.GOLD if n > 0 else UI.DIM
		p.set_enabled("minus:" + id, n > 0)
		p.set_enabled("plus:" + id, left > 0)
		p.set_enabled("all:" + id, left > 0)
	var chosen := int(plan["attack"]) + int(plan["defense"]) + int(plan["energy"])
	p.set_text("confirm_word", "SPEND %s POINT%s" % [UI.grouped(chosen), "" if chosen == 1 else "S"]
		if chosen > 0 else "SPEND POINTS", 20)
	p.set_enabled("spend", chosen > 0)
	# The word is on the plate, so it dims with it.
	(p.node("confirm_word") as Label).modulate = Color.WHITE if chosen > 0 else Color(1, 1, 1, 0.45)


static func _spend(p: PaintedPage) -> void:
	var plan: Dictionary = p.get_meta("plan")
	var chosen := int(plan["attack"]) + int(plan["defense"]) + int(plan["energy"])
	if chosen <= 0:
		return
	var res: Api.Response = await GameState.act("/v1/stats/spend",
		{"attack": int(plan["attack"]), "defense": int(plan["defense"]), "energy": int(plan["energy"])})
	if not res.ok:
		return
	GameState.toast("Spent %d point%s" % [chosen, "" if chosen == 1 else "s"])
	for k in plan:
		plan[k] = 0
	if is_instance_valid(p):
		if int(GameState.player().get("stat_points_unspent", 0)) > 0:
			_paint(p)
		else:
			p.close()
