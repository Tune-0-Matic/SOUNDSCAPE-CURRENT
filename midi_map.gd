class_name MidiMap
extends RefCounted
## What a MIDI message means. The table of assignable actions, the bindings that point at them,
## and every piece of arithmetic that turns a 0-127 byte into something the player can use.
##
## None of this touches the player: it is a lookup and some sums, so the whole thing is testable
## without a window, an audio bus or a controller. player.gd owns the window, the learn flow and
## the dispatch; this owns what a binding IS.
##
## WHY THE CHANNEL IS IN THE KEY. A Traktor Kontrol S2 sends deck A on channel 1 and deck B on
## channel 2, and reuses the SAME controller numbers across the two -- the left and right volume
## faders are both CC 16. Keying on the controller number alone would make those one binding, and
## half the surface of the controller unmappable. The key is "cc:<channel>:<number>", so they are
## two bindings and cannot collide.

## Absolute controls send where they ARE. Relative ones -- jog wheels, endless browse encoders --
## send how far they MOVED, around a neutral value, and there are two conventions in the wild for
## saying that. Neither can be told from the other by looking at one message, so this is a choice
## per binding rather than a guess per event.
enum { MODE_ABS, MODE_REL64, MODE_REL2C }
const MODE_NAMES := ["ABS", "REL 64", "REL 2C"]

## What a binding DOES with its value.
##   BUTTON  -- fires once on note-on, or on a CC crossing half way. Value is ignored.
##   FADER   -- a continuous value. Absolute writes the position; relative nudges it.
##   STEPPER -- whole clicks: browse a list, step a palette. Never writes an absolute position,
##              because "jump to the 87th palette" is not a thing anyone wants from a knob.
enum { BUTTON, FADER, STEPPER }

