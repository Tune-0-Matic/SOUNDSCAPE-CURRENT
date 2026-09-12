extends SceneTree
## Runnable check for the remappable keybind table: default lookup, a clean rebind,
## refusing a key already bound to a DIFFERENT action, and ESC cancelling a capture
## without touching the binding.
##   godot --headless --path . --script res://test_keybinds.gd

func _initialize() -> void:
	var p := PanelContainer.new()
	p.set_script(load("res://player.gd"))
	var spec: Dictionary = p.get("KEYBIND_SPEC")
	var binds: Dictionary = p.get("_keybinds")
	for action in spec:
		binds[action] = spec[action][1]   # mirrors the unconditional seed in _ready

	var ok := true

	# default lookup: SPACE resolves to "pause"
	var found: String = p.call("_action_for_key", KEY_SPACE)
	ok = ok and found == "pause"
	print("SPACE -> %s (want pause)" % found)

	# clean rebind: mark_mode from M to G
	p.set("_awaiting_rebind", "mark_mode")
	p.call("_finish_rebind", KEY_G)
	var after_rebind: String = p.call("_action_for_key", KEY_G)
	var old_gone: String = p.call("_action_for_key", KEY_M)
	ok = ok and after_rebind == "mark_mode" and old_gone == ""
	print("mark_mode rebound M -> G: G resolves to %s, M resolves to '%s'" % [after_rebind, old_gone])

	# conflict refusal: try to bind "cursor" onto seek_fwd's key (RIGHT) -- must refuse
	p.set("_awaiting_rebind", "cursor")
	p.call("_finish_rebind", KEY_RIGHT)
	var cursor_key: int = binds["cursor"]
	ok = ok and cursor_key == KEY_H   # unchanged
	print("cursor rebind onto a taken key refused: cursor is still %d (want %d)" % [cursor_key, KEY_H])

	# ESC cancels: capture "deck_toggle" then send ESC -- binding must be untouched
	p.set("_awaiting_rebind", "deck_toggle")
	p.call("_finish_rebind", KEY_ESCAPE)
	var deck_key: int = binds["deck_toggle"]
	ok = ok and deck_key == KEY_TAB
	print("ESC cancel: deck_toggle is still %d (want %d)" % [deck_key, KEY_TAB])

	print("RESULT ", "PASS" if ok else "FAIL")
	p.free()
	quit(0 if ok else 1)
