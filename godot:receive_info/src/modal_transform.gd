@tool
extends RefCounted

# Blender-style modal transforms for the selected Node3D(s) in the editor.
#
#   G = grab/move, S = scale, R = rotate
#   While transforming:
#     X / Y / Z      lock to that world axis (press again -> local axis)
#     0-9 . -        type an exact amount (distance / factor / degrees)
#     Backspace      delete last typed digit
#     Ctrl (hold)    snap (1 unit / 0.1 scale / 5 degrees)
#     LMB or Enter   confirm (registered as an undoable editor action)
#     RMB or Esc     cancel (revert to original transforms)
#
# Mouse is NOT captured: the cursor moves freely and the object follows,
# exactly like Blender. handle_input() returns true while it owns the input.

enum Op { NONE, MOVE, SCALE, ROTATE }

const SNAP_MOVE := 1.0                 # world units
const SNAP_SCALE := 0.1                # factor increments
const SNAP_ROTATE_DEG := 5.0           # degrees
const PRECISION_FACTOR := 0.1          # cursor speed while Shift is held

# Set by the EditorPlugin so confirms become undoable.
var undo_redo: EditorUndoRedoManager = null

var _op := Op.NONE
var _active := false

var _targets: Array = []               # Array[Node3D]
var _orig: Array = []                  # parallel Array[Transform3D]
var _pivot := Vector3.ZERO

var _axis := -1                        # -1 none, 0 X, 1 Y, 2 Z
var _axis_local := false
var _numeric := ""

# Virtual cursor: advances by raw mouse delta (x0.1 while Shift held for
# precision). All transform math reads this instead of the OS cursor, so
# engaging/releasing Shift slows movement without any jump.
var _cursor := Vector2.ZERO

# Cached at begin() — the camera does not move during a transform.
var _start_mouse := Vector2.ZERO
var _start_world := Vector3.ZERO
var _pivot_screen := Vector2.ZERO
var _start_dist := 1.0


func handle_input(event: InputEvent) -> bool:
	if _active:
		return _handle_active(event)

	# Idle: only react to G/S/R to start a transform.
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_G:
					return _begin(Op.MOVE)
				KEY_S:
					return _begin(Op.SCALE)
				KEY_R:
					return _begin(Op.ROTATE)
				KEY_X:
					return _delete_selected()
				KEY_D:
					if k.shift_pressed:
						return _duplicate_and_grab()
	return false


