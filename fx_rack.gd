class_name FxRack
extends Node
## The dynamic FX rack: a blank rack you add modules to at runtime, one per deck bus.
##
## NOTHING IS ALLOCATED AT RUNTIME, and that is the whole design. Every module's
## AudioEffect is created and inserted ONCE in setup(), disabled; "ADD EFFECT" only
## flips set_bus_effect_enabled on a slot that has existed since boot. AudioServer's
## add_bus_effect/remove_bus_effect rebuild every effect INSTANCE on the bus and take
## the audio driver lock to do it -- which is also what invalidates a cached analyser
## handle (see AudioDirector._bind_analyser). Measured on this build, a runtime
## insert did not audibly starve the deck feed, but a 60 Hz energy sample cannot prove
## sample-accurate glitch-freeness and the lock is taken either way. Pre-allocation
## makes the question moot instead of hoping: the bus effect COUNT is constant for the
## life of the program, which test_fx_rack.gd asserts directly.
##
## ponytail: one instance per module type per deck, so a rack cannot hold two Wahs.
## Pre-allocating N copies of each type is the upgrade if stacking ever matters.
##
## The rack inserts its modules just AHEAD of the deck limiter Equalizer puts on the end of the
## bus, so everything the rack adds -- AMPLIFY, CLIP, OVERDRIVE, a reverb tail -- is limited on
## the deck before it reaches the crossfader. It used to append past that limiter, where only
## the MASTER limiter saw its output (audit D4).

## Module table. Every module is [display name, {float params}, {switches}, {choices}]
## and the UI is generated from it -- a new module is one entry here and nothing in
## player.gd, the same way Equalizer.FX_SPEC already drives the old fixed rack.
##   params:   key -> [label, min, max, default]
##   switches: key -> [label, default]
##   choices:  key -> [label, [options...], default]
## Every module carries MIX, and MIX is a TRUE parallel wet/dry: each module sits between the two
## halves of an SsParallel pair (libsoundscape_dsp, ss_parallel.h). The TAP keeps an untouched copy
## of the block, the module's effects run at full strength as the wet path, and the BLEND outputs
## wet * MIX + dry * (1 - MIX) -- a linear crossfade, constant sum, since most modules are
## correlated with their input -- before the signal moves on toward the deck limiter. The stock
## effects' own dry/wet controls are pinned fully wet so the pair is the only mix.
## ponytail: without libsoundscape_dsp there is no pair and MIX does nothing; the effects stay at
## full strength rather than faking a mix with depth.
##
## MIX 0 is a BYPASS, not a quiet module: the BLEND already outputs the dry block bit for bit there,
## but the wet path would still run, so the whole module -- TAP, effects and BLEND -- is switched out
## once the BLEND has ramped down to it (see _in_circuit). Out of circuit, Godot skips the slots, so
## the bus carries the untouched signal at no cost, exactly as with the module removed.
const MODULES := {
	"notch": ["FEEDBACK KILLER",
		{"freq": ["FREQ", 60.0, 8000.0, 1000.0], "width": ["WIDTH", 0.1, 2.0, 0.7],
		"mix": ["MIX", 0.0, 1.0, 1.0]}, {}, {}],
	"tbass": ["T-BASS",
		{"amount": ["AMOUNT", 0.0, 1.0, 0.5], "mix": ["MIX", 0.0, 1.0, 1.0]}, {}, {}],
	"bbe": ["BBE",
		{"amount": ["AMOUNT", 0.0, 1.0, 0.5], "mix": ["MIX", 0.0, 1.0, 1.0]}, {}, {}],
	"octaver": ["DUAL OCTAVER",
		{"mix": ["MIX", 0.0, 1.0, 1.0]}, {},
		{"octave": ["OCTAVE", ["-1 DOWN", "UNISON", "+1 UP"], 0]}],
	"pumper": ["PUMPER",
		{"rate": ["RATE HZ", 0.25, 8.0, 2.0], "depth": ["DEPTH", 0.0, 1.0, 0.6],
		"mix": ["MIX", 0.0, 1.0, 1.0]}, {}, {}],
	"pan": ["PAN",
		{"pan": ["PAN", -1.0, 1.0, 0.0], "rate": ["AUTO RATE HZ", 0.05, 4.0, 0.5],
		"mix": ["MIX", 0.0, 1.0, 1.0]}, {"auto": ["AUTO", false]}, {}],
	"wah": ["WAH",
		{"freq": ["FREQ", 200.0, 4000.0, 800.0], "q": ["Q", 0.5, 8.0, 3.0],
		"rate": ["AUTO RATE HZ", 0.05, 6.0, 1.2], "mix": ["MIX", 0.0, 1.0, 1.0]},
		{"auto": ["AUTO", false]}, {}],
	"chorus": ["CHORUS",
		{"rate": ["RATE HZ", 0.1, 6.0, 1.0], "depth": ["DEPTH MS", 0.5, 8.0, 3.0],
		"mix": ["MIX", 0.0, 1.0, 0.5]}, {}, {}],
	"fuzz": ["FUZZ",
		{"drive": ["DRIVE", 0.0, 1.0, 0.5], "tone": ["TONE HZ", 500.0, 12000.0, 4000.0],
		"mix": ["MIX", 0.0, 1.0, 1.0]}, {}, {}],
	"tape": ["TAPE SIMULATOR",
		{"drive": ["DRIVE", 0.0, 1.0, 0.35], "wow": ["WOW", 0.0, 1.0, 0.25],
		"mix": ["MIX", 0.0, 1.0, 1.0]}, {"modulate": ["MODULATE", false]}, {}],
	"reverb": ["REVERB",
		{"size": ["SIZE", 0.0, 1.0, 0.6], "damp": ["DAMP", 0.0, 1.0, 0.5],
		"mix": ["MIX", 0.0, 1.0, 0.3]}, {},
		{"type": ["TYPE", ["ROOM", "HALL", "PLATE", "CHAMBER", "CAVE"], 0]}],
}

