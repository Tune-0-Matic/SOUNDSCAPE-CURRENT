class_name AudioDirector
extends Node
## Tracks music in real time: latency-corrected song clock, spectral-flux onsets,
## a phase-invariant tempo lock, and a PREDICTIVE beat clock (beats lead the kick,
## they never chase it). Attach a player with attach(), then listen to beat/bar/onset.

signal beat(index: int)
signal bar(index: int)
signal onset(strength: float)

## Analyser window. Measured (RaveShark): 0.1 -> beat clock -169 ms sd 196 (unlocked);
## 0.05 -> +6 ms sd 8; 0.03 collapses tempo confidence 0.87 -> 0.29. Do not "tune" this up.
const BUFFER_LENGTH := 0.05
const BAND_COUNT := 32   # >= 32 so the EQ has at least 32 bars to draw
const F_MIN := 30.0
const F_MAX := 16000.0
const HISTORY := 10.0     # seconds of onsets kept for the tempo fit
const MIN_ONSETS := 6     # below this a tempo fit is noise, not a reading
const PHASE_EASE := 0.25  # how hard a locked clock follows each new phase fit
## Onset flux is taken from the low bands only (~30-250 Hz: kick and low bass).
## Full-spectrum flux tracks a click track fine but smears on a real dense mix -
## measured 0.11 confidence on a pop track, versus a usable lock from these bands.
## (11 of 32 bands ~= 250 Hz, same cutoff as the old 9 of 24.)
const FLUX_BANDS := 11
const FLUX_WINDOW := 43   # ~0.7 s at 60 fps, the adaptive threshold window

## The analyser reports over a trailing buffer, and that lag is NOT covered by the
## standard latency formula. Calibration knob: onsets are timestamped back by this
## while the beat clock runs on true song time. Measured on test_director.gd's click
## tracks at 60 FPS, as the mean phase error of emitted beats over each track's second
## half: 0.036 -> +5 ms, 0.046 -> -5 ms, 0.056 -> -16 ms, 0.066 (the old value) -> -21 ms, averaged over 90/120/128/174 BPM.
## ponytail: beats are emitted from _process, so that error includes up to a frame of
## lateness and the value is calibrated at 60 FPS. Anything that must land ON the beat at
## another cap should lead with time_to_beat() rather than react to the signal.
@export var onset_lag := 0.041
@export var bus := "Master"
@export_range(1.0, 4.0) var sensitivity := 1.5
@export var beats_per_bar := 4
## Off by default: the spectrum feed costs almost nothing, but the tempo fit sweeps
## ~560 candidate periods every 0.5 s. Nothing but the BPM readout consumes it.
@export var track_tempo := false
@export_range(60.0, 200.0) var min_bpm := 60.0
@export_range(60.0, 240.0) var max_bpm := 200.0

var bpm := 0.0
var confidence := 0.0
var beat_index := -1
var bar_index := -1
var levels := PackedFloat32Array()
var energy := 0.0
var stereo := Vector2.ZERO   # summed left/right magnitude, for meters

var _player: AudioStreamPlayer
var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _slot := -1   # the analyser's bus slot, so set_tracking can switch it in and out
var _edges := PackedFloat32Array()
var _weight := PackedFloat32Array()
var _prev := PackedFloat32Array()
var _flux := PackedFloat32Array()
var _last_flux := 0.0
var _onsets := PackedFloat64Array()
var _last_onset := -1.0
var _phase := 0.0
var _next_fit := 0.0
var _fitting := false   # a sweep is out on a worker; do not queue a second
var _fit_gen := 0       # bumped by reset(), so a fit for the previous track is discarded

var _tasks: Array[int] = []   # sweep task ids: reaped as new ones start, joined in _exit_tree

# Sizing lives in _init, not _ready: a node added during SceneTree._initialize does not
# get _ready until the first idle frame, and attach() may legitimately be called before that.
func _init() -> void:
	for i in BAND_COUNT + 1:
		_edges.append(F_MIN * pow(F_MAX / F_MIN, float(i) / BAND_COUNT))
	for i in BAND_COUNT:
		_weight.append(1.0 + 2.0 * (1.0 - float(i) / BAND_COUNT))  # kick-weighted flux
	_prev.resize(BAND_COUNT)
	levels.resize(BAND_COUNT)

func _ready() -> void:
	_bind_analyser()  # in _ready so an inspector-set `bus` is already applied

