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

const RAIL_WIDTH := 96

## The rail's own tap height, separate from UI.TAP_MIN so that shrinking the
## rail does not shrink every button in the game.
##
## 72 units is 44.0 pt on a 16 Pro Max at the 0.611 pt/unit this file's type
## scale is calibrated to -- exactly Apple's minimum -- and 37.9 pt on an SE,
## which is the trade ui.gd already documents and takes. It is what pays for the
## portrait and the settings gear the rail now carries.
const RAIL_TAP := 72

## How often the client says it is still here.
##
## The server treats silence past 90 seconds as gone, so thirty is three beats
## of headroom -- one lost request on a train must not read as leaving.
const BEAT_SECONDS := 30.0
const ICON_SIZE := UI.ICON_MD

## Short enough that spamming Collect never leaves the counter visibly behind the
## real balance, long enough to read as movement.
const GOLD_ROLL_SECONDS := 0.30
## Smaller than UI.TAP_MIN, because the rail's vertical budget is the tightest
## thing in this file and eight units here is eight units the House button does
## not lose off the bottom of an iPad. 68 is still a 41 pt target on a 16 Pro
## Max, and the ring drawn inside it is decoration, not margin.
const AVATAR_SIZE := 68

## Floors, not fixed heights. The top bar sizes to its own content and the action
## host to the tallest bar any section mounts; these only stop them collapsing.
## The safe-area inset is added on top of both at runtime, so the numbers here
## stay device-independent.
##
## 96, down from 140: the bar was two stacked rows -- a portrait, a name and an
## experience bar over a full-width energy meter. It is one banner now, and the
## 44 units it gave back are most of what the rail's portrait costs.
const TOPBAR_MIN_H := 96

## 116 for the button, a line of caption under it, and margins. Measured on an
## iPhone SE, which is the tightest device: at 164 the caption grazed the edge.
const ACTION_H := 150


var _avatar_btn: Button
var _avatar_img: TextureRect
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
var _xp_bar: ProgressBar

## The screen's own title, retitled on every section change. The tabs never had
## one: the shell knew which section was open and the screen never said so.
var _title: Control

# Chrome that has to be re-inset whenever the safe area changes.
var _topbar_panel: PanelContainer
var _topbar_pad: MarginContainer
var _rail_pad: MarginContainer