## action id -> [label, group, kind]. Order is the order the mapper draws them, exactly as
## KEYBIND_SPEC drives the keybind rows in TBS.
##
## IDS ARE STRUCTURED, not arbitrary: an "a_" or "b_" prefix names the deck and the rest is the
## same id the focused-deck action uses, so player.gd splits one off the other with two lines
## instead of fifty explicit cases. Keep that shape when adding to this table -- "a_eq_low" works
## because "eq_low" exists.
##
## Every one of these calls something that already exists in the player. Nothing here is a
## feature waiting to be written -- see the gaps note at the bottom of this file for the three
## DJ controls that are NOT in this table, and why.
const ACTIONS := {
	# --- the focused deck: what the transport bar is showing ---
	"play_pause":  ["PLAY / PAUSE", "DECK", BUTTON],
	"stop":        ["STOP", "DECK", BUTTON],
	"next":        ["NEXT TRACK", "DECK", BUTTON],
	"prev":        ["PREVIOUS TRACK", "DECK", BUTTON],
	"seek":        ["SEEK POSITION", "DECK", FADER],
	"jog":         ["JOG NUDGE", "DECK", STEPPER],
	"seek_back":   ["SEEK BACK", "DECK", BUTTON],
	"seek_fwd":    ["SEEK FORWARD", "DECK", BUTTON],
	"cue_set":     ["CUE SET HERE", "DECK", BUTTON],
	"cue_1":       ["CUE 1", "DECK", BUTTON],
	"cue_2":       ["CUE 2", "DECK", BUTTON],
	"cue_3":       ["CUE 3", "DECK", BUTTON],
	"cue_4":       ["CUE 4", "DECK", BUTTON],
	"eq_low":      ["EQ LOW", "DECK", FADER],
	"eq_mid":      ["EQ MID", "DECK", FADER],
	"eq_high":     ["EQ HIGH", "DECK", FADER],
	"sync":        ["BEAT SYNC", "DECK", BUTTON],
	"cue_del_1":   ["CUE 1 CLEAR", "DECK", BUTTON],
	"cue_del_2":   ["CUE 2 CLEAR", "DECK", BUTTON],
	"cue_del_3":   ["CUE 3 CLEAR", "DECK", BUTTON],
	"cue_del_4":   ["CUE 4 CLEAR", "DECK", BUTTON],
	# --- the decks BY NAME, addressed directly ---
	#
	# These do NOT take focus. Every one of them drives its own deck's player, EQ rack and
	# markers by index, so the right-hand side of a controller can run deck B while the screen
	# is still showing deck A -- which is the only way a two-deck surface is usable at all.
	# SELECT is here for when moving the screen IS what you want.
	"a_play_pause": ["A PLAY / PAUSE", "DECK A", BUTTON],
	"a_stop":      ["A STOP", "DECK A", BUTTON],
	"a_select":    ["A SELECT (MOVES FOCUS)", "DECK A", BUTTON],
	"a_seek":      ["A SEEK POSITION", "DECK A", FADER],
	"a_jog":       ["A JOG NUDGE", "DECK A", STEPPER],
	"a_next":      ["A NEXT TRACK", "DECK A", BUTTON],
	"a_prev":      ["A PREVIOUS TRACK", "DECK A", BUTTON],
	"a_sync":      ["A BEAT SYNC", "DECK A", BUTTON],
	"a_cue_set":   ["A CUE SET HERE", "DECK A", BUTTON],
	"a_cue_1":     ["A CUE 1", "DECK A", BUTTON],
	"a_cue_2":     ["A CUE 2", "DECK A", BUTTON],
	"a_cue_3":     ["A CUE 3", "DECK A", BUTTON],
	"a_cue_4":     ["A CUE 4", "DECK A", BUTTON],
	"a_eq_low":    ["A EQ LOW", "DECK A", FADER],
	"a_eq_mid":    ["A EQ MID", "DECK A", FADER],
	"a_eq_high":   ["A EQ HIGH", "DECK A", FADER],
	"b_play_pause": ["B PLAY / PAUSE", "DECK B", BUTTON],
	"b_stop":      ["B STOP", "DECK B", BUTTON],
	"b_select":    ["B SELECT (MOVES FOCUS)", "DECK B", BUTTON],
	"b_seek":      ["B SEEK POSITION", "DECK B", FADER],
	"b_jog":       ["B JOG NUDGE", "DECK B", STEPPER],
	"b_next":      ["B NEXT TRACK", "DECK B", BUTTON],
	"b_prev":      ["B PREVIOUS TRACK", "DECK B", BUTTON],
	"b_sync":      ["B BEAT SYNC", "DECK B", BUTTON],
	"b_cue_set":   ["B CUE SET HERE", "DECK B", BUTTON],
	"b_cue_1":     ["B CUE 1", "DECK B", BUTTON],
	"b_cue_2":     ["B CUE 2", "DECK B", BUTTON],
	"b_cue_3":     ["B CUE 3", "DECK B", BUTTON],
	"b_cue_4":     ["B CUE 4", "DECK B", BUTTON],
	"b_eq_low":    ["B EQ LOW", "DECK B", FADER],
	"b_eq_mid":    ["B EQ MID", "DECK B", FADER],
	"b_eq_high":   ["B EQ HIGH", "DECK B", FADER],
	# --- the mixer ---
	"crossfader":  ["CROSSFADER", "MIXER", FADER],
	"auto_fade":   ["AUTO FADE ACROSS", "MIXER", BUTTON],
	"master_vol":  ["MASTER VOLUME", "MIXER", FADER],
	"boost":       ["VOLUME BOOST", "MIXER", FADER],
	"both":        ["DECK A+B", "MIXER", BUTTON],
	# --- the library, for the browse encoder ---
	"browse":      ["BROWSE TRACKS", "LIBRARY", STEPPER],
	"load_a":      ["LOAD TO DECK A", "LIBRARY", BUTTON],
	"load_b":      ["LOAD TO DECK B", "LIBRARY", BUTTON],
	# --- everything else ---
	"viz_mode":    ["VISUALIZER MODE", "GLOBAL", STEPPER],
	"viz_color":   ["VISUALIZER COLOUR", "GLOBAL", STEPPER],
	"viz_full":    ["VIZ FULLSCREEN", "GLOBAL", BUTTON],
	"os_full":     ["OS FULLSCREEN", "GLOBAL", BUTTON],
	"mark":        ["MARK MODE", "GLOBAL", BUTTON],
	# The controller's own SHIFT, so a pad grid can do two things. Held rather than pressed:
	# player.gd reads this one's value on EVERY message instead of only on the press, which is
	# what a modifier needs and what nothing else here wants.
	"shift":       ["SHIFT (HOLD)", "GLOBAL", BUTTON],
}

