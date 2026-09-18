class_name Equalizer
extends Node
## Real-time EQ and hardware-DSP emulation on one DECK bus. There is an instance per deck;
## player.gd calls setup() with _engine.deck_bus(i), and the single UI rack binds to
## whichever deck is live. (This used to sit on Master and the docstring said so; the deck
## split moved it, and the Master bus now carries only AudioEngine's safety limiter and
## AudioDirector's analyser.)
##
## Chain order matters: every effect here runs on the deck, which sends to Master, so it
## is all still AHEAD of AudioDirector's SpectrumAnalyzer -- the visualizer shows post-EQ
## audio, what you see is what you hear. Bus effects also run before the bus volume is
## applied on send, so none of this is affected by where the VOL control sits, and the
## crossfader (which IS deck bus volume) lands downstream of the whole rack.
##
## Godot has no AudioEffectEQ16: the shipped sizes are EQ6/EQ10/EQ21. The 16 UI lanes
## are therefore a control curve that is interpolated onto EQ21's 21 bands.

signal changed()

enum Mode { OFF, EZ, ADVANCED }

const LANES := 16
const GAIN_MIN := -18.0
const GAIN_MAX := 18.0
## Gaussian width for ADAPT, in lanes. 1.6 puts the immediate neighbour at ~0.82 of the
## dragged lane and the third one out at ~0.17 -- a smooth shoulder, not a plateau.
const ADAPT_SIGMA := 1.6
## Ceiling for the output booster, in dB. 24 dB is 16x amplitude -- enough to bring a
## quiet master right up. The hard limiter behind it is what makes that safe: past the
## point where the signal would clip it saturates instead, so the top of the dial
## trades dynamics for loudness rather than breaking up.
const BOOST_MAX := 24.0

## FX rack parameters. One spec table rather than ten typed fields: the UI builder, the
## readouts and the config file all iterate this, so a new knob is one line here instead
## of a setter, a getter, a save line, a load line and a slider.
##   key -> [label, min, max, default]
## THE FIXED RACK IS GONE, and this is the note that says so. Reverb, stereo delay, the DJ
## filter sweep and the pitch shifter were removed in v1.5. The controls that drove them went
## when performance FX became FxRack, so for two releases they were six AudioEffects allocated
## on every deck bus that no user action could reach, no config could set and nothing could
## switch on -- [effects] stopped being read, and set_fx() stopped having a caller. Equalizer
## keeps what the EQ tab actually shows: the 21-band curve, the boost, and the limiter over
## both. Performance FX live in FxRack, per deck, where they have faders.

var mode: Mode = Mode.OFF
var adapt := true
var lane_db := PackedFloat32Array()
var ez_db := PackedFloat32Array()      # LOW, MID, HIGH
var boost_db := 0.0                     # extra output gain, 0..BOOST_MAX

var _bus := 0
var _eq: AudioEffectEQ21
var _boost: AudioEffectAmplify
var _limiter: AudioEffectHardLimiter
var _on_state := {}                     # effect -> last enabled flag actually written
var _dirty := true

func _init() -> void:
	lane_db.resize(LANES)
	ez_db.resize(3)

## Inserted at ascending slots from the head of the bus so the analyser, which is
## appended by AudioDirector, always ends up last in the chain.
func setup(bus_name := "Master") -> void:
	_bus = maxi(AudioServer.get_bus_index(bus_name), 0)
	_eq = AudioEffectEQ21.new()
	_boost = AudioEffectAmplify.new()
	_limiter = AudioEffectHardLimiter.new()

	# a hair under 0 dBFS: the booster exists to be pushed, and this is what stops it
	# turning into hard digital clipping on a loud master
	_limiter.ceiling_db = -0.5

	var slot := 0
	# Chain order, and it is not arbitrary: the curve shapes the signal, the boost follows it,
	# and the limiter is appended on its own below so it covers both. T-BASS and BBE sat between
	# them until 2026-09-16; they are FxRack modules now, each in its own parallel wet/dry pair.
	for effect in [_eq, _boost]:
		AudioServer.add_bus_effect(_bus, effect, slot)
		# add_bus_effect enables by default, and _push does not run until the first
		# frame -- without this the chain would process a frame or two of audio before
		# anything had decided it should be on.
		AudioServer.set_bus_effect_enabled(_bus, slot, false)
		_on_state[effect] = false   # seeds the change-gate in _enable()
		slot += 1
	# The limiter goes on the END of the bus, not straight after the boost: FxRack.setup()
	# inserts its modules just ahead of it, so whatever the rack adds is limited too. It used to
	# sit at slot 11 with the rack appended past it, and a module's gain reached the master bus
	# with nothing in between (audit D4). Bus volume is applied after the chain on send, which is
	# why this is an effect and not the bus volume.
	AudioServer.add_bus_effect(_bus, _limiter)
	AudioServer.set_bus_effect_enabled(_bus, AudioServer.get_bus_effect_count(_bus) - 1, false)
	_on_state[_limiter] = false
	_dirty = true

