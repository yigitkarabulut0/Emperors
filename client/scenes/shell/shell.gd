extends Control
## The chrome around every screen: ground, the left rail, the currency pills,
## and the host the seven screens are mounted in.
##
## Geometry is the reference painting's own (art/reference/collect.png is the
## canonical rail; each section's lit plate is cut from the painting where that
## section is active and scaled so its border box is 148x170).

const TABS := {
	"family": "res://scenes/tabs/family.gd",
	"collect": "res://scenes/tabs/collect.gd",
	"inventory": "res://scenes/tabs/inventory.gd",
	"shop": "res://scenes/tabs/shop.gd",
	"army": "res://scenes/tabs/army.gd",
	"attack": "res://scenes/tabs/attack.gd",
	"kingdom": "res://scenes/tabs/kingdom.gd",
}
const ORDER := ["family", "collect", "inventory", "shop", "army", "attack", "kingdom"]

## Vertical centre of each rail entry, and where its unlit icon+label is drawn.
const CENTER := {"family": 295, "collect": 462, "inventory": 637, "shop": 822, "army": 1010, "attack": 1197, "kingdom": 1385}
const ENTRY_POS := {"family": Vector2(10, 232), "collect": Vector2(10, 388), "inventory": Vector2(10, 562),
	"shop": Vector2(10, 742), "army": Vector2(10, 928), "attack": Vector2(10, 1118), "kingdom": Vector2(10, 1305)}
## The lit plate's border box inside its crop (x, y, w, h), per source painting.
const PLATE_BOX := {"collect": [5, 9, 148, 170], "inventory": [8, 11, 142, 167], "shop": [10, 10, 152, 177],
	"army": [10, 10, 148, 173], "attack": [10, 10, 153, 175], "family": [10, 10, 152, 177], "kingdom": [8, 10, 137, 157]}

## Which server section gates each tab. Estates and Bank fold into Family.
const SECTION_KEY := {"family": "hero", "collect": "jobs", "inventory": "items", "shop": "shop",
	"army": "army", "attack": "fight", "kingdom": "house"}

var _host: Control
var _rail: Control
var _plate: TextureRect
var _entries: Dictionary = {}       ## id -> TextureRect (unlit icon+label)
var _locks: Dictionary = {}         ## id -> Label
var _tabs: Dictionary = {}          ## id -> Control (instantiated lazily)
var _current := ""
var _gold: Label
var _diamonds: Label
var _energy: Label
var _level: Label
var _toast: Label
var _toast_timer: SceneTreeTimer


var _inset_top := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_host)

	_build_rail()
	_build_pills()
	_build_toast()
	_apply_safe_area()

	GameState.changed.connect(_on_changed)
	GameState.action_failed.connect(toast)
	GameState.level_up.connect(_on_level_up)
	Api.offline.connect(func() -> void: toast("Connection lost"))
	Api.online.connect(func() -> void: toast("Connected"))

	var tick := Timer.new()
	tick.wait_time = 0.25
	tick.timeout.connect(_tick)
	add_child(tick)
	tick.start()
	var heartbeat := Timer.new()
	heartbeat.wait_time = 30.0
	heartbeat.timeout.connect(func() -> void: Api.post_json("/v1/presence", {}))
	add_child(heartbeat)
	heartbeat.start()

	_on_changed()
	open(str(Env.args.get("tab", "collect")))
	_daily_on_boot.call_deferred()


# --- diamonds, energy, the daily reward ------------------------------------------------

var _busy_popup := false
var _daily_shown := false


## Diamonds are earned, never bought: level-ups and the daily calendar. The "+"
## on the pill opens the calendar with a claim when one is due.
func _diamonds_popup() -> void:
	if _busy_popup:
		return
	_busy_popup = true
	var res: Api.Response = await Api.get_json("/v1/daily")
	_busy_popup = false
	if not res.ok:
		toast(res.error)
		return
	var d := res.data
	var rewards: Array = d.get("rewards", [])
	var day := int(d.get("day", 1))
	var lines: Array = []
	for i in rewards.size():
		var mark := "●" if i + 1 < day or (i + 1 == day and not bool(d.get("claimable", false))) else ("▶" if i + 1 == day else "○")
		lines.append("%s Day %d   %d diamonds" % [mark, i + 1, int(rewards[i])])
	var body := "Diamonds come from levelling up and from the daily reward.\nStreak: %d days.\n\n%s" % [int(d.get("streak", 0)), "\n".join(lines)]
	if bool(d.get("claimable", false)):
		if await Dialog.ask(self, {"title": "Daily reward", "body": body, "confirm_text": "Claim %d diamonds" % int(d.get("reward", 0)), "cancel_text": "Later"}):
			var c: Api.Response = await Api.post_json("/v1/daily/claim", {})
			if c.ok:
				toast("+%d diamonds" % int(d.get("reward", 0)))
				await GameState.refresh()
			elif c.code != "already_claimed":
				toast(c.error)
	else:
		await Dialog.ask(self, {"title": "Diamonds", "body": body + "\n\nToday's reward is already claimed.", "confirm_text": "OK"})


