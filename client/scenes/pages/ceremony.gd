extends CanvasLayer
## The moment a level or a mastery is reached: a burst of light, the title,
## what it brought, and a way on.
##
## A level-up was a toast -- "Level 31!" -- at the foot of the screen for two
## seconds, with the diamonds, the stat points and a newly opened tab left for
## the player to discover. A mastery milestone, a permanent raise on a job, had
## no moment at all. Both are the same shape here, and a second one waiting
## (a raid that levels twice, a collect that levels and masters) plays after
## the first is closed rather than on top of it.
##
## Everything it says is the server's: the level and the job from the new
## snapshot, the points and diamonds as the snapshot moved, the tabs by the
## server's own `unlocked` flags.

signal finished

const W := 941.0
const TAB_NAMES := {"jobs": "COLLECT", "hero": "FAMILY", "shop": "SHOP", "items": "INVENTORY",
	"estates": "THE ESTATES", "army": "ARMY", "bank": "THE TREASURY", "fight": "ATTACK", "house": "KINGDOM"}
const TAB_ICONS := {"jobs": "nav/collect", "hero": "nav/family", "shop": "nav/shop", "items": "nav/inventory",
	"army": "nav/army", "fight": "nav/attack", "house": "nav/kingdom"}

static var _queue: Array = []
static var _showing := false

var _cfg: Dictionary = {}
var _root: Control
var _glow: TextureRect


## Plays a level-up: {level, levels, points, gems, unlocked: [section ids]}.
static func level_up(cfg: Dictionary) -> void:
	cfg["kind"] = "level"
	_enqueue(cfg)


## Plays a mastery milestone: {job, collects, bonus_bp}.
static func mastery(cfg: Dictionary) -> void:
	cfg["kind"] = "mastery"
	_enqueue(cfg)


static func _enqueue(cfg: Dictionary) -> void:
	_queue.append(cfg)
	if not _showing:
		_next()


static func _next() -> void:
	if _queue.is_empty():
		_showing = false
		return
	_showing = true
	var c: CanvasLayer = load("res://scenes/pages/ceremony.gd").new()
	c._cfg = _queue.pop_front()
	c.finished.connect(_next)
	Nav.overlay_parent().add_child(c)


func _ready() -> void:
	layer = 95
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var back := ColorRect.new()
	back.color = Color(UI.GROUND, 0.9)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(back)
	_root.modulate.a = 0.0

	var h := UI.canvas_size(self).y
	var mid := minf(h, 2040.0) * 0.36

	# The light behind the title: the battle's own burst, turning slowly.
	_glow = UI.image("battle/impact", Rect2(W / 2.0 - 360, mid - 360, 720, 720))
	_glow.pivot_offset = Vector2(360, 360)
	_glow.modulate = Color(1.0, 0.85, 0.5, 0.55)
	_root.add_child(_glow)

	var lines: Array = []
	var title := ""
	var over := ""
	var art := ""
	if str(_cfg.get("kind")) == "level":
		over = "YOU HAVE REACHED"
		title = "LEVEL %d" % int(_cfg.get("level", 1))
		var pts := int(_cfg.get("points", 0))
		if pts > 0:
			lines.append(["+%d stat point%s to spend" % [pts, "" if pts == 1 else "s"], UI.INK])
		var gems := int(_cfg.get("gems", 0))
		if gems > 0:
			lines.append(["+%d diamonds" % gems, Color("#9FD8FF")])
		lines.append(["Energy refilled", UI.GREEN])
		for id in _cfg.get("unlocked", []):
			lines.append(["%s is open" % str(TAB_NAMES.get(id, str(id).to_upper())), UI.GOLD])
	else:
		var job: Dictionary = _cfg.get("job", {})
		over = "MASTERY"
		title = str(job.get("name", "")).to_upper()
		art = str(_cfg.get("art", ""))
		lines.append(["%s collects" % UI.grouped(int(_cfg.get("collects", 0))), UI.INK])
		var bp := int(_cfg.get("bonus_bp", 0))
		var pct := str(bp / 100) if bp % 100 == 0 else "%.1f" % (bp / 100.0)
		lines.append(["+%s%% gold on every one, for good" % pct, UI.GOLD])

	var y := mid - 150.0
	if art != "":
		var pic := UI.image(art, Rect2(W / 2.0 - 110, mid - 290, 220, 183))
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_root.add_child(pic)
		y = mid - 90.0
	var o := UI.label(over, 30, UI.DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(o, Rect2(0, y, W, 44))
	_root.add_child(o)
	var t := UI.label(title, 96, UI.GOLD, "title", 800, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(t, Rect2(40, y + 44, W - 80, 130))
	UI.fit_label(t, 96, 44)
	t.pivot_offset = Vector2((W - 80) / 2.0, 65)
	_root.add_child(t)
	y += 190.0
	for l in lines:
		var line := UI.label(str(l[0]), 32, l[1], "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(line, Rect2(40, y, W - 80, 46))
		UI.fit_label(line, 32, 20)
		_root.add_child(line)
		y += 50.0

	var bottom := y + 40.0
	if str(_cfg.get("kind")) == "level" and int(_cfg.get("points", 0)) > 0:
		var spend := Sheet.button("SPEND THE POINTS", Dialog.CONFIRM_PLATE, Color("#F3FBF3"))
		UI.place(spend, Rect2(W / 2.0 - 220, bottom, 440, 96))
		spend.pressed.connect(func() -> void:
			_close()
			var page: GDScript = load("res://scenes/pages/stats_page.gd")
			page.open(Nav.overlay_parent()))
		_root.add_child(spend)
		bottom += 110.0
	var go := Sheet.button("CONTINUE", Dialog.QUIET_PLATE, UI.INK)
	UI.place(go, Rect2(W / 2.0 - 220, bottom, 440, 96))
	go.pressed.connect(_close)
	_root.add_child(go)

	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 1.0, 0.22)
	t.scale = Vector2(0.6, 0.6)
	var pop := create_tween()
	pop.tween_property(t, "scale", Vector2.ONE, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _process(dt: float) -> void:
	if _glow != null:
		_glow.rotation += dt * 0.25


func _close() -> void:
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, 0.18)
	tw.tween_callback(func() -> void:
		finished.emit()
		queue_free())
