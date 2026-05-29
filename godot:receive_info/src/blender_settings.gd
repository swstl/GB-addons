@tool
extends RefCounted

# Typed view of the settings the Blender bridge sends us. Defaults match a
# fresh Blender install so navigation behaves sensibly before the first
# message arrives (or if Blender isn't running).
#
# Referenced via preload() (not class_name) because this addon folder has a
# colon in its name, which breaks Godot's global class_name registration.

var emulate_3_button := false          # MMB scheme vs <modifier>+LMB scheme
var emulate_modifier := "ALT"          # "ALT" or "OSKEY" (Cmd/Super)
var zoom_to_mouse := false             # zoom toward cursor vs viewport center
var orbit_around_selection := false    # orbit around selected node vs free pivot
var invert_zoom_mouse := false         # invert drag-zoom direction
var invert_zoom_wheel := false         # invert wheel-zoom direction
var rotate_method := "TURNTABLE"       # "TURNTABLE" or "TRACKBALL"
var auto_depth := false                # orbit/zoom pivot on surface under cursor
var smooth_view_ms := 200.0            # view-transition duration (ms; 0 = instant)
var spacebar_search := false           # Blender's Spacebar Action == "SEARCH"


# Copy values out of the raw dict from Blender, falling back to defaults.
func apply(d: Dictionary) -> void:
	emulate_3_button = d.get("emulate_3_button", false)
	emulate_modifier = d.get("emulate_3_button_modifier", "ALT")
	zoom_to_mouse = d.get("zoom_to_mouse", false)
	orbit_around_selection = d.get("orbit_around_selection", false)
	invert_zoom_mouse = d.get("invert_zoom_mouse", false)
	invert_zoom_wheel = d.get("invert_zoom_wheel", false)
	rotate_method = d.get("rotate_method", "TURNTABLE")
	auto_depth = d.get("auto_depth", false)
	smooth_view_ms = d.get("smooth_view", 200.0)
	spacebar_search = d.get("spacebar_search", false)
