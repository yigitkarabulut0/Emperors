extends RefCounted
## THE CART'S LOAD -- behind the Tax Cart's (i): what a cart may carry, and
## how often each thing comes.
##
## Every row is one of the server's published prizes (GET /v1/cart `odds`): its
## picture, its name, what it pays (its reward lines, resolved for this lord),
## and its chance, from the basis points the server rolls with. The chances
## are the server's own and add up to the whole; the page never works one out.
## A plain page: the painted header scenes each belong to one information page
## (tests/page_headers.gd), and the rows carry the prizes' own paintings.

const ROW_H := 104.0
const ICON := 76.0


## `cart` is the /v1/cart answer.
static func open(host: Node, cart: Dictionary) -> Sheet:
	var s := Sheet.open(host, "THE CART'S LOAD", "What each cart may carry, and how often.")
	var rp: GDScript = load("res://scenes/army/reroll_panel.gd")
	var view: GDScript = load("res://scenes/court/chests_view.gd")
	var odds: Array = cart.get("odds", [])
	if odds.is_empty():
		s.paragraph("The cart's load could not be read. Close this and try again in a moment.", 22, UI.DIM)
	else:
		for o in odds:
			if not (o is Dictionary):
				continue
			var row := s.slot(ROW_H)
			var lines: Array = o.get("lines", [])
			# The prize in its own painting: a purse, the scroll, the gear chest.
			var shown: Array = view.call("dressed_lines", str(o.get("id", "")), lines)
			var first: Dictionary = shown[0] if not shown.is_empty() else {}
			var pic := TextureRect.new()
			pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pic.texture = Art.reward_line_icon(first) if not first.is_empty() else Art.tex("icons/reward_crown")
			UI.place(pic, Rect2(16, (ROW_H - ICON) / 2.0, ICON, ICON))
			row.add_child(pic)
			# Gear on its rarity's velvet, as every tile of gear is drawn.
			ItemGround.for_line(pic, first, Rect2(pic.position, pic.size))
			var x := 16.0 + ICON + 18.0
			var pct_w := 132.0
			var w := s.inner_w - x - pct_w - 16.0
			var name := str(o.get("name", ""))
			var words := what(lines)
			if words.to_lower() == name.to_lower():
				# A prize that is its own line (the Small Flask): its name alone,
				# on the row's middle, rather than the same words twice.
				Sheet.put(row, name, Rect2(x, 0, w, ROW_H), 26, UI.GOLD, "title", 700)
			else:
				Sheet.put(row, name, Rect2(x, 12, w, 40), 26, UI.GOLD, "title", 700)
				Sheet.put(row, words, Rect2(x, 52, w, 36), 22, UI.INK, "body", 600)
			Sheet.put(row, rp.percent(int(o.get("bp", 0))), Rect2(s.inner_w - pct_w - 16.0, 0, pct_w, ROW_H), 32,
				UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_RIGHT)
		s.paragraph(terms(cart), 21, UI.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	s.add_close()
	return s


## A prize's lines as one line of words: "2,400 gold", "A Small Flask",
## "Uncommon gear".
static func what(lines: Array) -> String:
	var words: Array = []
	for l in lines:
		if l is Dictionary and str(l.get("text", "")) != "":
			words.append(str(l["text"]))
	return ", ".join(words)


## The terms under the table, in the server's numbers: how often a cart comes,
## how many wait at most, and that a cart's load is set before it is opened.
static func terms(cart: Dictionary) -> String:
	var view: GDScript = load("res://scenes/court/chests_view.gd")
	var interval := int(cart.get("interval", 0))
	var cap := int(cart.get("cap", 0))
	var out := ""
	if interval > 0 and cap > 0:
		out = "A cart comes %s, and %d can wait in the yard; a Cart Writ opens one more. " % [
			str(view.call("every", interval)), cap]
	return out + "What a cart carries is sealed before it reaches the gate."
