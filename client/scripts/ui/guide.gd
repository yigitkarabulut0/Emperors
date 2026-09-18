class_name Guide
extends CanvasLayer
## THE GUIDE -- the Royal Steward walks a new lord through the first ten
## minutes: work the vineyard, reach level two, take the day's gift, open the
## tax cart, buy a blade and wear it, spend the points, build, recruit, and see
## off Karel the Bandit (docs/FRONTEND.md, "The guide").
##
## The server holds the step (snapshot.guide): which one, its words, the
## control to point at, and whether its deed is done (`ready`). This overlay
## only shows it. It was a five-page tour in a Sheet, read once and gone; now
## the game itself is the lesson, one real action at a time.
##
## What it draws, all from guide.png and ftue_sheet.png (art/slices/guide.json,
## ftue.json; laid out by client/layout/guide.json):
##
##  - the screen dimmed except a soft spotlight round the step's control, which
##    alone takes a tap (the dim refuses every other one);
##  - the steel gauntlet on that control, pressing, a gold ring spreading from
##    its fingertip; while the control is not on screen, the gold arrow on the
##    way there instead -- the tab's rail entry, or the diamond pill that opens
##    the day's reward;
##  - the steward's bust behind the speech scroll, which carries the step's
##    title and words; the steward stands on the side away from the control and
##    looks toward it, and the scroll sits in the half of the screen the control
##    is not in;
##  - SKIP, always, at the scroll's other end (it asks first).
##
## A tap step (the welcome, the farewell) and a step whose deed is done (the
## steward's `done` words) dim the whole screen and wait for a tap anywhere.
## A step whose control cannot be found anywhere never dims: the lord is never
## shut in with nothing to press. While a page, a dialog, a ceremony or the
## battle lies over the game -- one the control is not in -- the guide stands
## aside and comes back when it closes.

const SCREEN := "guide"
const LAYER := 84
## The dim: the game's navy, most of the way -- further while the steward
## waits on a tap, when nothing under it is to be pressed.
const DIM := Color(0.035, 0.082, 0.118, 0.74)
const DIM_WAITING := Color(0.035, 0.082, 0.118, 0.84)
const HOLE_PAD := 14.0
const HOLE_RADIUS := 20.0
const HOLE_FEATHER := 26.0
## The scroll high (its top this far under the notch: the steward's head clears
## the pills and their timers) or low (its foot this far above the screen's).
const SPEECH_HIGH_TOP := 380.0
const SPEECH_LOW_FOOT := 28.0
## The story card rides between the pills and the steward's head.
const STORY_TOP := 110.0
## "TAP TO CONTINUE", over the scroll's upper edge between the steward and SKIP.
const HINT_SIZE := 22
const HINT_H := 34.0
const HINT_UP := 52.0
## The gauntlet: the fingertip lands a little below and right of the
## control's centre, so the word on a plate stays readable, and hovers this
## far off it before each press.
const TIP_INTO := Vector2(0.16, 0.22)
const HOVER := 10.0
const PRESS_EVERY := 1.25
const PRESS_FOR := 0.3
const RING_FROM := 0.35
## The arrow's tip rests just inside the entry it names, and bobs along its own
## line.
const ARROW_INTO := Vector2(0.3, 0.25)
const ARROW_BOB := 9.0
const EDGE := 4.0
const TITLE_SIZE := 25
const TITLE_MIN := 18
const BODY_SIZE := 24
const BODY_MIN := 20
const FALLBACK_DONE := "Well done, my lord."
## What the steward hands over (the purse on the way to the market, the
## parting gift): the Royal Delivery's plate.
const DELIVERY_TITLE := "FROM YOUR STEWARD"
## A control only reached through another: the chests card opens the cart's
## view, whose OPEN is the step's real control.
const DEEPER := {"court.chests": "chests.open"}
## A control whose page is opened from somewhere other than its tab's rail
## entry: the day's reward, from the diamond pill.
const APPROACH := {"daily.claim": "pill.diamonds"}

static var _live: Guide = null

var _root: Control
var _dim: _Dim
var _dim_mat: ShaderMaterial
var _story: TextureRect
var _speech: Control
var _parts: Dictionary = {}
var _scroll_hit: Button
var _hint: Label
var _hand: TextureRect
var _press: TextureRect
var _ring: TextureRect
var _arrow: TextureRect
var _hand_tip := Vector2.ZERO
var _press_tip := Vector2.ZERO
var _arrow_tip := Vector2.ZERO
var _speech_x := 30.0
var _body_box := Rect2()

