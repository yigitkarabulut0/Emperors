extends Node
## Environment configuration.
##
## The API base URL is never baked into code. It is resolved in three steps, each
## overriding the one before:
##
##  1. the compiled-in dev default, 127.0.0.1 -- right for running on this machine
##  2. res://env.build.json, written at export time. A phone cannot be handed a
##     user:// file before its first launch, so a device build has to carry its
##     server address with it
##  3. user://env.json, so an installed build can be repointed without a rebuild

const _DEV_DEFAULT := "http://127.0.0.1:8080"

## Device safe-area insets to pretend we have, for previewing notch layout on a
## desktop that has none. See _parse_fake_safe_area().
const _SAFE_AREA_PRESETS := {
	"none": Vector4(0, 0, 0, 0),
	"se3": Vector4(0, 38, 0, 0),
	"iphone15": Vector4(0, 108, 0, 62),
	"iphone16promax": Vector4(0, 101, 0, 56),
	"ipad": Vector4(0, 32, 0, 28),
}

var api_base_url: String = _DEV_DEFAULT
var build_version: String = "dev"

var fake_safe_area := Vector4.ZERO
var fake_safe_area_on := false

func _ready() -> void:
	# user://env.json wins when present, so a device build can be repointed
	# without recompiling. Shipped builds simply will not have the file.
	for path in ["res://env.build.json", "user://env.json"]:
		_apply(path)
	_parse_fake_safe_area()
	print("[env] api_base_url=", api_base_url, " build=", build_version)


## --fake-safe-area=<preset|l,t,r,b>
##
## A phone's insets cannot be reproduced on a desktop, and the layout they break
## is exactly the layout nobody sees until the build is on a device. This makes
## them a flag, so the notch case is one relaunch away rather than one deploy.
##
## The presets are in stretch units, measured for each device's real viewport, so
## a preview is only faithful at roughly that device's aspect -- run the game at
## a phone-shaped window and it is close enough to judge.
func _parse_fake_safe_area() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if not a.begins_with("--fake-safe-area="):
			continue
		var v := a.substr("--fake-safe-area=".length())
		if _SAFE_AREA_PRESETS.has(v):
			fake_safe_area = _SAFE_AREA_PRESETS[v]
			fake_safe_area_on = v != "none"
		else:
			var parts := v.split(",")
			if parts.size() != 4:
				push_warning("[env] bad --fake-safe-area=%s (want a preset or l,t,r,b)" % v)
				continue
			fake_safe_area = Vector4(
				float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			fake_safe_area_on = true
		print("[env] fake safe area ", v, " -> ", fake_safe_area)


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
