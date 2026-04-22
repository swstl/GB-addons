@tool
extends EditorPlugin

var viewport_camera : Camera3D = null
var mouse_down: bool = false
var pivot_point: Vector3 = Vector3.ZERO 
var alt_down: bool = false
var ctrl_down: bool = false
var shift_down: bool = false
var distance: float = 10.0
var base_sensitivity: float = 0.005
var base_distance: float = 3.0

# decide what mode we are in
var is_orbiting: bool = false
var is_panning: bool = false
var is_zooming: bool = false

# for is_orbiting
var yaw: float = 0.0
var pitch: float = 0.0


func _enter_tree():
	print("Plugin new loaded!")
	var viewport = get_editor_interface().get_editor_viewport_3d(0)
	viewport_camera = viewport.get_camera_3d()

	if viewport_camera:
		print("Camera found: ", viewport_camera.name)
	else:
		print("No camera found in the editor viewport.")

func _exit_tree():
	print("Plugin new unloaded!")

func _input(event) -> void:
	if !viewport_camera:
		return

	var sensitivity = base_sensitivity

	# print("Event: ", event)
	# print("pivot piont: ", pivot_point)

	# also handle mouse wheel for zooming
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		if viewport_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
			viewport_camera.size = max(0.1, viewport_camera.size - sensitivity * 100) 
		else:
			var zoom_sensitivity = base_sensitivity * sqrt(500*(viewport_camera.global_position - pivot_point).length())
			viewport_camera.global_position -= (viewport_camera.global_transform.basis.z * zoom_sensitivity)
			distance = (viewport_camera.global_position - pivot_point).length()
		_mark_handeled()


	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if viewport_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
			viewport_camera.size += sensitivity * 100
		else:
			var zoom_sensitivity = base_sensitivity * sqrt(500*(viewport_camera.global_position - pivot_point).length())
			viewport_camera.global_position += (viewport_camera.global_transform.basis.z * zoom_sensitivity)
			distance = (viewport_camera.global_position - pivot_point).length()
		_mark_handeled()


	if event is InputEventMouseButton:
		if viewport_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
			sensitivity = base_sensitivity * 2 
		else:
			sensitivity = base_sensitivity

		if event.button_index == MOUSE_BUTTON_LEFT:
			mouse_down = event.pressed
			if not mouse_down:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				is_orbiting = false
				is_panning = false
				is_zooming = false
			else:
				# alt key handles normal pivoting
				if event.alt_pressed:
					var offset = viewport_camera.global_position - pivot_point
					yaw = atan2(offset.x, offset.z)
					pitch = atan2(offset.y, Vector2(offset.x, offset.z).length())
					_spawn_pivot_point_and_catch_mouse()
					is_orbiting = true
					is_panning = false
					is_zooming = false
				if event.shift_pressed:
					_spawn_pivot_point_and_catch_mouse()
					is_panning = true
					is_orbiting = false
					is_zooming = false
				if event.ctrl_pressed:
					_spawn_pivot_point_and_catch_mouse()
					is_zooming = true
					is_orbiting = false
					is_panning = false

		if event.button_index == MOUSE_BUTTON_MIDDLE and \
		   event.alt_pressed and \
		   event.pressed:
			var old_direction = (viewport_camera.global_position - pivot_point).normalized()
			pivot_point = _get_pivot_under_mouse()
			viewport_camera.global_position = pivot_point + old_direction * distance
			viewport_camera.look_at(pivot_point, Vector3.UP)
			distance = base_distance
			_mark_handeled()


	if is_orbiting or is_panning or is_zooming:
		if event is InputEventMouseMotion and mouse_down:
			# distance since last event
			var delta = event.relative
			var offset = viewport_camera.global_position - pivot_point

			if is_zooming:
				viewport_camera.global_position += offset.normalized() * delta.y * sensitivity * 10
				distance = (viewport_camera.global_position - pivot_point).length()
				_mark_handeled()
				return

			if is_panning:
				var right = viewport_camera.global_transform.basis.x
				var up = viewport_camera.global_transform.basis.y
				var new_sensitivity = base_sensitivity * (viewport_camera.global_position - pivot_point).length()

				viewport_camera.global_position += (-right * delta.x + up * delta.y) * new_sensitivity
				pivot_point += (-right * delta.x + up * delta.y) * new_sensitivity
				_mark_handeled()
				return

			# update yaw and pitch based on mouse movement
			yaw -= delta.x * sensitivity
			pitch += delta.y * sensitivity
			pitch = clamp(pitch, -PI/2 + 0.01, PI/2 - 0.01)

			# calculate the new offset from the pivot point
			var new_offset = Vector3(
				sin(yaw) * cos(pitch),
				sin(pitch),
				cos(yaw) * cos(pitch)
			) * distance

			var up = Vector3.UP if cos(pitch) >= 0 else Vector3.DOWN

			viewport_camera.global_position = pivot_point + new_offset
			viewport_camera.look_at(pivot_point, up)

			_mark_handeled()

	else:
		if event is InputEventMouseMotion and event.alt_pressed:
			_mark_handeled()

func _mark_handeled():
	get_viewport().set_input_as_handled()


func _spawn_pivot_point_and_catch_mouse():
	# set the pivot point infront of the camera at a fixed distance
	pivot_point = viewport_camera.global_position - (viewport_camera.global_transform.basis.z * distance)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mark_handeled()


func _get_pivot_under_mouse() -> Vector3:
	var viewport = get_editor_interface().get_editor_viewport_3d(0)
	var mouse_pos = viewport.get_mouse_position()

	var from = viewport_camera.project_ray_origin(mouse_pos)
	var direction = viewport_camera.project_ray_normal(mouse_pos)

	var space_state = get_tree().get_edited_scene_root().get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, from + direction * 1000)
	var result = space_state.intersect_ray(query)

	if result:
		return result.collider.global_position

	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() > 0 and selected[0] is Node3D:
		return selected[0].global_position

	return pivot_point