## room_size / damping / spread / predelay per reverb type, in TYPE order above.
## Plate is the tell: near-zero predelay, wide spread, bright (low damping) -- a plate
## is a sheet of metal, not a space, so it has no early-reflection gap to model.
const REVERB_TYPES := [
	{"size": 0.45, "damp": 0.55, "spread": 0.4, "pre": 8.0},    # ROOM
	{"size": 0.80, "damp": 0.40, "spread": 0.7, "pre": 35.0},   # HALL
	{"size": 0.55, "damp": 0.20, "spread": 1.0, "pre": 2.0},    # PLATE
	{"size": 0.65, "damp": 0.60, "spread": 0.5, "pre": 18.0},   # CHAMBER
	{"size": 1.00, "damp": 0.75, "spread": 0.8, "pre": 60.0},   # CAVE
]

## Modules whose sound moves on their own, so _process has to write them every frame
## rather than only when a control is touched.
const ANIMATED := ["pumper", "pan", "wah", "tape"]

var active := {}        # type -> true, for whatever is currently in the rack
var fx := {}            # type -> {param key -> float}
var sw := {}            # type -> {switch key -> bool}
var ch := {}            # type -> {choice key -> int}

var _bus := 0
var _effects := {}      # type -> Array[AudioEffect], the module's own effects (the wet path)
var _pairs := {}        # type -> [tap SsParallel, blend SsParallel], or [] without the extension
var _idx := {}          # type -> Array[int], every bus slot the module owns, pair included
var _phase := {}        # type -> LFO phase in turns, free-running while the module is on
var _parked := {}       # type -> BLEND block count when its MIX reached 0, until it is switched out
var _dirty := true

## Modules in the rack but switched OUT: bypass keeps the module, its faders and its place, and
## takes it out of the signal path. REMOVE throws the settings away; bypass is the one you reach
## for mid-set to hear what the effect is doing, and the one you can put back with the same click.
##
## It works by feeding the BLEND a MIX of 0 rather than by disabling slots directly, so switching
## out rides the ramp the MIX fader already has: the same three-block park in _in_circuit, and the
## same absence of a click. The user's own MIX value is untouched underneath.
var bypass := {}

func _init() -> void:
	for type in MODULES:
		active[type] = false
		bypass[type] = false
		_phase[type] = 0.0
		fx[type] = {}
		sw[type] = {}
		ch[type] = {}
		for key in _params(type):
			fx[type][key] = float(_params(type)[key][3])
		for key in _switches(type):
			sw[type][key] = bool(_switches(type)[key][1])
		for key in _choices(type):
			ch[type][key] = int(_choices(type)[key][2])

