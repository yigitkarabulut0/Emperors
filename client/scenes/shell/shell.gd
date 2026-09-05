extends Control
## The game shell: left icon rail, top status bar, content area, bottom action.
##
## The rail is always visible and one tap from anywhere, which is what the
## reference game does too. The bottom strip is deliberately reserved for the
## primary action of the current section — it is the only part of a tall phone
## the thumb reaches comfortably, and this game is mostly one repeated tap.

## The navigation rail.
##
## Names are literal on purpose. "Keep", "Fields", "Armory", "War Gate" and "Map"
## are good flavour and tell a new player nothing about what is behind them --
## the reference game calls its screens Jobs, Properties, Crew, Bank, Fight, and
## you always know where you are. The flavour moved into the screens themselves.
##
## One entry does one thing. Bank and House used to be buttons buried inside the
## Keep, which made the Keep a grab bag of five unrelated things and put the
## clan system two taps deep behind a line of text.
const SECTIONS := [
	{"id": "hero", "icon": "keep", "glyph": "H", "label": "Hero"},
	{"id": "jobs", "icon": "fields", "glyph": "J", "label": "Jobs"},
	{"id": "shop", "icon": "market", "glyph": "S", "label": "Shop"},
	{"id": "items", "icon": "armory", "glyph": "I", "label": "Items"},
	{"id": "estates", "icon": "territory", "glyph": "E", "label": "Estates"},
	{"id": "army", "icon": "barracks", "glyph": "A", "label": "Army"},
	{"id": "bank", "icon": "bank", "glyph": "B", "label": "Bank"},
	{"id": "fight", "icon": "war_gate", "glyph": "F", "label": "Fight"},
	{"id": "house", "icon": "house", "glyph": "K", "label": "House"},
]

const RAIL_WIDTH := 88
const ICON_SIZE := 34

## Short enough that spamming Collect never leaves the counter visibly behind the
## real balance, long enough to read as movement.
const GOLD_ROLL_SECONDS := 0.30
const AVATAR_SIZE := 46


var _avatar_btn: Button
var _avatar_img: TextureRect
var _name: Label
var _diamonds: Label

## Section id -> the tab node, and -> its action bar. Both are kept alive for
## the lifetime of the shell; see _open().
var _tabs: Dictionary = {}
var _rail_locks: Dictionary = {}
var _action_bars: Dictionary = {}

var _gold_shown := 0
var _gold_seen := false
var _gold_tween: Tween

var _current := "jobs"
var _rail_buttons: Dictionary = {}
var _content: Control
var _action_host: Control
var _toast: Label
var _dev_act := false

# top bar
var _level: Label
var _gold: Label
var _energy: Label
var _energy_bar: ProgressBar


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_top_bar())

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 0)
	root.add_child(middle)

	middle.add_child(_build_rail())

	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		(_content as MarginContainer).add_theme_constant_override("margin_" + side, 10)
	middle.add_child(_content)

	_toast = UI.label("", 15, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	_toast.custom_minimum_size = Vector2(0, 22)
	root.add_child(_toast)

	_action_host = MarginContainer.new()
	_action_host.custom_minimum_size = Vector2(0, 78)
	for side in ["left", "right"]:
		(_action_host as MarginContainer).add_theme_constant_override("margin_" + side, 12)
	(_action_host as MarginContainer).add_theme_constant_override("margin_bottom", 12)
	root.add_child(_action_host)

	GameState.changed.connect(_on_state_changed)
	GameState.action_failed.connect(_on_action_failed)
	GameState.level_up.connect(func(lv: int) -> void: _flash("Level %d!" % lv, Palette.GOLD))

	# Dev-only: fire the section's primary action once the tab is open, so a
	# capture run (which disables input) can reach a screen that only exists
	# after an action — a battle replay, for instance.
	for i in OS.get_cmdline_user_args().size():
		var a2 := OS.get_cmdline_user_args()
		if a2[i] == "--dev-act":
			_dev_act = true

	# Dev-only: open a specific section for a proof capture.
	for i in OS.get_cmdline_user_args().size():
		var a := OS.get_cmdline_user_args()
		if a[i] == "--dev-tab" and i + 1 < a.size():
			_current = a[i + 1]

	_open(_current)
	_on_state_changed()

	# Dev-only: hammer the section switcher. This is the shape that crashed --
	# leaving a section while its HTTP request is still in the air -- so it is
	# worth being able to reproduce on demand.
	for i in OS.get_cmdline_user_args().size():
		var ta := OS.get_cmdline_user_args()
		if ta[i] == "--dev-thrash" and i + 1 < ta.size():
			_thrash(int(ta[i + 1]))
			return

	# Dev-only: open the portrait picker for a proof capture, since a capture run
	# disables input and cannot press the button itself.
	if OS.get_cmdline_user_args().has("--dev-avatars"):
		_open_avatar_picker()

	if _dev_act:
		await get_tree().create_timer(1.2).timeout
		for c in _action_host.get_children():
			_press_first_button(c)

	# A 4 Hz tick drives only the two numbers that move on their own (the energy
	# bar and its countdown). Everything else redraws on `changed`, so no node
	# polls state per frame.
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)