var _g: Dictionary = {}
var _step := ""
## A step the server has already moved past, whose done words are still to be
## read (Karel's: the fight itself finishes the step). Shown until a tap.
var _held: Dictionary = {}
## shop.offer and family.gear name a set; which one of it, once asked.
var _pick := ""
var _target: Control = null
var _target_name := ""
var _scrolled_to: Control = null
var _covered := false
var _busy := false
var _t := 0.0
var _canvas := Vector2(941, 1672)


## Shows the guide while the server says it is running; one at a time.
static func start(_host: Node = null) -> Guide:
	if not bool(GameState.guide().get("active", false)):
		return null
	if _live != null and is_instance_valid(_live) and _live.is_inside_tree():
		_live.sync()
		return _live
	var g: Guide = load("res://scripts/ui/guide.gd").new()
	Nav.overlay_parent().add_child(g)
	_live = g
	return g


## The guide on screen, if any.
static func live() -> Guide:
	return _live if _live != null and is_instance_valid(_live) else null


static func active() -> bool:
	return bool(GameState.guide().get("active", false))


## On the bandit step the Attack tab opens for Karel's card, whatever its
## level gate says.
static func bandit_step() -> bool:
	var g := GameState.guide()
	return bool(g.get("active", false)) and str(g.get("step", "")) == "bandit"


## Where the gauntlet points for a step, most wanted first: the step's own
## control once it can be seen, else the way to it. Below the step's level,
## Collect's first job, which is how a level is earned.
static func chain(g: Dictionary, level: int) -> Array:
	var target := str(g.get("target", ""))
	var tab := str(g.get("tab", ""))
	if int(g.get("min_level", 0)) > level:
		return ["collect.job0", "rail.collect"]
	var out: Array = []
	if DEEPER.has(target):
		out.append(DEEPER[target])
	if target != "":
		out.append(target)
	if APPROACH.has(target):
		out.append(APPROACH[target])
	elif tab != "":
		out.append("rail." + tab)
	return out


## Whether a name in the chain is the way to the control rather than the
## control: those take the arrow, not the gauntlet.
static func is_approach(name: String) -> bool:
	return name.begins_with("rail.") or name == "pill.diamonds"


## The scroll goes where the control is not: high when the control is in the
## lower half.
static func speech_high(target: Rect2, canvas: Vector2) -> bool:
	return target.size != Vector2.ZERO and target.get_center().y >= canvas.y / 2.0


## The steward stands on the side away from the control, looking at it.
static func steward_left(target: Rect2, canvas: Vector2) -> bool:
	return target.size == Vector2.ZERO or target.get_center().x >= canvas.x / 2.0


## Where a pointer whose fingertip is `tip` in its `size` goes so the tip
## lands on `at`: mirrored across when it would run off the right edge, and
## upside down when it would run off the foot. {pos, flip_h, flip_v}.
static func point_at(at: Vector2, size: Vector2, tip: Vector2, canvas: Vector2) -> Dictionary:
	var flip_h := at.x + (size.x - tip.x) > canvas.x - EDGE
	var flip_v := at.y + (size.y - tip.y) > canvas.y - EDGE
	var tx := size.x - tip.x if flip_h else tip.x
	var ty := size.y - tip.y if flip_v else tip.y
	return {"pos": at - Vector2(tx, ty), "flip_h": flip_h, "flip_v": flip_v}


