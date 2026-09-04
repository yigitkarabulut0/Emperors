extends Control
## M0 proof screen.
##
## If this shows the motto, then the whole pipe works: Godot -> HTTP -> Go ->
## Neon pooled endpoint -> migration chain -> back. That is milestone M0's
## definition of done, and it is worth having a screen dedicated to it because
## every later failure is easier to localise when this one still passes.

@onready var _status: Label = %Status
@onready var _motto: Label = %Motto
@onready var _detail: Label = %Detail
@onready var _retry: Button = %Retry

func _ready() -> void:
	_retry.pressed.connect(_check)
	_check()

func _check() -> void:
	_retry.disabled = true
	_status.text = "Reaching the realm…"
	_status.modulate = Color(0.85, 0.80, 0.65)
	_motto.text = ""
	_detail.text = Env.api_base_url

	var res: Api.Response = await Api.get_json("/v1/ping")

	_retry.disabled = false
	if not res.ok:
		print("[boot] FAILED: ", res.error)
		_status.text = "No answer"
		_status.modulate = Color(0.86, 0.35, 0.30)
		_motto.text = res.error
		return

	print("[boot] OK motto=", res.data.get("motto", ""), " db_time=", res.data.get("db_time", ""))
	_status.text = "Connected"
	_status.modulate = Color(0.45, 0.78, 0.45)
	_motto.text = str(res.data.get("motto", ""))
	_detail.text = "server %s · db %s" % [
		res.data.get("version", "?"),
		res.data.get("db_time", "?"),
	]
