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
const FX_SPEC := {
	"rev_room": ["ROOM SIZE", 0.0, 1.0, 0.60],
	"rev_damp": ["DAMPNESS", 0.0, 1.0, 0.50],
	"rev_wet": ["WET MIX", 0.0, 1.0, 0.30],
	"dly_ms": ["TIME", 20.0, 1000.0, 250.0],
	"dly_fb": ["FEEDBACK", 0.0, 1.0, 0.35],
	"dly_wet": ["MIX", 0.0, 1.0, 0.40],
	"cut": ["CUTOFF", 0.0, 1.0, 0.50],
	"res": ["RESONANCE", 0.0, 1.0, 0.20],
	"tape": ["TAPE SPEED", 0.5, 2.0, 1.0],
	"key_semi": ["KEY SHIFT", -12.0, 12.0, 0.0],
}
## Half-width of the CUTOFF bar's dead centre, as a fraction of the whole bar. Without a
## detent there is no pixel that means "off", and a DJ filter that cannot be returned to
## flat by feel is a filter you end up leaving slightly on.
const CUT_DEAD := 0.04
## Feedback maps into this dB range rather than straight to unity. At 0 dB a delay line
## never decays -- the tail builds until it clips. -3 dB at the top is still ~10 audible
## repeats, which is as far as this needs to go.
const FB_DB_MIN := -30.0
const FB_DB_MAX := -3.0

var mode: Mode = Mode.OFF
var adapt := true
var lane_db := PackedFloat32Array()
var ez_db := PackedFloat32Array()      # LOW, MID, HIGH
var tbass := 0.0                        # 0..1
var bbe := 0.0                          # 0..1
var boost_db := 0.0                     # extra output gain, 0..BOOST_MAX
var fx := {}                            # FX_SPEC key -> float
var fx_switch := {"rev_on": false, "dly_on": false, "bypass": false}

var _bus := 0
var _eq: AudioEffectEQ21
var _tb_shelf: AudioEffectLowShelfFilter
var _tb_drive: AudioEffectDistortion
var _bbe_shelf: AudioEffectHighShelfFilter
var _bbe_phase: AudioEffectStereoEnhance
var _boost: AudioEffectAmplify
var _limiter: AudioEffectHardLimiter
var _lp: AudioEffectLowPassFilter
var _hp: AudioEffectHighPassFilter
var _pitch: AudioEffectPitchShift
var _delay: AudioEffectDelay
var _reverb: AudioEffectReverb
var _idx := {}                          # effect -> bus slot, for true bypass
var _on_state := {}                     # effect -> last enabled flag actually written
var _dirty := true

func _init() -> void:
	lane_db.resize(LANES)
	ez_db.resize(3)
	for key in FX_SPEC:
		fx[key] = FX_SPEC[key][3]

