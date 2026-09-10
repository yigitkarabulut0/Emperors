extends RefCounted
## The first-run tour: five pages, one for each part of the realm, shown once
## to a new lord and never again.
##
## A new player arrived on Collect with seven tabs, three currencies and no
## word about any of them. Each page is the screen's own painted header -- its
## title painted in -- and two sentences on what the screen is for and when it
## opens.

const IMAGE_H := 330.0
const TOP_CUT := 92.0      ## the band where the pills were painted out of each header
const STEPS := [
	["collect/header", "COLLECT", "Spend energy on the tasks of the realm to earn gold and experience. Energy returns on its own, and each new level fills it at once."],
	["family/header", "YOUR FAMILY", "Put your stat points into your hero, wear the best gear you own, and build estates that earn gold while you are away."],
	["army/header", "YOUR ARMY", "Recruit soldiers, give them gear and reroll their tier. Your army's might is what wins a raid."],
	["attack/header", "RAIDS", "From level 10, raid rivals for the gold they carry -- and strike back at anyone who raids you. Gold in the Royal Treasury cannot be taken."],
	["kingdom/header", "KINGDOMS", "At level 20, join a kingdom or found your own, and grow it together with other lords."],
]


static func open(host: Node) -> Sheet:
	var s := Sheet.open(host, "WELCOME, MY LORD")
	s.set_meta("step", 0)
	_paint(s)
	return s


static func _paint(s: Sheet) -> void:
	s.clear_body()
	for c in s.foot.get_children():
		c.queue_free()
	var i := int(s.get_meta("step"))
	var step: Array = STEPS[i]
	var tex: Texture2D = Art.tex(str(step[0]))
	var k := s.inner_w / tex.get_width()
	# As tall as the header has painting below the cut band, up to IMAGE_H.
	var h := minf(IMAGE_H, (tex.get_height() - TOP_CUT) * k)
	var frame := Control.new()
	frame.clip_contents = true
	frame.custom_minimum_size = Vector2(s.inner_w, h)
	s.body.add_child(frame)
	var img := UI.image(str(step[0]), Rect2(0, -TOP_CUT * k, s.inner_w, tex.get_height() * k))
	frame.add_child(img)
	frame.add_child(UI.image("inventory/frame_common", Rect2(0, 0, s.inner_w, h)))

	var t := UI.label(str(step[1]), 40, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	t.custom_minimum_size = Vector2(s.inner_w, 60)
	s.body.add_child(t)
	s.paragraph(str(step[2]), 28, UI.INK, HORIZONTAL_ALIGNMENT_CENTER)
	var dots := ""
	for n in STEPS.size():
		dots += ("●" if n == i else "○") + ("  " if n < STEPS.size() - 1 else "")
	s.paragraph(dots, 26, UI.GOLD_DIM, HORIZONTAL_ALIGNMENT_CENTER)

	var last := i == STEPS.size() - 1
	if not last:
		s.add_button("SKIP", "quiet", s.close)
	s.add_button("BEGIN" if last else "NEXT", "confirm", func() -> void:
		if last:
			s.close()
		else:
			s.set_meta("step", i + 1)
			_paint(s))