## A sweep still out on a worker when the tree is torn down calls back into a freed node.
## Bumping the generation drops any result that lands late; the join makes sure none is
## still running by the time this object goes away.
func _exit_tree() -> void:
	_fit_gen += 1
	AudioEngine.join_tasks(_tasks)

## Inserting or removing a bus effect rebuilds every effect INSTANCE on that bus, which
## silently invalidates the analyser handle cached here -- levels just read 0.0 forever
## with no error. Anything that edits the Master chain must call this afterwards.
func rebind() -> void:
	_bind_analyser()

## Bus effects run BEFORE the bus volume is applied on send, so analysis is
## independent of wherever the user has the volume knob.
func _bind_analyser() -> void:
	var b := AudioServer.get_bus_index(bus)
	if b < 0:
		push_warning("AudioDirector: no bus named %s" % bus)
		return
	var slot := -1
	for i in AudioServer.get_bus_effect_count(b):
		if AudioServer.get_bus_effect(b, i) is AudioEffectSpectrumAnalyzer:
			slot = i
			break
	if slot < 0:
		var fx := AudioEffectSpectrumAnalyzer.new()
		fx.buffer_length = BUFFER_LENGTH
		AudioServer.add_bus_effect(b, fx)
		slot = AudioServer.get_bus_effect_count(b) - 1
	_spectrum = AudioServer.get_bus_effect_instance(b, slot)
	_slot = slot

func attach(p: AudioStreamPlayer) -> void:
	_player = p
	reset()

func reset() -> void:
	bpm = 0.0
	confidence = 0.0
	beat_index = -1
	bar_index = -1
	_onsets.clear()
	_flux.clear()
	_last_onset = -1.0
	_phase = 0.0
	_next_fit = 0.0
	_prev.fill(0.0)
	# a sweep may still be out on a worker against the OLD track's onsets; bumping the
	# generation is what makes _apply_fit throw its result away when it lands
	_fit_gen += 1
	_fitting = false

## Analyser slot and tempo fit together, for a director that only matters while a feature is
## on -- the per-deck BEAT SYNC trackers. Off, it costs neither an FFT on the audio thread nor
## a sweep on a worker, and its stale lock is dropped.
func set_tracking(on: bool) -> void:
	track_tempo = on
	var b := AudioServer.get_bus_index(bus)
	if b >= 0 and _slot >= 0:
		AudioServer.set_bus_effect_enabled(b, _slot, on)
	if not on:
		reset()

## Seconds to move `slave`'s playhead so its next beat lands on `master`'s, or NAN when the
## two cannot be aligned: either clock unlocked, or tempos further apart than `tol` -- phase
## alignment without matching tempo holds for an instant and then drifts audibly apart.
static func sync_seek(master: AudioDirector, slave: AudioDirector, tol: float) -> float:
	if master.bpm <= 0.0 or slave.bpm <= 0.0 or master.confidence < 0.5 or slave.confidence < 0.5:
		return NAN
	if absf(slave.bpm / master.bpm - 1.0) > tol:
		return NAN
	return sync_offset(master.time_to_beat(), slave.time_to_beat(), 60.0 / master.bpm)

## Pure: the smallest move, within half a period, that puts a beat due in `slave_ttb` onto one
## due in `master_ttb`. Moving a playhead FORWARD by d brings its next beat d seconds sooner.
static func sync_offset(master_ttb: float, slave_ttb: float, period: float) -> float:
	return fposmod(slave_ttb - master_ttb + period * 0.5, period) - period * 0.5

static func sync_test() -> bool:
	return is_equal_approx(sync_offset(0.10, 0.25, 0.5), 0.15) \
		and is_equal_approx(sync_offset(0.40, 0.05, 0.5), 0.15) \
		and is_equal_approx(sync_offset(0.05, 0.40, 0.5), -0.15) \
		and is_equal_approx(sync_offset(0.2, 0.2, 0.5), 0.0)

## True song position: mix-ahead and output latency both removed.
func song_time() -> float:
	if not _player or not _player.playing:
		return 0.0
	var t := _player.get_playback_position() \
		+ AudioServer.get_time_since_last_mix() \
		- AudioServer.get_output_latency()
	return maxf(t, 0.0)

## Seconds until the next predicted beat; negative once it has passed. Use this to
## lead an animation instead of reacting after the fact.
func time_to_beat() -> float:
	if bpm <= 0.0:
		return INF
	var period := 60.0 / bpm
	return period - fposmod(song_time() - _phase, period)