## Inserted at ascending slots from the head of the bus so the analyser, which is
## appended by AudioDirector, always ends up last in the chain.
func setup(bus_name := "Master") -> void:
	_bus = maxi(AudioServer.get_bus_index(bus_name), 0)
	_eq = AudioEffectEQ21.new()
	_tb_shelf = AudioEffectLowShelfFilter.new()
	_tb_drive = AudioEffectDistortion.new()
	_bbe_shelf = AudioEffectHighShelfFilter.new()
	_bbe_phase = AudioEffectStereoEnhance.new()
	_boost = AudioEffectAmplify.new()
	_limiter = AudioEffectHardLimiter.new()
	_lp = AudioEffectLowPassFilter.new()
	_hp = AudioEffectHighPassFilter.new()
	_pitch = AudioEffectPitchShift.new()
	_delay = AudioEffectDelay.new()
	_reverb = AudioEffectReverb.new()

	_tb_shelf.cutoff_hz = 120.0
	# OVERDRIVE with a low keep_hf makes the harmonics band-limited, so T-BASS thickens
	# the bottom end instead of fizzing the whole mix like a full-range distortion would.
	_tb_drive.mode = AudioEffectDistortion.MODE_OVERDRIVE
	_tb_drive.keep_hf_hz = 320.0
	_bbe_shelf.cutoff_hz = 3500.0
	# pan_pullout is driven per-push now; see the BBE block in _push for why the delay
	# half of this effect is switched off permanently.
	_bbe_phase.time_pullout_ms = 0.0
	# a hair under 0 dBFS: the booster exists to be pushed, and this is what stops it
	# turning into hard digital clipping on a loud master
	_limiter.ceiling_db = -0.5

	var slot := 0
	# Chain order, and it is not arbitrary. The DJ filter and the tape pitch sit at the
	# front, where a performance move belongs -- filtering after the reverb would leave
	# the tail unfiltered and the sweep would not read as a cut. EQ and the hardware DSP
	# shape the dry signal next. The time-based effects come after that so they reverberate
	# what you actually hear. boost + limiter go last: they are effects rather than bus
	# volume on purpose, since bus volume is applied after the chain on send, so a limiter
	# placed anywhere else could never catch clipping the rack in front of it caused.
	for effect in [_lp, _hp, _pitch, _eq, _tb_shelf, _tb_drive, _bbe_shelf, _bbe_phase,
			_delay, _reverb, _boost, _limiter]:
		AudioServer.add_bus_effect(_bus, effect, slot)
		_idx[effect] = slot
		# add_bus_effect enables by default, and _push does not run until the first
		# frame -- without this the chain would process a frame or two of audio before
		# anything had decided it should be on.
		AudioServer.set_bus_effect_enabled(_bus, slot, false)
		_on_state[effect] = false   # seeds the change-gate in _enable()
		slot += 1
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

# --- FX rack --------------------------------------------------------------
## Every FX control funnels through these two. Neither touches AudioServer: they set the
## same dirty flag the EQ faders use, so a drag that fires forty times a second still
## costs exactly one bus update per frame. That is the whole reason dragging a reverb
## slider does not stutter the mix.
func set_fx(key: String, value: float) -> void:
	var spec: Array = FX_SPEC[key]
	fx[key] = clampf(value, spec[1], spec[2])
	_dirty = true

func set_fx_on(key: String, on: bool) -> void:
	fx_switch[key] = on
	_dirty = true

## BYPASS is a mute for the rack, not a reset: nothing in `fx` is touched, so switching
## it back on returns every fader to exactly where the user left it.
func fx_bypassed() -> bool:
	return fx_switch["bypass"]

## The DJ cutoff is a single bi-directional bar with a dead centre. Returns
## [-1 low-pass | 0 bypass | +1 high-pass, cutoff in Hz]. _push and the on-screen readout
## both call this, so the label can never disagree with what the filter is doing.
func cut_state() -> Array:
	var c: float = fx["cut"]
	var span := 0.5 - CUT_DEAD
	if c < 0.5 - CUT_DEAD:
		return [-1, _sweep(c / span, 80.0, 20000.0)]
	if c > 0.5 + CUT_DEAD:
		return [1, _sweep((c - 0.5 - CUT_DEAD) / span, 20.0, 8000.0)]
	return [0, 0.0]

# --- pitch ------------------------------------------------------------------
## TAPE SPEED and KEY SHIFT are two views of ONE AudioEffectPitchShift: tape in playback
## ratio, key in semitones, multiplied. A second shifter would double the most expensive
## thing on the bus to say the same thing twice.
##
## Nothing here touches AudioStreamPlayer.pitch_scale. That was tried and reverted: it
## puts every frame of a 96 kHz stream through the realtime resampler, which is exactly
## the work the mix thread has no budget for.
func pitch_scale() -> float:
	return fx["tape"] * pow(2.0, fx["key_semi"] / 12.0)

