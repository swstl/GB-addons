@tool
extends RefCounted

# Adds Blender-style pan/zoom to Godot's 2D editor viewport. Writing
# canvas_transform does NOT move the editor view (the CanvasItemEditor renders
# with its own internal transform), so instead we REMAP our gestures to the
# synthetic mouse events Godot's built-in nav already understands, and inject
# them -- letting the native pan/zoom do the real work.
#
#   Alt+LMB drag        -> pan   (injects a middle-mouse drag)
#   Ctrl+Alt+LMB drag   -> zoom  (injects wheel notches toward the start point)
#
# Driven from the plugin's global _input. Returns true when it consumes an
# event; pan motion is left to propagate so the native pan handles it.

const BlenderSettings = preload("res://addons/godot:receive_info/src/blender_settings.gd")

const ZOOM_PIXELS_PER_NOTCH := 18.0   # vertical drag per injected wheel step

enum Mode { NONE, PAN, ZOOM }

var settings := BlenderSettings.new()

var _mode := Mode.NONE
var _zoom_accum := 0.0
var _zoom_anchor_pos := Vector2.ZERO
var _zoom_anchor_global := Vector2.ZERO


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and mb.alt_pressed and _mode == Mode.NONE and _is_mouse_in_2d_viewport():
				if mb.ctrl_pressed:
					_mode = Mode.ZOOM
					_zoom_accum = 0.0
					_zoom_anchor_pos = mb.position
					_zoom_anchor_global = mb.global_position
				else:
					_mode = Mode.PAN
					_inject_middle(true, mb)
				# Capture the cursor so relative motion keeps flowing past the
				# screen edge -> infinite pan/zoom drag (like Blender).
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				return true
			if not mb.pressed and _mode != Mode.NONE:
				if _mode == Mode.PAN:
					_inject_middle(false, mb)
				_mode = Mode.NONE
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				return true
		return false  # non-LEFT (incl. our injected middle/wheel) -> native nav

	if event is InputEventMouseMotion:
		if _mode == Mode.ZOOM:
			_zoom_drag(event as InputEventMouseMotion)
			return true
		# PAN: let motion propagate so the native pan moves the view.

	return false


func _zoom_drag(mm: InputEventMouseMotion) -> void:
	var dir := -1.0 if settings.invert_zoom_mouse else 1.0
	_zoom_accum += -mm.relative.y * dir  # drag up zooms in
	while _zoom_accum >= ZOOM_PIXELS_PER_NOTCH:
		_zoom_accum -= ZOOM_PIXELS_PER_NOTCH
		_inject_wheel(true)
	while _zoom_accum <= -ZOOM_PIXELS_PER_NOTCH:
		_zoom_accum += ZOOM_PIXELS_PER_NOTCH
		_inject_wheel(false)


func _inject_middle(pressed: bool, src: InputEventMouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_MIDDLE
	ev.pressed = pressed
	ev.position = src.position
	ev.global_position = src.global_position
	ev.button_mask = MOUSE_BUTTON_MASK_MIDDLE if pressed else 0
	Input.parse_input_event(ev)


func _inject_wheel(zoom_in: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if zoom_in else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.factor = 1.0
	ev.position = _zoom_anchor_pos
	ev.global_position = _zoom_anchor_global
	Input.parse_input_event(ev)


func _is_mouse_in_2d_viewport() -> bool:
	var vp := EditorInterface.get_editor_viewport_2d()
	if vp == null:
		return false
	var c := vp.get_parent()
	if c is Control and not (c as Control).is_visible_in_tree():
		return false
	return vp.get_visible_rect().has_point(vp.get_mouse_position())