static func _params(type: String) -> Dictionary: return MODULES[type][1]
static func _switches(type: String) -> Dictionary: return MODULES[type][2]
static func _choices(type: String) -> Dictionary: return MODULES[type][3]
static func module_name(type: String) -> String: return MODULES[type][0]

## Every module, created and inserted once, disabled. Called after Equalizer.setup() on the same
## bus: Equalizer builds its chain from slot 0 and ends the bus with its limiter, and each module
## goes in just ahead of that limiter. The slots recorded here never move afterwards, because
## every later insert lands after them.
func setup(bus_name: String) -> void:
	_bus = maxi(AudioServer.get_bus_index(bus_name), 0)
	var parallel := ClassDB.class_exists("SsParallel")
	if not parallel:
		push_warning("FxRack: libsoundscape_dsp did not load, so MIX has no dry path to blend with")
	for type in MODULES:
		var made: Array[AudioEffect] = _build(type)
		var chain: Array = made.duplicate()
		var pair: Array = []
		if parallel:
			var tap: AudioEffect = ClassDB.instantiate("SsParallel")
			pair = [tap, tap.call("make_blend")]
			chain = [pair[0]] + chain + [pair[1]]
		var slots: Array[int] = []
		for effect: AudioEffect in chain:
			var at := _before_limiter()
			AudioServer.add_bus_effect(_bus, effect, at)
			# add_bus_effect enables by default; the rack boots blank, so every slot is
			# switched out until a module is actually added
			AudioServer.set_bus_effect_enabled(_bus, at, false)
			slots.append(at)
		_effects[type] = made
		_pairs[type] = pair
		_idx[type] = slots
	_dirty = true

## The slot the next module takes: the deck limiter's, pushing it one along -- or the end of a
## bus whose last effect is not a limiter.
func _before_limiter() -> int:
	var n := AudioServer.get_bus_effect_count(_bus)
	return n - 1 if n > 0 and AudioServer.get_bus_effect(_bus, n - 1) is AudioEffectHardLimiter else n

## The stock effects each module is made of. Two of the eleven modules asked for are
## NOT here and cannot be: a NOISE GATE is a downward expander and a BIT CRUSHER is a
## sample-rate/word-length quantiser, and Godot 4.7 ships neither. Both need per-sample
## access, and AudioEffectInstance._process hands GDScript raw pointers typed `int`
## (measured in this project -- a custom mono-fold effect failed to compile on exactly
## that signature), so there is no GDScript path to either. They need a C++/GDExtension
## effect, which is a different kind of change than this file.
func _build(type: String) -> Array[AudioEffect]:
	match type:
		"notch":
			return [AudioEffectNotchFilter.new()]
		"tbass":
			# aggressive and punchy: a 160 Hz shelf lifting the bass hard, straight into OVERDRIVE. Only
			# the band under keep_hf_hz goes through the curve (Godot splits it off with a one-pole
			# lowpass); at 650 Hz that band reaches the upper-bass growl, so the harmonics bite, while
			# everything above passes untouched
			var shelf := AudioEffectLowShelfFilter.new()
			shelf.cutoff_hz = 160.0
			var drive := AudioEffectDistortion.new()
			drive.mode = AudioEffectDistortion.MODE_OVERDRIVE
			drive.keep_hf_hz = 650.0
			drive.pre_gain = 6.0   # drives the low band hard into the curve
			return [shelf, drive]
		"bbe":
			var sparkle := AudioEffectHighShelfFilter.new()
			sparkle.cutoff_hz = 3500.0
			var width := AudioEffectStereoEnhance.new()
			# surround and time_pullout build a DELAYED copy into the side channel, a Haas smear on every
			# transient; pan_pullout alone is a straight side gain, no delay, and folds cleanly to mono
			width.surround = 0.0
			width.time_pullout_ms = 0.0
			return [sparkle, width]
		"octaver":
			var shift := AudioEffectPitchShift.new()
			# ponytail: ONE shifter, so "dual" is a direction switch rather than both
			# octaves at once -- a serial bus cannot run two pitches in parallel, that
			# needs a send bus per voice.
			return [shift]
		"pumper":
			return [AudioEffectAmplify.new()]
		"pan":
			return [AudioEffectPanner.new()]
		"wah":
			return [AudioEffectBandPassFilter.new()]
		"chorus":
			return [AudioEffectChorus.new()]
		"fuzz":
			var d := AudioEffectDistortion.new()
			d.mode = AudioEffectDistortion.MODE_CLIP
			return [d]
		"tape":
			var sat := AudioEffectDistortion.new()
			sat.mode = AudioEffectDistortion.MODE_OVERDRIVE
			# the wow shifter is SEPARATE from the saturation so MODULATE can switch the
			# pitch side out entirely while the tape colour stays
			return [sat, AudioEffectPitchShift.new()]
		"reverb":
			return [AudioEffectReverb.new()]
	return []

