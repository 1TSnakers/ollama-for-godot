# ollama.gd
# Godot 4.x – Fixed for tool-calling, name conflict, and add_child during setup.
# Uses get_tree().root.add_child(http) to avoid ERR_UNCONFIGURED.

extends Node
class_name OllamaClient

var BaseURL: String = "http://127.0.0.1:11434"

# ----------------------------------------------------------------------
# Core chat request – flexible enough for tools, keep_alive, stream, etc.
# ----------------------------------------------------------------------
func prompt_model(
		model: String,
		messages: Array,
		output_full_message: bool = false,
		optional_params: Dictionary = {}
) -> Variant:

	# Create a fresh HTTPRequest
	var http: HTTPRequest = HTTPRequest.new()

	# Add to root – always safe, even during scene setup
	get_tree().root.add_child(http)

	# ------------------------------------------------------------------
	# Build request body
	# ------------------------------------------------------------------
	var request_body: Dictionary = {
		"model": model,
		"messages": messages,
	}
	request_body["keep_alive"] = optional_params["keep_alive"] if optional_params.has("keep_alive") else 5
	request_body["stream"]     = optional_params["stream"]     if optional_params.has("stream")     else false

	# Merge any extra keys the caller supplied (tools, tool_choice, …)
	for key in optional_params.keys():
		if key != "keep_alive" and key != "stream":
			request_body[key] = optional_params[key]

	var json_body: String = JSON.stringify(request_body)

	var err: int = http.request("%s/api/chat" % BaseURL, [], HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_error("prompt_model – request failed to start: %s" % err)
		http.queue_free()
		return null

	var result = await http.request_completed
	http.queue_free()   # clean up the request node

	var response_code: int = result[1]
	var body = result[3]

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("prompt_model – could not parse JSON")
		return null

	var output = parsed.get("message", {})

	if output_full_message:
		var conv = messages.duplicate()
		conv.append(output)
		output = conv

	if SharedConstants.more_logging:
		print("[Ollama] POST /api/chat – %s" % response_code)
		print("[Ollama] Body: %s" % SharedFunctions.shorten_string(body.get_string_from_utf8()))
		print("[Ollama] Output: %s" % SharedFunctions.shorten_string(str(output)))
		print("---")

	return output


# ----------------------------------------------------------------------
# Helper to build a “tool” role message
# ----------------------------------------------------------------------
# Renamed 'name' → 'tool_name' to avoid shadowing Node.name
func create_tool_message(
	tool_call_id: String, 
	content: String, 
	tool_name: String = ""
) -> Dictionary:
	var msg: Dictionary = {
		"role": "tool",
		"content": content,
		"tool_call_id": tool_call_id,
	}
	if tool_name != "":
		msg["name"] = tool_name   # ← now it's safe to use "name" as a key in the dict
	return msg


# ----------------------------------------------------------------------
# Load a model (or change its keep‑alive timeout)
# ----------------------------------------------------------------------
func load_model(
	model: String, 
	keep_alive: int = 300
) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	get_tree().root.add_child(http)   # ← always safe

	var request_body: Dictionary = {
		"model": model,
		"keep_alive": keep_alive,
		"messages": [],
	}
	var json_body: String = JSON.stringify(request_body)

	var err: int = http.request("%s/api/chat" % BaseURL, [], HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_error("load_model – request failed to start: %s" % err)
		http.queue_free()
		return

	var result = await http.request_completed
	http.queue_free()

	if SharedConstants.more_logging:
		var resp_code = result[1]
		var body = result[3]
		print("[Ollama] load_model – %s (code %d)" % [model, resp_code])
		print("[Ollama] Body: %s" % SharedFunctions.shorten_string(body.get_string_from_utf8()))
		print("---")


# ----------------------------------------------------------------------
# Unload a model (keep_alive = 0)
# ----------------------------------------------------------------------
func unload_model(model: String) -> void:
	await load_model(model, 0)


# Returns locally installed Ollama models, optionally filtered by capabilities.
#
# filters:
#   Dictionary of capability requirements.
#   Example:
#     {
#       "vision": true,
#       "tools": false
#     }
#
#   - If a key is NOT present → that capability is ignored
#   - If key == true          → model MUST have that capability
#   - If key == false         → model MUST NOT have that capability
#
# no_parse:
#   If true, returns raw model entries from /api/tags
#   If false, returns a list of model name strings
#
func get_models(
	filters: Dictionary = {},
	no_parse: bool = false
) -> Array:
	var tags_http := HTTPRequest.new()
	get_tree().root.add_child(tags_http)

	var tags_err = tags_http.request("%s/api/tags" % BaseURL)
	if tags_err != OK:
		if SharedConstants.more_logging:
			print("[Ollama] GET /api/tags – request failed (%s)" % tags_err)
			print("---")
		tags_http.queue_free()
		return []

	var tags_result = await tags_http.request_completed
	tags_http.queue_free()

	var tags_body: String = tags_result[3].get_string_from_utf8()
	var tags_parsed = JSON.parse_string(tags_body)
	if typeof(tags_parsed) != TYPE_DICTIONARY:
		if SharedConstants.more_logging:
			print("[Ollama] GET /api/tags – invalid JSON")
			print("[Ollama] Body: %s" % SharedFunctions.shorten_string(tags_body))
			print("---")
		return []

	var tag_models: Array = tags_parsed.get("models", [])
	if SharedConstants.more_logging:
		print("[Ollama] GET /api/tags – %d models found" % tag_models.size())

	var filtered_models: Array = []

	for entry in tag_models:
		var full_name: String = entry.get("name", "")
		var base_name := full_name.split(":")[0]

		var caps := await _fetch_capabilities(base_name)
		if caps.is_empty():
			continue

		var reject := false
		for key in filters.keys():
			if filters[key] == true and not caps.has(key):
				reject = true
				break
			if filters[key] == false and caps.has(key):
				reject = true
				break

		if reject:
			if SharedConstants.more_logging:
				print("[Ollama] Model filtered out: %s (caps=%s)" % [
					full_name,
					str(caps)
				])
			continue

		filtered_models.append(entry)

	if SharedConstants.more_logging:
		print("[Ollama] get_models – %d models matched filters %s" % [
			filtered_models.size(),
			str(filters)
		])
		print("---")

	if no_parse:
		return filtered_models

	var model_names: Array = []
	for e in filtered_models:
		model_names.append(e.get("name", ""))

	return model_names



# Cache to avoid repeated HTTP calls for the same model base name
var _cap_cache := {}

# Fetches capability metadata for a base model name
# (e.g. "qwen3-vl") from the hosted search API.
#
# Returns:
#   Array of capability strings, e.g.:
#     ["vision", "tools", "thinking"]
#
func _fetch_capabilities(
	model_base_name: String
) -> Array:
	if _cap_cache.has(model_base_name):
		if SharedConstants.more_logging:
			print("[Ollama] Capabilities cache hit: %s" % model_base_name)
		return _cap_cache[model_base_name]

	var cap_http := HTTPRequest.new()
	get_tree().root.add_child(cap_http)

	var cap_url := "https://1tsnakers-ollamasearchapi.hf.space/library/%s" % model_base_name
	var cap_err = cap_http.request(cap_url)
	if cap_err != OK:
		if SharedConstants.more_logging:
			print("[Ollama] GET /library/%s – request failed (%s)" % [
				model_base_name,
				cap_err
			])
			print("---")
		cap_http.queue_free()
		return []

	var cap_result = await cap_http.request_completed
	cap_http.queue_free()

	var cap_body: String = cap_result[3].get_string_from_utf8()
	var cap_parsed = JSON.parse_string(cap_body)
	if typeof(cap_parsed) != TYPE_DICTIONARY:
		if SharedConstants.more_logging:
			print("[Ollama] GET /library/%s – invalid JSON" % model_base_name)
			print("[Ollama] Body: %s" % SharedFunctions.shorten_string(cap_body))
			print("---")
		return []

	var capabilities: Array = cap_parsed.get("capabilities", [])
	_cap_cache[model_base_name] = capabilities

	if SharedConstants.more_logging:
		print("[Ollama] GET /library/%s – capabilities: %s" % [
			model_base_name,
			str(capabilities)
		])
		print("---")

	return capabilities

# ----------------------------------------------------------------------
# High‑level helper that automatically does tool‑calling.
# ----------------------------------------------------------------------
# Parameters:
#   model: String – model name to use
#   messages: Array – conversation history
#   tool_definitions: Array – list of tool schemas
#   tool_handler: Callable – function to handle tool calls
#   optional_params: Dictionary – additional params (keep_alive, stream, etc.)
#   output_full_message: bool – if true, returns full conversation history including all messages
# ----------------------------------------------------------------------
func prompt_with_tool_handling(
		model: String,
		messages: Array,
		tool_definitions: Array,
		tool_handler: Callable,
		output_full_message: bool = false,  # ← NEW PARAMETER
		optional_params: Dictionary = {}
) -> Variant:
	optional_params["tools"] = tool_definitions
	optional_params["tool_choice"] = "auto"

	var first_reply = await prompt_model(model, messages, output_full_message, optional_params)  # ← PASS IT HERE
	if typeof(first_reply) != TYPE_DICTIONARY:
		return first_reply

	if first_reply.has("tool_calls"):
		var tool_calls = first_reply["tool_calls"]
		var tool_responses : Array = []

		for tc in tool_calls:
			var fn = tc.get("function", {})
			var name = fn.get("name", "")
			var args = fn.get("arguments", {})  # ← already a dict
			if typeof(args) != TYPE_DICTIONARY:
				args = {}

			# ✅ FIX: Remove 'index' if it exists — Ollama's Go backend can't handle float index
			if fn.has("index"):
				fn.erase("index")

			var result_str = tool_handler.call(name, args)
			var tool_msg = create_tool_message(tc.get("id", ""), result_str, name)
			tool_responses.append(tool_msg)

		var new_messages = messages.duplicate()
		new_messages.append(first_reply)      # assistant message that asked for tools
		new_messages.append_array(tool_responses)

		# Second request – no need to resend the tool schema.
		# Pass output_full_message through here too
		return await prompt_model(model, new_messages, output_full_message, {})  # ← PASS IT HERE TOO

	return first_reply