## Self-check for the semitone maths, asserted from player.gd's _ready like cut_test.
## The invariant that matters for stability is the first one: at rest this returns
## exactly 1.0, which is what lets _push leave the shifter switched off entirely.
static func pitch_test() -> bool:
	var e := Equalizer.new()
	var ok := is_equal_approx(e.pitch_scale(), 1.0)     # defaults are unity -> effect OFF
	e.fx["key_semi"] = 12.0
	ok = ok and is_equal_approx(e.pitch_scale(), 2.0)   # +12 ST is one octave up
	e.fx["key_semi"] = -12.0
	ok = ok and is_equal_approx(e.pitch_scale(), 0.5)   # -12 ST is one octave down
	e.fx["key_semi"] = 0.0
	e.fx["tape"] = 1.5
	ok = ok and is_equal_approx(e.pitch_scale(), 1.5)   # tape alone, exactly as before
	e.free()   # Equalizer is a Node, not RefCounted
	return ok

## Cutoff sweeps have to be logarithmic. A linear one spends most of its travel above
## 10 kHz, where nothing is, and crosses the whole audible bass range in the last few px.
static func _sweep(t: float, lo: float, hi: float) -> float:
	return lo * pow(hi / lo, clampf(t, 0.0, 1.0))

## Self-check for the one bit of FX maths with real branches. Called from an assert in
## player.gd's _ready, so a broken dead-centre fails the run instead of the ear.
static func cut_test() -> bool:
	var e := Equalizer.new()
	var ok := true
	for probe in [[0.5, 0, 0.0], [0.52, 0, 0.0], [0.0, -1, 80.0], [1.0, 1, 8000.0]]:
		e.fx["cut"] = probe[0]
		var s: Array = e.cut_state()
		if s[0] != probe[1] or (s[0] != 0 and not is_equal_approx(s[1], probe[2])):
			ok = false
	e.free()   # Equalizer is a Node, not RefCounted: dropping the reference would leak it
	return ok

func set_dsp(which: String, amount: float) -> void:
	if which == "tbass":
		tbass = clampf(amount, 0.0, 1.0)
	else:
		bbe = clampf(amount, 0.0, 1.0)
	_dirty = true

