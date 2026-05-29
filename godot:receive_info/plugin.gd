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
const CanvasNavigator = preload("res://addons/godot:receive_info/src/canvas_navigator.gd")
const NodeSearch = preload("res://addons/godot:receive_info/src/node_search.gd")

var _client: BlenderBridgeClient
var _nav: ViewportNavigator
var _modal: ModalTransform
var _canvas: CanvasNavigator
var _node_search: NodeSearch


func _enter_tree() -> void:
	_client = BlenderBridgeClient.new()
	_nav = ViewportNavigator.new()
	_modal = ModalTransform.new()
	_modal.undo_redo = get_undo_redo()  # makes transform confirms undoable
	_canvas = CanvasNavigator.new()
	_node_search = NodeSearch.new()
	_node_search.undo_redo = get_undo_redo()
	EditorInterface.get_base_control().add_child(_node_search)

	# Start with whatever defaults the client has, then track live updates.
	_nav.settings = _client.settings
	_canvas.settings = _client.settings
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
	_canvas = null
	if _node_search:
		_node_search.queue_free()
		_node_search = null
	print("[GodotBridge] plugin disabled")


func _process(delta: float) -> void:
	if _client:
		_client.poll(delta)
	if _nav:
		_nav.process(delta)  # advances smooth-view animations


func _on_settings_changed(settings) -> void:
	if _nav:
		_nav.settings = settings
	if _canvas:
		_canvas.settings = settings


func _input(event: InputEvent) -> void:
	# Modal transform gets first dibs so it owns input while transforming.
	if _modal and _modal.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if _open_node_search_if_requested(event):
		get_viewport().set_input_as_handled()
		return
	if _nav and _nav.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if _canvas and _canvas.handle_input(event):
		get_viewport().set_input_as_handled()


func _open_node_search_if_requested(event: InputEvent) -> bool:
	if _node_search == null or _node_search.visible:
		return false
	if not (event is InputEventKey):
		return false
	var k := event as InputEventKey
	if not (k.pressed and not k.echo and k.keycode == KEY_SPACE):
		return false
	# Only when Blender's Spacebar Action is "Search" and the cursor is over
	# a viewport (so it doesn't hijack Space while typing elsewhere).
	if _nav == null or not _nav.settings.spacebar_search:
		return false
	if not _mouse_in_viewport():
		return false
	_node_search.open()
	return true


func _mouse_in_viewport() -> bool:
	var viewports := [EditorInterface.get_editor_viewport_3d(0), EditorInterface.get_editor_viewport_2d()]
	for vp in viewports:
		if vp == null:
			continue
		var c = vp.get_parent()
		if c is Control and not (c as Control).is_visible_in_tree():
			continue
		if vp.get_visible_rect().has_point(vp.get_mouse_position()):
			return true
	return false