func _handle_active(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var speed := PRECISION_FACTOR if Input.is_key_pressed(KEY_SHIFT) else 1.0
		_cursor += mm.relative * speed
		_apply()
		return true

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_LEFT:
					_confirm()
				MOUSE_BUTTON_RIGHT:
					_cancel()
		return true  # swallow all clicks (incl. wheel) while transforming

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return true
		match key.keycode:
			KEY_ESCAPE:
				_cancel()
				return true
			KEY_ENTER, KEY_KP_ENTER:
				_confirm()
				return true
			KEY_X:
				_set_axis(0)
				return true
			KEY_Y:
				_set_axis(1)
				return true
			KEY_Z:
				_set_axis(2)
				return true
			KEY_BACKSPACE:
				if _numeric != "":
					_numeric = _numeric.substr(0, _numeric.length() - 1)
				_apply()
				return true

		# Numeric entry (digits, decimal point, sign). Guard unicode == 0
		# (Esc/Shift/Ctrl/arrows/etc.) which would emit a NUL-char warning.
		if key.unicode >= 32:
			var ch := char(key.unicode)
			if "0123456789.-".contains(ch):
				_numeric += ch
				_apply()
				return true

		# Any other key (e.g. Ctrl) just re-applies so snapping updates.
		_apply()
		return true

	return true  # while active, own every event


func _begin(op: int) -> bool:
	return _begin_with(op, _selected_node3ds())


func _begin_with(op: int, sel: Array) -> bool:
	if not _is_mouse_in_3d_viewport():
		return false
	if sel.is_empty():
		return false
	var cam := _get_camera()
	if cam == null:
		return false

	_targets = sel
	_orig = []
	var sum := Vector3.ZERO
	for n in _targets:
		var node: Node3D = n
		_orig.append(node.global_transform)
		sum += node.global_position
	_pivot = sum / float(_targets.size())

	_op = op
	_axis = -1
	_axis_local = false
	_numeric = ""

	_start_mouse = _get_mouse()
	_cursor = _start_mouse
	_start_world = _plane_point(cam, _start_mouse)
	_pivot_screen = cam.unproject_position(_pivot)
	_start_dist = maxf((_start_mouse - _pivot_screen).length(), 0.001)

	_active = true
	return true


func _apply() -> void:
	var cam := _get_camera()
	if cam == null:
		return
	var mouse := _cursor
	match _op:
		Op.MOVE:
			_apply_move(cam, mouse)
		Op.SCALE:
			_apply_scale(cam, mouse)
		Op.ROTATE:
			_apply_rotate(cam, mouse)


func _apply_move(cam: Camera3D, mouse: Vector2) -> void:
	var snap := Input.is_key_pressed(KEY_CTRL)
	var delta := Vector3.ZERO
	var num := _numeric_value()

	if not is_nan(num):
		var a := _axis_vec() if _axis >= 0 else Vector3(1, 0, 0)
		delta = a * num
	else:
		delta = _plane_point(cam, mouse) - _start_world
		if _axis >= 0:
			var a := _axis_vec()
			delta = a * delta.dot(a)
		if snap:
			if _axis >= 0:
				var a := _axis_vec()
				delta = a * snappedf(delta.dot(a), SNAP_MOVE)
			else:
				delta = Vector3(snappedf(delta.x, SNAP_MOVE), snappedf(delta.y, SNAP_MOVE), snappedf(delta.z, SNAP_MOVE))

	for i in _targets.size():
		var node: Node3D = _targets[i]
		var t: Transform3D = _orig[i]
		t.origin += delta
		node.global_transform = t


func _apply_scale(cam: Camera3D, mouse: Vector2) -> void:
	var num := _numeric_value()
	var factor: float
	if not is_nan(num):
		factor = num
	else:
		factor = (mouse - _pivot_screen).length() / _start_dist
		if Input.is_key_pressed(KEY_CTRL):
			factor = snappedf(factor, SNAP_SCALE)

	var s: Basis
	if _axis >= 0:
		s = _scale_along_axis(_axis_vec(), factor)
	else:
		s = Basis.from_scale(Vector3(factor, factor, factor))

	for i in _targets.size():
		var node: Node3D = _targets[i]
		var t: Transform3D = _orig[i]
		node.global_transform = Transform3D(s * t.basis, _pivot + s * (t.origin - _pivot))


func _apply_rotate(cam: Camera3D, mouse: Vector2) -> void:
	var num := _numeric_value()
	var angle: float
	if not is_nan(num):
		angle = deg_to_rad(num)
	else:
		angle = (mouse - _pivot_screen).angle() - (_start_mouse - _pivot_screen).angle()
		if Input.is_key_pressed(KEY_CTRL):
			angle = snappedf(angle, deg_to_rad(SNAP_ROTATE_DEG))

	var axis := _axis_vec() if _axis >= 0 else -cam.global_transform.basis.z
	var r := Basis(axis.normalized(), angle)

	for i in _targets.size():
		var node: Node3D = _targets[i]
		var t: Transform3D = _orig[i]
		node.global_transform = Transform3D(r * t.basis, _pivot + r * (t.origin - _pivot))


func _confirm() -> void:
	if undo_redo != null and not _targets.is_empty():
		undo_redo.create_action("Transform (Blender bridge)")
		for i in _targets.size():
			var node: Node3D = _targets[i]
			undo_redo.add_do_property(node, "global_transform", node.global_transform)
			undo_redo.add_undo_property(node, "global_transform", _orig[i])
		undo_redo.commit_action()
	_finish()


func _cancel() -> void:
	for i in _targets.size():
		var node: Node3D = _targets[i]
		node.global_transform = _orig[i]
	_finish()


func _finish() -> void:
	_active = false
	_op = Op.NONE
	_axis = -1
	_axis_local = false
	_numeric = ""
	_targets = []
	_orig = []


func _set_axis(index: int) -> void:
	if _axis == index:
		_axis_local = not _axis_local  # second press -> local axis
	else:
		_axis = index
		_axis_local = false
	_apply()


func _axis_vec() -> Vector3:
	var base := Vector3(1, 0, 0)
	match _axis:
		1:
			base = Vector3(0, 1, 0)
		2:
			base = Vector3(0, 0, 1)
	if _axis_local and not _orig.is_empty():
		var t: Transform3D = _orig[0]
		return (t.basis * base).normalized()
	return base


# Scaling matrix by `factor` along unit vector `a`: M = I + (f-1) * a (a . v).
func _scale_along_axis(a: Vector3, factor: float) -> Basis:
	var k := factor - 1.0
	var m := Basis.IDENTITY
	m.x = Vector3(1, 0, 0) + a * (k * a.x)
	m.y = Vector3(0, 1, 0) + a * (k * a.y)
	m.z = Vector3(0, 0, 1) + a * (k * a.z)
	return m


func _numeric_value() -> float:
	if _numeric == "" or _numeric == "-" or _numeric == ".":
		return NAN
	return _numeric.to_float()


# Unproject a screen point onto the plane through the pivot facing the camera.
func _plane_point(cam: Camera3D, mouse: Vector2) -> Vector3:
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var n := -cam.global_transform.basis.z
	var denom := dir.dot(n)
	if absf(denom) < 0.000001:
		return _start_world
	return origin + dir * ((_pivot - origin).dot(n) / denom)


func _selected_node3ds() -> Array:
	var out: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is Node3D:
			out.append(n)
	return out


func _get_camera() -> Camera3D:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()


func _get_mouse() -> Vector2:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return Vector2.ZERO
	return vp.get_mouse_position()


func _is_mouse_in_3d_viewport() -> bool:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return false
	return vp.get_visible_rect().has_point(vp.get_mouse_position())


# --- X = delete, Shift+D = duplicate & grab --------------------------------

func _delete_selected() -> bool:
	if not _is_mouse_in_3d_viewport() or undo_redo == null:
		return false
	var root := EditorInterface.get_edited_scene_root()
	var nodes := _editable_selection(root)
	if nodes.is_empty():
		return false

	# custom_context = root pins this to the scene's undo history (the do/undo
	# targets are this RefCounted, which otherwise wouldn't resolve a history).
	undo_redo.create_action("Delete (Blender bridge)", UndoRedo.MERGE_DISABLE, root)
	for n in nodes:
		var node: Node = n
		undo_redo.add_do_method(self, "_remove_node", node)
		undo_redo.add_undo_method(self, "_restore_node", node, node.get_parent(), node.get_index(), node.owner)
		undo_redo.add_undo_reference(node)
	undo_redo.commit_action()
	return true


func _duplicate_and_grab() -> bool:
	if not _is_mouse_in_3d_viewport() or undo_redo == null:
		return false
	var root := EditorInterface.get_edited_scene_root()
	var nodes := _editable_selection(root)
	if nodes.is_empty():
		return false

	var dups: Array = []
	undo_redo.create_action("Duplicate (Blender bridge)", UndoRedo.MERGE_DISABLE, root)
	for n in nodes:
		var node: Node = n
		var dup := node.duplicate()
		undo_redo.add_do_method(self, "_add_node", dup, node.get_parent(), root)
		undo_redo.add_do_reference(dup)
		undo_redo.add_undo_method(self, "_remove_node", dup)
		dups.append(dup)
	undo_redo.commit_action()  # creates the duplicates

	# Reselect the duplicates, then immediately start moving them.
	var es := EditorInterface.get_selection()
	es.clear()
	for d in dups:
		es.add_node(d)
	_begin_with(Op.MOVE, dups)
	return true


# Selected Node3Ds that can be edited (have a parent and aren't the root).
func _editable_selection(root: Node) -> Array:
	var out: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is Node3D and n != root and n.get_parent() != null:
			out.append(n)
	return out


func _add_node(node: Node, parent: Node, owner: Node) -> void:
	parent.add_child(node)
	_set_owner_recursive(node, owner)


func _remove_node(node: Node) -> void:
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)


func _restore_node(node: Node, parent: Node, index: int, owner: Node) -> void:
	parent.add_child(node)
	_set_owner_recursive(node, owner)
	parent.move_child(node, index)


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)
