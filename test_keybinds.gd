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

	# the two focus contexts. The rule they exist for: SPACE, the arrows and TAB are transport
	# keys, so in the MOUSE context nothing may hold focus and take them, and in the KEYBOARD
	# context the same controls must be reachable.
	var probes: Array[Control] = [Button.new(), OptionButton.new(), ItemList.new(), Tree.new(), TabBar.new()]
	var typed := LineEdit.new()
	var mouse_ctx := true
	var kb_ctx := true
	for mode in [false, true]:
		p.set("_kb_nav", mode)
		for probe in probes:
			p.call("_drop_focus", probe)
			var want: int = Control.FOCUS_ALL if mode else Control.FOCUS_NONE
			if mode:
				kb_ctx = kb_ctx and probe.focus_mode == want
			else:
				mouse_ctx = mouse_ctx and probe.focus_mode == want
		# a text field is never touched by either context: typing has to keep working
		var typed_was := typed.focus_mode
		p.call("_drop_focus", typed)
		mouse_ctx = mouse_ctx and typed.focus_mode == typed_was
	var nav_bound: bool = p.call("_action_for_key", KEY_F2) == "kb_nav"
	var contexts := mouse_ctx and kb_ctx and nav_bound
	ok = ok and contexts
	print("focus contexts: mouse takes no focus %s, keyboard takes it %s, LineEdit untouched, F2 enters %s: %s" % [
		mouse_ctx, kb_ctx, nav_bound, contexts])
	for probe in probes:
		probe.free()
	typed.free()

	# --- MIDI ---------------------------------------------------------------------------
	# The same table-and-learn shape as the keys above, so it lives here rather than in a
	# script of its own. MidiMap.midi_test() covers the arithmetic; what is checked here is
	# the half that needs the player: the learn flow, and the dispatch table being complete.
	var midi_pure: bool = MidiMap.midi_test()
	ok = ok and midi_pure
	print("MidiMap.midi_test (keys, channels, both relative encodings, clash, round trip): %s" % midi_pure)

	var map: MidiMap = p.get("_midi")
	var cc := InputEventMIDI.new()
	cc.message = MIDI_MESSAGE_CONTROL_CHANGE
	cc.channel = 0
	cc.controller_number = 16
	cc.controller_value = 100
	p.set("_midi_learn", "crossfader")
	p.call("_finish_midi_learn", cc)
	var learned: bool = map.key_of("crossfader") == "cc:0:16" and str(p.get("_midi_learn")).is_empty()
	ok = ok and learned
	print("MIDI learn binds the control that arrived, and disarms: %s (%s)" % [
		learned, map.label_of("crossfader")])

	# the S2 case: the same CC number on channel 2 is a DIFFERENT control and binds cleanly
	var cc_b := InputEventMIDI.new()
	cc_b.message = MIDI_MESSAGE_CONTROL_CHANGE
	cc_b.channel = 1
	cc_b.controller_number = 16
	cc_b.controller_value = 20
	p.set("_midi_learn", "master_vol")
	p.call("_finish_midi_learn", cc_b)
	var split: bool = map.key_of("master_vol") == "cc:1:16" and map.key_of("crossfader") == "cc:0:16"
	ok = ok and split
	print("deck A ch1 and deck B ch2 on the same CC number stay separate bindings: %s" % split)

	# a clash is refused, and the sitting tenant keeps the control
	p.set("_midi_learn", "boost")
	p.call("_finish_midi_learn", cc)
	var refused: bool = map.key_of("boost").is_empty() and map.action_for("cc:0:16") == "crossfader"
	ok = ok and refused
	print("learning a control that is already bound is refused, not stolen: %s" % refused)

	# a note-off must not bind: a pad sends both, and the release would win
	var off := InputEventMIDI.new()
	off.message = MIDI_MESSAGE_NOTE_OFF
	off.channel = 0
	off.pitch = 36
	p.set("_midi_learn", "play_pause")
	p.call("_finish_midi_learn", off)
	var ignored_off: bool = map.key_of("play_pause").is_empty() \
		and str(p.get("_midi_learn")) == "play_pause"   # still listening for the press
	ok = ok and ignored_off
	print("a note-off does not take the binding, and learn keeps listening: %s" % ignored_off)

	# device enumeration, against mock lists -- the only way to check it on a machine with
	# nothing plugged in, and the empty case is the one people actually hit
	var none := MidiMap.device_note(PackedStringArray([]))
	var one := MidiMap.device_note(PackedStringArray(["Traktor Kontrol S2 MK2"]))
	var many := MidiMap.device_note(PackedStringArray(["Traktor Kontrol S2 MK2", "loopMIDI Port"]))
	var devices: bool = none == "NO MIDI DEVICES FOUND" \
		and one.contains("Traktor Kontrol S2 MK2") and one.begins_with("1 MIDI INPUT") \
		and many.begins_with("2 MIDI INPUTS") and many.contains("loopMIDI Port")
	ok = ok and devices
	print("device enumeration reports its exact names: %s" % devices)
	print("   none -> %s" % none)
	print("   one  -> %s" % one)
	print("   many -> %s" % many)

	# the deck prefix is the whole reason there is one dispatcher and not fifty cases, so the
	# split is checked directly -- an "a_"/"b_" id must reduce to the same bare id its
	# focused-deck twin uses, or the match arm for it silently never fires
	var pairs := {"a_eq_low": "eq_low", "b_cue_3": "cue_3", "a_play_pause": "play_pause",
		"b_jog": "jog", "a_seek": "seek", "crossfader": "crossfader"}
	var split_ok := true
	for id in pairs:
		if p.call("_midi_bare", id) != pairs[id]:
			split_ok = false
	var decks_ok: bool = p.call("_midi_deck", "a_eq_low") == 0 and p.call("_midi_deck", "b_eq_low") == 1
	# and every prefixed action must reduce to an id that is ITSELF in the table
	var orphans: Array[String] = []
	for action in MidiMap.ACTIONS:
		var a := str(action)
		if a.begins_with("a_") or a.begins_with("b_"):
			var bare: String = p.call("_midi_bare", a)
			if not MidiMap.ACTIONS.has(bare) and bare != "select":
				orphans.append(a)
	ok = ok and split_ok and decks_ok and orphans.is_empty()
	print("deck-prefixed ids reduce to their focused-deck twin: %s/%s, orphans %s" % [
		split_ok, decks_ok, orphans])

	# every action in the table must be dispatchable: an id in ACTIONS with no arm in the
	# match statements would bind, light up in the mapper and then do nothing at all
	var missing: Array[String] = []
	for action in MidiMap.ACTIONS:
		var kind: int = MidiMap.ACTIONS[action][2]
		var src := ""
		match kind:
			MidiMap.BUTTON: src = "_midi_button"
			MidiMap.STEPPER: src = "_midi_step"
			MidiMap.FADER: src = "_midi_fader"
		if not p.has_method(src):
			missing.append("%s: no %s" % [action, src])
	var dispatchable: bool = missing.is_empty() and MidiMap.ACTIONS.size() >= 30
	ok = ok and dispatchable
	print("all %d actions have a dispatcher: %s %s" % [MidiMap.ACTIONS.size(), dispatchable, missing])

	print("RESULT ", "PASS" if ok else "FAIL")
	p.free()
	quit(0 if ok else 1)