## The "+" on energy offers the refill from the Diamond Goods directly.
func _energy_popup() -> void:
	if _busy_popup:
		return
	_busy_popup = true
	var res: Api.Response = await Api.get_json("/v1/store")
	_busy_popup = false
	if not res.ok:
		toast(res.error)
		return
	var good: Dictionary = {}
	for g in res.data.get("goods", []):
		if str(g.get("id", "")) == "energy_refill":
			good = g
	if good.is_empty():
		open("shop")
		return
	var have := int(GameState.player().get("diamonds", 0))
	var cost := int(good.get("diamonds", 0))
	var body := "%s\nCosts %d diamonds. You have %d." % [str(good.get("blurb", "")), cost, have]
	if not bool(good.get("useful", true)):
		await Dialog.ask(self, {"title": "Energy refill", "body": body + "\nYour energy is already full.", "confirm_text": "OK"})
		return
	if have < cost:
		await Dialog.ask(self, {"title": "Energy refill", "body": body + "\nNot enough diamonds. Tap the diamond pill to see how to earn them.", "confirm_text": "OK"})
		return
	if await Dialog.ask(self, {"title": "Energy refill", "body": body, "confirm_text": "Refill"}):
		var r: Api.Response = await GameState.act("/v1/store/buy", {"good": "energy_refill"})
		if r.ok:
			toast("Energy refilled")


## Once per session, when the day's reward is waiting, offer it on arrival.
func _daily_on_boot() -> void:
	if _daily_shown or Env.args.has("capture"):
		return
	_daily_shown = true
	var res: Api.Response = await Api.get_json("/v1/daily")
	if res.ok and bool(res.data.get("claimable", false)):
		_diamonds_popup()


## On a phone the display's safe area (notch, Dynamic Island) sits over the top
## of the canvas. Everything shifts down by that inset, in canvas units; the rail
## column is extended upward so the band above stays part of the rail.
func _apply_safe_area() -> void:
	if not OS.has_feature("mobile"):
		return
	var sa := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or sa.position.y <= 0:
		return
	_inset_top = float(sa.position.y) * 941.0 / float(win.x)
	_host.position.y = _inset_top
	_rail.position.y = _inset_top
	var band: TextureRect = _rail.get_child(0)
	band.position.y = -_inset_top
	band.size.y += _inset_top
	for c in get_children():
		if c != _host and c != _rail and c is Control and c.get_child_count() > 0 and c.get_child(0) is TextureRect:
			c.position.y = _inset_top
	print("[shell] safe-area top inset ", _inset_top)


# --- rail -------------------------------------------------------------------------

func _build_rail() -> void:
	_rail = Control.new()
	_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.size = Vector2(160, 1672)
	add_child(_rail)

	var band := TextureRect.new()
	band.texture = Art.tex("chrome/rail_band")
	band.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	band.stretch_mode = TextureRect.STRETCH_TILE
	UI.place(band, Rect2(0, 0, 160, 1470))
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.add_child(band)
	_rail.add_child(UI.image("chrome/rail_bottom", Rect2(0, 1470, 160, 202)))

	_plate = TextureRect.new()
	_plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_plate.stretch_mode = TextureRect.STRETCH_SCALE
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.add_child(_plate)

	_rail.add_child(UI.image("chrome/rail_divider", Rect2(20, 208, 110, 8)))
	for i in ORDER.size() - 1:
		var mid: int = (CENTER[ORDER[i]] + CENTER[ORDER[i + 1]]) / 2
		_rail.add_child(UI.image("chrome/rail_divider", Rect2(20, mid - 4, 110, 8)))

	_rail.add_child(UI.image("chrome/avatar", Rect2(14, 6, 132, 190)))
	_level = UI.label("", 30, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	# Centred on the plaque painted into chrome/avatar, measured off the source
	# image rather than guessed at from the crop's own middle -- the plaque is
	# not centred in its 132x190 tile, so "half the avatar" is six units right
	# of where the number belongs.
	#
	# Scanning avatar.png: the plaque's gold rim runs down to x 4..118 counting
	# the laurel, but the rim rows on the plaque's own centre column are y 134
	# and y 171, and the dark red interior between them centres on (61, 153).
	# The avatar is placed at (14, 6), so that centre lands at (75, 159) on the
	# rail. A 62x38 label centred there starts at (44, 140).
	UI.place(_level, Rect2(44, 140, 62, 38))
	_rail.add_child(_level)

	for id in ORDER:
		var tex: Texture2D = Art.tex("nav/" + id)
		var img := UI.image("nav/" + id, Rect2(ENTRY_POS[id], tex.get_size()))
		_rail.add_child(img)
		_entries[id] = img
		var lock := UI.label("", 22, UI.GOLD_DIM, "title", 700, HORIZONTAL_ALIGNMENT_CENTER)
		UI.place(lock, Rect2(10, CENTER[id] + 62, 136, 26))
		lock.visible = false
		_rail.add_child(lock)
		_locks[id] = lock
		var hit := UI.hotspot(Rect2(0, CENTER[id] - 92, 156, 184))
		hit.pressed.connect(open.bind(id))
		_rail.add_child(hit)


func _set_active(id: String) -> void:
	for k in _entries:
		_entries[k].visible = k != id
	var box: Array = PLATE_BOX[id]
	var tex: Texture2D = Art.tex("nav/active_" + id)
	var sx := 148.0 / float(box[2])
	var sy := 170.0 / float(box[3])
	_plate.texture = tex
	_plate.size = Vector2(round(tex.get_width() * sx), round(tex.get_height() * sy))
	_plate.position = Vector2(round(5 - box[0] * sx), round(CENTER[id] - 85 - box[1] * sy))


# --- pills --------------------------------------------------------------------------

func _build_pills() -> void:
	var top := Control.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	top.add_child(UI.image("chrome/pill_gold", Rect2(180, 21, 221, 58)))
	top.add_child(UI.image("chrome/pill_diamond", Rect2(439, 21, 209, 58)))
	top.add_child(UI.image("chrome/pill_energy", Rect2(666, 21, 225, 58)))
	_gold = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_gold, Rect2(236, 26, 112, 46))
	_diamonds = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_diamonds, Rect2(500, 26, 94, 46))
	_energy = UI.label("", 29, UI.INK, "body", 700, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_energy, Rect2(732, 26, 110, 46))
	for l in [_gold, _diamonds, _energy]:
		top.add_child(l)
	var plus_gold := UI.hotspot(Rect2(354, 24, 38, 52))
	plus_gold.pressed.connect(open.bind("collect"))
	var plus_gems := UI.hotspot(Rect2(598, 24, 38, 52))
	plus_gems.pressed.connect(_diamonds_popup)
	var plus_energy := UI.hotspot(Rect2(848, 24, 38, 52))
	plus_energy.pressed.connect(_energy_popup)
	for h in [plus_gold, plus_gems, plus_energy]:
		top.add_child(h)