## EZ mode is three macros over the same 16-lane curve, weighted with raised cosines so
## the bands overlap smoothly rather than stepping at the crossover.
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
	AudioServer.set_bus_effect_enabled(_bus, _idx[effect], on)

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
	e.from_dict({"mode": "x", "adapt": "y", "lanes": "z", "ez": 9, "tbass": "q", "bbe": []})
	var ok := e.mode == Mode.OFF and e.adapt == true and e.tbass == 0.0 and e.bbe == 0.0
	e.from_dict({"lanes": [999.0, -999.0], "ez": [500.0], "tbass": 50.0, "bbe": -3.0})
	ok = ok and e.lane_db[0] == GAIN_MAX and e.lane_db[1] == GAIN_MIN 		and e.ez_db[0] == GAIN_MAX and e.tbass == 1.0 and e.bbe == 0.0
	e.fx_from_dict({"rev_room": [1, 2], "dly_ms": "loud", "tape": {}, "dly_on": 5})
	ok = ok and e.fx["rev_room"] == FX_SPEC["rev_room"][3] 		and e.fx["dly_ms"] == FX_SPEC["dly_ms"][3] and e.fx["tape"] == FX_SPEC["tape"][3] 		and e.fx_switch["dly_on"] == false
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

	# T-BASS: shelf lift plus band-limited saturation, true-bypassed at zero.
	#
	# NOT gated on the EQ mode. It used to be, and that made the FX rack's T-BASS fader
	# silently inert whenever EQ read OFF -- the fader moved, the readout changed, and
	# nothing happened to the sound, with the explanation two tabs away. The drive stage
	# is the hardware colour of the signal rather than part of the equalizer curve, which
	# is exactly how boost_db below has always behaved; these now match it.
	var tb_on := tbass > 0.001
	_enable(_tb_shelf, tb_on)
	_enable(_tb_drive, tb_on)
	if tb_on:
		# Shelf lift capped at 1.9x (+5.6 dB) rather than 2.8x (+8.9 dB). A shelving
		# biquad's group delay scales with its gain, and Godot 4 ships no linear-phase
		# filter to escape that with -- so how hard this lifts IS the only lever on how
		# far it moves the kick's leading edge relative to the rest of the mix.
		_tb_shelf.gain = 1.0 + tbass * 0.9
		# pre_gain used to drive the already-boosted bass 4 dB harder into the
		# nonlinearity, which is where the intermodulation was coming from. `drive` alone
		# sets the amount of saturation; the extra pre-stage bought nothing but IMD.
		_tb_drive.drive = tbass * 0.18
		_tb_drive.pre_gain = 0.0
		# Partial makeup -- roughly half the shelf's lift, not all of it. post_gain is
		# full-band while the shelf is not, so compensating in full would be a treble cut
		# wearing a bass boost's label. Half is what keeps normally mastered material out
		# of sustained gain reduction, which is what had the mids breathing on every kick.
		_tb_drive.post_gain = -tbass * 3.0

	var boosting := boost_db > 0.05
	_enable(_boost, boosting)
	if boosting:
		_boost.volume_db = boost_db

	# BBE: high shelf for the sparkle, plus a phase-linear stereo widen.
	#
	# The inter-channel time offset this used to run is gone. Godot's StereoEnhance builds
	# `surround` out of a DELAYED MONO SUM added to L and subtracted from R -- decompose
	# that and mid is untouched while the side channel receives a full, late copy of the
	# programme. At the old bbe * 12.0 that was a 4.5 ms anti-phase ghost of every
	# transient, sitting squarely inside the Haas fusion window, which the ear reads as a
	# smeared image and a blurred attack instant rather than as width. Worst on
	# headphones, where there is no crossfeed to cover it.
	#
	# pan_pullout widens with no delay whatsoever: it is a straight M/S gain -- mid
	# untouched, side scaled -- so it is phase-linear and still collapses cleanly to mono.
	var bb_on := bbe > 0.001   # same rule as T-BASS above: independent of the EQ mode
	_enable(_bbe_shelf, bb_on)
	_enable(_bbe_phase, bb_on)
	if bb_on:
		_bbe_shelf.gain = 1.0 + bbe * 1.5
		_bbe_phase.pan_pullout = 1.0 + bbe * 0.6
		_bbe_phase.surround = 0.0       # zero is what keeps the delay line out of circuit
		_bbe_phase.time_pullout_ms = 0.0

	# --- FX rack. Independent of the EQ mode: these are performance effects, and
	# switching the equalizer OFF should not silently kill a reverb tail.
	var live: bool = not fx_switch["bypass"]

	var rv: bool = live and fx_switch["rev_on"]
	_enable(_reverb, rv)
	if rv:
		_reverb.room_size = fx["rev_room"]
		_reverb.damping = fx["rev_damp"]
		# a true wet/dry crossfade, not a wet send bolted onto a full dry signal --
		# otherwise the level climbs with the mix knob and WET MIX reads as a volume
		_reverb.wet = fx["rev_wet"]
		_reverb.dry = 1.0 - fx["rev_wet"]

	var dl: bool = live and fx_switch["dly_on"]
	_enable(_delay, dl)
	if dl:
		var ms: float = fx["dly_ms"]
		var wet_db := linear_to_db(maxf(fx["dly_wet"], 0.0001))
		_delay.dry = 1.0
		# two taps at 1x and 1.5x the set time, panned apart: that offset IS the stereo
		# in "stereo delay". One centred tap is an echo, not a spread.
		_delay.tap1_active = true
		_delay.tap1_delay_ms = ms
		_delay.tap1_level_db = wet_db
		_delay.tap1_pan = -0.4
		_delay.tap2_active = true
		_delay.tap2_delay_ms = ms * 1.5
		_delay.tap2_level_db = wet_db - 3.0
		_delay.tap2_pan = 0.4
		_delay.feedback_active = fx["dly_fb"] > 0.005
		_delay.feedback_delay_ms = ms
		_delay.feedback_level_db = lerpf(FB_DB_MIN, FB_DB_MAX, fx["dly_fb"])

	# only ever one of the two filters is in circuit; the centre detent runs neither
	var cut: Array = cut_state()
	var lp_on: bool = live and cut[0] == -1
	var hp_on: bool = live and cut[0] == 1
	_enable(_lp, lp_on)
	_enable(_hp, hp_on)
	if lp_on:
		_lp.cutoff_hz = cut[1]
		_lp.resonance = fx["res"]
	elif hp_on:
		_hp.cutoff_hz = cut[1]
		_hp.resonance = fx["res"]

	# PitchShift is the most expensive thing on the bus (an FFT per block), so unity
	# genuinely unloads it rather than running a 1.0x shift
	# This guard is what keeps normal playback free: with TAPE at 1.00x and KEY SHIFT at
	# 0 ST the effect is not merely at unity, it is switched off and costs nothing.
	var shift := pitch_scale()
	var shifting: bool = live and absf(shift - 1.0) > 0.005
	_enable(_pitch, shifting)
	if shifting:
		_pitch.pitch_scale = shift

	# The limiter covers the rack, not just the booster: a resonant filter peak and a
	# stacked delay tail both add level that boost_db knows nothing about, and the whole
	# point of putting it last in the chain is that it catches all of it.
	#
	# tb_on and bb_on used to arm it too, and THAT was the pumping. T-BASS is a tone
	# control that happens to add level, so arming a limiter off it meant every kick drove
	# gain reduction and the mids breathed back up over the release -- a gain artefact
	# locked to the beat, which is heard as the track being fractionally off rather than
	# as compression. AudioEngine now puts a real limiter on Master, which is the right
	# place to catch a tone control: it sees the actual summed output of both decks and
	# the video node, so this one no longer has to guess on their behalf.
	_enable(_limiter, boosting or rv or dl or lp_on or hp_on or shifting)

