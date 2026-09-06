extends Node
## HTTP client, over connections that stay open.
##
## This used to wrap HTTPRequest, which opens a fresh TCP connection and a fresh
## TLS handshake for every single call. Measured against the deployed server that
## is 80 ms per request where a reused connection is 25 ms -- a 3.2x tax on
## everything the game does, and on a phone at ~150 ms RTT the two extra round
## trips of a handshake cost about 300 ms per tap. It is why the game felt slow
## to answer and why a burst of taps queued up visibly.
##
## So each lane keeps one HTTPClient connected and sends request after request
## down it. Lanes are leased the way the old pool was, and the PUBLIC API is
## unchanged -- get_json, post_json and Response are what every caller still
## sees, so nothing else in the client had to move.
##
## A 401 triggers a single refresh attempt and one replay, so a token expiring
## mid-session is invisible to the player.

signal unauthorized  ## refresh failed; the player must sign in again

## The transport failed, or started working again.
##
## Emitted on the edge only, so a screen can hold the player in place through an
## outage without every single request repainting something. What listens to
## these must never sign anyone out: a lost connection is not a lost session.
signal offline
signal online

var _reachable := true

## How long one request may take before it is abandoned. Generous, because
## abandoning a request the server is about to answer is worse than waiting: the
## action still happened, and the client would show the player otherwise.
const TIMEOUT_SECONDS := 20.0

## The reachability check on the loading screen gets a much shorter fuse.
##
## Different question, different answer: an action already in flight is worth
## waiting 20 seconds for, because abandoning it tells the player something
## untrue about what happened. "Can I reach the realm at all" is worth about
## eight, because the honest answer arrives long before then and the player is
## sitting looking at a bar.
const REACHABILITY_TIMEOUT := 8.0

## Two is the right number: one request in flight per lane, and the client is
## deliberately built to ask for one snapshot rather than a dozen resources. More
## lanes would mean more idle sockets for the server to hold open.
const LANES := 2

## Sent so the server knows we intend to reuse the socket. Go's net/http keeps
## HTTP/1.1 connections alive by default, but saying so makes the intent explicit
## and survives a proxy that would otherwise close.
const KEEP_ALIVE := "Connection: keep-alive"


class Response:
	var ok: bool = false
	var status: int = 0
	var data: Dictionary = {}
	var code: String = ""      ## machine-readable error code from the server
	var error: String = ""

	func _init(p_ok: bool, p_status: int, p_data: Dictionary, p_code: String, p_error: String) -> void:
		ok = p_ok; status = p_status; data = p_data; code = p_code; error = p_error


## One reusable connection.
class Lane:
	var http := HTTPClient.new()
	var host := ""
	var port := 0
	var tls := false
	var live := false        ## the socket is open and idle, ready for a request
	var busy := false


var _lanes: Array[Lane] = []


func _ready() -> void:
	for i in LANES:
		_lanes.append(Lane.new())


func get_json(path: String, authed: bool = true, timeout: float = TIMEOUT_SECONDS) -> Response:
	return await _send(HTTPClient.METHOD_GET, path, {}, authed, true, timeout)


func post_json(path: String, body: Dictionary, authed: bool = true) -> Response:
	return await _send(HTTPClient.METHOD_POST, path, body, authed, true, TIMEOUT_SECONDS)


## Fires a request and does not wait for it.
##
## For the one case where waiting is impossible: iOS delivers
## NOTIFICATION_APPLICATION_PAUSED and then stops the display link, so
## process_frame never fires again and any coroutine part-way through a request
## is simply abandoned. Every other call in this file is an await loop over
## process_frame, which means none of them can complete from inside a pause
## handler.
##
## So this writes the request into the socket and returns immediately. The
## kernel usually flushes it; nothing here guarantees that, and nothing should
## depend on it. On the server the leaving beacon only shortens a departure that
## the presence timeout would have produced anyway, so losing it costs a slightly
## later "left", not a wrong answer.
func beacon(path: String, body: Dictionary) -> void:
	for lane in _lanes:
		if lane.live and not lane.busy:
			var headers := PackedStringArray([
				"Accept: application/json",
				"Content-Type: application/json",
				KEEP_ALIVE,
			])
			if Session.access_token != "":
				headers.append("Authorization: Bearer " + Session.access_token)
			# Deliberately unchecked: there is no one left to tell.
			lane.http.request(HTTPClient.METHOD_POST, path, headers, JSON.stringify(body))
			lane.http.poll()
			# The lane is left dirty rather than reused. Whatever the server
			# answers arrives with nobody reading, so the next request on this
			# lane would read the wrong body.
			lane.live = false
			return