## Idle decay, in wall-clock time rather than per frame. `*= 0.85` once per _process
## ran 0.85^30 per second at 30 FPS and 0.85^144 at 144 -- the same "fade out" emptying
## the display roughly five times faster on a fast machine, which is the frame-rate
## dependence every other moving part here was already built to avoid.
const IDLE_DECAY_PER_SEC := 0.01   # fraction of the level surviving after one second

## Is there a player attached and actually producing sound? The visualizer asks so it
## can hard-zero its bars instead of easing toward a zero it never quite reaches.
func is_live() -> bool:
	return _player != null and (_player.playing or _player.stream_paused)

func _process(delta: float) -> void:
	if not _spectrum:
		return
	if not _player or not _player.playing:
		# STOPPED (or nothing attached at all) is not "quiet", it is silent: zero the
		# array outright so an idle display holds no residue from the last track and
		# anything reading these bands gets exact zeros rather than a decaying tail.
		if not _player or not _player.stream_paused:
			levels.fill(0.0)
			stereo = Vector2.ZERO
			energy = 0.0
			return
		# PAUSED keeps the picture but lets it fall away smoothly
		var keep := pow(IDLE_DECAY_PER_SEC, delta)
		for i in BAND_COUNT:
			levels[i] *= keep
		stereo *= keep
		energy *= keep
		return
	var t := song_time()
	_read_bands()
	if not track_tempo:
		return
	var f := _flux_now()
	if _is_onset(f, t):
		_onsets.append(t - onset_lag)  # timestamp back to where the sound really was
		_last_onset = t
		onset.emit(f)
	_last_flux = f
	while _onsets.size() > 0 and _onsets[0] < t - HISTORY:
		_onsets.remove_at(0)
	if t >= _next_fit:
		_next_fit = t + 0.5
		_fit_tempo()
	_advance_clock(t)

## get_magnitude_for_frequency_range returns a Vector2 of left/right magnitudes. The
## per-band level collapses that to one number, but the channel split is kept whole in
## `stereo` -- a VU meter needs it, and recomputing it later would mean a second FFT read.
func _read_bands() -> void:
	energy = 0.0
	stereo = Vector2.ZERO
	for i in BAND_COUNT:
		var lr := _spectrum.get_magnitude_for_frequency_range(_edges[i], _edges[i + 1])
		stereo += lr
		var m := lr.length()
		levels[i] = m
		energy += m

func _flux_now() -> float:
	var f := 0.0
	for i in BAND_COUNT:
		var d: float = levels[i] - _prev[i]
		if d > 0.0 and i < FLUX_BANDS:
			f += d * _weight[i]
		_prev[i] = levels[i]
	return f

## Adaptive threshold over a trailing window plus a debounce. Deliberately no
## local-peak test: it rejected the rising frame of short transients and starved the
## tempo fit (7-11 onsets where 15-30 were present). The debounce covers the tail.
func _is_onset(f: float, t: float) -> bool:
	_flux.append(f)
	if _flux.size() > FLUX_WINDOW:
		_flux.remove_at(0)
	if _flux.size() < FLUX_WINDOW:
		return false
	var mean := 0.0
	for v in _flux:
		mean += v
	mean /= _flux.size()
	if f <= mean * sensitivity:
		return false
	return _last_onset < 0.0 or t - _last_onset > 0.12  # debounce: cap at ~500 onsets/min

## Hands the periodicity sweep to a worker.
##
## This is the one genuinely expensive thing in the class and it used to run inline:
## (max_bpm - min_bpm) / 0.25 candidate periods, each summing a cos and a sin over every
## onset in the 10 s history -- on the order of 90,000 transcendental pairs, in GDScript,
## in a single frame, every half second. It stalled the frame, and an irregular frame
## cadence jitters the song_time() samples that timestamp the onsets feeding the next fit,
## so the stall degraded the very reading it was computing. Off the main thread it goes.
func _fit_tempo() -> void:
	if _fitting or _onsets.size() < MIN_ONSETS:
		return
	_fitting = true
	var gen := _fit_gen
	# A COPY. _process appends to _onsets and trims its front every frame, and a
	# PackedFloat64Array is not safe to read while that is happening.
	var snapshot := _onsets.duplicate()
	var lo := min_bpm
	var hi := max_bpm
	AudioEngine.reap_tasks(_tasks)
	_tasks.append(WorkerThreadPool.add_task(func() -> void:
		_apply_fit.bind(sweep_tempo(snapshot, lo, hi), gen).call_deferred()))

