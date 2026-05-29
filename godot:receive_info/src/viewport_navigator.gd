@tool
extends RefCounted

# Blender-style navigation for Godot's 3D editor viewport, driven by settings
# imported from Blender. Call handle_input(event) from the EditorPlugin's
# _input; it returns true when it consumed the event.
#
# Trigger mapping (matches Blender):
#   emulate_3_button == false (real 3-button mouse):
#       MMB = orbit, Shift+MMB = pan, Ctrl+MMB = zoom
#   emulate_3_button == true (modifier + LMB; modifier is Alt or Cmd/OSKEY):
#       mod+LMB = orbit, Shift+mod+LMB = pan, Ctrl+mod+LMB = zoom
#   Wheel        = stepped zoom (always)
#   Alt+MMB click = recenter the orbit point on whatever is under the cursor

const BlenderSettings = preload("res://addons/godot:receive_info/src/blender_settings.gd")

enum Mode { NONE, ORBIT, PAN, ZOOM }

# Tuning constants (calibrated toward Blender's defaults; tweak to taste).
const ORBIT_SENSITIVITY := 0.0075     # radians of orbit per pixel of drag
const ZOOM_DRAG_SENSITIVITY := 0.01   # zoom exponent per pixel of drag
const WHEEL_ZOOM_FACTOR := 1.15       # distance multiplier per wheel notch

var settings := BlenderSettings.new()

# Persistent orbit point. Survives across orbit/pan/zoom so the center stays
# consistent (Blender keeps one focus point). Only reset by selection-orbit,
# the recenter action, or the very first drag.
var pivot := Vector3.ZERO
var distance := 10.0
var yaw := 0.0
var pitch := 0.0
var _pivot_set := false

var _mode := Mode.NONE
var _active := false
var _trigger_button := -1


func handle_input(event: InputEvent) -> bool:
	var cam := _get_camera()
	if cam == null:
		return false

	# Escape cancels an in-progress drag.
	if _active and event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and key.keycode == KEY_ESCAPE:
			_end_drag()
			return true

	if event is InputEventMouseButton:
		return _handle_button(event as InputEventMouseButton, cam)

	if event is InputEventMouseMotion and _active:
		return _handle_motion(event as InputEventMouseMotion, cam)

	return false


func _handle_button(event: InputEventMouseButton, cam: Camera3D) -> bool:
	# Wheel zoom while hovering the viewport.
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		if _is_mouse_in_3d_viewport():
			_zoom_step(cam, -1.0)
			return true
		return false
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if _is_mouse_in_3d_viewport():
			_zoom_step(cam, 1.0)
			return true
		return false

	# Alt+MMB click: recenter the orbit point on whatever is under the cursor.
	if event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE and event.alt_pressed:
		if _is_mouse_in_3d_viewport():
			_recenter_on_cursor(cam)
			return true
		return false

	# Start a drag when the nav trigger is pressed inside the viewport.
	if event.pressed and _is_trigger_button(event) and _is_mouse_in_3d_viewport():
		_begin_drag(event, cam)
		return true

	# End the drag when the same button is released.
	if not event.pressed and _active and event.button_index == _trigger_button:
		_end_drag()
		return true

	return false


func _is_trigger_button(event: InputEventMouseButton) -> bool:
	if settings.emulate_3_button:
		return event.button_index == MOUSE_BUTTON_LEFT and _modifier_pressed(event)
	return event.button_index == MOUSE_BUTTON_MIDDLE


func _modifier_pressed(event: InputEventWithModifiers) -> bool:
	if settings.emulate_modifier == "OSKEY":
		return event.meta_pressed
	return event.alt_pressed


func _begin_drag(event: InputEventMouseButton, cam: Camera3D) -> void:
	_trigger_button = event.button_index

	# Shift = pan, Ctrl = zoom, otherwise orbit (Blender's secondary modifiers).
	if event.shift_pressed:
		_mode = Mode.PAN
	elif event.ctrl_pressed:
		_mode = Mode.ZOOM
	else:
		_mode = Mode.ORBIT

	# Orbit-around-selection overrides the pivot at the start of an orbit.
	if _mode == Mode.ORBIT and settings.orbit_around_selection:
		var sel := EditorInterface.get_selection().get_selected_nodes()
		if sel.size() > 0 and sel[0] is Node3D:
			pivot = (sel[0] as Node3D).global_position
			_pivot_set = true

	# First use ever: seed the persistent pivot in front of the camera.
	if not _pivot_set:
		pivot = cam.global_position - cam.global_transform.basis.z * distance
		_pivot_set = true

	# Seed turntable angles + distance from the camera's current offset.
	var offset := cam.global_position - pivot
	yaw = atan2(offset.x, offset.z)
	pitch = atan2(offset.y, Vector2(offset.x, offset.z).length())
	distance = offset.length()

	_active = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _handle_motion(event: InputEventMouseMotion, cam: Camera3D) -> bool:
	var delta := event.relative
	match _mode:
		Mode.ORBIT:
			if settings.rotate_method == "TRACKBALL":
				_orbit_trackball(cam, delta)
			else:
				_orbit_turntable(cam, delta)
		Mode.PAN:
			_pan(cam, delta)
		Mode.ZOOM:
			_zoom_drag(cam, delta)
	return true


