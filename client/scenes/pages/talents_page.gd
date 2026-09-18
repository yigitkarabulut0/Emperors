extends RefCounted
## THE TALENT TREE -- the Family strip's TALENTS card (balance/talents.json).
##
## Built from the owner's own painting (art/reference/talents.png, slices
## art/slices/talents.json, layout client/layout/talents.json). It was a Sheet
## of text rows for a wave, because the painting sat unused in the design pack;
## this is the tree the painting asks for -- one great oak, three coloured
## banners, fifteen painted medallions and a row of ranks under each.
##
## A point every three levels from ten, and one for each Legacy: twenty-seven
## against fifty-one ranks, so the tree is a choice and never a checklist. Every
## rank feeds a channel the game already has -- the same buckets the Family's
## own upgrades feed -- and is folded in exactly where an upgrade is, under the
## same caps.
##
## Nothing is worked out here. What a rank is worth, what a tier's gate is, how
## many points a lord has and what a respec costs are all the server's
## (GET /v1/talents), and the buying is the lord's own sequenced action.
##
## The painting has no room for words beside a medallion, and it is right not
## to: a tap opens what the rank is, what it is worth and what it costs, and
## buys it there.

const PAGE := "talents"
## What a bucket does, in the words the Family's ledger uses for the same one.
const BUCKET := {
	"collect_income_bp": "collect income", "tax_income_bp": "estate income",
	"xp_bp": "hero experience", "energy_regen_bp": "energy regen",
	"max_energy_flat": "max energy", "soldier_atk_bp": "soldier attack",
	"soldier_def_bp": "soldier defence", "soldier_spd_bp": "soldier speed",
	"shop_discount_bp": "shop prices", "steal_cap_bp": "raid steal cap",
	"ransom_bp": "ransom", "luck_bp": "luck", "storehouse_minutes": "storehouse",
}
## The buckets that are not a percentage: flat energy and minutes.
const FLAT := ["max_energy_flat", "storehouse_minutes"]
## A tier the lord has not opened yet, drawn back. Lighter than the kit's usual
## 0.5, because twelve of the fifteen medallions are shut until the tree is
## spent into and the painting's own oak should still be a painting.
const DIM := Color(0.68, 0.68, 0.7)


## Opens the tree. `family` is the Family tab, refreshed when a rank is bought.
static func open(host: Node, family: Node, view: Dictionary, opts: Dictionary = {}) -> PaintedPage:
	var p := PaintedPage.open(host, PAGE, opts)
	p.set_meta("family", family)
	p.set_meta("view", view)
	p.on("respec", func() -> void: _respec(p))
	_wire(p)
	_paint(p)
	return p


static func _view(p: PaintedPage) -> Dictionary:
	return p.get_meta("view", {})


## Every medallion the layout built, by branch: [{node, parts, data}, ...].
static func _cells(p: PaintedPage) -> Array:
	var built: Variant = p.parts.get("medallion", [])
	return built if built is Array else []


## Which talent stands on which painted medallion. The layout says so, because
## the icons mean something -- the sword is Sharpened Steel, the clover is A
## Lucky Hand. A talent the layout does not name falls back to its branch's own
## order, so a new one in the balance cannot leave a medallion empty.
static func _order(branch: String, talents: Array) -> Array:
	var want: Array = Layout.spec(PAGE).get("medallions", {}).get(branch, [])
	var by_id := {}
	for t in talents:
		if t is Dictionary:
			by_id[str((t as Dictionary).get("id", ""))] = t
	var out: Array = []
	var used := {}
	for id in want:
		if by_id.has(str(id)):
			out.append(by_id[str(id)])
			used[str(id)] = true
	for t in talents:
		if t is Dictionary and not used.has(str((t as Dictionary).get("id", ""))):
			out.append(t)
	return out


static func _wire(p: PaintedPage) -> void:
	for cell in _cells(p):
		var parts: Dictionary = cell["parts"]
		var data: Dictionary = cell["data"]
		(parts["hit"] as BaseButton).pressed.connect(
			_tap.bind(p, str(data.get("branch", "")), int(data.get("index", 0))))


static func _paint(p: PaintedPage) -> void:
	var v := _view(p)
	var left := int(v.get("left", 0))
	if not bool(v.get("unlocked", false)):
		p.set_text("points", "LEVEL %d" % int(v.get("unlock_level", 0)), 16)
	elif left > 0:
		p.set_text("points", "%d POINT%s" % [left, "" if left == 1 else "S"], 16)
	else:
		p.set_text("points", "NONE LEFT", 16)

	# Every branch the server sent, on the column the layout gives it.
	var branches := {}
	for b in v.get("branches", []):
		if b is Dictionary:
			branches[str((b as Dictionary).get("id", ""))] = b
	var ordered := {}
	for id in branches:
		ordered[id] = _order(id, (branches[id] as Dictionary).get("talents", []))

	for cell in _cells(p):
		var data: Dictionary = cell["data"]
		var branch := str(data.get("branch", ""))
		var i := int(data.get("index", 0))
		var parts: Dictionary = cell["parts"]
		var list: Array = ordered.get(branch, [])
		var t: Dictionary = list[i] if i < list.size() else {}
		cell["talent"] = t

		var bought := int(t.get("bought", 0))
		var ranks := int(t.get("ranks", 0))
		var ring := parts["ring"] as TextureRect
		ring.texture = Art.tex("talents/ring_%s_%s" % ["lit" if bought > 0 else "dark", branch])
		# A tier still shut is drawn back, face and ring together: the painting
		# has no third state for it, and the dim is the one every unreachable
		# painted thing here wears. The face is the page's own pixels, so at
		# full strength nothing about the painting changes.
		var shut := not bool(t.get("open", false))
		ring.modulate = DIM if shut else Color.WHITE
		(parts["face"] as CanvasItem).modulate = DIM if shut else Color.WHITE

		for k in 5:
			var pip := parts["pip_%d" % (k + 1)] as TextureRect
			# Only a rank the lord HAS wears a gem. A rank the talent does not
			# have at all keeps the painting's own empty socket, so a three-rank
			# talent does not pretend to five.
			pip.visible = k < bought
			pip.modulate = DIM if shut else Color.WHITE
			if k >= ranks:
				pip.visible = false

	p.set_enabled("respec", int(v.get("spent", 0)) > 0)