## Actions whose RELEASE matters as much as their press. Everything else fires once and forgets.
const HELD := ["shift"]

## action -> {"kind": "cc"|"note", "ch": int, "num": int, "mode": int}
## Empty by default: an unbound program is the right thing to ship, because a default map for a
## controller nobody has plugged in would fire actions off stray messages from whatever they did.
var binds := {}

# --- reading an event ------------------------------------------------------
## The lookup key for a message, or "" for a message type this does not map. Aftertouch, pitch
## bend and program change are deliberately not mapped: the S2 does not send them for anything
## a person would want to bind, and accepting them would make the learn flow catch stray traffic.
static func event_key(e: InputEventMIDI) -> String:
	match e.message:
		MIDI_MESSAGE_CONTROL_CHANGE:
			return "cc:%d:%d" % [e.channel, e.controller_number]
		MIDI_MESSAGE_NOTE_ON, MIDI_MESSAGE_NOTE_OFF:
			return "note:%d:%d" % [e.channel, e.pitch]
	return ""

## The 0-127 payload, whichever field this message carries it in.
static func event_value(e: InputEventMIDI) -> int:
	match e.message:
		MIDI_MESSAGE_CONTROL_CHANGE:
			return e.controller_value
		MIDI_MESSAGE_NOTE_ON:
			return e.velocity
		MIDI_MESSAGE_NOTE_OFF:
			return 0
	return 0

## Whether this message should make a BUTTON fire. A note-off never does, and neither does a
## note-on at velocity 0 -- which is how a great many controllers say "released", the S2 included.
static func is_press(e: InputEventMIDI) -> bool:
	if e.message == MIDI_MESSAGE_NOTE_ON:
		return e.velocity > 0
	if e.message == MIDI_MESSAGE_CONTROL_CHANGE:
		return e.controller_value >= 64
	return false

static func to_unit(v: int) -> float:
	return clampf(float(v) / 127.0, 0.0, 1.0)

## What the device row and the status line say about a list of connected inputs. Pure, so the
## enumeration can be checked against mock lists -- which is the only way to check it at all on a
## machine with no controller plugged in.
##
## The exact string Godot hands back is printed rather than summarised: a controller can enumerate
## under a name nobody expects ("2- Traktor Kontrol S2 MK2", a vendor's own wrapper port), and
## knowing which of several ports is the one sending is the whole question when nothing arrives.
static func device_note(names: PackedStringArray) -> String:
	if names.is_empty():
		return "NO MIDI DEVICES FOUND"
	if names.size() == 1:
		return "1 MIDI INPUT: %s" % names[0]
	return "%d MIDI INPUTS, USING %s  //  ALSO: %s" % [names.size(), names[0],
		", ".join(Array(names).slice(1))]

## The monitor line. Channels are printed 1-16 the way every controller's own documentation
## numbers them, while the event carries 0-15 -- getting that backwards is an hour of wondering
## why the manual disagrees with the screen.
static func describe(e: InputEventMIDI) -> String:
	var what := ""
	match e.message:
		MIDI_MESSAGE_CONTROL_CHANGE:
			what = "CC %-3d   VAL %d" % [e.controller_number, e.controller_value]
		MIDI_MESSAGE_NOTE_ON:
			what = "NOTE %-3d VEL %d" % [e.pitch, e.velocity]
		MIDI_MESSAGE_NOTE_OFF:
			what = "NOTE %-3d OFF" % e.pitch
		MIDI_MESSAGE_PITCH_BEND:
			what = "PITCH BEND (NOT MAPPABLE)"
		_:
			what = "MESSAGE %d (NOT MAPPABLE)" % e.message
	return "DEV %d   //   CH %d   //   %s" % [e.device, e.channel + 1, what]

