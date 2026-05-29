@tool
extends PopupPanel

# Blender-style "press Space to search & add a node" popup. Lists instantiable
# Node types; pick one to add it as a child of the current selection (or the
# scene root if nothing is selected), undoably. Set undo_redo before use.

var undo_redo: EditorUndoRedoManager = null

var _search: LineEdit
var _list: ItemList
var _classes: PackedStringArray


func _init() -> void:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(420, 520)
	add_child(vb)

	_search = LineEdit.new()
	_search.placeholder_text = "Search node type..."
	_search.clear_button_enabled = true
	vb.add_child(_search)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_list)

	_search.text_changed.connect(_on_filter)
	_search.text_submitted.connect(_on_submit)
	_search.gui_input.connect(_on_search_gui_input)
	_list.item_activated.connect(_on_item_activated)

	_collect_classes()


func _collect_classes() -> void:
	var out: Array = []
	for c in ClassDB.get_inheriters_from_class("Node"):
		if ClassDB.can_instantiate(c):
			out.append(c)
	out.sort()
	_classes = PackedStringArray(out)


func open() -> void:
	_search.text = ""
	_refresh("")
	popup_centered(Vector2i(420, 520))
	_search.grab_focus()


func _on_filter(text: String) -> void:
	_refresh(text)


func _refresh(text: String) -> void:
	_list.clear()
	var q := text.to_lower()
	for c in _classes:
		if q == "" or c.to_lower().contains(q):
			_list.add_item(c)
	if _list.item_count > 0:
		_list.select(0)


func _on_submit(_text: String) -> void:
	_confirm()


func _on_item_activated(_index: int) -> void:
	_confirm()


func _on_search_gui_input(event: InputEvent) -> void:
	# Let the arrow keys move the list selection while typing, Esc closes.
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed:
			return
		if k.keycode == KEY_ESCAPE:
			hide()
		elif k.keycode == KEY_DOWN and _list.item_count > 0:
			var s := _list.get_selected_items()
			_list.select(mini((s[0] + 1) if s.size() > 0 else 0, _list.item_count - 1))
		elif k.keycode == KEY_UP and _list.item_count > 0:
			var s := _list.get_selected_items()
			_list.select(maxi((s[0] - 1) if s.size() > 0 else 0, 0))


func _confirm() -> void:
	if _list.item_count == 0:
		return
	var sel := _list.get_selected_items()
	var idx := sel[0] if sel.size() > 0 else 0
	_add_node(_list.get_item_text(idx))
	hide()


func _add_node(cls: String) -> void:
	if not ClassDB.can_instantiate(cls):
		return
	var obj = ClassDB.instantiate(cls)
	if not (obj is Node):
		return
	var node: Node = obj

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("[GodotBridge] No scene open to add a node to.")
		node.free()
		return

	var parent: Node = root
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.size() > 0 and selected[0] is Node:
		parent = selected[0]
	node.name = cls

	if undo_redo != null:
		undo_redo.create_action("Add %s" % cls, UndoRedo.MERGE_DISABLE, root)
		undo_redo.add_do_method(self, "_do_add", node, parent, root)
		undo_redo.add_do_reference(node)
		undo_redo.add_undo_method(self, "_do_remove", node)
		undo_redo.commit_action()
	else:
		parent.add_child(node)
		node.owner = root


func _do_add(node: Node, parent: Node, owner: Node) -> void:
	parent.add_child(node)
	node.owner = owner
	var es := EditorInterface.get_selection()
	es.clear()
	es.add_node(node)


func _do_remove(node: Node) -> void:
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
