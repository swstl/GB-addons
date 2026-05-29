@tool
extends RefCounted

# Blender-style navigation for Godot's 3D editor viewport, driven by settings
# imported from Blender. Call handle_input(event) from the EditorPlugin's
# _input (returns true when it consumed the event), and process(delta) from
# _process (advances smooth-view animations).
#
# Trigger mapping (matches Blender):
#   MMB = orbit, Shift+MMB = pan, Ctrl+MMB = zoom   (always available)
#   When emulate_3_button is on, modifier+LMB ALSO works (Alt or Cmd/OSKEY):
#       mod+LMB = orbit, Shift+mod+LMB = pan, Ctrl+mod+LMB = zoom
#   Both paths share the same pivot. Wheel = stepped zoom (always).
#   Alt+MMB click  = recenter the orbit point on whatever is under the cursor
#
# View shortcuts (cursor over the viewport):
#   Numpad . = frame selected, Home = frame all
#   Numpad 1/3/7 = front/right/top (Ctrl+ for back/left/bottom)
#   Numpad 5 = toggle ortho/perspective, Numpad 0 = align to scene camera

const BlenderSettings = preload("res://addons/godot:receive_info/src/blender_settings.gd")

enum Mode { NONE, ORBIT, PAN, ZOOM }

# Tuning constants (calibrated toward Blender's defaults; tweak to taste).
const ORBIT_SENSITIVITY := 0.0075     # radians of orbit per pixel of drag
const ZOOM_DRAG_SENSITIVITY := 0.01   # zoom exponent per pixel of drag
const WHEEL_ZOOM_FACTOR := 1.15       # distance multiplier per wheel notch
const FRAME_MARGIN := 1.3             # extra room when framing

var settings := BlenderSettings.new()

# Persistent orbit point. Survives across orbit/pan/zoom so the center stays
# consistent (Blender keeps one focus point). Only reset by selection-orbit,
# auto-depth, the recenter action, or the very first drag.
var pivot := Vector3.ZERO
var distance := 10.0
var yaw := 0.0
var pitch := 0.0
var _pivot_set := false

var _mode := Mode.NONE
var _active := false
var _trigger_button := -1

# Smooth-view animation state (used by view shortcuts and the recenter action).
var _anim_active := false
var _anim_t := 0.0
var _anim_dur := 0.0
var _anim_from := Transform3D.IDENTITY
var _anim_to := Transform3D.IDENTITY
var _anim_from_size := 0.0
var _anim_to_size := -1.0
var _anim_to_pivot := Vector3.ZERO
var _anim_to_distance := 0.0


func process(delta: float) -> void:
	if not _anim_active:
		return
	var cam := _get_camera()
	if cam == null:
		_anim_active = false
		return
	_anim_t += delta
	var f := 1.0 if _anim_dur <= 0.0 else clampf(_anim_t / _anim_dur, 0.0, 1.0)
	var eased := smoothstep(0.0, 1.0, f)
	cam.global_transform = _anim_from.interpolate_with(_anim_to, eased)
	if _anim_to_size >= 0.0:
		cam.size = lerpf(_anim_from_size, _anim_to_size, eased)
	if f >= 1.0:
		_anim_active = false
		pivot = _anim_to_pivot
		distance = _anim_to_distance


func handle_input(event: InputEvent) -> bool:
	var cam := _get_camera()
	if cam == null:
		return false

	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			if _active and key.keycode == KEY_ESCAPE:
				_end_drag()
				return true
			if _is_mouse_in_3d_viewport() and _handle_view_key(key, cam):
				return true

	if event is InputEventMouseButton:
		return _handle_button(event as InputEventMouseButton, cam)

	if event is InputEventMouseMotion and _active:
		return _handle_motion(event as InputEventMouseMotion, cam)

	return false


# --- View shortcuts --------------------------------------------------------

func _handle_view_key(key: InputEventKey, cam: Camera3D) -> bool:
	match key.keycode:
		KEY_KP_1:
			_set_axis_view(cam, Vector3(0, 0, 1), Vector3.UP, key.ctrl_pressed)   # front / back
		KEY_KP_3:
			_set_axis_view(cam, Vector3(1, 0, 0), Vector3.UP, key.ctrl_pressed)   # right / left
		KEY_KP_7:
			_set_axis_view(cam, Vector3(0, 1, 0), Vector3(0, 0, -1), key.ctrl_pressed)  # top / bottom
		KEY_KP_5:
			_toggle_projection(cam)
		KEY_KP_0:
			_align_to_scene_camera(cam)
		KEY_KP_PERIOD:
			_frame(cam, false)
		KEY_HOME:
			_frame(cam, true)
		_:
			return false
	return true


