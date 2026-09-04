extends Node
## Minimal HTTP client for milestone M0.
##
## Deliberately small: it proves the transport works. The pooled, cancellable,
## token-refreshing transport described in docs/design/client.md lands in M1,
## once there is an endpoint worth cancelling.
##
## Note for later: Godot's HTTPRequest does NOT reuse connections, so every call
## pays a fresh TLS handshake. That is acceptable for a boot ping and not
## acceptable for a collect loop.

signal request_failed(path: String, message: String)

const TIMEOUT_SECONDS := 10.0

## Result of one call. `ok` distinguishes a usable payload from any failure —
## transport, HTTP status, or malformed JSON — so callers never inspect a
## half-filled response.
class Response:
	var ok: bool = false
	var status: int = 0
	var data: Dictionary = {}
	var error: String = ""

	func _init(p_ok: bool, p_status: int, p_data: Dictionary, p_error: String) -> void:
		ok = p_ok
		status = p_status
		data = p_data
		error = p_error


func get_json(path: String) -> Response:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	add_child(http)

	var url := Env.api_base_url + path
	var err := http.request(url, PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return _fail(path, "could not start request (error %d)" % err)

	var result: Array = await http.request_completed
	http.queue_free()

	# result = [result_code, response_code, headers, body]
	var result_code: int = result[0]
	var status: int = result[1]
	var body: PackedByteArray = result[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		return _fail(path, _describe_transport_error(result_code))

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		return _fail(path, "malformed response body")

	if status < 200 or status >= 300:
		var problem := parsed as Dictionary
		return _fail(path, "server said %d: %s" % [status, problem.get("message", "unknown")], status)

	return Response.new(true, status, parsed as Dictionary, "")


func _fail(path: String, message: String, status: int = 0) -> Response:
	push_warning("[api] %s -> %s" % [path, message])
	request_failed.emit(path, message)
	return Response.new(false, status, {}, message)


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
