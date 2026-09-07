extends Node
## Credentials and the sign-in lifecycle.
##
## Tokens live in user://session.dat, encrypted with a per-install key. Access
## tokens last 15 minutes and refresh tokens rotate on use, so a stolen refresh
## token is detected the moment the real client uses its copy. Only the server may
## end a session: a lost packet during a refresh is not a dead token.

signal signed_in
signal signed_out

const SESSION_PATH := "user://session.dat"
const KEY_PATH := "user://install.key"

var access_token := ""
var refresh_token := ""
var player_id := ""
var refresh_failed_offline := false
var _refreshing := false


func _ready() -> void:
	_load()
	Api.unauthorized.connect(_on_unauthorized)


func is_signed_in() -> bool:
	return refresh_token != ""


func register(username: String, password: String) -> String:
	var res: Api.Response = await Api.post_json("/v1/auth/register", {
		"username": username, "password": password, "tz_offset_minutes": _tz_offset_minutes()}, false)
	return _consume(res)


func login(username: String, password: String) -> String:
	var res: Api.Response = await Api.post_json("/v1/auth/login", {"username": username, "password": password}, false)
	return _consume(res)


func _consume(res: Api.Response) -> String:
	if not res.ok:
		return res.error
	access_token = str(res.data.get("access_token", ""))
	refresh_token = str(res.data.get("refresh_token", ""))
	player_id = str(res.data.get("player_id", ""))
	_save()
	signed_in.emit()
	return ""


func try_refresh() -> bool:
	if refresh_token == "":
		return false
	if _refreshing:
		while _refreshing:
			await get_tree().process_frame
		return access_token != ""
	_refreshing = true
	var res: Api.Response = await Api.post_json("/v1/auth/refresh", {"refresh_token": refresh_token}, false)
	_refreshing = false
	if not res.ok:
		refresh_failed_offline = res.status == 0
		if res.status == 401 or res.status == 403:
			sign_out()
		return false
	refresh_failed_offline = false
	access_token = str(res.data.get("access_token", ""))
	refresh_token = str(res.data.get("refresh_token", ""))
	player_id = str(res.data.get("player_id", ""))
	_save()
	return true


func sign_out() -> void:
	access_token = ""; refresh_token = ""; player_id = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))
	signed_out.emit()


func _on_unauthorized() -> void:
	if not _refreshing:
		sign_out()


func _install_key() -> PackedByteArray:
	if FileAccess.file_exists(KEY_PATH):
		var f := FileAccess.open(KEY_PATH, FileAccess.READ)
		if f:
			var k := f.get_buffer(32)
			if k.size() == 32:
				return k
	var key := PackedByteArray()
	key.resize(32)
	for i in 32:
		key[i] = randi() % 256
	var out := FileAccess.open(KEY_PATH, FileAccess.WRITE)
	if out:
		out.store_buffer(key)
	return key


func _save() -> void:
	var f := FileAccess.open_encrypted(SESSION_PATH, FileAccess.WRITE, _install_key())
	if f == null:
		push_warning("[session] could not write session file")
		return
	f.store_string(JSON.stringify({"access_token": access_token, "refresh_token": refresh_token, "player_id": player_id}))


func _load() -> void:
	if not FileAccess.file_exists(SESSION_PATH):
		return
	var f := FileAccess.open_encrypted(SESSION_PATH, FileAccess.READ, _install_key())
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		access_token = str(parsed.get("access_token", ""))
		refresh_token = str(parsed.get("refresh_token", ""))
		player_id = str(parsed.get("player_id", ""))


func _tz_offset_minutes() -> int:
	var tz: Dictionary = Time.get_time_zone_from_system()
	return clampi(int(tz.get("bias", 0)), -840, 840)
