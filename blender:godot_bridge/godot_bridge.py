# Godot Bridge - exposes Blender settings to Godot.
# Phase 3: a background WebSocket server serves shared_state (JSON) to any
# client. The main-thread timer keeps shared_state up to date; the server
# thread only ever READS shared_state, never bpy.

import bpy
import json
import asyncio
import threading
from websockets.asyncio.server import serve

HOST = "localhost"
PORT = 8765


bl_info = {
    "name": "Godot Bridge",
    "author": "swstl",
    "version": (0, 2, 0),
    "blender": (4, 2, 0),
    "location": "Runs in the background once enabled",
    "description": "Exposes Blender settings to Godot over WebSocket",
    "category": "Development",
}

# Plain Python dict. The main thread writes to it (in _poll_settings); the
# server thread only READS it. Keys are fixed at load time and values are
# plain types, so reading it from another thread is safe (no bpy, and the
# dict never changes size at runtime).
shared_state = {
    "emulate_3_button": False,
    "emulate_3_button_modifier": "ALT",   # "ALT" or "OSKEY"
    "zoom_to_mouse": False,
    "orbit_around_selection": False,
    "invert_zoom_mouse": False,
    "invert_zoom_wheel": False,
    "rotate_method": "TURNTABLE",          # "TURNTABLE" or "TRACKBALL"
}

# Remember the last state we printed so we only log on change.
_last_printed = None

# --- WebSocket server plumbing (lives on a background thread) -------------
_loop = None           # the asyncio event loop running on the server thread
_stop_event = None     # asyncio.Event used to shut the loop down cleanly
_server_thread = None   # the background thread itself


def _poll_settings():
    """Runs on Blender's MAIN thread via bpy.app.timers.

    The only place allowed to touch bpy. Copies settings into shared_state,
    which the server thread reads. Returning a number reschedules the timer.
    """
    global _last_printed

    i = bpy.context.preferences.inputs
    # getattr with a default so a renamed/missing property never crashes the
    # timer - it just keeps the default. Confirm the names in the Python
    # console (see the snippet I gave you) if any value looks stuck.
    shared_state["emulate_3_button"] = i.use_mouse_emulate_3_button
    shared_state["emulate_3_button_modifier"] = getattr(i, "mouse_emulate_3_button_modifier", "ALT")
    shared_state["zoom_to_mouse"] = getattr(i, "use_zoom_to_mouse", False)
    shared_state["orbit_around_selection"] = getattr(i, "use_rotate_around_active", False)
    shared_state["invert_zoom_mouse"] = getattr(i, "invert_mouse_zoom", False)
    shared_state["invert_zoom_wheel"] = getattr(i, "invert_zoom_wheel", False)
    shared_state["rotate_method"] = getattr(i, "view_rotate_method", "TURNTABLE")

    if shared_state != _last_printed:
        print(f"[GodotBridge] emulate_3_button = {shared_state['emulate_3_button']}")
        # store a COPY so it's a frozen snapshot, not a reference to the same
        # dict we keep mutating. Comparing the whole state means adding more
        # settings later "just works".
        _last_printed = dict(shared_state)

    return 0.5  # call me again in 0.5 seconds


async def _handler(websocket):
    """Handles one connected client. Runs on the server thread's loop."""
    print("[GodotBridge] client connected")
    # Push the current state immediately on connect.
    await websocket.send(json.dumps(shared_state))
    try:
        # Then, whenever the client sends anything, reply with latest state.
        async for _message in websocket:
            await websocket.send(json.dumps(shared_state))
    finally:
        print("[GodotBridge] client disconnected")


async def _server_main():
    """Starts the server and waits until told to stop."""
    global _stop_event
    _stop_event = asyncio.Event()
    async with serve(_handler, HOST, PORT):
        print(f"[GodotBridge] WebSocket server on ws://{HOST}:{PORT}")
        await _stop_event.wait()
    print("[GodotBridge] WebSocket server stopped")


def _run_server():
    """Thread entry point: owns its own asyncio event loop."""
    global _loop
    _loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_loop)
    try:
        _loop.run_until_complete(_server_main())
    finally:
        _loop.close()


def register():
    global _server_thread
    print("[GodotBridge] registered")
    bpy.app.timers.register(_poll_settings)

    _server_thread = threading.Thread(target=_run_server, daemon=True, name="GodotBridgeWS")
    _server_thread.start()


def unregister():
    global _server_thread
    if bpy.app.timers.is_registered(_poll_settings):
        bpy.app.timers.unregister(_poll_settings)

    # Ask the server loop (on the other thread) to stop, then wait briefly so
    # the port is released before a possible re-register (e.g. Reload Scripts).
    if _loop is not None and _stop_event is not None:
        _loop.call_soon_threadsafe(_stop_event.set)
    if _server_thread is not None:
        _server_thread.join(timeout=2.0)
        _server_thread = None

    print("[GodotBridge] unregistered")
