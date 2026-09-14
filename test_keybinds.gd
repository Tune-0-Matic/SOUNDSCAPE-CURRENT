extends SceneTree
## Runnable check for the remappable keybind table: default lookup, a clean rebind,
## refusing a key already bound to a DIFFERENT action, ESC cancelling a capture without
## touching the binding, and the two things Phase 8 added -- a capture that is not open
## must not write a junk entry into _keybinds, and every bound key must be taken off the
## built-in ui_* actions that would otherwise swallow it before _unhandled_input sees it.
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

	# ESC cancels: capture "deck_both" then send ESC -- binding must be untouched
	p.set("_awaiting_rebind", "deck_both")
	p.call("_finish_rebind", KEY_ESCAPE)
	var deck_key: int = binds["deck_both"]
	ok = ok and deck_key == KEY_TAB
	print("ESC cancel: deck_both is still %d (want %d)" % [deck_key, KEY_TAB])

	# the deck keys: [1] and [2] select outright
	var deck_keys: bool = binds.get("deck_a", -1) == KEY_1 and binds.get("deck_b", -1) == KEY_2
	ok = ok and deck_keys
	print("deck selection sits on [1]/[2]: %s" % deck_keys)

	# PURGE: a finish with no capture open must write NOTHING. The old version stored
	# _keybinds[""] = keycode, and that entry then shadowed a real binding in
	# _action_for_key -- whichever came first in the dictionary won, so a working key
	# silently went dead with nothing on screen to say why.
	var before: int = binds.size()
	p.set("_awaiting_rebind", "")
	p.call("_finish_rebind", KEY_J)
	var no_junk: bool = binds.size() == before and not binds.has("")
	ok = ok and no_junk
	print("a finish with no capture open writes no junk entry: %s (size %d -> %d)" % [
		no_junk, before, binds.size()])
	# ...and the same for an action that is not in the table at all
	p.set("_awaiting_rebind", "not_a_real_action")
	p.call("_finish_rebind", KEY_K)
	var unknown_ignored: bool = not binds.has("not_a_real_action")
	ok = ok and unknown_ignored
	print("an unknown action is ignored rather than bound: %s" % unknown_ignored)

	# INPUT MAP: every bound key has to come OFF the ui_* actions, or the focused control
	# eats it first. SPACE is ui_accept, the arrows are ui_left/right/up/down.
	p.call("_sync_input_map")
	var leaks: Array[String] = []
	for ui in p.get("UI_ACTIONS_GUARDED"):
		if not InputMap.has_action(ui):
			continue
		for ev in InputMap.action_get_events(ui):
			if not (ev is InputEventKey):
				continue
			var code: int = ev.keycode if ev.keycode != 0 else ev.physical_keycode
			for action in binds:
				if binds[action] == code:
					leaks.append("%s still holds %s (%s)" % [ui, OS.get_keycode_string(code), action])
	ok = ok and leaks.is_empty()
	print("bound keys stripped from the ui_* actions: %s %s" % [leaks.is_empty(), leaks])

	# ...and it must be idempotent AND reversible: syncing again must not keep eating
	# events, and a key that gets rebound away has to be handed back to its ui_* action.
	var before_events: int = InputMap.action_get_events("ui_accept").size()
	p.call("_sync_input_map")
	var stable: bool = InputMap.action_get_events("ui_accept").size() == before_events
	binds["pause"] = KEY_P            # move PAUSE off SPACE
	p.call("_sync_input_map")
	var space_back := false
	for ev in InputMap.action_get_events("ui_accept"):
		if ev is InputEventKey and (ev.keycode == KEY_SPACE or ev.physical_keycode == KEY_SPACE):
			space_back = true
	ok = ok and stable and space_back
	print("sync is idempotent: %s  //  a freed key returns to ui_accept: %s" % [stable, space_back])

	# media keys ride the same table, so they resolve, rebind and dedupe like the rest
	var media: bool = p.call("_action_for_key", KEY_MEDIAPLAY) == "media_play" \
		and p.call("_action_for_key", KEY_MEDIANEXT) == "media_next" \
		and p.call("_action_for_key", KEY_MEDIAPREVIOUS) == "media_prev" \
		and p.call("_action_for_key", KEY_MEDIASTOP) == "media_stop"
	ok = ok and media
	print("media keys resolve to their transport actions: %s" % media)

	print("RESULT ", "PASS" if ok else "FAIL")
	p.free()
	quit(0 if ok else 1)