# --- rack contents ----------------------------------------------------------
func add_module(type: String) -> void:
	if not MODULES.has(type) or active.get(type, false):
		return
	active[type] = true
	_phase[type] = 0.0
	_dirty = true

func remove_module(type: String) -> void:
	if not active.get(type, false):
		return
	active[type] = false
	_dirty = true

func clear() -> void:
	for type in MODULES:
		active[type] = false
	_dirty = true

func set_param(type: String, key: String, value: float) -> void:
	var spec: Array = _params(type)[key]
	fx[type][key] = clampf(value, spec[1], spec[2])
	_dirty = true

func set_switch(type: String, key: String, on: bool) -> void:
	sw[type][key] = on
	_dirty = true

func set_bypass(type: String, on: bool) -> void:
	if not MODULES.has(type):
		return
	bypass[type] = on
	_dirty = true

## The MIX the BLEND is actually given: zero while bypassed, whatever the fader says otherwise.
func effective_mix(type: String) -> float:
	return 0.0 if bypass.get(type, false) else float(fx[type].get("mix", 1.0))

func set_choice(type: String, key: String, i: int) -> void:
	ch[type][key] = clampi(i, 0, (_choices(type)[key][1] as Array).size() - 1)
	_dirty = true

# --- audio push -------------------------------------------------------------
## Dirty-flagged exactly like Equalizer's: a fader drag fires dozens of times a second
## and every set_bus_effect_enabled takes the audio driver lock, so the bus is written
## once per frame rather than once per input event.
##
## Animated modules are the exception -- they have to be written every frame while they
## are on, but only while they are on, so an empty rack costs one dictionary lookup.
func _process(delta: float) -> void:
	var moving := not _parked.is_empty()   # a module ramping to MIX 0 is waiting to be switched out
	for type in ANIMATED:
		if active.get(type, false):
			_phase[type] = fposmod(_phase[type] + delta * _lfo_rate(type), 1.0)
			moving = true
	if not (_dirty or moving):
		return
	_dirty = false
	_push()

## Turns per second for whatever drives this module's movement, or 0 when it is not
## currently moving (AUTO switched off, MODULATE off) -- a stopped LFO must not keep
## accumulating phase, or switching AUTO back on would jump to wherever it drifted to.
func _lfo_rate(type: String) -> float:
	match type:
		"pumper":
			return fx["pumper"]["rate"]
		"pan":
			return fx["pan"]["rate"] if sw["pan"]["auto"] else 0.0
		"wah":
			return fx["wah"]["rate"] if sw["wah"]["auto"] else 0.0
		"tape":
			# wow is a slow ~0.8 Hz warble; flutter would be 6-10 Hz and is deliberately
			# not modelled, one shifter cannot do both without intermodulating
			return 0.8 if sw["tape"]["modulate"] else 0.0
	return 0.0

func _push() -> void:
	if _effects.is_empty():
		return
	for type in MODULES:
		var on := _in_circuit(type)
		var slots: Array = _idx[type]
		if not (_pairs[type] as Array).is_empty():
			# Every enable takes the lock on its own, so a block can mix between two of them. The TAP
			# and BLEND go in BEFORE the wet effects and come out AFTER them: each state in between
			# then passes the dry block (effects out, the BLEND sums the tap's copy with itself; BLEND
			# out, the TAP is a copy). Chain order would leave a BLEND reading a stale dry block.
			var outer := [slots[0], slots[-1]]
			var inner := slots.slice(1, slots.size() - 1)
			slots = outer + inner if on else inner + [slots[-1], slots[0]]
		for slot in slots:
			# only a CHANGE is worth the driver lock, the same rule Equalizer._enable uses
			if AudioServer.is_bus_effect_enabled(_bus, slot) != on:
				AudioServer.set_bus_effect_enabled(_bus, slot, on)
		if on:
			_apply(type)

