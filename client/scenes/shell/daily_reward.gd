extends CanvasLayer
## The daily login calendar, shown once on the first foreground of a local day.
##
## Diamonds had exactly one source — five per level, 295 across a whole climb to
## the cap — against three things to spend them on, so the premium currency was
## a number that only ever went up. The design always specified this calendar and
## put more than half the intended free supply in it.
##
## It is a reward, so it opens itself and closes on a tap: the confirmation
## modal's arming delay exists to stop an accidental SPEND, and there is nothing
## here to spend.

signal finished

var _view: Dictionary = {}
var _root: Control


func setup(view: Dictionary) -> void:
	_view = view


func _ready() -> void:
	layer = 40

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SafeArea.wrap(self, Vector4(UI.GAP_L, UI.GAP_L, UI.GAP_L, UI.GAP_L)).add_child(centre)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	centre.add_child(card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, UI.GAP_L)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_M)
	pad.add_child(col)

	col.add_child(UI.label("THE COURT PAYS ITS RESPECTS", UI.F_H1, Palette.GOLD_INK,
		HORIZONTAL_ALIGNMENT_CENTER))

	var streak := int(_view.get("streak", 0))
	var sub := "Welcome back."
	if streak > 0:
		sub = "%d days running." % (streak + 1)
	col.add_child(UI.label(sub, UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))

	# The whole week at once. Seeing that the seventh square is worth five times
	# the first is the entire reason to come back on day six.
	var week := HBoxContainer.new()
	week.alignment = BoxContainer.ALIGNMENT_CENTER
	week.add_theme_constant_override("separation", 4)
	col.add_child(week)

	var day := int(_view.get("day", 1))
	var rewards: Array = _view.get("rewards", [])
	for i in rewards.size():
		var today := i == day - 1
		var square := PanelContainer.new()
		square.custom_minimum_size = Vector2(64, 64)
		square.add_theme_stylebox_override("panel", UI.panel_box(
			Palette.PANEL_HIGH if today else Palette.PANEL,
			Palette.GOLD_DEEP if today else Palette.LINE))
		var inner := VBoxContainer.new()
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		inner.add_theme_constant_override("separation", 0)
		square.add_child(inner)
		inner.add_child(UI.label(str(int(rewards[i])), UI.F_BODY,
			Palette.DIAMOND if today else Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
		inner.add_child(UI.label("day %d" % (i + 1), UI.F_MICRO,
			Palette.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER))
		week.add_child(square)

	var take := UI.button("TAKE %d DIAMONDS" % int(_view.get("reward", 0)), UI.F_H2)
	take.custom_minimum_size = Vector2(0, UI.TAP_PRIMARY)
	take.pressed.connect(_claim)
	col.add_child(take)
	_root = card


func _claim() -> void:
	var res: Api.Response = await Api.post_json("/v1/daily/claim", {})
	if not res.ok:
		# Already claimed on another device is not worth an error card: the
		# calendar is a gift, and the worst case is that they already have it.
		GameState.action_failed.emit(res.error)
	else:
		GameState.action_failed.emit("+%d diamonds" % int(_view.get("reward", 0)))
		await GameState.refresh()
	finished.emit()
	queue_free()