## Opens the portrait picker over everything.
func _open_avatar_picker() -> void:
	var picker: CanvasLayer = load("res://scenes/shell/avatar_picker.gd").new(
		str(GameState.player().get("avatar", "knight")))
	add_child(picker)


## Cycles every section `rounds` times with barely a frame between, so requests
## are always still outstanding when the section changes, then quits.
func _thrash(rounds: int) -> void:
	var ids: Array[String] = []
	for sec in SECTIONS:
		ids.append(str(sec["id"]))
	for r in rounds:
		for id in ids:
			_open(id)
			await get_tree().process_frame
			await get_tree().process_frame
	print("[thrash] survived ", rounds * ids.size(), " section switches")
	get_tree().quit(0)


func _build_top_bar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_box(Palette.RAIL, Color.TRANSPARENT, 0))
	panel.custom_minimum_size = Vector2(0, 96)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	pad.add_theme_constant_override("margin_top", 9)
	pad.add_theme_constant_override("margin_bottom", 9)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)

	# Your face, top left, and it opens the picker. In asynchronous PvP you never
	# meet an opponent -- they are a row on a list -- so the portrait is most of
	# the identity either side has.
	_avatar_btn = Button.new()
	_avatar_btn.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	_avatar_btn.focus_mode = Control.FOCUS_NONE
	_avatar_btn.tooltip_text = "Change your portrait"
	_avatar_btn.add_theme_stylebox_override("normal", UI.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	_avatar_btn.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.pressed.connect(_open_avatar_picker)
	_avatar_img = TextureRect.new()
	_avatar_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_btn.add_child(_avatar_img)
	row.add_child(_avatar_btn)

	var who := VBoxContainer.new()
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", 0)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name = UI.label("", 16, Palette.TEXT)
	who.add_child(_name)
	_level = UI.label("Lv 1", 12, Palette.TEXT_FAINT)
	who.add_child(_level)
	row.add_child(who)

	# Currency reads as a pair of stamped coins rather than a bare number in the
	# corner, which is what it was.
	var purse := HBoxContainer.new()
	purse.add_theme_constant_override("separation", 8)
	purse.alignment = BoxContainer.ALIGNMENT_END
	_gold = _purse_chip(purse, "coin", Palette.GOLD)
	_diamonds = _purse_chip(purse, "gem", Palette.DIAMOND)
	row.add_child(purse)

	var erow := HBoxContainer.new()
	erow.add_theme_constant_override("separation", 8)
	col.add_child(erow)
	erow.add_child(_glyph("currency/bolt", 16, Palette.ENERGY))

	_energy_bar = ProgressBar.new()
	_energy_bar.show_percentage = false
	_energy_bar.custom_minimum_size = Vector2(0, 10)
	_energy_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_energy_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_energy_bar.add_theme_stylebox_override("background", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 5))
	_energy_bar.add_theme_stylebox_override("fill", UI.panel_box(Palette.ENERGY, Color.TRANSPARENT, 5))
	erow.add_child(_energy_bar)

	_energy = UI.label("0/0", 14, Palette.ENERGY, HORIZONTAL_ALIGNMENT_RIGHT)
	_energy.custom_minimum_size = Vector2(128, 0)
	erow.add_child(_energy)

	return panel


## One currency readout: its glyph, then its number. Returns the number's label
## so the caller can keep hold of it.
func _purse_chip(host: Control, icon: String, tint: Color) -> Label:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 14))
	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 9)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 4)
	box.add_child(pad)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	pad.add_child(line)
	line.add_child(_glyph("currency/" + icon, 17, tint))
	var value := UI.label("0", 17, tint, HORIZONTAL_ALIGNMENT_RIGHT)
	line.add_child(value)
	host.add_child(box)
	return value


