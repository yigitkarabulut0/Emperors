extends SceneTree
## THE TALENT TREE -- the painted page (scenes/pages/talents_page.gd), built
## from the owner's painting (art/reference/talents.png).
##
## What must hold:
##  - the fifteen medallions stand where the painting stands them, measured off
##    its own gold: three columns at x 185, 467 and 749, five rows at y 608,
##    797, 981, 1166 and 1352;
##  - a rank the lord has bought wears the painting's glowing ring and one
##    amber gem for each rank; one nobody has bought wears the plain ring and
##    none, so the painting's own lit rows never survive into a lord's tree;
##  - a talent with three ranks never shows a fourth or fifth gem;
##  - a tier still shut is drawn back whole -- face, ring and gems together --
##    and never a grey ring round a bright icon;
##  - the plate beside the title says what the server says is left, and RESPEC
##    is dark until something has been spent;
##  - the page works out no worth of its own: what a rank gives comes from the
##    server's bucket and per_rank and nothing else.
##
## Run: godot --headless --path client --script tests/talents_tree.gd

const COLS := {"war": 185, "defence": 467, "economy": 749}
const ROWS := [608, 797, 981, 1166, 1352]
## A medallion's cell, its ring's circle and its five gem sockets, from the
## painting (art/slices/talents.json).
const CELL := Vector2(190, 200)
const RING_D := 146.0
const GEM_DX := [-72, -42, -11, 19, 48]
const GEM_DY := 62
const GEM := Vector2(28, 26)

var _fails := 0
var _checked := 0
var _art: Node = null
var _lay: GDScript = null


func _initialize() -> void:
	await process_frame
	root.get_node("Env").set("api_base_url", "http://127.0.0.1:9")
	_art = root.get_node("Art")
	_lay = load("res://scripts/ui/layout.gd")
	_grid_is_the_painting()
	_no_arithmetic()
	await _tree_states()
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  %d checks: the tree is the painting's, and every rank on it is the server's" % _checked)
	quit()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_fails += 1
		print("  FAIL  " + what)


func _grid_is_the_painting() -> void:
	var tpl: Dictionary = _lay.call("element", "talents", "medallion")
	_expect(not tpl.is_empty(), "the talents layout has no medallion template")
	if tpl.is_empty():
		return
	var r: Rect2 = _lay.call("rect_of", tpl)
	_expect(r.size == CELL, "a medallion's cell is %s, not the painting's %s" % [r.size, CELL])

	var want: Array = []
	for br in ["war", "defence", "economy"]:
		for cy in ROWS:
			want.append(Vector2(int(COLS[br]) - 95, cy - 95))
	var got: Array = []
	for inst in tpl.get("instances", []):
		var at: Array = (inst as Dictionary).get("pos", [])
		got.append(Vector2(float(at[0]), float(at[1])))
	_expect(got.size() == 15, "the layout stands %d medallions, not fifteen" % got.size())
	for i in mini(got.size(), want.size()):
		_expect(got[i] == want[i], "medallion %d stands at %s, not the painting's %s" % [i + 1, got[i], want[i]])

	# Every part the page paints, and the gems on the painting's own sockets.
	var parts := {}
	for p in tpl.get("parts", []):
		parts[str((p as Dictionary).get("id", ""))] = p
	for id in ["face", "ring", "hit", "pip_1", "pip_2", "pip_3", "pip_4", "pip_5"]:
		_expect(parts.has(id), "the medallion has no %s" % id)
	if parts.has("hit"):
		var hr: Rect2 = _lay.call("rect_of", parts["hit"])
		_expect(is_equal_approx(hr.size.x, RING_D) and is_equal_approx(hr.size.y, RING_D),
			"the tap is %s, not the ring's %d across" % [hr.size, int(RING_D)])
	for k in 5:
		if not parts.has("pip_%d" % (k + 1)):
			continue
		var pr: Rect2 = _lay.call("rect_of", parts["pip_%d" % (k + 1)])
		var wanted := Rect2(95 + int(GEM_DX[k]), 95 + GEM_DY, GEM.x, GEM.y)
		_expect(pr.is_equal_approx(wanted), "gem %d sits at %s, not the painting's %s" % [k + 1, pr, wanted])

	# The layout says which talent stands on which painted medallion, and no
	# talent may stand on two.
	var seen := {}
	var med: Dictionary = _lay.call("spec", "talents").get("medallions", {})
	_expect(med.size() == 3, "the layout names medallions for %d branches, not three" % med.size())
	for br in med:
		var ids: Array = med[br]
		_expect(ids.size() == 5, "%s names %d medallions, not five" % [br, ids.size()])
		for id in ids:
			_expect(not seen.has(str(id)), "%s stands on two medallions" % str(id))
			seen[str(id)] = true


## What a rank gives is the server's bucket and per_rank. The page may say them
## in the Family's words; it may not have a table of its own.
func _no_arithmetic() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/pages/talents_page.gd")
	for word in ["first_level", "levels_per_point", "point_per_legacy", "tier_gate", "respec_mult"]:
		_expect(not src.contains(word), "the tree works out %s itself" % word)


