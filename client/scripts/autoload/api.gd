extends Node
## HTTP client.
##
## Godot's HTTPRequest is a Node and handles one request at a time, so this pools
## a small number of them rather than creating one per call. It also does NOT
## reuse connections, so every call pays a TLS handshake — acceptable at the
## rate this game talks to the server, and the reason the client asks for one
## snapshot rather than a dozen resources.
##
## A 401 triggers a single refresh attempt and one replay, so a token expiring
## mid-session is invisible to the player.

signal unauthorized  ## refresh failed; the player must sign in again

const TIMEOUT_SECONDS := 15.0
const POOL_SIZE := 4

var _pool: Array[HTTPRequest] = []
var _busy: Array[HTTPRequest] = []
var _slot_freed := Signal()

class Response:
	var ok: bool = false
	var status: int = 0
	var data: Dictionary = {}
	var code: String = ""      ## machine-readable error code from the server
	var error: String = ""

	func _init(p_ok: bool, p_status: int, p_data: Dictionary, p_code: String, p_error: String) -> void:
		ok = p_ok; status = p_status; data = p_data; code = p_code; error = p_error


func _ready() -> void:
	for i in POOL_SIZE:
		var h := HTTPRequest.new()
		h.timeout = TIMEOUT_SECONDS
		add_child(h)
		_pool.append(h)


func get_json(path: String, authed: bool = true) -> Response:
	return await _send(HTTPClient.METHOD_GET, path, {}, authed, true)


func post_json(path: String, body: Dictionary, authed: bool = true) -> Response:
	return await _send(HTTPClient.METHOD_POST, path, body, authed, true)


func _send(method: int, path: String, body: Dictionary, authed: bool, may_retry: bool) -> Response:
	var http := await _lease()
	if http == null:
		return _fail(path, "client is shutting down")

	var headers := PackedStringArray([
		"Accept: application/json",
		"Content-Type: application/json",
	])
	if authed and Session.access_token != "":
		headers.append("Authorization: Bearer " + Session.access_token)

	var payload := JSON.stringify(body) if method == HTTPClient.METHOD_POST else ""
	var err := http.request(Env.api_base_url + path, headers, method, payload)
	if err != OK:
		_release(http)
		return _fail(path, "could not start request (error %d)" % err)

	var result: Array = await http.request_completed
	_release(http)

	var result_code: int = result[0]
	var status: int = result[1]
	var raw: PackedByteArray = result[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		return _fail(path, _describe_transport_error(result_code))

	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	var data: Dictionary = parsed if parsed is Dictionary else {}

	if status >= 200 and status < 300:
		return Response.new(true, status, data, "", "")

	var code := str(data.get("code", ""))

	# A rejected access token is recoverable without bothering the player: refresh
	# once and replay. Only one retry, or a server that always 401s would loop.
	#
	# ANY 401 on an authenticated call, not just code "token_expired". The refresh
	# token lives in Postgres and survives things the access token does not: a
	# restarted server with a new signing key, a rotated key, clock skew. Those
	# all come back as a plain "unauthorized", and refusing to refresh on them
	# signed the player out over something a single retry would have fixed. If
	# the refresh token really is dead, try_refresh() signs out anyway.
	if status == 401 and authed and may_retry and Session.is_signed_in():
		if await Session.try_refresh():
			return await _send(method, path, body, authed, false)

	if status == 401 and authed:
		unauthorized.emit()

	return Response.new(false, status, data, code, str(data.get("message", "request failed")))


## Waits for a free HTTPRequest node.
func _lease() -> HTTPRequest:
	while _pool.is_empty():
		await get_tree().process_frame
		if not is_inside_tree():
			return null
	var h: HTTPRequest = _pool.pop_back()
	_busy.append(h)
	return h


func _release(h: HTTPRequest) -> void:
	_busy.erase(h)
	_pool.append(h)


func _fail(path: String, message: String) -> Response:
	push_warning("[api] %s -> %s" % [path, message])
	return Response.new(false, 0, {}, "transport", message)


## Turns an HTTPRequest result code into something a player can act on. The raw
## code is kept in parentheses because it is what makes a bug report useful.
func _describe_transport_error(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "Cannot reach the server (%d)" % code
		HTTPRequest.RESULT_TIMEOUT:
			return "The server took too long to answer (%d)" % code
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "The connection dropped (%d)" % code
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Could not establish a secure connection (%d)" % code
		_:
			return "Network error (%d)" % code