## Whether a module's slots should be switched in. Active at a MIX above 0, yes. Active at MIX 0 it
## goes out, but not at once: the BLEND ramps MIX across a block, and switching it out before that
## block has run would jump from the last wet mix straight to dry, a click. So the BLEND's block
## counter is noted when MIX reaches 0, and the slots go out once three more blocks have run --
## the first may have started before the new MIX landed. A module already out stays out.
func _in_circuit(type: String) -> bool:
	if not active.get(type, false):
		_parked.erase(type)
		return false
	var pair: Array = _pairs[type]
	if pair.is_empty() or effective_mix(type) > 0.0:
		_parked.erase(type)
		return true
	if not AudioServer.is_bus_effect_enabled(_bus, _idx[type][0]):
		_parked.erase(type)
		return false
	var blocks := int(pair[1].call("get_split_blocks"))
	if not _parked.has(type):
		_parked[type] = blocks
	return blocks - int(_parked[type]) < 3

## Modules in circuit, and modules in the rack but switched out at MIX 0. For the DSP AUTOPSY.
func circuit_counts() -> Array[int]:
	var live := 0
	var out := 0
	for type in MODULES:
		if active.get(type, false):
			if not _idx.has(type) or AudioServer.is_bus_effect_enabled(_bus, _idx[type][0]):
				live += 1
			else:
				out += 1
	return [live, out]

## How many modules carry a TAP/BLEND pair: all of them, or none without libsoundscape_dsp.
func pair_count() -> int:
	var n := 0
	for type in _pairs:
		n += 1 if not (_pairs[type] as Array).is_empty() else 0
	return n

