@tool
extends EditorPlugin

# Thin orchestrator: owns the Blender bridge client and the viewport navigator,
# feeds imported settings into the navigator, and forwards editor input to it.
#
# Scripts are pulled in via preload() rather than class_name, because this
# addon folder has a colon in its name (class_name registration breaks, but
# explicit res:// paths resolve fine).

const BlenderBridgeClient = preload("res://addons/godot:receive_info/src/bridge_client.gd")
const ViewportNavigator = preload("res://addons/godot:receive_info/src/viewport_navigator.gd")
const ModalTransform = preload("res://addons/godot:receive_info/src/modal_transform.gd")

var _client: BlenderBridgeClient
var _nav: ViewportNavigator
var _modal: ModalTransform


func _enter_tree() -> void:
	_client = BlenderBridgeClient.new()
	_nav = ViewportNavigator.new()
	_modal = ModalTransform.new()
	_modal.undo_redo = get_undo_redo()  # makes transform confirms undoable

	# Start with whatever defaults the client has, then track live updates.
	_nav.settings = _client.settings
	_client.settings_changed.connect(_on_settings_changed)
	_client.start()

	set_process(true)
	print("[GodotBridge] plugin enabled")


func _exit_tree() -> void:
	if _client:
		_client.stop()
	_client = null
	_nav = null
	_modal = null
	print("[GodotBridge] plugin disabled")


func _process(delta: float) -> void:
	if _client:
		_client.poll(delta)


func _on_settings_changed(settings) -> void:
	if _nav:
		_nav.settings = settings


func _input(event: InputEvent) -> void:
	# Modal transform gets first dibs so it owns input while transforming.
	if _modal and _modal.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if _nav and _nav.handle_input(event):
		get_viewport().set_input_as_handled()