## Back to defaults. Kept here rather than in the UI so there is one definition of
## "off", and the dirty flag makes the bus follow on the next frame like any other edit.
func reset_all() -> void:
	mode = Mode.OFF
	adapt = true
	for i in LANES:
		lane_db[i] = 0.0
	for i in 3:
		ez_db[i] = 0.0
	tbass = 0.0
	bbe = 0.0
	boost_db = 0.0
	for key in FX_SPEC:
		fx[key] = FX_SPEC[key][3]
	for key in fx_switch:
		fx_switch[key] = false
	_dirty = true

# --- persistence ----------------------------------------------------------
func to_dict() -> Dictionary:
	return {"mode": int(mode), "adapt": adapt, "lanes": Array(lane_db),
		"ez": Array(ez_db), "tbass": tbass, "bbe": bbe}

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
	tbass = clampf(_num(d.get("tbass"), 0.0), 0.0, 1.0)
	bbe = clampf(_num(d.get("bbe"), 0.0), 0.0, 1.0)
	_dirty = true

## The FX section of the config, keyed exactly as it is written. Clamped on the way in
## rather than trusted: library.cfg is a plain text file a user can and will hand-edit,
## and an out-of-range pitch_scale or cutoff is an audible fault, not a caught error.
func fx_from_dict(d: Dictionary) -> void:
	for key in FX_SPEC:
		var spec: Array = FX_SPEC[key]
		# _num rather than float(): float() on an Array or Dictionary is a runtime error,
		# and [effects] is as hand-editable as every other section
		fx[key] = clampf(_num(d.get(key), spec[3]), spec[1], spec[2])
	for key in fx_switch:
		var v: Variant = d.get(key, false)
		fx_switch[key] = v if v is bool else false
	_dirty = true

## Chunky fader cap, generated rather than shipped as a PNG. Deliberately neutral grey
## so it reads on every skin without needing to be rebuilt when the palette changes.
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