func _talent(id: String, ranks: int, bought: int, needs: int, spent: int) -> Dictionary:
	return {"id": id, "name": id.capitalize(), "blurb": "A rank.", "tier": 1,
		"bucket": "soldier_atk_bp", "per_rank": 150, "ranks": ranks, "bought": bought,
		"now": 150 * bought, "needs": needs, "open": spent >= needs,
		"can_buy": spent >= needs and bought < ranks}


## war: the first talent bought twice of four, the rest shut. defence: nothing
## bought and the first open. economy: a three-rank talent bought to the last.
func _view(spent_war: int) -> Dictionary:
	var branches: Array = []
	var ids := {"war": ["war_edge", "war_speed", "war_spoils", "war_ransom", "war_fury"],
		"defence": ["def_wall", "def_stores", "def_larder", "def_vigil", "def_bastion"],
		"economy": ["eco_granary", "eco_market", "eco_tithe", "eco_fortune", "eco_ledger"]}
	for br in ["war", "defence", "economy"]:
		var ts: Array = []
		var spent := spent_war if br == "war" else (0 if br == "defence" else 3)
		for i in 5:
			var ranks := 3 if br == "economy" else 4
			var bought := 0
			if br == "war" and i == 0:
				bought = spent_war
			elif br == "economy" and i == 0:
				bought = 3
			ts.append(_talent(str((ids[br] as Array)[i]), ranks, bought, [0, 3, 6, 10, 14][i], spent))
		branches.append({"id": br, "name": br.to_upper(), "blurb": "", "spent": spent, "talents": ts})
	var spent_all := spent_war + 3
	return {"unlocked": true, "unlock_level": 10, "points": 27, "spent": spent_all,
		"left": 27 - spent_all, "next_point_at": 33, "respec_cost": 12000, "respecs": 0,
		"branches": branches}


func _tree_states() -> void:
	var host := Control.new()
	host.size = Vector2(941, 1672)
	root.add_child(host)
	await process_frame
	var TP: GDScript = load("res://scenes/pages/talents_page.gd")
	for spent_war in [0, 2]:
		var v := _view(spent_war)
		var page: Control = TP.call("open", host, null, v)
		await process_frame
		var tag := "%d spent in war" % spent_war
		var cells: Array = page.get("parts").get("medallion", [])
		_expect(cells.size() == 15, "%s: %d medallions were built, not fifteen" % [tag, cells.size()])

		for cell in cells:
			var data: Dictionary = (cell as Dictionary)["data"]
			var parts: Dictionary = (cell as Dictionary)["parts"]
			var t: Dictionary = (cell as Dictionary).get("talent", {})
			var br := str(data.get("branch", ""))
			var i := int(data.get("index", 0))
			var who := "%s: %s %d" % [tag, br, i + 1]
			_expect(not t.is_empty(), "%s has no talent on it" % who)
			if t.is_empty():
				continue
			var bought := int(t.get("bought", 0))
			var ranks := int(t.get("ranks", 0))
			var shut := not bool(t.get("open", false))

			var ring := parts["ring"] as TextureRect
			var want_ring: Texture2D = _art.call("tex", "talents/ring_%s_%s" % ["lit" if bought > 0 else "dark", br])
			_expect(ring.texture == want_ring,
				"%s wears the %s ring" % [who, "lit" if ring.texture != want_ring else "wrong"])

			# Face, ring and gems are drawn back together or not at all.
			var face := parts["face"] as TextureRect
			_expect((face.modulate == Color.WHITE) != shut and (ring.modulate == Color.WHITE) != shut,
				"%s: a shut tier is not drawn back whole" % who)
			_expect(face.texture == _art.call("tex", "talents/face_%s_%d" % [br, i + 1]),
				"%s does not wear its own painted face" % who)

			var lit := 0
			for k in 5:
				var pip := parts["pip_%d" % (k + 1)] as TextureRect
				if pip.visible:
					lit += 1
					_expect(k < ranks, "%s lights a gem past its %d ranks" % [who, ranks])
					_expect((pip.modulate == Color.WHITE) != shut,
						"%s: a gem is not drawn back with its medallion" % who)
			_expect(lit == bought, "%s lights %d gems for %d ranks" % [who, lit, bought])

		var points := page.call("node", "points") as Label
		_expect(points != null and points.text == "%d POINTS" % int(v["left"]),
			"%s: the plate reads %s, not %d POINTS" % [tag, points.text if points != null else "nothing", int(v["left"])])

		var respec: BaseButton = null
		var btns: Array = []
		_buttons(page, btns)
		for b in btns:
			if str((b as BaseButton).get_meta("action", "")) == "respec":
				respec = b
		_expect(respec != null, "%s: the page has no RESPEC" % tag)
		if respec != null:
			_expect(respec.disabled == (int(v["spent"]) <= 0),
				"%s: RESPEC is %s" % [tag, "dark" if respec.disabled else "lit"])
		page.call("close")
		await process_frame
	host.queue_free()
	await process_frame


func _buttons(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is BaseButton:
			out.append(c)
		_buttons(c, out)
