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

var api_base_url: String = _DEV_DEFAULT
var build_version: String = "dev"

func _ready() -> void:
	# user://env.json wins when present, so a device build can be repointed
	# without recompiling. Shipped builds simply will not have the file.
	for path in ["res://env.build.json", "user://env.json"]:
		_apply(path)
	print("[env] api_base_url=", api_base_url, " build=", build_version)


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