# --- lane control ---------------------------------------------------------
## ADAPT spreads a change across neighbours using a Gaussian falloff, measured from a
## snapshot taken when the drag began. Working from the snapshot rather than the live
## values is what stops the curve compounding into a spike during a long drag.
func apply_lane(i: int, db: float, base: PackedFloat32Array) -> void:
	if not adapt:
		lane_db[i] = db
		_dirty = true
		return
	var delta := db - base[i]
	for j in LANES:
		var d := float(j - i)
		var w: float = exp(-(d * d) / (2.0 * ADAPT_SIGMA * ADAPT_SIGMA))
		lane_db[j] = clampf(base[j] + delta * w, GAIN_MIN, GAIN_MAX)
	_dirty = true

## Bulk lane write for presets. Goes through the same dirty flag as a fader drag, so
## the bus is updated on the next frame by the one code path that talks to AudioServer.
func set_lanes(values: Array) -> void:
	for i in mini(values.size(), LANES):
		# _num, because a preset curve can come straight out of a hand-edited library.cfg
		# and clampf() on a String throws instead of clamping
		lane_db[i] = clampf(_num(values[i], 0.0), GAIN_MIN, GAIN_MAX)
	_dirty = true

func set_ez(i: int, db: float) -> void:
	ez_db[i] = db
	_dirty = true

func set_mode(m: Mode) -> void:
	mode = m
	_dirty = true

## Independent of the EQ mode: the booster is an output stage, so it still works with
## the equalizer switched OFF. At 0 dB both effects bypass and the path stays clean.
func set_boost(db: float) -> void:
	boost_db = clampf(db, 0.0, BOOST_MAX)
	_dirty = true

# --- EZ mode ----------------------------------------------------------------
func _ez_curve() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(LANES)
	for i in LANES:
		var t := float(i) / float(LANES - 1)    # 0 at 32 Hz, 1 at 16 kHz
		var w_low: float = _bump(t, 0.0)
		var w_mid: float = _bump(t, 0.5)
		var w_high: float = _bump(t, 1.0)
		var sum: float = w_low + w_mid + w_high
		out[i] = (ez_db[0] * w_low + ez_db[1] * w_mid + ez_db[2] * w_high) / maxf(sum, 0.001)
	return out

static func _bump(t: float, centre: float) -> float:
	var d: float = absf(t - centre) / 0.5
	return 0.0 if d >= 1.0 else 0.5 + 0.5 * cos(d * PI)

# --- audio push -----------------------------------------------------------
## Everything is applied once per frame off a dirty flag, never inside the slider
## callback. During a fast drag ADAPT rewrites 16 lanes per input event; pushing 21 band
## gains plus five effect toggles on every one of those is what would stall the UI.
func _process(_delta: float) -> void:
	if not _dirty:
		return
	_dirty = false
	_push()
	changed.emit()

## AudioServer.set_bus_effect_enabled takes the audio driver lock, so writing all twelve
## slots on every dirty frame meant twelve lock/unlock pairs per frame contending with the
## mix thread -- during a fader drag, which is exactly when a glitch gets noticed. The bus
## already holds this state; only a CHANGE is worth the lock.
func _enable(effect: AudioEffect, on: bool) -> void:
	if _on_state.get(effect) == on:
		return
	_on_state[effect] = on
	# Found by identity, not by a slot remembered at setup: FxRack inserts ahead of the limiter
	# after this chain is built, which moves it. Only a CHANGE reaches here, so the scan is rare.
	for i in AudioServer.get_bus_effect_count(_bus):
		if AudioServer.get_bus_effect(_bus, i) == effect:
			AudioServer.set_bus_effect_enabled(_bus, i, on)
			return

## Below this a lane is inaudible, and running the bank for it buys phase rotation and
## nothing else. 0.1 dB is finer than any step a fader can produce.
const FLAT_DB := 0.1

static func is_flat(curve: PackedFloat32Array) -> bool:
	for g in curve:
		if absf(g) > FLAT_DB:
			return false
	return true

## Self-check for the bypass rule, asserted from player.gd's _ready beside cut_test. This
## one fails silently in both directions: a bank left in circuit still sounds "fine", and
## a bank wrongly bypassed just means the EQ quietly does nothing.
## Self-check for the config trust boundary. The failure this catches is the dangerous
## one: junk that does not throw but arrives as gain.
static func from_dict_test() -> bool:
	var e := Equalizer.new()
	e.from_dict({"mode": "x", "adapt": "y", "lanes": "z", "ez": 9})
	var ok := e.mode == Mode.OFF and e.adapt == true
	e.from_dict({"lanes": [999.0, -999.0], "ez": [500.0]})
	ok = ok and e.lane_db[0] == GAIN_MAX and e.lane_db[1] == GAIN_MIN 		and e.ez_db[0] == GAIN_MAX
	e.free()
	return ok