## How far a relative encoder moved, in clicks. Zero for the neutral value, and zero for a mode
## that has no delta to give.
##
## REL64 is binary offset: 64 is "no movement", 65 is one click forward, 63 one back.
## REL2C is two's complement: 1 is one click forward, 127 one back, and the high half is negative.
## They disagree about almost every value, which is exactly why this is a stored choice and not
## something inferred from the stream.
static func rel_delta(v: int, mode: int) -> int:
	match mode:
		MODE_REL64:
			return v - 64
		MODE_REL2C:
			return v if v < 64 else v - 128
	return 0

# --- the bindings ----------------------------------------------------------
## Points `action` at the control that sent `e`. Returns "" on success, or the name of the action
## already holding that control.
##
## A clash is REFUSED, not stolen -- the same rule the keyboard rebind follows. Stealing leaves
## the robbed action silently dead with nothing on screen to say so, and on a control surface
## where one physical fader now drives something you did not expect, that is worse than a message.
func bind(action: String, e: InputEventMIDI, mode := MODE_ABS) -> String:
	if not ACTIONS.has(action):
		return "?"
	var key := event_key(e)
	if key.is_empty():
		return "?"
	var held := action_for(key)
	if not held.is_empty() and held != action:
		return held
	var parts := key.split(":")
	binds[action] = {"kind": parts[0], "ch": int(parts[1]), "num": int(parts[2]), "mode": mode}
	return ""

func clear(action: String) -> void:
	binds.erase(action)

func key_of(action: String) -> String:
	var b: Dictionary = binds.get(action, {})
	if b.is_empty():
		return ""
	return "%s:%d:%d" % [b["kind"], int(b["ch"]), int(b["num"])]

## Which action a key drives, or "". Linear over at most ~35 bindings, and a jog wheel sends about
## a hundred messages a second, so this stays a scan rather than a second index to keep in step.
func action_for(key: String) -> String:
	for action in binds:
		if key_of(action) == key:
			return action
	return ""

func mode_of(action: String) -> int:
	return int((binds.get(action, {}) as Dictionary).get("mode", MODE_ABS))

func set_mode(action: String, mode: int) -> void:
	if binds.has(action):
		binds[action]["mode"] = posmod(mode, MODE_NAMES.size())

## What the mapper row shows: "CH1 CC16", or a dash. The mode is NOT in here -- it is on the
## button immediately to the right, and printing it twice cost the row 60 px it did not have.
##
## The channel IS in here, because a controller in the wrong mode sends everything on channel 1,
## and seeing that is the difference between a five-minute fix and an evening.
func label_of(action: String) -> String:
	var b: Dictionary = binds.get(action, {})
	if b.is_empty():
		return "--"
	var what: String = "CC%d" % int(b["num"]) if str(b["kind"]) == "cc" else "NOTE%d" % int(b["num"])
	return "CH%d %s" % [int(b["ch"]) + 1, what]

# --- persistence -----------------------------------------------------------
func to_dict() -> Dictionary:
	return binds.duplicate(true)

## Rebuilt entry by entry rather than assigned wholesale: library.cfg is a text file a person can
## and will hand-edit, and one malformed entry must cost that entry rather than the whole map. A
## duplicate is dropped the way a duplicate keybind is -- first writer keeps it -- because two
## actions on one fader is a state the mapper itself refuses to create.
func from_dict(d: Dictionary) -> void:
	binds = {}
	var seen := {}
	for action in d:
		if not ACTIONS.has(action) or not (d[action] is Dictionary):
			continue
		var b: Dictionary = d[action]
		var kind := str(b.get("kind", ""))
		if kind != "cc" and kind != "note":
			continue
		var ch := int(b.get("ch", -1))
		var num := int(b.get("num", -1))
		if ch < 0 or ch > 15 or num < 0 or num > 127:
			continue
		var key := "%s:%d:%d" % [kind, ch, num]
		if seen.has(key):
			push_warning("midi: %s dropped, %s was already bound to it" % [action, seen[key]])
			continue
		seen[key] = action
		binds[str(action)] = {"kind": kind, "ch": ch, "num": num,
			"mode": clampi(int(b.get("mode", MODE_ABS)), 0, MODE_NAMES.size() - 1)}