## The wet path at full strength, and MIX handed to the module's pair. Nothing here scales an
## effect by MIX any more: that was the serial-bus stand-in for a dry path, and the pair is one.
func _apply(type: String) -> void:
	var p: Dictionary = fx[type]
	var pair: Array = _pairs[type]
	if not pair.is_empty():
		pair[0].call("set_mix", effective_mix(type))   # both halves share one MIX
	var fxs: Array = _effects[type]
	match type:
		"notch":
			var f: AudioEffectNotchFilter = fxs[0]
			f.cutoff_hz = p["freq"]
			f.resonance = p["width"]
		"tbass":
			# up to 2.5x (+8 dB). Godot's OVERDRIVE ignores `drive` (4.7 source): its saturation is set
			# only by how hot the band arrives, so AMOUNT drives it through this shelf -- more AMOUNT,
			# more bass into the curve, more saturation. ponytail: a shelving biquad's group delay grows
			# with its gain, so this lift also moves the kick's leading edge further than the old 1.9x
			(fxs[0] as AudioEffectLowShelfFilter).gain = 1.0 + p["amount"] * 1.5
			# post_gain scales only the saturated band. The 6 dB pre_gain comes back off after the curve,
			# so it sets how hard the bass clips rather than how loud it is, plus about half the shelf's
			# lift -- all of it would hand the deck limiter the whole boost to pump on
			(fxs[1] as AudioEffectDistortion).post_gain = -6.0 - p["amount"] * 3.0
		"bbe":
			(fxs[0] as AudioEffectHighShelfFilter).gain = 1.0 + p["amount"] * 1.5
			(fxs[1] as AudioEffectStereoEnhance).pan_pullout = 1.0 + p["amount"] * 0.6
		"octaver":
			var s: AudioEffectPitchShift = fxs[0]
			var steps: Array = [0.5, 1.0, 2.0]
			s.pitch_scale = steps[ch["octaver"]["octave"]]
		"pumper":
			var a: AudioEffectAmplify = fxs[0]
			# one-sided duck: the LFO only ever pulls DOWN from unity, so a pumper at any
			# depth can never add gain the master limiter then has to catch
			var duck: float = (0.5 - 0.5 * cos(_phase["pumper"] * TAU))
			a.volume_db = -duck * p["depth"] * 24.0
		"pan":
			var pan: AudioEffectPanner = fxs[0]
			var want: float = sin(_phase["pan"] * TAU) if sw["pan"]["auto"] else p["pan"]
			pan.pan = clampf(want, -1.0, 1.0)
		"wah":
			var w: AudioEffectBandPassFilter = fxs[0]
			var spec: Array = _params("wah")["freq"]
			var hz: float = p["freq"]
			if sw["wah"]["auto"]:
				# swept in LOG space: a linear sweep spends most of its travel up where
				# there is nothing, which reads as a filter that barely moves
				hz = spec[1] * pow(spec[2] / spec[1], 0.5 + 0.5 * sin(_phase["wah"] * TAU))
			w.cutoff_hz = hz
			w.resonance = p["q"]
		"chorus":
			var c: AudioEffectChorus = fxs[0]
			c.voice_count = 2
			for v in 2:
				c.set_voice_rate_hz(v, p["rate"] * (1.0 if v == 0 else 1.31))
				c.set_voice_depth_ms(v, p["depth"])
				c.set_voice_pan(v, -0.5 if v == 0 else 0.5)
			# fully wet: the pair's BLEND is the dry/wet control, constant sum, so the chorus is
			# never louder than the signal it widens
			c.wet = 1.0
			c.dry = 0.0
		"fuzz":
			var d: AudioEffectDistortion = fxs[0]
			d.drive = p["drive"]
			d.keep_hf_hz = p["tone"]
			# clipping adds level; back it off as drive climbs so FUZZ is a texture
			# control rather than a volume control
			d.post_gain = -p["drive"] * 8.0
		"tape":
			var sat: AudioEffectDistortion = fxs[0]
			sat.drive = p["drive"] * 0.5
			sat.keep_hf_hz = 5000.0
			sat.post_gain = -p["drive"] * 4.0
			var wow: AudioEffectPitchShift = fxs[1]
			# MODULATE off means EXACTLY 1.0, not "nearly 1.0". That is the whole point
			# of the switch: an idle shifter left at 0.999 is an audible, permanent
			# detune on every track, which is the unwanted pitch shift being prevented.
			wow.pitch_scale = 1.0 if not sw["tape"]["modulate"] \
				else 1.0 + sin(_phase["tape"] * TAU) * p["wow"] * 0.004
		"reverb":
			var r: AudioEffectReverb = fxs[0]
			var t: Dictionary = REVERB_TYPES[ch["reverb"]["type"]]
			# the TYPE sets the character, the SIZE/DAMP faders trim around it rather
			# than replacing it -- otherwise every type collapses to the same reverb the
			# moment a fader is touched
			r.room_size = clampf(t["size"] * lerpf(0.5, 1.5, p["size"]), 0.0, 1.0)
			r.damping = clampf(t["damp"] * lerpf(0.5, 1.5, p["damp"]), 0.0, 1.0)
			r.spread = t["spread"]
			r.predelay_msec = t["pre"]
			r.wet = 1.0   # the pair blends the dry signal back in
			r.dry = 0.0

# --- presets ----------------------------------------------------------------
## A preset is the whole rack: which modules are in it and every value they hold.
## Stored as a plain Dictionary so it goes into library.cfg like every other section.
func to_dict() -> Dictionary:
	var on: Array[String] = []
	for type in MODULES:
		if active[type]:
			on.append(type)
	var off: Array[String] = []
	for type in MODULES:
		if bypass.get(type, false):
			off.append(type)
	return {"active": on, "bypass": off, "fx": fx.duplicate(true), "sw": sw.duplicate(true),
		"ch": ch.duplicate(true)}

## Clamped on the way in rather than trusted: library.cfg is hand-editable, and an
## out-of-range cutoff or pitch_scale is an audible fault, not a caught error.
func from_dict(d: Dictionary) -> void:
	var on: Variant = d.get("active", [])
	var off: Variant = d.get("bypass", [])
	for type in MODULES:
		active[type] = (on is Array) and (type in (on as Array))
		bypass[type] = (off is Array) and (type in (off as Array))
	var in_fx: Variant = d.get("fx", {})
	var in_sw: Variant = d.get("sw", {})
	var in_ch: Variant = d.get("ch", {})
	for type in MODULES:
		var got_fx: Dictionary = (in_fx as Dictionary).get(type, {}) if in_fx is Dictionary else {}
		for key in _params(type):
			var spec: Array = _params(type)[key]
			fx[type][key] = clampf(_num(got_fx.get(key), spec[3]), spec[1], spec[2])
		var got_sw: Dictionary = (in_sw as Dictionary).get(type, {}) if in_sw is Dictionary else {}
		for key in _switches(type):
			var v: Variant = got_sw.get(key, _switches(type)[key][1])
			sw[type][key] = v if v is bool else bool(_switches(type)[key][1])
		var got_ch: Dictionary = (in_ch as Dictionary).get(type, {}) if in_ch is Dictionary else {}
		for key in _choices(type):
			var opts: Array = _choices(type)[key][1]
			ch[type][key] = clampi(int(_num(got_ch.get(key), _choices(type)[key][2])),
				0, opts.size() - 1)
	_dirty = true

