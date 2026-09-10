extends RefCounted
## Choosing a piece of gear: every item that fits, as the Inventory draws it.
##
## The choice was a list of names in a dialog -- "Tempered Flamberge / UNCOMMON
## · Power 1,240" -- with nothing to compare against what was being worn and
## nothing saying whose it already was. Each row here is the item's painting in
## its tier's frame, its stat and its Power, whether it is stronger or weaker
## than the piece it would replace, and who wears it now if anyone does.
## Numbers are the server's; the page only compares two of them.

const ROW_H := 176.0
const STAT := {"weapon": ["attack", "ATK"], "armor": ["defense", "DEF"], "horse": ["speed", "SPD"]}


## Returns the chosen item's id, "__unequip" to take the worn piece off, or ""
## when the page was closed. `worn` is the piece in the slot now, or {}.
static func pick(host: Node, title: String, items: Array, worn: Dictionary) -> String:
	var s := Sheet.open(host, title, "Tap a piece to wear it.")
	var chosen := [""]
	if not worn.is_empty():
		s.heading("WORN NOW")
		var row := _row(s, worn, {}, false)
		var off := Sheet.button("TAKE OFF", Dialog.QUIET_PLATE, UI.INK, 96, 24)
		UI.place(off, Rect2(s.inner_w - 210, ROW_H / 2.0 - 48, 196, 96))
		off.pressed.connect(func() -> void:
			chosen[0] = "__unequip"
			s.close())
		row.add_child(off)
	s.heading("IN YOUR BAGS" if not items.is_empty() else "NOTHING ELSE FITS")
	if items.is_empty():
		s.paragraph("Nothing in your bags fits this slot. The Royal Market in the Shop sells new gear every few minutes.",
			22, UI.DIM)
	for it in items:
		var row := _row(s, it, worn, true)
		var wear := Sheet.button("WEAR", Dialog.CONFIRM_PLATE, Color("#F3FBF3"), 96, 26)
		UI.place(wear, Rect2(s.inner_w - 190, ROW_H / 2.0 - 48, 176, 96))
		var id := str(it.get("id", ""))
		wear.pressed.connect(func() -> void:
			chosen[0] = id
			s.close())
		row.add_child(wear)
	s.add_close()
	await s.closed
	return chosen[0]


static func _row(s: Sheet, it: Dictionary, worn: Dictionary, compare: bool) -> NinePatchRect:
	var row := s.slot(ROW_H)
	var tier := str(it.get("tier", "common"))
	var tile := UI.image("inventory/item_tile_empty", Rect2(16, 16, 144, 144))
	row.add_child(tile)
	var pic := UI.image("", Rect2(26, 24, 124, 124))
	pic.texture = Art.item(str(it.get("art", "")))
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(pic)
	row.add_child(UI.image("inventory/frame_" + tier, Rect2(16, 16, 144, 144)))
	var badge := UI.image("inventory/badge_" + tier, Rect2(178, 18, 93, 38))
	badge.size = badge.texture.get_size()
	row.add_child(badge)
	var right := s.inner_w - 220.0
	Sheet.put(row, str(it.get("name", "")), Rect2(176, 58, right - 176, 40), 27, UI.INK, "body", 700)
	var slot := str(it.get("slot", "weapon"))
	var st: Array = STAT.get(slot, ["attack", "ATK"])
	var power := int(it.get("power", 0))
	Sheet.put(row, "%s +%s   ·   Power %s" % [st[1], UI.grouped(int(it.get(st[0], 0))), UI.grouped(power)],
		Rect2(176, 98, right - 176, 32), 22, UI.DIM)
	var note := ""
	var col := UI.DIM
	var worn_by := str(it.get("worn_by", ""))
	if compare and not worn.is_empty():
		var theirs := int(worn.get("power", 0))
		if power > theirs:
			note = "Stronger than what you wear"
			col = UI.GREEN
		elif power < theirs:
			note = "Weaker than what you wear"
			col = UI.RED
		else:
			note = "As strong as what you wear"
	if worn_by != "" and compare:
		note = ("Worn by " + worn_by) + (("  ·  " + note) if note != "" else "")
		col = UI.GOLD if col == UI.DIM else col
	if note != "":
		Sheet.put(row, note, Rect2(176, 130, right - 176, 30), 20, col)
	return row