## Phase-invariant periodicity fit: treat onsets as impulses and take the DFT
## magnitude at each candidate tempo. The argument hands us the grid phase for free.
##
## Static and pure -- it touches no node state, which is what makes it safe to run on a
## worker and testable without a tree or an audio device. Returns [bpm, phase, confidence],
## or [] when there is not enough to fit.
static func sweep_tempo(onsets: PackedFloat64Array, lo: float, hi: float) -> Array:
	if onsets.size() < MIN_ONSETS:
		return []
	var best := 0.0
	var best_bpm := 0.0
	var best_phase := 0.0
	var b := lo
	while b <= hi:
		var r := _dft_at(onsets, 60.0 / b)
		if r.x > best:
			best = r.x
			best_bpm = b
			best_phase = r.y
		b += 0.25
	# Octave correction: an eighth-note grid scores as well as the quarter-note one.
	# Prefer the slower reading when it is nearly as strong.
	var half := best_bpm * 0.5
	if half >= lo:
		var r := _dft_at(onsets, 60.0 / half)
		if r.x > best * 0.8:
			best_bpm = half
			best = r.x
			best_phase = r.y
	return [best_bpm, best_phase, best]

## DFT magnitude and grid phase of the onset impulse train at one candidate period,
## as (magnitude, phase). A Vector2 rather than an Array so a full sweep does not put
## a thousand throwaway allocations through the heap.
static func _dft_at(onsets: PackedFloat64Array, period: float) -> Vector2:
	var re := 0.0
	var im := 0.0
	for t in onsets:
		var a := TAU * t / period
		re += cos(a)
		im += sin(a)
	return Vector2(sqrt(re * re + im * im) / onsets.size(),
		fposmod(atan2(im, re) / TAU * period, period))

## Back on the main thread with the worker's result.
func _apply_fit(r: Array, gen: int) -> void:
	if gen != _fit_gen:
		return   # attach()/reset() moved us on; this fit belongs to the previous track
	_fitting = false
	if r.is_empty():
		return
	var best_bpm: float = r[0]
	var best_phase: float = r[1]
	# Once locked, ease the phase toward the new fit instead of snapping to it. A hard
	# re-anchor every fit makes the beat clock jitter (sd 89 ms at 90 BPM); this is a
	# PLL-lite that keeps the clock predictive while still following real tempo drift.
	if bpm > 0.0 and absf(best_bpm - bpm) < 1.0 and confidence > 0.5:
		var period := 60.0 / best_bpm
		var d := fposmod(best_phase - _phase + period * 0.5, period) - period * 0.5
		_phase = fposmod(_phase + d * PHASE_EASE, period)
	else:
		_phase = best_phase
	bpm = best_bpm
	confidence = r[2]

## Self-check for the sweep, asserted from player.gd's _ready. Static and pure, so it needs
## no tree and no audio: a perfect 120 BPM impulse train must come back as 120, at full
## confidence, with the grid phase landing on an onset. The range is kept narrow so the
## boot-time assert stays cheap while still reaching the octave-correction branch.
static func tempo_test() -> bool:
	var onsets := PackedFloat64Array()
	for i in 16:
		onsets.append(2.5 + i * 0.5)        # 120 BPM, deliberately not anchored at zero
	var r := sweep_tempo(onsets, 60.0, 130.0)
	if r.is_empty() or absf(float(r[0]) - 120.0) > 0.26:
		return false
	if float(r[2]) < 0.99:                  # a perfect train fits exactly
		return false
	# the grid phase must land on an onset, modulo the period
	if absf(fposmod(float(r[1]), 0.5) - fposmod(2.5, 0.5)) > 0.01:
		return false
	return sweep_tempo(PackedFloat64Array([1.0]), 60.0, 130.0).is_empty()

func _advance_clock(t: float) -> void:
	if bpm <= 0.0:
		return
	var period := 60.0 / bpm
	var idx := int(floor((t - _phase) / period))
	if idx <= beat_index:
		return
	beat_index = idx
	beat.emit(idx)
	# A re-lock re-anchors the absolute index, so bars follow the music, not a
	# running count. bars_emitted != beats_emitted / beats_per_bar. That is correct.
	if idx % beats_per_bar == 0:
		bar_index = idx / beats_per_bar
		bar.emit(bar_index)
