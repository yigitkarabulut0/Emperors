extends RefCounted
## RECRUIT ODDS -- behind the (i) over the recruit cards.
##
## It was a dialog of text lines, each type's tiers run together ("I 71.8%
## II 21.8%  III 5.1% ..."), and the lines wrapped wherever they ran out of
## room: a tier's numeral at the end of one line and its chance at the start
## of the next. Here each type is a row of seven tiers, the painted numeral
## over its chance as the reroll panel shows them, and the tiers stand in the
## same columns on every row so they can be read down as well as across.
## Every number is the server's (/v1/army/odds), for this player's level and
## luck; a tier a type cannot be drawn at reads as a dash.

const TIER_IDS := ["common", "uncommon", "rare", "epic", "legendary", "mystic", "special"]
const ROW_H := 116.0
const BADGE := 54.0


## `odds` is the /v1/army/odds answer; `types` the type ids in the order the
## cards show them; `names` their display names.
static func open(host: Node, odds: Dictionary, types: Array, names: Dictionary) -> Sheet:
	var s := Sheet.open(host, "RECRUIT ODDS", "The tier a soldier is drawn at, recruited or rerolled, at your level.")
	var rp: GDScript = load("res://scenes/army/reroll_panel.gd")
	var by_type := {}
	for t in odds.get("types", []):
		by_type[str(t.get("type_id", ""))] = t.get("odds", [])
	if by_type.is_empty():
		s.paragraph("The odds could not be read. Close this and try again in a moment.", 22, UI.DIM)
	else:
		for type in types:
			s.heading(str(names.get(type, str(type).to_upper())))
			var row := s.slot(ROW_H)
			var cell_w := (s.inner_w - 16.0) / float(TIER_IDS.size())
			for i in TIER_IDS.size():
				var bp := 0
				for o in by_type.get(type, []):
					if str(o.get("tier", "")) == TIER_IDS[i]:
						bp = int(o.get("bp", 0))
				var x := 8.0 + cell_w * i
				var badge: TextureRect = rp.numeral_badge(i + 1, Rect2(x + (cell_w - BADGE) / 2.0, 10, BADGE, BADGE))
				badge.modulate = Color.WHITE if bp > 0 else Color(1, 1, 1, 0.3)
				row.add_child(badge)
				Sheet.put(row, rp.percent(bp), Rect2(x, 10 + BADGE + 4, cell_w, 34), 22,
					UI.INK if bp > 0 else UI.DIM, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
		s.paragraph("These are your own odds: your level and the luck of your Collection are counted in them.",
			21, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	s.add_close()
	return s