## "+1.5% soldier attack a rank, +6.0% at four" -- in the bucket's own units,
## from the server's own numbers.
static func worth_words(t: Dictionary) -> String:
	var per := int(t.get("per_rank", 0))
	var ranks := int(t.get("ranks", 0))
	var bucket := str(t.get("bucket", ""))
	var what := str(BUCKET.get(bucket, bucket))
	if bucket in FLAT:
		var unit := " minutes" if bucket == "storehouse_minutes" else ""
		return "+%d%s %s a rank, +%d%s at %d" % [per, unit, what, per * ranks, unit, ranks]
	return "+%.1f%% %s a rank, +%.1f%% at %d" % [per / 100.0, what, per * ranks / 100.0, ranks]


## A tap on a medallion: what it is, what it is worth, and BUY.
static func _tap(p: PaintedPage, branch: String, index: int) -> void:
	if not p.armed() or bool(p.get_meta("busy", false)):
		return
	var t: Dictionary = {}
	for cell in _cells(p):
		var d: Dictionary = cell["data"]
		if str(d.get("branch", "")) == branch and int(d.get("index", 0)) == index:
			t = cell.get("talent", {})
	if t.is_empty():
		return
	var lines := PackedStringArray([str(t.get("blurb", "")), "", worth_words(t), "",
		"%d of %d ranks." % [int(t.get("bought", 0)), int(t.get("ranks", 0))]])
	if not bool(t.get("open", false)):
		lines.append("")
		lines.append("This tier opens at %d points in this branch." % int(t.get("needs", 0)))
	elif int(t.get("bought", 0)) >= int(t.get("ranks", 0)):
		lines.append("")
		lines.append("It is at its last rank.")
	elif int(_view(p).get("left", 0)) <= 0:
		lines.append("")
		lines.append("You have no points left to spend.")
	var can := bool(t.get("can_buy", false))
	var cfg := {"title": str(t.get("name", "")).to_upper(), "body": "\n".join(lines)}
	if can:
		cfg["confirm_text"] = "Take the rank"
		cfg["cancel_text"] = "Not yet"
	else:
		cfg["confirm_text"] = "Close"
	if not await Dialog.ask(p, cfg) or not can or not is_instance_valid(p):
		return
	await _buy(p, t)


static func _buy(p: PaintedPage, t: Dictionary) -> void:
	if bool(p.get_meta("busy", false)):
		return
	p.set_meta("busy", true)
	var res: Api.Response = await GameState.act("/v1/talents/buy", {"talent_id": str(t.get("id", ""))},
		{"no_talent_points": "You have no points left.",
		 "talent_shut": "Spend more in this branch first.",
		 "talent_maxed": "That talent is at its last rank."})
	p.set_meta("busy", false)
	if not res.ok or not is_instance_valid(p):
		return
	GameState.toast("%s is yours." % str(t.get("name", "The talent")))
	_adopt(p, res.data.get("talents", {}))


static func _respec(p: PaintedPage) -> void:
	if bool(p.get_meta("busy", false)):
		return
	var v := _view(p)
	if int(v.get("spent", 0)) <= 0:
		return
	if not await Dialog.ask(p, {
			"title": "Take every rank back?",
			"body": "For %s gold. Every point returns and the tree is empty; the next respec costs more." %
				UI.grouped(int(v.get("respec_cost", 0))),
			"confirm_text": "Respec", "danger": true}):
		return
	p.set_meta("busy", true)
	var res: Api.Response = await GameState.act("/v1/talents/respec", {},
		{"no_talents": "You have spent nothing to take back.",
		 "not_enough_gold": "Not enough gold for that."})
	p.set_meta("busy", false)
	if not res.ok or not is_instance_valid(p):
		return
	GameState.toast("Every point is yours again.")
	_adopt(p, res.data.get("talents", {}))


## Takes the tree the server just sent, and tells the Family tab, whose card
## carries the count.
static func _adopt(p: PaintedPage, tree: Variant) -> void:
	if tree is Dictionary:
		p.set_meta("view", tree)
	_paint(p)
	var family: Variant = p.get_meta("family") if p.has_meta("family") else null
	if family is Node and is_instance_valid(family) and (family as Node).has_method("talents_changed"):
		(family as Node).call("talents_changed", p.get_meta("view", {}))