func _orbit_turntable(cam: Camera3D, delta: Vector2) -> void:
	yaw -= delta.x * ORBIT_SENSITIVITY
	pitch += delta.y * ORBIT_SENSITIVITY
	pitch = clamp(pitch, -PI / 2 + 0.01, PI / 2 - 0.01)

	var new_offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * distance

	var up := Vector3.UP if cos(pitch) >= 0 else Vector3.DOWN
	cam.global_position = pivot + new_offset
	cam.look_at(pivot, up)


func _orbit_trackball(cam: Camera3D, delta: Vector2) -> void:
	# Rotate around the camera's own local axes -> free orbit with roll,
	# no gimbal/pole lock. Approximation of Blender's trackball; refine later.
	var b := cam.global_transform.basis
	var rot := Quaternion(b.y.normalized(), -delta.x * ORBIT_SENSITIVITY) * Quaternion(b.x.normalized(), -delta.y * ORBIT_SENSITIVITY)

	var offset := rot * (cam.global_position - pivot)

	var t := cam.global_transform
	t.origin = pivot + offset
	t.basis = (Basis(rot) * b).orthonormalized()
	cam.global_transform = t
	distance = offset.length()


func _pan(cam: Camera3D, delta: Vector2) -> void:
	# True 1:1 pan: the point on the pivot plane under the cursor stays put.
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var vp_height := vp.get_visible_rect().size.y
	if vp_height <= 0.0:
		return

	var world_per_px: float
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		world_per_px = cam.size / vp_height
	else:
		world_per_px = 2.0 * distance * tan(deg_to_rad(cam.fov) * 0.5) / vp_height

	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	var move := (-right * delta.x + up * delta.y) * world_per_px
	cam.global_position += move
	pivot += move


func _zoom_drag(cam: Camera3D, delta: Vector2) -> void:
	# Exponential drag zoom (dragging up zooms in), relative to the pivot.
	var amount := delta.y * ZOOM_DRAG_SENSITIVITY
	if settings.invert_zoom_mouse:
		amount = -amount
	_apply_zoom(cam, pow(2.0, amount), pivot)


func _zoom_step(cam: Camera3D, dir: float) -> void:
	# dir: -1 = zoom in (wheel up), +1 = zoom out (wheel down).
	if settings.invert_zoom_wheel:
		dir = -dir

	var factor := pow(WHEEL_ZOOM_FACTOR, dir)

	# Zoom toward the cursor when enabled (perspective only); else the pivot.
	var target := pivot
	if settings.zoom_to_mouse and cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
		target = _point_under_mouse(cam)

	_apply_zoom(cam, factor, target)


func _apply_zoom(cam: Camera3D, factor: float, target: Vector3) -> void:
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		cam.size = clampf(cam.size * factor, 0.01, 100000.0)
	else:
		# Scale both camera and pivot toward the target. When target == pivot
		# the pivot is unchanged; when target is the cursor, the orbit point
		# eases toward it (Blender's zoom-to-mouse recentering).
		cam.global_position = target + (cam.global_position - target) * factor
		pivot = target + (pivot - target) * factor

	distance = (cam.global_position - pivot).length()


func _recenter_on_cursor(cam: Camera3D) -> void:
	# Center the view on the object under the cursor, keeping the current
	# orientation and zoom distance. Repositioning the camera onto the view
	# axis through the target guarantees it ends up screen-centered.
	var target := _pick_focus_point(cam)
	var forward := -cam.global_transform.basis.z
	pivot = target
	cam.global_position = target - forward * distance
	_pivot_set = true


func _pick_focus_point(cam: Camera3D) -> Vector3:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var mouse := vp.get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)

	# 1) Nearest visual whose bounding box the ray crosses -> its center.
	#    (Works without collision shapes, unlike a physics raycast.)
	var root := EditorInterface.get_edited_scene_root()
	if root:
		var best := INF
		var best_point := Vector3.ZERO
		var found := false
		for n in root.find_children("*", "GeometryInstance3D", true, false):
			var vi := n as VisualInstance3D
			var inv := vi.global_transform.affine_inverse()
			var aabb := vi.get_aabb()
			var hit = aabb.intersects_ray(inv * from, inv.basis * dir)
			if hit != null:
				var d := from.distance_to(vi.global_transform * (hit as Vector3))
				if d < best:
					best = d
					best_point = vi.global_transform * aabb.get_center()
					found = true
		if found:
			return best_point

	# 2) Physics colliders, if the scene has any.
	var world := vp.get_world_3d()
	if world:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 10000.0)
		var hit := world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]

	# 3) Fallback: a point at the current distance along the ray.
	return from + dir * distance


func _point_under_mouse(cam: Camera3D) -> Vector3:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var mouse := vp.get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var ndir := cam.project_ray_normal(mouse)

	# Use the editor viewport's own World3D (type-safe; get_edited_scene_root()
	# returns a plain Node, which has no get_world_3d()).
	var world := vp.get_world_3d()
	if world:
		var q := PhysicsRayQueryParameters3D.create(from, from + ndir * 10000.0)
		var hit := world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]

	# Fallback when nothing is hit: a point at the current distance along the ray.
	return from + ndir * distance


func _end_drag() -> void:
	_active = false
	_mode = Mode.NONE
	_trigger_button = -1
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _get_camera() -> Camera3D:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()


func _is_mouse_in_3d_viewport() -> bool:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return false
	return vp.get_visible_rect().has_point(vp.get_mouse_position())
