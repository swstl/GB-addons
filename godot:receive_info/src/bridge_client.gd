@tool
extends RefCounted

# WebSocket client for the Blender "Godot Bridge" addon (ws://localhost:8765).
# Driven by an external poll(delta) call each frame (from the EditorPlugin).
# Emits settings_changed whenever Blender sends new values.

const BlenderSettings = preload("res://addons/godot:receive_info/src/blender_settings.gd")

signal settings_changed(settings)

const URL := "ws://localhost:8765"
const RECONNECT_INTERVAL := 2.0  # seconds between reconnect attempts
const POLL_INTERVAL := 0.7       # seconds between state requests while connected
const CACHE_PATH := "user://godot_bridge_settings.json"  # last settings from Blender

var settings := BlenderSettings.new()

var _socket: WebSocketPeer = null
var _was_open := false
var _reconnect_timer := 0.0
var _poll_timer := 0.0
var _last_raw := {}


func start() -> void:
	# Seed from the last settings Blender sent us (if any) so navigation
	# matches your real preferences even before Blender connects.
	_load_cache()
	_open_socket()


func stop() -> void:
	if _socket:
		_socket.close()
		_socket = null


func poll(delta: float) -> void:
	# Not connected: count down to the next reconnect attempt.
	if _socket == null:
		_reconnect_timer += delta
		if _reconnect_timer >= RECONNECT_INTERVAL:
			_reconnect_timer = 0.0
			_open_socket()
		return

	_socket.poll()

	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				print("[GodotBridge] connected to Blender")

			while _socket.get_available_packet_count() > 0:
				_on_message(_socket.get_packet().get_string_from_utf8())

			_poll_timer += delta
			if _poll_timer >= POLL_INTERVAL:
				_poll_timer = 0.0
				_socket.send_text("get")

		WebSocketPeer.STATE_CLOSED:
			if _was_open:
				print("[GodotBridge] disconnected from Blender")
			_was_open = false
			_socket = null
			_reconnect_timer = 0.0


func _open_socket() -> void:
	_socket = WebSocketPeer.new()
	if _socket.connect_to_url(URL) != OK:
		_socket = null


func _on_message(text: String) -> void:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[GodotBridge] unexpected message: %s" % text)
		return

	if data != _last_raw:
		_last_raw = data
		settings = BlenderSettings.new()
		settings.apply(data)
		print("[GodotBridge] settings updated: ", data)
		settings_changed.emit(settings)
		_save_cache(data)


func _load_cache() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_DICTIONARY:
		_last_raw = data
		settings = BlenderSettings.new()
		settings.apply(data)
		print("[GodotBridge] loaded cached settings: ", data)
		settings_changed.emit(settings)


func _save_cache(data: Dictionary) -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
