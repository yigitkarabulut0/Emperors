extends SceneTree
## The cards a thumb actually works on: nothing overlaps, every name fits its
## box, and every button is big enough to hit.
##
## The two-column inventory card failed all three quietly. Its buttons were 43
## units tall, which on the phone is 20 pt against the 44 pt Apple asks for; its
## name was set at 20 units, 9.4 pt against 17 pt of body text; and the shop's
## name box held one line while the label wrapped, so a long name laid its
## second line across the type icon underneath.
##
## Run: godot --headless --path client --script tests/cards_usable.gd

## The design grid is 941 wide and the phone draws it across the screen, so a
## design unit is this many points. 44 pt is 94 units.
const PT_PER_UNIT := 440.0 / 941.0
const MIN_TAP_PT := 44.0

## screen -> template id. Both hold one item and its actions.
const CARDS := {"inventory": "item_card", "shop": "offer_card"}

## Parts that are meant to sit on top of another, and the part they sit on.
const OVER := {"painting": "tile", "price": "price_pill"}

## A part that other parts are allowed to read over, the way a caption reads
## over a photograph.
const GROUNDS := ["frame", "tile", "painting"]

## The longest text each field really has to carry, from balance/items.json.
var _longest_name := ""

var _fails: int = 0
var _L: GDScript


func _initialize() -> void:
	await process_frame
	_L = load("res://scripts/ui/layout.gd")
	_longest_name = _longest_item_name()
	print("  longest item name: \"%s\"" % _longest_name)
	for screen in CARDS:
		_no_part_overlaps_another(screen, CARDS[screen])
		_every_button_is_thumb_sized(screen, CARDS[screen])
		_the_name_fits(screen, CARDS[screen])
	if _fails > 0:
		print("FAIL  %d check(s)" % _fails)
		quit(1)
		return
	print("PASS  cards fit their text and their buttons take a thumb")
	quit()


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL  " + msg)


func _parts(screen: String, tpl_id: String) -> Array:
	var tpl: Dictionary = _L.find(screen, tpl_id)
	return tpl.get("parts", [])


## No two parts may share pixels unless one is painted on the other on purpose.
func _no_part_overlaps_another(screen: String, tpl_id: String) -> void:
	var parts := _parts(screen, tpl_id)
	for i in parts.size():
		for j in range(i + 1, parts.size()):
			var a: Dictionary = parts[i]
			var b: Dictionary = parts[j]
			var ai := str(a.get("id", ""))
			var bi := str(b.get("id", ""))
			var ra: Rect2 = _L.rect_of(a)
			var rb: Rect2 = _L.rect_of(b)
			if not ra.intersects(rb):
				continue
			# A frame, a tile or a painting is a ground. Paint may read over one
			# freely -- a level reads across the foot of its painting on purpose
			# -- and a control may sit fully inside one, which is every button on
			# its card. A control only PARTLY on a ground is the thing worth
			# catching: a button hanging off the edge of the card it belongs to.
			if _is_ground(a) and (not _is_control(b) or ra.encloses(rb)):
				continue
			if _is_ground(b) and (not _is_control(a) or rb.encloses(ra)):
				continue
			# A button that keeps its texture's size is declaring that its rect
			# is a tap target rather than a picture, so it is allowed to reach
			# over paint. Over another control it is not: two tap targets that
			# share pixels means one of them cannot be pressed.
			if _is_reach(a) and not _is_control(b):
				continue
			if _is_reach(b) and not _is_control(a):
				continue
			if OVER.get(ai, "?") == bi or OVER.get(bi, "?") == ai:
				continue
			_fail("%s/%s: %s %s overlaps %s %s" % [screen, tpl_id, ai, ra, bi, rb])


func _is_ground(p: Dictionary) -> bool:
	return str(p.get("id", "")) in GROUNDS


func _is_reach(p: Dictionary) -> bool:
	return str(p.get("kind", "")) == "button" and bool(p.get("keep_texture_size", false))


func _is_control(p: Dictionary) -> bool:
	return str(p.get("kind", "")) in ["button", "hotspot"]


func _every_button_is_thumb_sized(screen: String, tpl_id: String) -> void:
	for p in _parts(screen, tpl_id):
		if str(p.get("kind", "")) != "button":
			continue
		var r: Rect2 = _L.rect_of(p)
		var h := r.size.y * PT_PER_UNIT
		var w := r.size.x * PT_PER_UNIT
		if h < MIN_TAP_PT or w < MIN_TAP_PT:
			_fail("%s/%s: %s is %.0fx%.0f pt on the phone, under the %.0f pt a thumb needs"
				% [screen, tpl_id, str(p.get("id", "")), w, h, MIN_TAP_PT])


## The longest name the game can actually produce must fit the box at a size a
## person can read -- not by being shrunk until it does.
func _the_name_fits(screen: String, tpl_id: String) -> void:
	for p in _parts(screen, tpl_id):
		if str(p.get("id", "")) != "name":
			continue
		var r: Rect2 = _L.rect_of(p)
		var size := int(p.get("size", 20))
		var f := _font(int(p.get("weight", 500)))
		var m: Vector2 = f.get_multiline_string_size(
			_longest_name, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, size)
		if m.y > r.size.y:
			_fail("%s/%s: \"%s\" needs %.0f units of height at size %d, the box gives %.0f"
				% [screen, tpl_id, _longest_name, m.y, size, r.size.y])
		if size * PT_PER_UNIT < 11.0:
			_fail("%s/%s: the name is set at %.1f pt, too small to read"
				% [screen, tpl_id, size * PT_PER_UNIT])


func _font(weight: int) -> FontVariation:
	var f := FontVariation.new()
	f.base_font = load("res://assets/fonts/EBGaramond[wght].ttf")
	f.variation_opentype = {"wght": weight + 100}
	return f


func _longest_item_name() -> String:
	var fh := FileAccess.open("res://../balance/items.json", FileAccess.READ)
	if fh == null:
		return "The Unbroken Breastplate"
	var d: Variant = JSON.parse_string(fh.get_as_text())
	var best := ""
	for it in d.get("definitions", []):
		var n := str(it.get("name", ""))
		if n.length() > best.length():
			best = n
	return best