func _ready() -> void:
	# Parchment, tiled, running to every edge -- including behind the toast and
	# the action strip, so the ground is continuous rather than a panel floating
	# on a colour.
	var bg := TextureRect.new()
	bg.texture = ArtRegistry.ui_icon("tile/parchment")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_TILE
	# Godot 4 carries repeat on the node rather than the import; without it the
	# tile is stretched once over the whole screen, silently.
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
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

	# The title belongs to the shell, not to the nine tabs. It is one node here
	# against nine near-identical edits there, and the wording then has a single
	# source -- SECTIONS, which is the same table the rail is built from.
	var content_col := VBoxContainer.new()
	content_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_col.add_theme_constant_override("separation", UI.GAP_S)
	middle.add_child(content_col)

	_title = UI.screen_title("")
	content_col.add_child(_title)

	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		(_content as MarginContainer).add_theme_constant_override("margin_" + side, 10)
	content_col.add_child(_content)

	_toast = UI.label("", UI.F_CAPTION, Palette.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	_toast.custom_minimum_size = Vector2(0, 30)
	root.add_child(_toast)

	_action_host = MarginContainer.new()
	_action_host.custom_minimum_size = Vector2(0, ACTION_H)
	for side in ["left", "right"]:
		(_action_host as MarginContainer).add_theme_constant_override("margin_" + side, 12)
	(_action_host as MarginContainer).add_theme_constant_override("margin_bottom", 12)
	root.add_child(_action_host)

	# Holds the player in place through an outage instead of letting them fall
	# back to the sign-in screen, which is where a lost connection used to end.
	add_child(load("res://scenes/shell/reconnect.gd").new())

	_apply_safe_insets()
	get_tree().root.size_changed.connect(_apply_safe_insets)
	if Env.fake_safe_area_on:
		get_tree().root.add_child.call_deferred(SafeArea.debug_overlay())

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

	# Dev-only: put a sample confirmation up, for the same reason.
	if OS.get_cmdline_user_args().has("--dev-confirm"):
		Confirm.ask(self, {
			"title": "Sell this?",
			"body": "Guard's Breastplate (UNCOMMON) is gone for good.",
			"cost": {"amount": 103, "currency": "gold"},
			"confirm_text": "Sell", "danger": true})

	if _dev_act:
		await get_tree().create_timer(1.2).timeout
		for c in _action_host.get_children():
			_press_first_button(c)

	_prefetch()

	# A 4 Hz tick drives only the two numbers that move on their own (the energy
	# bar and its countdown). Everything else redraws on `changed`, so no node
	# polls state per frame.
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	t.timeout.connect(_tick)
	add_child(t)

	# And one call home every thirty seconds, which is the ONLY request this
	# client makes while nobody is touching it.
	#
	# That is the point. Everything above redraws from local projections, so a
	# player who opens the game and puts the phone down was, from the server's
	# side, indistinguishable from one who closed it -- and the live board had to
	# guess. This is what turns the guess into a fact.
	var beat := Timer.new()
	beat.wait_time = BEAT_SECONDS
	beat.autostart = true
	beat.timeout.connect(_beat)
	add_child(beat)


## Builds the other sections in the background so opening one is instant.
##
## A tab is built on first open and fetches over HTTP, so the first tap on every
## section showed an empty screen for a round trip. They are all cached after
## that, which is why only the first tap felt slow -- and the first tap is the one
## that forms the impression.
##
## Staggered rather than fired at once: nine simultaneous requests would queue
## behind two lanes anyway and would delay the section the player is actually
## looking at. The order is the order people reach for.
func _prefetch() -> void:
	await get_tree().create_timer(0.4).timeout
	for id in ["hero", "shop", "items", "army", "estates", "bank", "fight", "house"]:
		if not is_instance_valid(self):
			return
		if _tabs.has(id) or not _unlocked(id):
			continue
		_build_tab(id)
		# A freshly built tab is visible by default and would land on top of the
		# section the player is actually looking at.
		_show_only(_current)
		# One at a time. The point is to be ready before the player asks, not to
		# be ready first.
		await get_tree().create_timer(0.35).timeout


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
	_topbar_panel = PanelContainer.new()
	# The panel bleeds all the way to y=0 on purpose. Insetting the chrome itself
	# would leave a strip of background under the Dynamic Island, which is the
	# most obvious "this is a port" tell there is; only the PADDING moves.
	_topbar_panel.add_theme_stylebox_override("panel", UI.skin("banner", Palette.BANNER, 0, 0))
	_topbar_panel.custom_minimum_size = Vector2(0, TOPBAR_MIN_H)

	_topbar_pad = MarginContainer.new()
	_topbar_panel.add_child(_topbar_pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_S)
	_topbar_pad.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UI.GAP_M)
	col.add_child(row)

	# The crest, then the purse. One row, where it used to be two: a portrait,
	# a name and an experience bar over a full-width energy meter. The portrait
	# moved to the rail, the name to the portrait's tooltip and the Hero card
	# that already printed it, and the energy meter became the third coin.
	row.add_child(_ornament("orn/laurel_l", 64, 24))
	row.add_child(UI.caps("SPQR", UI.F_H2, Palette.BANNER_INK))

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	_gold = _purse_chip(row, "coin", Palette.GOLD)
	_diamonds = _purse_chip(row, "gem", Palette.DIAMOND)
	_energy = _purse_chip(row, "bolt", Palette.ENERGY)

	row.add_child(_ornament("orn/laurel_r", 64, 24))

	# Experience as a thread along the foot of the banner rather than a bar with
	# a number beside it. It is here at all because it is the one figure that
	# says "you are getting somewhere", and it was two taps away before; the
	# exact count lives on the Hero card, which is where you go to read it.
	_xp_bar = ProgressBar.new()
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(0, 8)
	_xp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_xp_bar.add_theme_stylebox_override(
		"background", UI.panel_box(Palette.BANNER.darkened(0.35), Color.TRANSPARENT, 4))
	_xp_bar.add_theme_stylebox_override(
		"fill", UI.panel_box(Palette.GOLD, Color.TRANSPARENT, 4))
	col.add_child(_xp_bar)

	return _topbar_panel