func _send(method: int, path: String, body: Dictionary, authed: bool, may_retry: bool,
		timeout: float) -> Response:
	var lane := await _lease()
	if lane == null:
		return _fail(path, "client is shutting down")

	# One retry on a dead socket, and only on a dead socket. A connection the
	# server closed while idle is the normal cost of keeping it open, and the
	# player must never see it -- but a request that reached the server and then
	# failed must NOT be replayed, or a collect could be spent twice.
	var res := await _once(lane, method, path, body, authed, timeout)
	if res.status == 0 and res.code == "transport_predelivery":
		lane.live = false
		res = await _once(lane, method, path, body, authed, timeout)

	lane.busy = false

	if res.status == 401 and authed and may_retry and Session.is_signed_in():
		# A rejected access token is recoverable without bothering the player:
		# refresh once and replay. ANY 401, not just "token_expired" -- a
		# restarted server with a new signing key answers a plain "unauthorized",
		# and refusing to refresh on that signed the player out over something one
		# retry fixes. If the refresh token really is dead, try_refresh signs out.
		if await Session.try_refresh():
			return await _send(method, path, body, authed, false, timeout)

	if res.status == 401 and authed:
		unauthorized.emit()

	return res


## One attempt down one lane.
func _once(lane: Lane, method: int, path: String, body: Dictionary, authed: bool,
		timeout: float) -> Response:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)

	if not await _ensure_connected(lane, deadline):
		return _fail(path, "Cannot reach the server")

	var headers := PackedStringArray([
		"Accept: application/json",
		"Content-Type: application/json",
		KEEP_ALIVE,
	])
	if authed and Session.access_token != "":
		headers.append("Authorization: Bearer " + Session.access_token)

	var payload := JSON.stringify(body) if method == HTTPClient.METHOD_POST else ""
	var err := lane.http.request(method, path, headers, payload)
	if err != OK:
		# The socket was closed under us before a byte went out. Nothing reached
		# the server, so this is the one case that is safe to replay.
		lane.live = false
		return Response.new(false, 0, {}, "transport_predelivery",
			"could not start request (error %d)" % err)

	while lane.http.get_status() == HTTPClient.STATUS_REQUESTING:
		lane.http.poll()
		if Time.get_ticks_msec() > deadline:
			_drop(lane)
			return _fail(path, "The server took too long to answer")
		await get_tree().process_frame

	if not lane.http.has_response():
		# Sent, but the connection died before an answer. The request may well
		# have been applied, so it is NOT replayed.
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

	# Keep the socket unless the server said not to. This is the whole point.
	var connection := str(response_headers.get("Connection",
		response_headers.get("connection", ""))).to_lower()
	lane.live = lane.http.get_status() == HTTPClient.STATUS_CONNECTED and connection != "close"
	if not lane.live:
		lane.http.close()

	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	var data: Dictionary = parsed if parsed is Dictionary else {}

	if not _reachable:
		_reachable = true
		online.emit()

	if status >= 200 and status < 300:
		return Response.new(true, status, data, "", "")
	return Response.new(false, status, data, str(data.get("code", "")),
		str(data.get("message", "request failed")))


## Opens the lane's socket if it is not already open and pointed at the right
## host. Reconnects when the base URL changes, which the tests do.
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
	lane.host = host
	lane.port = port
	lane.tls = tls
	lane.live = false

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


## Waits for a free lane.
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
	if _reachable:
		_reachable = false
	offline.emit()
	return Response.new(false, 0, {}, "transport", message)