func _set_axis_view(cam: Camera3D, dir: Vector3, up: Vector3, opposite: bool) -> void:
	_settle_anim(cam)
	var d := -dir if opposite else dir
	var new_pos := pivot + d.normalized() * distance
	var to := Transform3D(Basis.IDENTITY, new_pos).looking_at(pivot, up)
	_animate_to(cam, to, pivot, distance)


func _toggle_projection(cam: Camera3D) -> void:
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	else:
		cam.size = 2.0 * distance * tan(deg_to_rad(cam.fov) * 0.5)
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL


func _align_to_scene_camera(cam: Camera3D) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var cams := root.find_children("*", "Camera3D", true, false)
	if cams.is_empty():
		return
	var scene_cam := cams[0] as Camera3D
	var to := scene_cam.global_transform
	_settle_anim(cam)
	_animate_to(cam, to, to.origin - to.basis.z * distance, distance)


func _frame(cam: Camera3D, frame_all: bool) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var nodes: Array
	if frame_all:
		if root == null:
			return
		nodes = [root]
	else:
		nodes = _selected_node3ds()
		if nodes.is_empty():
			if root == null:
				return
			nodes = [root]

	var aabb := _world_aabb(nodes)
	var center := aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.5, 0.05)
	var forward := -cam.global_transform.basis.z
	var new_distance := radius / sin(deg_to_rad(maxf(cam.fov, 1.0)) * 0.5) * FRAME_MARGIN
	var to := Transform3D(cam.global_transform.basis, center - forward * new_distance)
	var size := -1.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		size = 2.0 * radius * FRAME_MARGIN

	_settle_anim(cam)
	_animate_to(cam, to, center, new_distance, size)


# --- Smooth view animation -------------------------------------------------

func _animate_to(cam: Camera3D, to_xform: Transform3D, to_pivot: Vector3, to_distance: float, to_size := -1.0) -> void:
	var dur := settings.smooth_view_ms / 1000.0
	if dur <= 0.0:
		cam.global_transform = to_xform
		if to_size >= 0.0:
			cam.size = to_size
		pivot = to_pivot
		distance = to_distance
		_pivot_set = true
		return

	_anim_from = cam.global_transform
	_anim_from_size = cam.size
	_anim_to = to_xform
	_anim_to_size = to_size
	_anim_to_pivot = to_pivot
	_anim_to_distance = to_distance
	_anim_t = 0.0
	_anim_dur = dur
	_anim_active = true
	_pivot_set = true


func _settle_anim(cam: Camera3D) -> void:
	if not _anim_active:
		return
	cam.global_transform = _anim_to
	if _anim_to_size >= 0.0:
		cam.size = _anim_to_size
	pivot = _anim_to_pivot
	distance = _anim_to_distance
	_anim_active = false


# --- Mouse navigation ------------------------------------------------------

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
	# MMB always navigates (a real 3-button mouse). Emulate-3-button ADDS
	# modifier+LMB as an alternative -- it does NOT disable MMB. This keeps
	# both paths on the same pivot instead of leaking MMB to Godot's own nav.
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		return true
	if settings.emulate_3_button and event.button_index == MOUSE_BUTTON_LEFT and _modifier_pressed(event):
		return true
	return false


func _modifier_pressed(event: InputEventWithModifiers) -> bool:
	if settings.emulate_modifier == "OSKEY":
		return event.meta_pressed
	return event.alt_pressed


