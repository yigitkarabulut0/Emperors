extends Node
## Owns credentials and the sign-in lifecycle.
##
## Tokens live in user://session.dat, encrypted with a per-install random key.
## That is obfuscation, not security: anyone with the device can recover both
## files. It is worth doing anyway because it keeps tokens out of plaintext
## backups and casual inspection, and it costs nothing. The real defence is that
## access tokens expire in 15 minutes and refresh tokens rotate on every use, so
## a stolen refresh token is detected the moment the real client uses its copy.

signal signed_in
signal signed_out

const SESSION_PATH := "user://session.dat"
const KEY_PATH := "user://install.key"

var access_token := ""
var refresh_token := ""
var player_id := ""

var _refreshing := false

## True when the last try_refresh() failed because the network was unreachable
## rather than because the server rejected the token. Boot uses it to keep
## retrying instead of showing the sign-in screen.
var refresh_failed_offline := false


func _ready() -> void:
	_load()
	Api.unauthorized.connect(_on_unauthorized)


func is_signed_in() -> bool:
	return refresh_token != ""


func register(username: String, password: String) -> String:
	var res: Api.Response = await Api.post_json("/v1/auth/register", {
		"username": username,
		"password": password,
		"tz_offset_minutes": _tz_offset_minutes(),
	}, false)
	return _consume(res)


func login(username: String, password: String) -> String:
	var res: Api.Response = await Api.post_json("/v1/auth/login", {
		"username": username, "password": password,
	}, false)
	return _consume(res)


## Returns "" on success, or a human-readable message.
func _consume(res: Api.Response) -> String:
	if not res.ok:
		return res.error
	access_token = str(res.data.get("access_token", ""))
	refresh_token = str(res.data.get("refresh_token", ""))
	player_id = str(res.data.get("player_id", ""))
	_save()
	signed_in.emit()
	return ""


## Exchanges the refresh token. Guarded so several concurrent 401s do not all
## refresh at once — the second would present an already-rotated token, which the
## server correctly treats as theft and would log the player out.
##
## Returns false for a network failure as well as a rejection, but only a
## rejection signs you out. The caller must not treat false as "log in again".
func try_refresh() -> bool:
	if refresh_token == "":
		return false
	if _refreshing:
		while _refreshing:
			await get_tree().process_frame
		return access_token != ""

	_refreshing = true
	var res: Api.Response = await Api.post_json("/v1/auth/refresh", {
		"refresh_token": refresh_token,
	}, false)
	_refreshing = false

	if not res.ok:
		# A dropped packet is not a dead token.
		#
		# This used to sign out on ANY failure, and Api._fail() returns status 0
		# for every transport error -- so one lost packet during a refresh deleted
		# session.dat and the player had to type their password again. On a phone
		# that happens constantly. Only the server may end a session: it answers
		# 401 when the refresh token is genuinely revoked, reused or expired.
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
	access_token = ""
	refresh_token = ""
	player_id = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))
	if FileAccess.file_exists(SESSION_PATH):
		var f := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
		if f: f.store_string("")
	signed_out.emit()


func _on_unauthorized() -> void:
	# Reached only when a refresh has already failed.
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
	f.store_string(JSON.stringify({
		"access_token": access_token,
		"refresh_token": refresh_token,
		"player_id": player_id,
	}))


func _load() -> void:
	if not FileAccess.file_exists(SESSION_PATH):
		return
	var f := FileAccess.open_encrypted(SESSION_PATH, FileAccess.READ, _install_key())
	if f == null:
		# Key rotated or file corrupt. Not an error worth surfacing: the player
		# simply signs in again.
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		access_token = str(parsed.get("access_token", ""))
		refresh_token = str(parsed.get("refresh_token", ""))
		player_id = str(parsed.get("player_id", ""))


## Minutes east of UTC, clamped to the range the server accepts. Used so daily
## resets land at the player's local midnight instead of one global UTC hour.
func _tz_offset_minutes() -> int:
	var tz: Dictionary = Time.get_time_zone_from_system()
	return clampi(int(tz.get("bias", 0)), -840, 840)