# --- check -----------------------------------------------------------------
## Pure, so the whole translation layer is checkable with no controller, window or audio bus.
## Called from player.gd's boot asserts and from test_keybinds.gd.
static func midi_test() -> bool:
	var m := MidiMap.new()
	var cc := InputEventMIDI.new()
	cc.message = MIDI_MESSAGE_CONTROL_CHANGE
	cc.channel = 0
	cc.controller_number = 16
	cc.controller_value = 127
	# the S2 case: the SAME controller number on another channel is another control
	var cc_b := InputEventMIDI.new()
	cc_b.message = MIDI_MESSAGE_CONTROL_CHANGE
	cc_b.channel = 1
	cc_b.controller_number = 16
	cc_b.controller_value = 0
	var note := InputEventMIDI.new()
	note.message = MIDI_MESSAGE_NOTE_ON
	note.channel = 0
	note.pitch = 36
	note.velocity = 100
	var note_off := InputEventMIDI.new()
	note_off.message = MIDI_MESSAGE_NOTE_OFF
	note_off.channel = 0
	note_off.pitch = 36
	var zero_vel := InputEventMIDI.new()
	zero_vel.message = MIDI_MESSAGE_NOTE_ON
	zero_vel.channel = 0
	zero_vel.pitch = 36
	zero_vel.velocity = 0

	var keys_split := event_key(cc) == "cc:0:16" and event_key(cc_b) == "cc:1:16" \
		and event_key(note) == "note:0:36" and event_key(cc) != event_key(cc_b)
	var binds_ok := m.bind("eq_low", cc) == "" and m.bind("eq_high", cc_b) == "" \
		and m.action_for("cc:0:16") == "eq_low" and m.action_for("cc:1:16") == "eq_high"
	# the same control twice: refused, and the sitting tenant keeps it
	var clash := m.bind("crossfader", cc) == "eq_low" and m.action_for("cc:0:16") == "eq_low"
	# rebinding an action to a new control is not a clash with itself
	var rebind := m.bind("eq_low", cc) == "" and m.key_of("eq_low") == "cc:0:16"
	var presses := is_press(note) and not is_press(note_off) and not is_press(zero_vel)
	var units := to_unit(0) == 0.0 and to_unit(127) == 1.0 and absf(to_unit(64) - 0.5039) < 0.001
	var rel := rel_delta(65, MODE_REL64) == 1 and rel_delta(63, MODE_REL64) == -1 \
		and rel_delta(64, MODE_REL64) == 0 \
		and rel_delta(1, MODE_REL2C) == 1 and rel_delta(127, MODE_REL2C) == -1 \
		and rel_delta(0, MODE_REL2C) == 0 \
		and rel_delta(65, MODE_ABS) == 0
	# channels print 1-based, the way every controller's own documentation numbers them
	var labels := m.label_of("eq_low") == "CH1 CC16" and m.label_of("eq_high") == "CH2 CC16" \
		and m.label_of("stop") == "--"
	m.set_mode("eq_low", MODE_REL64)
	var modes: bool = m.mode_of("eq_low") == MODE_REL64 \
		and str(MODE_NAMES[m.mode_of("eq_low")]) == "REL 64"

	var round_trip := MidiMap.new()
	round_trip.from_dict(m.to_dict())
	var survives := round_trip.key_of("eq_low") == "cc:0:16" \
		and round_trip.mode_of("eq_low") == MODE_REL64 \
		and round_trip.key_of("eq_high") == "cc:1:16"
	# junk in the config costs its own entry and nothing else
	var junk := MidiMap.new()
	junk.from_dict({"eq_low": {"kind": "cc", "ch": 0, "num": 16, "mode": 0},
		"not_an_action": {"kind": "cc", "ch": 0, "num": 20},
		"eq_mid": "not a dictionary",
		"eq_high": {"kind": "sysex", "ch": 0, "num": 1},
		"boost": {"kind": "cc", "ch": 99, "num": 1},
		"stop": {"kind": "cc", "ch": 0, "num": 16}})   # duplicate of eq_low: dropped
	var filtered := junk.binds.size() == 1 and junk.key_of("eq_low") == "cc:0:16"

	m.clear("eq_low")
	var cleared := m.key_of("eq_low").is_empty() and m.action_for("cc:0:16").is_empty()

	return keys_split and binds_ok and clash and rebind and presses and units and rel \
		and labels and modes and survives and filtered and cleared