## Pushes the current safe-area insets into the four pieces of chrome that touch
## a screen edge.
##
## Panels keep bleeding to the edge; only their padding moves, so the dark bar
## still runs under the Dynamic Island and the rail still runs to x=0. The action
## host is the one that actually mattered: a 12-unit bottom margin put the
## primary button of every screen inside the home-indicator gesture zone.
func _apply_safe_insets() -> void:
	var i := SafeArea.insets()

	_topbar_pad.add_theme_constant_override("margin_left", UI.GUTTER + int(i.x))
	_topbar_pad.add_theme_constant_override("margin_right", UI.GUTTER + int(i.z))
	_topbar_pad.add_theme_constant_override("margin_top", 12 + int(i.y))
	_topbar_pad.add_theme_constant_override("margin_bottom", 12)
	_topbar_panel.custom_minimum_size.y = TOPBAR_MIN_H + int(i.y)

	_rail_pad.add_theme_constant_override("margin_left", int(i.x))

	(_content as MarginContainer).add_theme_constant_override("margin_right", 10 + int(i.z))

	(_action_host as MarginContainer).add_theme_constant_override(
		"margin_bottom", 12 + int(i.w))
	_action_host.custom_minimum_size.y = ACTION_H + int(i.w)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		# The safe area can change while backgrounded: rotating the phone on the
		# home screen is the everyday case.
		if _topbar_pad != null:
			_apply_safe_insets.call_deferred()
		# Back in the player's hands. Say so now rather than up to thirty
		# seconds from now.
		_beat()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		# Best effort, and it has to be: iOS stops the display link as this
		# fires, so an awaited request would never resume. Api.beacon writes and
		# returns. If it lands, the board shows the departure immediately; if it
		# does not, the presence timeout catches it a minute later.
		if Session.is_signed_in():
			Api.beacon("/v1/presence", {"state": "leaving"})