func _tick() -> void:
	GameState.tick_projection()
	_paint_pills()


func _paint_pills() -> void:
	if not GameState.has_state():
		return
	_gold.text = UI.short_number(GameState.display_gold())
	_diamonds.text = UI.grouped(int(GameState.player().get("diamonds", 0)))
	_energy.text = "%d/%d" % [GameState.display_energy(), GameState.max_energy()]


# --- tabs -------------------------------------------------------------------------

func open(id: String) -> void:
	if not TABS.has(id):
		id = "collect"
	if _is_locked(id):
		toast("Unlocks at level %d" % _unlock_level(id))
		return
	if _current == id:
		return
	if _current != "" and _tabs.has(_current):
		var old: Control = _tabs[_current]
		old.visible = false
		old.process_mode = Node.PROCESS_MODE_DISABLED
	if not _tabs.has(id):
		var script: GDScript = load(TABS[id])
		var tab: Control = script.new()
		tab.set_anchors_preset(Control.PRESET_FULL_RECT)
		tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_host.add_child(tab)
		_tabs[id] = tab
	var cur: Control = _tabs[id]
	cur.visible = true
	cur.process_mode = Node.PROCESS_MODE_INHERIT
	_current = id
	_set_active(id)
	if cur.has_method("refresh"):
		cur.refresh()


func _unlock_level(id: String) -> int:
	return GameState.unlock_level(SECTION_KEY.get(id, id))


func _is_locked(id: String) -> bool:
	return int(GameState.player().get("level", 1)) < _unlock_level(id)


func _on_changed() -> void:
	_paint_pills()
	_level.text = str(int(GameState.player().get("level", 1)))
	for id in ORDER:
		var locked := _is_locked(id)
		_entries[id].modulate = Color(0.45, 0.45, 0.45) if locked else Color.WHITE
		_locks[id].visible = locked
		_locks[id].text = "LV %d" % _unlock_level(id)
	if _current != "" and _tabs.has(_current) and _tabs[_current].has_method("refresh"):
		_tabs[_current].refresh()


# --- toast --------------------------------------------------------------------------

func _build_toast() -> void:
	_toast = UI.label("", 28, UI.INK, "body", 600, HORIZONTAL_ALIGNMENT_CENTER)
	UI.place(_toast, Rect2(180, 1590, 720, 56))
	_toast.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.06, 0.1, 0.92)
	sb.border_color = UI.GOLD_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	_toast.add_theme_stylebox_override("normal", sb)
	add_child(_toast)


func toast(message: String) -> void:
	if message == "":
		return
	_toast.text = message
	_toast.visible = true
	_toast_timer = get_tree().create_timer(2.5)
	var t := _toast_timer
	t.timeout.connect(func() -> void:
		if _toast_timer == t:
			_toast.visible = false)


func _on_level_up(level: int, _levels: int, _points: int, _gems: int) -> void:
	toast("Level %d!" % level)