func _ready() -> void:
	layer = LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_dim = _Dim.new()
	_dim.color = DIM
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim_mat = ShaderMaterial.new()
	_dim_mat.shader = _spotlight_shader()
	_dim.material = _dim_mat
	_dim.gui_input.connect(_on_dim_input)
	_root.add_child(_dim)

	var story := Layout.element(SCREEN, "story")
	_story = UI.image(str(story.get("asset", "")), Layout.rect_of(story))
	_story.visible = false
	_root.add_child(_story)

	var tpl := Layout.element(SCREEN, "speech")
	_speech_x = Layout.rect_of(tpl).position.x
	var built := Layout.instantiate(tpl)
	_speech = built["node"]
	_parts = built["parts"]
	_root.add_child(_speech)
	# The scroll takes a tap on a tap step and on a step done; SKIP stays above it.
	_scroll_hit = UI.hotspot(Rect2(_parts["scroll"].position, _parts["scroll"].size))
	_scroll_hit.pressed.connect(_continue)
	_speech.add_child(_scroll_hit)
	for id in ["skip_r", "skip_l"]:
		_speech.move_child(_parts[id], -1)
		(_parts[id] as BaseButton).pressed.connect(_skip)
	for id in ["title", "level", "body"]:
		(_parts[id] as Label).set_meta("box_x", (_parts[id] as Control).position.x)
	_body_box = Layout.rect_of(Layout.find(SCREEN, "body"))
	_hint = UI.label("TAP TO CONTINUE", HINT_SIZE, UI.GOLD, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	_hint.visible = false
	_speech.add_child(_hint)

	_arrow = _pointer("arrow")
	_ring = _pointer("ring")
	_hand = _pointer("hand")
	_press = _pointer("hand_press")
	_hand_tip = _tip("hand")
	_press_tip = _tip("hand_press")
	_arrow_tip = _tip("arrow")

	GameState.changed.connect(sync)
	var watch := Timer.new()
	watch.wait_time = 0.25
	watch.timeout.connect(_watch)
	add_child(watch)
	watch.start()
	sync()


func _pointer(id: String) -> TextureRect:
	var e := Layout.element(SCREEN, id)
	var t := UI.image(str(e.get("asset", "")), Layout.rect_of(e))
	t.visible = false
	_root.add_child(t)
	return t


func _tip(id: String) -> Vector2:
	var tip: Array = Layout.element(SCREEN, id).get("tip", [0, 0])
	return Vector2(float(tip[0]), float(tip[1]))


func _exit_tree() -> void:
	if _live == self:
		_live = null


# --- the step ----------------------------------------------------------------------------

## Takes the server's step and paints it. Called on every new snapshot.
func sync() -> void:
	if not is_inside_tree():
		return
	var g := GameState.guide()
	if not bool(g.get("active", false)):
		_end()
		return
	var step := str(g.get("step", ""))
	if step != _step:
		_step = step
		_pick = ""
		_scrolled_to = null
		_t = 0.0
		if str(g.get("target", "")) in ["shop.offer", "family.gear"]:
			_resolve_pick(g)
	_g = g
	_paint()


## The step on the scroll: the one held for its done words, else the server's.
func _view() -> Dictionary:
	return _held if not _held.is_empty() else _g


func _is_tap() -> bool:
	var v := _view()
	return bool(v.get("tap", false)) or str(v.get("kind", "")) == "tap"


func _is_done() -> bool:
	return bool(_view().get("ready", false)) and not _is_tap()


## Keeps a finished step's done words on the scroll after the server has moved
## on, until the lord taps: the bandit's, whose fight is its own end.
static func hold_done(step: Dictionary) -> void:
	var g := live()
	if g == null or str(step.get("done", "")) == "":
		return
	g._held = step.duplicate()
	g._held["ready"] = true
	g._held["tap"] = false
	g._paint()


func _level() -> int:
	return int(GameState.player().get("level", 1))


## The words: the step's own, or the steward's once its deed is done, and
## "LEVEL 3 OF 4" beside the title while the step waits on a level.
func _paint() -> void:
	var title: Label = _parts["title"]
	var body: Label = _parts["body"]
	var lvl: Label = _parts["level"]
	var v := _view()
	title.text = str(v.get("title", ""))
	UI.fit_line(title, TITLE_SIZE, TITLE_MIN)
	var words := str(v.get("text", ""))
	if _is_done():
		words = str(v.get("done", ""))
		if words == "":
			words = FALLBACK_DONE
	var need := int(v.get("min_level", 0))
	lvl.text = ("LEVEL %d OF %d" % [_level(), need]) if need > _level() and not _is_done() else ""
	UI.fit_line(lvl, 19, 14)
	body.text = words
	_fit_body(body)
	_story.visible = _held.is_empty() and _step == "welcome"
	_hint.visible = _is_tap() or _is_done()
	_scroll_hit.visible = _hint.visible


## The words at the largest size from BODY_SIZE at which they fit the
## parchment's box, then evened out (UI.balance_lines). Measured against the
## box the layout gives, not the label: a wrapping Label grows to its words.
func _fit_body(body: Label) -> void:
	var s := body.label_settings
	var size := BODY_SIZE
	while size > BODY_MIN:
		var m := s.font.get_multiline_string_size(body.text, HORIZONTAL_ALIGNMENT_LEFT, _body_box.size.x, size)
		if m.y <= _body_box.size.y:
			break
		size -= 1
	s.font_size = size
	body.position = _body_box.position
	body.size = _body_box.size
	UI.balance_lines(body)


## Which offer to buy (the cheapest the lord can still take) and which gear
## tile to open (a slot the hero has nothing in but the bag has something
## for), from the server's own lists.
func _resolve_pick(g: Dictionary) -> void:
	var target := str(g.get("target", ""))
	var step := str(g.get("step", ""))
	if target == "shop.offer":
		var res: Api.Response = await Api.get_json("/v1/shop")
		if res.ok and _step == step:
			_pick = "shop.offer.%d" % cheapest_offer(res.data.get("offers", []))
	elif target == "family.gear":
		var res: Api.Response = await Api.get_json("/v1/inventory")
		if res.ok and _step == step:
			_pick = "family.gear." + gear_slot(res.data.get("items", []))


## The index of the cheapest offer not yet bought (0 when none is left).
static func cheapest_offer(offers: Array) -> int:
	var best := -1
	var price := 0
	for i in offers.size():
		var o: Dictionary = offers[i]
		if bool(o.get("purchased", false)):
			continue
		var p := int(o.get("price", 0))
		if best < 0 or p < price:
			best = i
			price = p
	return maxi(best, 0)


## The gear slot to open: one the hero has nothing in and the bag has
## something for; else any the bag has something for; else the weapon.
static func gear_slot(items: Array) -> String:
	var worn := {}
	var held := {}
	for it in items:
		if not (it is Dictionary):
			continue
		var slot := str(it.get("slot", ""))
		if str(it.get("equipped_on", "")) == "hero":
			worn[slot] = true
		elif str(it.get("equipped_on", "")) == "":
			held[slot] = true
	for slot in ["weapon", "armor", "horse"]:
		if held.has(slot) and not worn.has(slot):
			return slot
	for slot in ["weapon", "armor", "horse"]:
		if held.has(slot):
			return slot
	return "weapon"


## The first control of the step's chain that is on screen, and its name.
func _find_target() -> Array:
	if _is_tap() or _is_done():
		return [null, ""]
	for n in chain(_g, _level()):
		var name := str(n)
		if name in ["shop.offer", "family.gear"]:
			if _pick == "":
				continue
			name = _pick
		var c := GuideTargets.find(name)
		if c != null:
			return [c, name]
	return [null, ""]


# --- following the game ------------------------------------------------------------------

## Four times a second: whether something lies over the game, and which
## control the step is on now.
func _watch() -> void:
	if not is_inside_tree():
		return
	var found := _find_target()
	_target = found[0]
	_target_name = str(found[1])
	if _target != null and _target != _scrolled_to:
		_scrolled_to = _target
		_scroll_into_view(_target)
	_covered = _covering_layer()
	_root.visible = not _covered


## A page, dialog, ceremony or battle over the game that the step's control is
## not in. The toast's layer does not count.
func _covering_layer() -> bool:
	for n in Nav.overlay_parent().find_children("*", "CanvasLayer", true, false):
		var cl: CanvasLayer = n
		if cl == self or not cl.visible or cl.layer < 50 or cl.layer >= 110:
			continue
		if _target != null and cl.is_ancestor_of(_target):
			continue
		for c in cl.get_children():
			if c is CanvasItem and (c as CanvasItem).visible:
				return true
	return false


## A control below the fold of its list is scrolled up into view, as far as
## it takes: the lord cannot scroll while the dim is up.
func _scroll_into_view(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
			return
		p = p.get_parent()


func _process(dt: float) -> void:
	if not _root.visible:
		return
	_t += dt
	_canvas = _root.size if _root.size.x > 0.0 else _canvas
	var has := _target != null and is_instance_valid(_target) and _target.is_visible_in_tree()
	var r := _target.get_global_rect() if has else Rect2()
	var waiting := _is_tap() or _is_done()
	# Dimmed with a hole round the control, dimmed whole while it waits for a
	# tap, and not at all with nothing to point at.
	_dim.visible = waiting or has
	_dim.color = DIM_WAITING if waiting else DIM
	_dim.hole = r.grow(HOLE_PAD) if has else Rect2()
	_dim_mat.set_shader_parameter("hole", Vector4(_dim.hole.position.x, _dim.hole.position.y,
		_dim.hole.size.x, _dim.hole.size.y))
	_place_speech(r if has else Rect2())
	var approach := has and is_approach(_target_name)
	_arrow.visible = has and approach
	_hand.visible = false
	_press.visible = false
	_ring.visible = false
	if has and approach:
		_place_arrow(r)
	elif has:
		_place_hand(r)
	if _hint.visible:
		_hint.modulate.a = 0.55 + 0.45 * absf(sin(_t * 2.4))


func _place_speech(r: Rect2) -> void:
	var top := UI.safe_top(_canvas)
	var scroll: Control = _parts["scroll"]
	var high := speech_high(r, _canvas)
	var y := top + SPEECH_HIGH_TOP if high else _canvas.y - SPEECH_LOW_FOOT - scroll.size.y
	_speech.position = Vector2(_speech_x, roundf(y))
	var left := steward_left(r, _canvas)
	(_parts["steward_r"] as CanvasItem).visible = left
	(_parts["steward_l"] as CanvasItem).visible = not left
	(_parts["skip_r"] as CanvasItem).visible = left
	(_parts["skip_l"] as CanvasItem).visible = not left
	# The hint between the steward's shoulder and SKIP.
	var steward: Control = _parts["steward_r" if left else "steward_l"]
	var skip: Control = _parts["skip_r" if left else "skip_l"]
	var from := steward.position.x + steward.size.x if left else skip.position.x + skip.size.x
	var to := skip.position.x if left else steward.position.x
	UI.place(_hint, Rect2(from, -HINT_UP - HINT_H / 2.0, maxf(0.0, to - from), HINT_H))
	if _story.visible:
		# Between the pills and the steward's head, centred in what is left.
		var head := _speech.position.y + steward.position.y
		var room := Rect2(0, top + STORY_TOP, _canvas.x, head - (top + STORY_TOP))
		_story.position = Vector2(roundf((_canvas.x - _story.size.x) / 2.0),
			roundf(room.position.y + maxf(0.0, (room.size.y - _story.size.y) / 2.0)))


## The gauntlet on the control: hovering, then pressing, the ring spreading
## from the fingertip.
func _place_hand(r: Rect2) -> void:
	var at := r.get_center() + r.size * TIP_INTO
	at = Vector2(clampf(at.x, r.position.x, r.end.x), clampf(at.y, r.position.y, r.end.y))
	var phase := fmod(_t, PRESS_EVERY)
	var pressing := phase > PRESS_EVERY - PRESS_FOR
	if pressing:
		var p := point_at(at, _press.size, _press_tip, _canvas)
		_show_pointer(_press, p)
		var k := (phase - (PRESS_EVERY - PRESS_FOR)) / PRESS_FOR
		var s := lerpf(RING_FROM, 1.0, k)
		_ring.visible = true
		_ring.pivot_offset = _ring.size / 2.0
		_ring.scale = Vector2(s, s)
		_ring.position = (at - _ring.size / 2.0).round()
		_ring.modulate.a = 1.0 - k * 0.8
	else:
		var p := point_at(at, _hand.size, _hand_tip, _canvas)
		# Hovers off along its own arm, then comes in.
		var away := Vector2(-1.0 if bool(p["flip_h"]) else 1.0, -1.0 if bool(p["flip_v"]) else 1.0).normalized()
		p["pos"] = (p["pos"] as Vector2) + away * HOVER * (0.5 + 0.5 * sin(phase / (PRESS_EVERY - PRESS_FOR) * PI))
		_show_pointer(_hand, p)


## The arrow toward the way there (a rail entry, the diamond pill).
func _place_arrow(r: Rect2) -> void:
	var at := r.get_center() + r.size * ARROW_INTO
	var p := point_at(at, _arrow.size, _arrow_tip, _canvas)
	var along := Vector2(-1.0 if bool(p["flip_h"]) else 1.0, -1.0 if bool(p["flip_v"]) else 1.0).normalized()
	p["pos"] = (p["pos"] as Vector2) + along * ARROW_BOB * (0.5 + 0.5 * sin(_t * 4.0))
	_show_pointer(_arrow, p)


func _show_pointer(t: TextureRect, p: Dictionary) -> void:
	t.visible = true
	t.flip_h = bool(p["flip_h"])
	t.flip_v = bool(p["flip_v"])
	t.position = (p["pos"] as Vector2).round()


# --- taps --------------------------------------------------------------------------------

func _on_dim_input(e: InputEvent) -> void:
	var up := (e is InputEventMouseButton and not (e as InputEventMouseButton).pressed \
		and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \
		or (e is InputEventScreenTouch and not (e as InputEventScreenTouch).pressed)
	if not up:
		return
	if _is_tap() or _is_done():
		_continue()
	else:
		# A tap beside the control: the gauntlet presses again, at once.
		_t = PRESS_EVERY - PRESS_FOR


## On: a tap step is done by the tap; a done step moves to the next. What the
## step hands over plays in the Royal Delivery.
func _continue() -> void:
	if not _held.is_empty():
		# The held words are read: on to the step the server is on.
		_held = {}
		_paint()
		return
	if _busy or not (_is_tap() or _is_done()):
		return
	_busy = true
	var step := _step
	var res: Api.Response = await Api.post_json("/v1/guide/advance", {"step": step})
	_busy = false
	if res.ok:
		var snap: Variant = res.data.get("snapshot", null)
		var lines: Array = res.data.get("lines", [])
		if snap is Dictionary:
			GameState.adopt_async(snap)
		if not lines.is_empty():
			Ceremony.delivery(Nav.overlay_parent(), {"title": DELIVERY_TITLE, "lines": lines})
	elif res.code in ["guide_moved", "guide_not_ready"]:
		await GameState.refresh()
	else:
		GameState.toast(res.error)


func _skip() -> void:
	if _busy:
		return
	_busy = true
	var ok: bool = await Dialog.ask(self, {"title": "Leave the steward?",
		"body": "He will leave you to find your own way through the realm, and his parting gift is kept for those who finish with him.",
		"confirm_text": "Skip", "cancel_text": "Stay", "danger": true})
	if not ok:
		_busy = false
		return
	var res: Api.Response = await Api.post_json("/v1/guide/skip", {})
	_busy = false
	if res.ok:
		var snap: Variant = res.data.get("snapshot", null)
		if snap is Dictionary:
			GameState.adopt_async(snap)
		_end()
	else:
		GameState.toast(res.error)


func _end() -> void:
	if _live == self:
		_live = null
	if is_inside_tree():
		queue_free()


# --- Karel the Bandit --------------------------------------------------------------------

## The bandit step's fight, from the card on the Attack tab: a real battle the
## server resolved (the first of its seeds the lord wins), played on the
## battle screen with Karel's face. Nobody's gold is taken; his purse is the
## result board's gold.
static func fight_bandit(_host: Node) -> void:
	var g := GameState.guide().duplicate()
	var res: Api.Response = await Api.post_json("/v1/guide/bandit", {})
	if not res.ok:
		if res.code in ["guide_moved", "guide_not_ready"]:
			await GameState.refresh()
		else:
			GameState.toast(res.error)
		return
	var snap: Variant = res.data.get("snapshot", null)
	if snap is Dictionary:
		GameState.adopt_async(snap)
	var b: Dictionary = g.get("bandit", {})
	var replay: CanvasLayer = load("res://scenes/battle/battle_replay.gd").new()
	replay.setup(res.data, {"name": str(b.get("name", "")), "avatar": str(b.get("avatar", "bandit"))})
	Nav.overlay_parent().add_child(replay)
	await replay.finished
	# The fight ends the step on the server; its done words are still said.
	if str(GameState.guide().get("step", "")) != str(g.get("step", "")):
		hold_done(g)


# --- the spotlight -----------------------------------------------------------------------

static func _spotlight_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
uniform vec4 hole = vec4(0.0);
uniform float radius = %.1f;
uniform float feather = %.1f;
varying vec2 local;
void vertex() {
	local = VERTEX;
}
void fragment() {
	float a = 1.0;
	if (hole.z > 0.0) {
		vec2 p = local;
		vec2 c = hole.xy + hole.zw * 0.5;
		vec2 q = abs(p - c) - hole.zw * 0.5 + vec2(radius);
		float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
		a = smoothstep(0.0, feather, d);
	}
	COLOR = vec4(COLOR.rgb, COLOR.a * a);
}
""" % [HOLE_RADIUS, HOLE_FEATHER]
	return s


## The dim takes every tap but the ones in its hole, which fall through to the
## control under it.
class _Dim:
	extends ColorRect
	var hole := Rect2()

	func _has_point(point: Vector2) -> bool:
		if hole.size.x > 0.0 and hole.has_point(point):
			return false
		return Rect2(Vector2.ZERO, size).has_point(point)