static func flat_test() -> bool:
	var e := Equalizer.new()
	var ok := is_flat(PackedFloat32Array([0.0, 0.0, 0.0]))
	ok = ok and is_flat(PackedFloat32Array([0.05, -0.09]))         # under the threshold
	ok = ok and not is_flat(PackedFloat32Array([0.0, 0.5, 0.0]))   # one lane is enough
	ok = ok and not is_flat(PackedFloat32Array([-18.0]))
	ok = ok and is_flat(e._ez_curve())       # EZ at rest must bypass, not process
	e.ez_db[1] = -7.0
	ok = ok and not is_flat(e._ez_curve())   # ...and engage the moment it is moved
	e.free()   # Equalizer is a Node, not RefCounted
	return ok

func _push() -> void:
	if not _eq:
		return
	# A flat curve is NOT a neutral equalizer. AudioEffectEQ21 is a PARALLEL bank of 21
	# two-pole bandpass sections summed with per-band gain, not a cascade of peaking
	# filters -- so with every lane at 0 dB the output is the sum of 21 IIR responses
	# rather than the input: magnitude roughly flat, phase very much not. The only
	# transparent setting is the effect switched out of the chain. So a flat curve, and
	# EZ with its three macros at rest, now bypass instead of rotating phase for nothing.
	var curve: PackedFloat32Array = lane_db if mode == Mode.ADVANCED else _ez_curve()
	var on := mode != Mode.OFF and not is_flat(curve)
	_enable(_eq, on)
	if on:
		var bands := _eq.get_band_count()
		for b in bands:
			# 21 bands sampled from a 16-point curve
			var t: float = float(b) / float(bands - 1) * float(LANES - 1)
			var i := int(floor(t))
			var f: float = t - float(i)
			var g: float = lerpf(curve[i], curve[mini(i + 1, LANES - 1)], f)
			_eq.set_band_gain_db(b, g)

	var boosting := boost_db > 0.05
	_enable(_boost, boosting)
	if boosting:
		_boost.volume_db = boost_db

	# The limiter covers the boost, which is exactly what it is there to catch. A tone control
	# must never arm it: T-BASS once did, and every kick drove gain reduction with the mids
	# breathing back up over the release. T-BASS lives in FxRack now, whose modules sit ahead
	# of this limiter, and AudioEngine's Master limiter sees the summed output.
	_enable(_limiter, boosting)

## Back to defaults. Kept here rather than in the UI so there is one definition of
## "off", and the dirty flag makes the bus follow on the next frame like any other edit.
func reset_all() -> void:
	mode = Mode.OFF
	adapt = true
	for i in LANES:
		lane_db[i] = 0.0
	for i in 3:
		ez_db[i] = 0.0
	boost_db = 0.0
	_dirty = true

# --- persistence ----------------------------------------------------------
func to_dict() -> Dictionary:
	return {"mode": int(mode), "adapt": adapt, "lanes": Array(lane_db),
		"ez": Array(ez_db)}

## A number, or the fallback for anything that is not one. The call site already refuses
## a non-Dictionary, but `state={"mode":"x"}` IS a valid Dictionary -- the junk arrives
## here intact, and clampi() on a String throws rather than clamping.
static func _num(v: Variant, fallback: float) -> float:
	return float(v) if (v is float or v is int) else fallback

func from_dict(d: Dictionary) -> void:
	mode = clampi(int(_num(d.get("mode"), 0.0)), 0, 2) as Mode
	var a: Variant = d.get("adapt", true)
	adapt = a if a is bool else true
	# CLAMPED, which set_lanes() has always done and this path never did: a hand-edited or
	# half-written lanes=[999] went straight into the 21-band bank as +999 dB, which is a
	# speaker-shredding load-time gain spike rather than a config nuisance.
	var l: Variant = d.get("lanes", [])
	if l is Array:
		for i in mini((l as Array).size(), LANES):
			lane_db[i] = clampf(_num((l as Array)[i], 0.0), GAIN_MIN, GAIN_MAX)
	var e: Variant = d.get("ez", [])
	if e is Array:
		for i in mini((e as Array).size(), 3):
			ez_db[i] = clampf(_num((e as Array)[i], 0.0), GAIN_MIN, GAIN_MAX)
	_dirty = true

static func grabber_texture() -> ImageTexture:
	var w := 13
	var h := 7
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var edge: bool = x == 0 or y == 0 or x == w - 1 or y == h - 1
			var notch: bool = y == h / 2
			img.set_pixel(x, y, Color.BLACK if edge or notch else Color(0.80, 0.82, 0.78))
	return ImageTexture.create_from_image(img)
