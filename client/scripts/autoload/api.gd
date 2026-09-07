extends Node
## HTTP client over connections that stay open.
##
## Each lane keeps one HTTPClient connected and sends request after request down
## it: a reused socket answers in a third of the time of a fresh TLS handshake,
## which on a phone is the difference between a tap that lands and a tap that
## visibly queues. A 401 triggers one refresh and one replay, so a token expiring
## mid-session is invisible. A request that may have reached the server is never
## replayed: a collect must not be spent twice.

signal unauthorized          ## refresh failed; the player must sign in again
signal offline               ## the transport failed (edge-triggered)
signal online                ## the transport works again (edge-triggered)

const TIMEOUT_SECONDS := 20.0
const REACHABILITY_TIMEOUT := 8.0
const LANES := 2


class Response:
	var ok: bool = false
	var status: int = 0
	var data: Dictionary = {}
	var code: String = ""
	var error: String = ""

	func _init(p_ok: bool, p_status: int, p_data: Dictionary, p_code: String, p_error: String) -> void:
		ok = p_ok; status = p_status; data = p_data; code = p_code; error = p_error


class Lane:
	var http := HTTPClient.new()
	var host := ""
	var port := 0
	var tls := false
	var live := false
	var busy := false


var _lanes: Array[Lane] = []
var _reachable := true


func _ready() -> void:
	for i in LANES:
		_lanes.append(Lane.new())


func get_json(path: String, authed: bool = true, timeout: float = TIMEOUT_SECONDS) -> Response:
	return await _send(HTTPClient.METHOD_GET, path, {}, authed, true, timeout)


func post_json(path: String, body: Dictionary, authed: bool = true) -> Response:
	return await _send(HTTPClient.METHOD_POST, path, body, authed, true, TIMEOUT_SECONDS)


## Fire-and-forget, for the one moment (iOS pause) when awaiting is impossible.
func beacon(path: String, body: Dictionary) -> void:
	for lane in _lanes:
		if lane.live and not lane.busy:
			lane.http.request(HTTPClient.METHOD_POST, path, _headers(true), JSON.stringify(body))
			lane.http.poll()
			lane.live = false
			return


func _headers(authed: bool) -> PackedStringArray:
	var h := PackedStringArray(["Accept: application/json", "Content-Type: application/json", "Connection: keep-alive"])
	if authed and Session.access_token != "":
		h.append("Authorization: Bearer " + Session.access_token)
	return h


func _send(method: int, path: String, body: Dictionary, authed: bool, may_retry: bool, timeout: float) -> Response:
	var lane := await _lease()
	if lane == null:
		return _fail(path, "client is shutting down")

	var res := await _once(lane, method, path, body, authed, timeout)
	if res.status == 0 and res.code == "transport_predelivery":
		# Nothing reached the server: the only case that is safe to replay.
		lane.live = false
		res = await _once(lane, method, path, body, authed, timeout)
	lane.busy = false

	if res.status == 401 and authed and may_retry and Session.is_signed_in():
		if await Session.try_refresh():
			return await _send(method, path, body, authed, false, timeout)
	if res.status == 401 and authed:
		unauthorized.emit()
	return res


func _once(lane: Lane, method: int, path: String, body: Dictionary, authed: bool, timeout: float) -> Response:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	if not await _ensure_connected(lane, deadline):
		return _fail(path, "Cannot reach the server")

	var payload := JSON.stringify(body) if method == HTTPClient.METHOD_POST else ""
	var err := lane.http.request(method, path, _headers(authed), payload)
	if err != OK:
		lane.live = false
		return Response.new(false, 0, {}, "transport_predelivery", "could not start request (error %d)" % err)

	while lane.http.get_status() == HTTPClient.STATUS_REQUESTING:
		lane.http.poll()
		if Time.get_ticks_msec() > deadline:
			_drop(lane)
			return _fail(path, "The server took too long to answer")
		await get_tree().process_frame

	if not lane.http.has_response():
		_drop(lane)
		return _fail(path, "The connection dropped")

	var status := lane.http.get_response_code()
	var response_headers := lane.http.get_response_headers_as_dictionary()
	var raw := PackedByteArray()
	while lane.http.get_status() == HTTPClient.STATUS_BODY:
		lane.http.poll()
		var chunk := lane.http.read_response_body_chunk()
		if chunk.size() == 0:
			if Time.get_ticks_msec() > deadline:
				_drop(lane)
				return _fail(path, "The server took too long to answer")
			await get_tree().process_frame
		else:
			raw.append_array(chunk)

	var connection := str(response_headers.get("Connection", response_headers.get("connection", ""))).to_lower()
	lane.live = lane.http.get_status() == HTTPClient.STATUS_CONNECTED and connection != "close"
	if not lane.live:
		lane.http.close()

	var text := raw.get_string_from_utf8().strip_edges()
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var data: Dictionary = parsed if parsed is Dictionary else {}
	if not _reachable:
		_reachable = true
		online.emit()
	if status >= 200 and status < 300:
		return Response.new(true, status, data, "", "")
	return Response.new(false, status, data, str(data.get("code", "")), str(data.get("message", "request failed")))


func _ensure_connected(lane: Lane, deadline: int) -> bool:
	var url := Env.api_base_url
	var tls := url.begins_with("https://")
	var rest := url.trim_prefix("https://").trim_prefix("http://").trim_suffix("/")
	var host := rest
	var port := 443 if tls else 80
	var colon := rest.rfind(":")
	if colon > 0:
		host = rest.substr(0, colon)
		port = int(rest.substr(colon + 1))
	if lane.live and lane.host == host and lane.port == port and lane.tls == tls \
			and lane.http.get_status() == HTTPClient.STATUS_CONNECTED:
		return true
	lane.http.close()
	lane.host = host; lane.port = port; lane.tls = tls; lane.live = false
	var opts: TLSOptions = TLSOptions.client() if tls else null
	if lane.http.connect_to_host(host, port, opts) != OK:
		return false
	while true:
		var st := lane.http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			lane.live = true
			return true
		if st != HTTPClient.STATUS_CONNECTING and st != HTTPClient.STATUS_RESOLVING:
			return false
		lane.http.poll()
		if Time.get_ticks_msec() > deadline:
			lane.http.close()
			return false
		await get_tree().process_frame
	return false


func _drop(lane: Lane) -> void:
	lane.live = false
	lane.http.close()


func _lease() -> Lane:
	while true:
		for lane in _lanes:
			if not lane.busy:
				lane.busy = true
				return lane
		if not is_inside_tree():
			return null
		await get_tree().process_frame
	return null


func _fail(path: String, message: String) -> Response:
	push_warning("[api] %s -> %s" % [path, message])
	_reachable = false
	offline.emit()
	return Response.new(false, 0, {}, "transport", message)