## One currency readout: its glyph, then its number, stamped into stone.
##
## chip_box, not panel_box: panel_box carries 10 units of padding above and
## below for a card, and two of these stacked came to 142 units, which is what
## pushed the shell's column past the viewport on an iPhone SE. They are side by
## side now, which is what the single-row banner bought.
func _purse_chip(host: Control, icon: String, tint: Color) -> Label:
	var box := PanelContainer.new()
	# The small nine-slice family. The standard one slices at 42 units a side,
	# and a chip is about 36 tall -- two 42s do not fit inside 36 and Godot
	# resolves that by squashing both into mush.
	box.add_theme_stylebox_override("panel", UI.skin("chip", Palette.RAIL, 10, 2))
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	box.add_child(line)
	line.add_child(_glyph("currency/" + icon, UI.ICON_SM, tint))
	# Tabular figures. Without them this reflows horizontally every time it
	# rolls 1,199 -> 1,200, and it is redrawn four times a second.
	var value := UI.number_label("0", UI.F_BODY, Palette.TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	line.add_child(value)
	host.add_child(box)
	return value


## A gold ornament that never takes a tap and never forces a row taller.
func _ornament(key: String, w: int, h: int) -> TextureRect:
	var t := TextureRect.new()
	t.texture = ArtRegistry.ui_icon(key)
	# expand_mode first: without it a TextureRect reports the SOURCE texture's
	# size as its minimum, and a 288 px branch would set the banner's height.
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(w, h)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = Palette.GOLD
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


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
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	panel.custom_minimum_size = Vector2(RAIL_WIDTH, 0)

	# The marble, and the eagle at its foot, are ANCHORED SIBLINGS of the padding
	# rather than rows in the column. A PanelContainer sizes to the largest
	# minimum among its children, and a TextureRect with EXPAND_IGNORE_SIZE
	# reports only its own custom_minimum_size -- so both of these cost the
	# column no height at all. That is what pays for the portrait above.
	var marble := TextureRect.new()
	marble.texture = ArtRegistry.ui_icon("tile/marble")
	marble.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	marble.stretch_mode = TextureRect.STRETCH_TILE
	# Godot 4 carries repeat on the node, not on the import. Without this the
	# tile is stretched once across the whole rail, silently and with no error.
	marble.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	marble.set_anchors_preset(Control.PRESET_FULL_RECT)
	marble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(marble)

	var eagle := _ornament("orn/eagle", UI.ICON_MD, UI.ICON_MD)
	eagle.anchor_left = 0.5
	eagle.anchor_right = 0.5
	eagle.anchor_top = 1.0
	eagle.anchor_bottom = 1.0
	eagle.offset_left = -UI.ICON_MD / 2
	eagle.offset_right = UI.ICON_MD / 2
	eagle.offset_top = -UI.ICON_MD - 6
	eagle.offset_bottom = -6
	eagle.modulate = Palette.STONE_EDGE
	panel.add_child(eagle)

	# The rail panel bleeds to x=0; only its buttons move in from a left inset,
	# which is zero in portrait but not on an Android cutout or in landscape.
	_rail_pad = MarginContainer.new()
	panel.add_child(_rail_pad)

	# NOT a ScrollContainer.
	#
	# The rail was briefly wrapped in one so that overflow would degrade to
	# scrolling instead of clipping. On a phone that is a trap: a scroll view
	# running the full height of the left edge captures vertical drags, so every
	# swipe that starts anywhere near it scrolls a rail that does not need
	# scrolling instead of the list the player is trying to move. The cure was
	# worse than the disease, and shell_fits.gd already guarantees the whole rail
	# fits on every device we ship to.
	var col := VBoxContainer.new()
	col.name = "RailColumn"    # shell_fits.gd measures this node by name
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	_rail_pad.add_child(col)

	col.add_child(_build_crest())

	var nav := VBoxContainer.new()
	# No gap between rail buttons: the selected section has its own lit slab,
	# which is what separates them.
	nav.add_theme_constant_override("separation", 0)
	col.add_child(nav)

	for s in SECTIONS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, RAIL_TAP)
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
		# 72 px rail button to grow.
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
			var glyph := UI.label(str(s["glyph"]), UI.F_H1, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
			glyph.modulate = Palette.TEXT_DIM
			glyph.custom_minimum_size = Vector2(0, ICON_SIZE)
			inner.add_child(glyph)
		inner.add_child(UI.caps(str(s["label"]), UI.F_MICRO, Palette.TEXT_FAINT,
			HORIZONTAL_ALIGNMENT_CENTER))
		b.add_child(inner)

		nav.add_child(b)
		_rail_buttons[str(s["id"])] = b

		# The unlock level rides in the corner rather than as a third line. Icon
		# plus name plus level came to 98 units inside an 88-unit button, so the
		# rail overflowed and "House" sat on top of "lv 20". Seeing what is coming
		# is worth keeping -- it just cannot cost vertical space.
		var lock := PanelContainer.new()
		lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lock.add_theme_stylebox_override("panel", UI.skin("plaque", Palette.RAIL, 6, 1))
		lock.anchor_left = 1.0
		lock.anchor_right = 1.0
		lock.offset_left = -40
		lock.offset_top = 0
		lock.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		b.add_child(lock)
		var lock_text := UI.number_label("", UI.F_MICRO, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
		lock.add_child(lock_text)
		_rail_locks[str(s["id"])] = lock

	# Settings, at the foot. It is a rail entry rather than a tenth SECTION so
	# that lint check 4 -- which reads SECTIONS and demands an icon at
	# assets/ui/<name>.png -- is not asked about an ornament.
	var gear := Button.new()
	gear.custom_minimum_size = Vector2(0, RAIL_TAP)
	gear.focus_mode = Control.FOCUS_NONE
	gear.tooltip_text = "Settings"
	gear.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	gear.add_theme_stylebox_override("hover", UI.skin("plaque", Palette.RAIL, 4, 4))
	gear.add_theme_stylebox_override("pressed", UI.skin("plaque", Palette.RAIL, 4, 4))
	var gear_icon := _ornament("orn/gear", UI.ICON_MD, UI.ICON_MD)
	gear_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	gear_icon.modulate = Palette.TEXT_FAINT
	gear.add_child(gear_icon)
	col.add_child(gear)

	return panel


## The player, at the head of their own rail: portrait in a gold ring, with the
## level stamped on a stone plate under it.
##
## It was in the top bar, which is where this genre usually puts it, and which
## cost the bar a whole row. In asynchronous PvP you never meet an opponent --
## they are a row on a list -- so the portrait is most of the identity either
## side has, and the rail is where it is seen on every screen rather than
## competing with the purse.
func _build_crest() -> Control:
	var crest := VBoxContainer.new()
	crest.add_theme_constant_override("separation", 2)

	var face := Control.new()
	face.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	face.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	crest.add_child(face)

	_avatar_btn = Button.new()
	_avatar_btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_btn.focus_mode = Control.FOCUS_NONE
	_avatar_btn.tooltip_text = "Change your portrait"
	_avatar_btn.add_theme_stylebox_override(
		"normal", UI.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	_avatar_btn.add_theme_stylebox_override(
		"hover", UI.panel_box(Palette.PANEL_HIGH, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.add_theme_stylebox_override(
		"pressed", UI.panel_box(Palette.PANEL, Color.TRANSPARENT, AVATAR_SIZE / 2))
	_avatar_btn.pressed.connect(_open_avatar_picker)
	face.add_child(_avatar_btn)

	# The art is inset inside the button rather than drawn at the button's size:
	# the whole tap target stays tappable while the portrait keeps its weight.
	_avatar_img = TextureRect.new()
	_avatar_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_img.offset_left = 7
	_avatar_img.offset_top = 7
	_avatar_img.offset_right = -7
	_avatar_img.offset_bottom = -7
	_avatar_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_btn.add_child(_avatar_img)

	var plate := PanelContainer.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_theme_stylebox_override("panel", UI.skin("plaque", Palette.RAIL, 8, 1))
	plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	crest.add_child(plate)
	_level = UI.number_label("1", UI.F_MICRO, Palette.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	plate.add_child(_level)

	return crest


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
	_retitle(id)

	_show_only(id)

	if _tabs.has(id) and is_instance_valid(_tabs[id]):
		# A cached tab has to re-fetch, or reopening the Market shows the offers
		# from the last time you looked and the Barracks a soldier you dismissed.
		# Collect has no _reload: it renders straight from GameState, which the
		# shell keeps current.
		var shown: Node = _tabs[id]
		if shown.has_method("_reload"):
			shown.call("_reload")
		return

	_build_tab(id)
	_show_only(id)


## Puts the open section's name over it, in the shell's own words.
func _retitle(id: String) -> void:
	if _title == null:
		return
	for sec in SECTIONS:
		if str(sec["id"]) == id:
			UI.set_screen_title(_title, str(sec["label"]))
			return


## Shows one section and hides every other, including the ones built ahead of
## time by _prefetch which have never been on screen.
func _show_only(id: String) -> void:
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


## Builds one section and its action bar, hidden. Called both when the player
## opens a section and, ahead of time, by _prefetch.
func _build_tab(id: String) -> void:
	if _tabs.has(id) and is_instance_valid(_tabs[id]):
		return

	# The action bar is cached alongside its tab, because the tab holds direct
	# references into it -- rebuilding it on every switch would hand the tab a
	# freed button and reintroduce the same crash from the other side.
	var bar := VBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Centred rather than filled. A Button in a filled VBox absorbs all the spare
	# height and shoves the caption under it hard against the bottom margin, which
	# on an iPhone SE put it a couple of units from the screen edge.
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
	col.add_child(UI.label(title.to_upper(), UI.F_H1, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.label("arrives in " + milestone, UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
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
			var lock: PanelContainer = _rail_locks[id]
			(lock.get_child(0) as Label).text = "" if open else str(_unlock_level(str(id)))
			lock.visible = not open
		var active: bool = id == _current
		# The open section is a lit slab set into the marble; the others are the
		# marble itself. A colour swap would say "different thing"; a change of
		# surface says "same thing, in a different state".
		if active:
			b.add_theme_stylebox_override("normal", UI.skin("rail_active", Palette.PANEL, 4, 4))
		else:
			b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		b.add_theme_stylebox_override("hover", UI.skin("plaque", Palette.RAIL, 4, 4))
		b.add_theme_stylebox_override("pressed", UI.skin("rail_active", Palette.PANEL, 4, 4))
		b.add_theme_stylebox_override("disabled", StyleBoxEmpty.new())
		var inner := b.get_child(0)
		var tint := Palette.GOLD_DEEP if active else Palette.TEXT_DIM
		if not open:
			tint = Palette.EMPTY_SLOT
		inner.get_child(0).modulate = tint
		inner.get_child(1).add_theme_color_override("font_color",
			Palette.TEXT if active else (Palette.TEXT_FAINT if open else Palette.EMPTY_SLOT))


func _on_state_changed() -> void:
	if not GameState.has_state():
		return
	var p := GameState.player()
	# The username is the portrait's tooltip now rather than a line of chrome.
	# The Hero card prints it in full, which is where you go to read it.
	_avatar_btn.tooltip_text = str(p.get("username", ""))
	_level.text = "Lv %d" % int(p.get("level", 1))
	_update_xp()
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


## The experience bar. Driven from `changed` rather than the 4 Hz tick: unlike
## energy, experience only moves when the player does something.
func _update_xp() -> void:
	var need := GameState.xp_to_next()
	var have := GameState.display_xp()
	if need <= 0:
		# The level cap. A full bar, rather than a division by nothing.
		_xp_bar.max_value = 1.0
		_xp_bar.value = 1.0
		return
	_xp_bar.max_value = float(need)
	_xp_bar.value = float(have)


func _update_energy() -> void:
	if not GameState.has_state():
		return
	var cur := GameState.display_energy()
	var mx := GameState.max_energy()
	if cur >= mx:
		_energy.text = "%d/%d" % [cur, mx]
		return
	# The next point, not the full pool. "1h 04m" is the answer to a question
	# nobody asked; the countdown is the one that decides whether you wait.
	#
	# It has to fit a coin now rather than a full-width bar, so the words are
	# gone and the separator carries them: "42/60 · 0:23".
	_energy.text = "%d/%d \u00b7 %s" % [
		cur, mx, UI.short_duration(GameState.display_seconds_to_next())]


func _tick() -> void:
	GameState.tick_projection()
	_update_energy()
	# Estate income is continuous, so the purse moves without anyone touching it.
	# Set directly rather than through _show_gold: that one tweens, and a tween
	# restarted four times a second would stutter instead of counting. The tween
	# stays for discrete gains -- a collect, a sale, a raid -- which are the ones
	# worth celebrating.
	var g := GameState.display_gold()
	if g != _gold_shown:
		_gold_shown = g
		_gold.text = UI.number(g)


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


## Tells the server the app is still open.
##
## Costs one request with an empty body and no database work; it exists purely
## so an idle player is not mistaken for an absent one.
func _beat() -> void:
	if not Session.is_signed_in():
		return
	# Fire and forget. Nothing on screen depends on the answer, and a failed
	# heartbeat is not worth telling the player about -- the next one is thirty
	# seconds away.
	Api.post_json("/v1/presence", {"state": "foreground"})