func _glyph(name: String, size: int, tint: Color) -> TextureRect:
	var t := TextureRect.new()
	t.texture = ArtRegistry.ui_icon(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = tint
	return t


func _build_rail() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.panel_box(Palette.RAIL, Color.TRANSPARENT, 0))
	panel.custom_minimum_size = Vector2(RAIL_WIDTH, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	for s in SECTIONS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 74)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = str(s["label"])
		b.pressed.connect(_open.bind(str(s["id"])))

		var inner := VBoxContainer.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.set_anchors_preset(Control.PRESET_FULL_RECT)
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		inner.add_theme_constant_override("separation", 2)
		# EXPAND_IGNORE_SIZE matters: without it a TextureRect reports the source
		# texture's own size as its minimum, and a 96 px icon would force the
		# 74 px rail button to grow.
		var tex := ArtRegistry.ui_icon(str(s["icon"]))
		if tex != null:
			var icon := TextureRect.new()
			icon.texture = tex
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
			icon.modulate = Palette.TEXT_DIM
			inner.add_child(icon)
		else:
			# An unshipped icon must not leave an unlabelled button. Both branches
			# tint through the same call below, so _style_rail needs no branch.
			var glyph := UI.label(str(s["glyph"]), 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
			glyph.modulate = Palette.TEXT_DIM
			glyph.custom_minimum_size = Vector2(0, ICON_SIZE)
			inner.add_child(glyph)
		inner.add_child(UI.label(str(s["label"]), 11, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
		b.add_child(inner)

		col.add_child(b)
		_rail_buttons[str(s["id"])] = b
		_rail_locks[str(s["id"])] = UI.label("", 10, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)
		inner.add_child(_rail_locks[str(s["id"])])

	return panel


const TABS := {
	"jobs": "res://scenes/tabs/collect.gd",
	"hero": "res://scenes/tabs/keep.gd",
	"shop": "res://scenes/tabs/shop.gd",
	"items": "res://scenes/tabs/inventory.gd",
	"estates": "res://scenes/tabs/territory.gd",
	"army": "res://scenes/tabs/barracks.gd",
	"bank": "res://scenes/tabs/bank.gd",
	"fight": "res://scenes/tabs/attack.gd",
	"house": "res://scenes/tabs/kingdom.gd",
}


## Switches sections. Tabs are built once and then hidden, never freed.
##
## Freeing them was crashing the game. Every tab loads over HTTP, and GDScript's
## await resumes wherever it left off -- so leaving a section while its request
## was still in the air resumed the coroutine inside a freed node and took the
## process down with it. There are ~58 await sites across the scenes; guarding
## each one would leave the next one someone writes unguarded. Keeping the node
## alive removes the whole class of bug, and it is what the design asked for
## anyway: instant switching, and no reload of a list you just looked at.
func _open(id: String) -> void:
	_current = id
	_style_rail()

	for other_id in _tabs:
		var node: Node = _tabs[other_id]
		if not is_instance_valid(node):
			continue
		var on: bool = other_id == id
		(node as CanvasItem).visible = on
		# A hidden tab must stop ticking, or seven of them poll at once.
		node.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		if _action_bars.has(other_id) and is_instance_valid(_action_bars[other_id]):
			(_action_bars[other_id] as CanvasItem).visible = on

	if _tabs.has(id) and is_instance_valid(_tabs[id]):
		# A cached tab has to re-fetch, or reopening the Market shows the offers
		# from the last time you looked and the Barracks a soldier you dismissed.
		# Collect has no _reload: it renders straight from GameState, which the
		# shell keeps current.
		var shown: Node = _tabs[id]
		if shown.has_method("_reload"):
			shown.call("_reload")
		return

	# The action bar is cached alongside its tab, because the tab holds direct
	# references into it -- rebuilding it on every switch would hand the tab a
	# freed button and reintroduce the same crash from the other side.
	var bar := VBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_action_host.add_child(bar)
	_action_bars[id] = bar

	if TABS.has(id):
		var tab: Node = load(TABS[id]).new()
		_content.add_child(tab)
		_tabs[id] = tab
		tab.mount_action_bar(bar)
		return

	var section: Dictionary = {}
	for sec in SECTIONS:
		if sec["id"] == id:
			section = sec
	var ph := _placeholder(str(section.get("label", id)), str(section.get("milestone", "")))
	_content.add_child(ph)
	_tabs[id] = ph


func _placeholder(title: String, milestone: String) -> Control:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	col.add_child(UI.label(title.to_upper(), 28, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("arrives in " + milestone, 15, Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
	return col


## Which sections the player has reached. Nine tabs handed to a new player at
## once is the single biggest reason this was hard to read: most of them do
## nothing yet -- no gold to spend, no army to gear, no house to join. Locked
## ones stay VISIBLE but dim with their level on them, because seeing what is
## coming is most of what makes levelling feel like progress.
func _unlocked(id: String) -> bool:
	for sec in GameState.snapshot.get("sections", []):
		if str(sec.get("id", "")) == id:
			return bool(sec.get("unlocked", false))
	return true   # before the first snapshot arrives, assume open rather than hide everything


func _unlock_level(id: String) -> int:
	for sec in GameState.snapshot.get("sections", []):
		if str(sec.get("id", "")) == id:
			return int(sec.get("unlock_level", 0))
	return 0


func _style_rail() -> void:
	for id in _rail_buttons:
		var b: Button = _rail_buttons[id]
		var open := _unlocked(str(id))
		b.disabled = not open
		if _rail_locks.has(id):
			var lock: Label = _rail_locks[id]
			lock.text = "" if open else "lv %d" % _unlock_level(str(id))
			lock.visible = not open
		var active: bool = id == _current
		var bg := Palette.PANEL if active else Color.TRANSPARENT
		b.add_theme_stylebox_override("normal", UI.panel_box(bg, Color.TRANSPARENT, 0))
		b.add_theme_stylebox_override("hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, 0))
		b.add_theme_stylebox_override("pressed", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, 0))
		var inner := b.get_child(0)
		var tint := Palette.GOLD if active else Palette.TEXT_DIM
		if not open:
			tint = Palette.EMPTY_SLOT
		inner.get_child(0).modulate = tint
		inner.get_child(1).add_theme_color_override("font_color", Palette.TEXT_DIM if active else Palette.TEXT_FAINT)


func _on_state_changed() -> void:
	if not GameState.has_state():
		return
	var p := GameState.player()
	_name.text = str(p.get("username", ""))
	_level.text = "Lv %d" % int(p.get("level", 1))
	_diamonds.text = UI.number(int(p.get("diamonds", 0)))
	_avatar_img.texture = ArtRegistry.portrait(str(p.get("avatar", "knight")))
	_show_gold(GameState.display_gold())
	_update_energy()
	_style_rail()


## Rolls the gold counter to `target` instead of snapping to it.
##
## Gold going up IS the game, so it is the one number worth animating. Two rules
## keep the animation from ever lying:
##
##  - the roll always starts from what is currently on screen, not from the last
##    target, so a change arriving mid-roll continues from where the eye is;
##  - `_gold_shown` is set to the target immediately. The tween only drives the
##    LABEL. If anything interrupts it the next change still starts from the true
##    figure, and a stalled tween can never leave a stale number on screen.
##
## display_gold() is confirmed + replayed pending, so it also moves DOWN when a
## prediction is rolled back. Rolling down reads as an honest correction; only
## the flash is suppressed, because a gain cue on a loss would be a lie.
func _show_gold(target: int) -> void:
	var from := _gold_shown
	_gold_shown = target

	# First paint: no roll. Spinning up from zero on every sign-in is theatre.
	if not _gold_seen:
		_gold_seen = true
		_gold.text = UI.number(target)
		return
	if from == target:
		return

	if _gold_tween != null and _gold_tween.is_valid():
		_gold_tween.kill()
	_gold_tween = create_tween()
	_gold_tween.tween_method(
		func(v: float) -> void: _gold.text = UI.number(int(v)),
		float(from), float(target), GOLD_ROLL_SECONDS)
	_gold_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	if target > from:
		_gold_tween.parallel().tween_property(_gold, "modulate", Color(1.35, 1.3, 1.1), 0.08)
		_gold_tween.chain().tween_property(_gold, "modulate", Color.WHITE, 0.22)


func _update_energy() -> void:
	if not GameState.has_state():
		return
	var cur := GameState.display_energy()
	var mx := GameState.max_energy()
	_energy_bar.max_value = maxf(float(mx), 1.0)
	_energy_bar.value = float(cur)
	var secs := GameState.display_seconds_to_full()
	_energy.text = "%d/%d  %s" % [cur, mx, UI.duration(secs)]


func _tick() -> void:
	_update_energy()


func _on_action_failed(message: String) -> void:
	_flash(message, Palette.DANGER)


func _flash(message: String, color: Color) -> void:
	_toast.add_theme_color_override("font_color", color)
	_toast.text = message
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_callback(func() -> void: _toast.text = "")


## Dev-only helper: presses the first enabled button it finds in a subtree.
func _press_first_button(node: Node) -> bool:
	if node is Button and not (node as Button).disabled:
		(node as Button).pressed.emit()
		return true
	for child in node.get_children():
		if _press_first_button(child):
			return true
	return false
