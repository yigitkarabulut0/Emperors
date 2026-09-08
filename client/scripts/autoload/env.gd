extends Node
## Environment: where the server is, and the dev flags.
##
## The API address is never baked into code. Resolution order, later wins:
##  1. the dev default (this machine)
##  2. res://env.build.json, written by the export script so a phone carries its server
##  3. user://env.json, so an installed build can be repointed without a rebuild

const _DEV_DEFAULT := "http://127.0.0.1:8080"

var api_base_url: String = _DEV_DEFAULT
var build_version: String = "dev"

## Command-line user args, parsed once: --dev-login <user> <pw>, --capture <path>,
## --capture-after <seconds>, --tab <name>. Only honoured in non-release builds.
var args: Dictionary = {}


func _ready() -> void:
	for path in ["res://env.build.json", "user://env.json"]:
		_apply(path)
	_parse_args()
	print("[env] api_base_url=", api_base_url, " build=", build_version)


func is_dev() -> bool:
	return OS.is_debug_build()


func _parse_args() -> void:
	if not is_dev():
		return
	var raw := OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		var a: String = raw[i]
		if a == "--dev-login" and i + 2 < raw.size():
			args["dev_login"] = [raw[i + 1], raw[i + 2]]
			i += 3
		elif a == "--capture" and i + 1 < raw.size():
			args["capture"] = raw[i + 1]
			i += 2
		elif a == "--capture-after" and i + 1 < raw.size():
			args["capture_after"] = float(raw[i + 1])
			i += 2
		elif a == "--capture-size" and i + 1 < raw.size():
			# WxH in canvas units: 941x2040 is a 19.5:9 phone's canvas.
			var wh: PackedStringArray = raw[i + 1].split("x")
			if wh.size() == 2:
				args["capture_size"] = Vector2i(int(wh[0]), int(wh[1]))
			i += 2
		elif a == "--tab" and i + 1 < raw.size():
			args["tab"] = raw[i + 1]
			i += 2
		elif a == "--replay-last":
			args["replay_last"] = true
			i += 1
		elif a.begins_with("--api="):
			api_base_url = a.substr(6)
			i += 1
		else:
			i += 1


func _apply(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		api_base_url = parsed.get("api_base_url", api_base_url)
		build_version = parsed.get("build_version", build_version)