static func _num(v: Variant, fallback: float) -> float:
	return float(v) if (v is float or v is int) else fallback

# --- self-check -------------------------------------------------------------
## Asserted from player.gd's _ready like every other pure-logic test here. The bus-side
## guarantee (effect count never changes at runtime) needs a real bus and lives in
## test_fx_rack.gd instead.
static func rack_test() -> bool:
	var r := FxRack.new()
	# every module's defaults must sit inside its own declared range, or the rack boots
	# holding a value its own fader cannot represent
	for type in MODULES:
		for key in _params(type):
			var spec: Array = _params(type)[key]
			if spec[3] < spec[1] or spec[3] > spec[2] or spec[1] >= spec[2]:
				r.free()
				return false
		for key in _choices(type):
			var c: Array = _choices(type)[key]
			if (c[1] as Array).is_empty() or c[2] < 0 or c[2] >= (c[1] as Array).size():
				r.free()
				return false
	# bypass takes a module out of the signal path WITHOUT touching what its faders say, and it
	# survives a save: a set rebuilt from library.cfg comes back with the same modules switched out
	r.add_module("reverb")
	r.set_param("reverb", "mix", 0.8)
	r.set_bypass("reverb", true)
	var bypassed: bool = is_equal_approx(r.effective_mix("reverb"), 0.0) \
		and is_equal_approx(float(r.fx["reverb"]["mix"]), 0.8) and r.active["reverb"]
	var saved := r.to_dict()
	var back := FxRack.new()
	back.from_dict(saved)
	bypassed = bypassed and back.bypass["reverb"] and back.active["reverb"] \
		and is_equal_approx(float(back.fx["reverb"]["mix"]), 0.8)
	r.set_bypass("reverb", false)
	bypassed = bypassed and is_equal_approx(r.effective_mix("reverb"), 0.8)
	r.remove_module("reverb")
	back.free()
	if not bypassed:
		r.free()
		return false
	var ok := true
	# the rack boots BLANK
	for type in MODULES:
		ok = ok and not r.active[type]
	# add / remove is idempotent, and params clamp at both ends
	r.add_module("wah")
	r.add_module("wah")
	ok = ok and r.active["wah"]
	r.set_param("wah", "freq", 99999.0)
	ok = ok and is_equal_approx(r.fx["wah"]["freq"], _params("wah")["freq"][2])
	r.set_param("wah", "freq", -5.0)
	ok = ok and is_equal_approx(r.fx["wah"]["freq"], _params("wah")["freq"][1])
	r.remove_module("wah")
	ok = ok and not r.active["wah"]
	# a choice cannot be driven off the end of its own option list
	r.set_choice("reverb", "type", 99)
	ok = ok and r.ch["reverb"]["type"] == REVERB_TYPES.size() - 1
	# MODULATE off is EXACTLY unity, at every wow depth -- the unwanted-detune guarantee
	r.set_switch("tape", "modulate", false)
	r.set_param("tape", "wow", 1.0)
	ok = ok and is_equal_approx(r._lfo_rate("tape"), 0.0)
	# junk from a hand-edited config clamps instead of throwing
	r.from_dict({"active": "not an array", "fx": {"wah": {"freq": "loud"}},
		"sw": {"tape": {"modulate": 7}}, "ch": {"reverb": {"type": 99}}})
	ok = ok and not r.active["wah"] and r.sw["tape"]["modulate"] == false \
		and r.ch["reverb"]["type"] == REVERB_TYPES.size() - 1 \
		and is_equal_approx(r.fx["wah"]["freq"], _params("wah")["freq"][3])
	r.free()   # FxRack is a Node, not RefCounted
	return ok