func _begin_drag(event: InputEventMouseButton, cam: Camera3D) -> void:
	_settle_anim(cam)
	_trigger_button = event.button_index

	# Shift = pan, Ctrl = zoom, otherwise orbit (Blender's secondary modifiers).
	if event.shift_pressed:
		_mode = Mode.PAN
	elif event.ctrl_pressed:
		_mode = Mode.ZOOM
	else:
		_mode = Mode.ORBIT

	# Choose the orbit pivot: selection > auto-depth (surface under cursor) >
	# the persistent pivot.
	if _mode == Mode.ORBIT:
		if settings.orbit_around_selection:
			var sel := EditorInterface.get_selection().get_selected_nodes()
			if sel.size() > 0 and sel[0] is Node3D:
				pivot = (sel[0] as Node3D).global_position
				_pivot_set = true
		elif settings.auto_depth:
			pivot = _point_under_mouse(cam)
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
	_settle_anim(cam)
	if settings.invert_zoom_wheel:
		dir = -dir

	var factor := pow(WHEEL_ZOOM_FACTOR, dir)

	# Zoom toward the cursor when zoom-to-mouse or auto-depth is on (persp only).
	var target := pivot
	if (settings.zoom_to_mouse or settings.auto_depth) and cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
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
	# orientation and zoom distance (animated when smooth-view is on).
	_settle_anim(cam)
	var target := _pick_focus_point(cam)
	var forward := -cam.global_transform.basis.z
	var to := Transform3D(cam.global_transform.basis, target - forward * distance)
	_animate_to(cam, to, target, distance)


# --- Picking ---------------------------------------------------------------

# Returns {"found": bool, "point": surface hit, "center": object AABB center}.
func _ray_pick(cam: Camera3D) -> Dictionary:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var mouse := vp.get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var result := {"found": false, "point": Vector3.ZERO, "center": Vector3.ZERO}

	# Nearest visual whose bounding box the ray crosses (no colliders needed).
	var root := EditorInterface.get_edited_scene_root()
	if root:
		var best := INF
		for n in root.find_children("*", "GeometryInstance3D", true, false):
			var vi := n as VisualInstance3D
			var inv := vi.global_transform.affine_inverse()
			var aabb := vi.get_aabb()
			var hit = aabb.intersects_ray(inv * from, inv.basis * dir)
			if hit != null:
				var world_hit := vi.global_transform * (hit as Vector3)
				var d := from.distance_to(world_hit)
				if d < best:
					best = d
					result["found"] = true
					result["point"] = world_hit
					result["center"] = vi.global_transform * aabb.get_center()

	# Fall back to physics colliders, if any.
	if not result["found"]:
		var world := vp.get_world_3d()
		if world:
			var q := PhysicsRayQueryParameters3D.create(from, from + dir * 10000.0)
			var phit := world.direct_space_state.intersect_ray(q)
			if not phit.is_empty():
				result["found"] = true
				result["point"] = phit["position"]
				result["center"] = phit["position"]

	return result


func _point_under_mouse(cam: Camera3D) -> Vector3:
	var p := _ray_pick(cam)
	if p["found"]:
		return p["point"]
	return _fallback_point(cam)


func _pick_focus_point(cam: Camera3D) -> Vector3:
	var p := _ray_pick(cam)
	if p["found"]:
		return p["center"]
	return _fallback_point(cam)


func _fallback_point(cam: Camera3D) -> Vector3:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var mouse := vp.get_mouse_position()
	return cam.project_ray_origin(mouse) + cam.project_ray_normal(mouse) * distance


# --- AABB helpers ----------------------------------------------------------

func _world_aabb(nodes: Array) -> AABB:
	var result := AABB()
	var has := false
	for n in nodes:
		var node: Node = n
		var instances: Array = []
		if node is GeometryInstance3D:
			instances.append(node)
		instances.append_array(node.find_children("*", "GeometryInstance3D", true, false))
		for gi in instances:
			var vi := gi as VisualInstance3D
			var world := _aabb_to_world(vi.get_aabb(), vi.global_transform)
			if not has:
				result = world
				has = true
			else:
				result = result.merge(world)

	if not has:
		# No geometry — fall back to a box around the node origins.
		for n in nodes:
			var node3 := n as Node3D
			if node3:
				if not has:
					result = AABB(node3.global_position, Vector3.ZERO)
					has = true
				else:
					result = result.expand(node3.global_position)
	return result


func _aabb_to_world(local: AABB, t: Transform3D) -> AABB:
	var out := AABB(t * local.get_endpoint(0), Vector3.ZERO)
	for i in range(1, 8):
		out = out.expand(t * local.get_endpoint(i))
	return out


# --- Helpers ---------------------------------------------------------------

func _selected_node3ds() -> Array:
	var out: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is Node3D:
			out.append(n)
	return out


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
	# The 3D SubViewport reports the mouse inside it even when the 2D editor
	# is showing, so also require its container to be actually visible.
	var c := vp.get_parent()
	if c is Control and not (c as Control).is_visible_in_tree():
		return false
	return vp.get_visible_rect().has_point(vp.get_mouse_position())
