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
## --capture-after <seconds>, --capture-size <WxH>, --tab <name>, --page <name>,
## --replay-last, --inset <units>, --api=<url>. Only honoured in non-release builds.
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
	args = parse_args(OS.get_cmdline_user_args())
	if args.has("api"):
		api_base_url = str(args["api"])
		args.erase("api")


## The dev flags in a list of user args. Static and pure, so a test can hand it
## any list.
##
## Every branch moves past exactly the words it read. Two did not: --replay-last
## never moved at all, so a run that asked to replay the last battle hung before
## the first frame, and --page moved one word instead of two, so the page's name
## was read again as a flag.
static func parse_args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		var a: String = raw[i]
		if a == "--dev-login" and i + 2 < raw.size():
			out["dev_login"] = [raw[i + 1], raw[i + 2]]
			i += 3
		elif a == "--capture" and i + 1 < raw.size():
			out["capture"] = raw[i + 1]
			i += 2
		elif a == "--capture-after" and i + 1 < raw.size():
			out["capture_after"] = float(raw[i + 1])
			i += 2
		elif a == "--capture-size" and i + 1 < raw.size():
			# WxH in canvas units: 941x2040 is a 19.5:9 phone's canvas.
			var wh: PackedStringArray = raw[i + 1].split("x")
			if wh.size() == 2:
				out["capture_size"] = Vector2i(int(wh[0]), int(wh[1]))
			i += 2
		elif a == "--tab" and i + 1 < raw.size():
			out["tab"] = raw[i + 1]
			i += 2
		elif a == "--scroll" and i + 1 < raw.size():
			# Dev capture only: how far down the screen's own scroll the shot
			# is taken (scripts/dev/proof.gd).
			out["scroll"] = raw[i + 1].to_float()
			i += 2
		elif a == "--sub" and i + 1 < raw.size():
			# A sub-tab inside the tab --tab opened: the Attack tab's ARENA,
			# CAMPAIGN and BOUNTIES, and the Kingdom's four sections. A page is
			# a page (--page); a sub-tab is a tab's body.
			out["sub"] = raw[i + 1]
			i += 2
		elif a == "--replay-last":
			out["replay_last"] = true
			i += 1
		elif a == "--lord" and i + 1 < raw.size():
			# Whose page --page rival opens: a lord's id. Without it the page
			# opens on the first lord the raid list offers, which on a fresh
			# realm is nobody.
			out["lord"] = raw[i + 1]
			i += 2
		elif a == "--page" and i + 1 < raw.size():
			# Opens one of the pages over the game on arrival, for a capture.
			out["page"] = raw[i + 1]
			i += 2
		elif a == "--inset" and i + 1 < raw.size():
			# The notch's height in canvas units (141 under a Dynamic Island on
			# a 941x2040 canvas), as a phone reports it: a desktop capture has
			# no safe area to read, so the top inset is otherwise never seen.
			out["inset"] = float(raw[i + 1])
			i += 2
		elif a.begins_with("--api="):
			out["api"] = a.substr(6)
			i += 1
		else:
			i += 1
	return out


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
