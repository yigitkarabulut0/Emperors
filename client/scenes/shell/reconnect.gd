extends CanvasLayer
## Covers the game while the connection is gone, and takes it away when it is back.
##
## What this exists to prevent: losing signal used to end at the sign-in screen.
## The player is still signed in -- the refresh token is on disk and the server
## never rejected it -- so asking someone to type their password because a train
## went into a tunnel is how an app teaches people not to trust it.
##
## So this holds the player exactly where they were, retries quietly, and puts
## them back in the same screen with fresh state. It never signs anyone out;
## only the server may do that, by answering 401.

signal recovered

## How long the connection must be gone before the player is told anything.
##
## Below this a dropped packet is invisible: the request already retried, the
## optimistic UI already moved, and flashing an alarm would make a working game
## look broken. Above it, silence is worse -- taps stop having any effect and
## nobody knows why.
const GRACE_SECONDS := 15.0

const POLL_SECONDS := 2.0

var _since_ms := 0
var _shown := false
var _title: Label
var _detail: Label
var _card: PanelContainer


func _ready() -> void:
	layer = 40
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(Palette.BG.r, Palette.BG.g, Palette.BG.b, 0.92)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SafeArea.wrap(self, Vector4(UI.GUTTER, UI.GUTTER, UI.GUTTER, UI.GUTTER)).add_child(centre)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(540, 0)
	_card.add_theme_stylebox_override("panel", UI.panel_box(Palette.PANEL, Palette.GOLD_DEEP))
	centre.add_child(_card)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, UI.GAP_L)
	_card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UI.GAP_M)
	pad.add_child(col)

	_title = UI.label("Connection lost", UI.F_H1, Palette.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_title)
	_detail = UI.label("", UI.F_BODY, Palette.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_detail)

	# Deliberately no "sign in again" button. There is nothing wrong with the
	# session, and offering that is what turns a tunnel into a lost account.
	Api.offline.connect(_on_offline)
	Api.online.connect(_on_online)


func _on_offline() -> void:
	if _since_ms == 0:
		_since_ms = Time.get_ticks_msec()
	if _shown:
		return
	if Time.get_ticks_msec() - _since_ms < int(GRACE_SECONDS * 1000.0):
		return
	_show()


func _on_online() -> void:
	_since_ms = 0
	if _shown:
		_hide()


func _show() -> void:
	_shown = true
	visible = true
	_detail.text = "Holding your place. This will clear itself."
	_poll()


func _hide() -> void:
	_shown = false
	visible = false
	recovered.emit()


## Retries until the realm answers, then refreshes and steps out of the way.
func _poll() -> void:
	while _shown and is_instance_valid(self):
		await get_tree().create_timer(POLL_SECONDS).timeout
		if not _shown or not is_instance_valid(self):
			return
		var res: Api.Response = await Api.get_json("/v1/ping", false, Api.REACHABILITY_TIMEOUT)
		if res.ok:
			_detail.text = "Back. Catching up…"
			await GameState.refresh()
			if is_instance_valid(self):
				_hide()
			return
