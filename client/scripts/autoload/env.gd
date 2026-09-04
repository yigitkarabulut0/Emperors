extends Node
## Environment configuration.
##
## The API base URL is not baked into the binary: it comes from an override file
## on disk (dev) or from the export feature set (release). This is what lets one
## build point at localhost, the VPS, or a teammate's machine without a rebuild.

const _DEV_DEFAULT := "http://127.0.0.1:8080"

var api_base_url: String = _DEV_DEFAULT
var build_version: String = "dev"

func _ready() -> void:
	# user://env.json wins when present, so a device build can be repointed
	# without recompiling. Shipped builds simply will not have the file.
	var path := "user://env.json"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				api_base_url = parsed.get("api_base_url", api_base_url)
				build_version = parsed.get("build_version", build_version)
	print("[env] api_base_url=", api_base_url)
