class_name Prefs
extends RefCounted
## What this phone remembers between runs that is nobody's business but its
## own: when the game was last on screen, whether the first-run tour was seen.
## Game state never lives here -- the server holds all of that.

const PATH := "user://prefs.cfg"


static func get_value(key: String, fallback: Variant = null) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return fallback
	return cfg.get_value("prefs", key, fallback)


static func set_value(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value("prefs", key, value)
	cfg.save(PATH)
