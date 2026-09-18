class_name AudioEngine
extends Node
## Decoding, caching, metadata and queue management for the media player.
##
## FIDELITY -- read this before trusting the word "lossless" anywhere below.
## FLAC, WAV and DSD decode natively in libsoundscape_dsp (SsFlacStream with dr_flac, SsWavStream
## with dr_wav, SsDsdStream for .dsf/.dff): 24-bit and hi-res files, EXTENSIBLE WAV headers and
## float WAVs included, reach the mixer as 32-bit float, with no transcode, no cache file and no
## ffmpeg spawn. Float holds every 24-bit sample exactly, so nothing is truncated on the way IN, and
## the extension converts each file's rate to audio/driver/mix_rate ITSELF with a 120 dB windowed
## sinc on the exact rational ratio (resampler.h: under -135 dB THD+N, no drift), where Godot's own
## 4-point cubic measured -26 dB and -19.9 ppm. DSD is decimated from its 1-bit stream first. The
## deck's effects then run in float, and the device takes whatever format it negotiated. MP3 and
## Ogg decode to float and still go through Godot's resampler. Without the extension, WAV falls
## back to AudioStreamWAV (16-bit, no EXTENSIBLE files), and FLAC and DSD do not play.

signal track_ready(path: String, stream: AudioStream, meta: Dictionary, deck: int)
## Carries the deck the decode was requested for, the same way track_ready does: a failure on the
## deck nobody is driving must not make the live deck skip the track it is playing.
signal track_failed(path: String, reason: String, deck: int)
signal queue_changed()

enum Repeat { OFF, ALL, ONE }


## Pitch-class names, index 0 = C. Only used to render a key TAG; nothing here
## analyses audio.
const KEY_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

var queue: Array[String] = []
var index := -1
var repeat: Repeat = Repeat.ALL
var shuffle := false

## path -> Dictionary. ffprobe results never change for a file, so they are cached for
## the session -- but the cache is written from WORKER threads (both request() and
## _preload() probe there) and read from the main thread, and a Godot Dictionary is not
## thread safe: an insert can rehash under a concurrent read. _meta_lock guards every
## touch of the container itself.
var _meta := {}
var _meta_lock := Mutex.new()
var _next_stream: AudioStream  # preloaded so a track change does not stall on disk I/O
var _next_path := ""
## One generation counter PER DECK. A single shared one let a request on deck B supersede a
## decode still in flight for deck A; each deck now only ever cancels its own.
var _tokens: Array[int] = [0, 0]

# --- decks -----------------------------------------------------------------
## Two mixer channels under one engine. Each deck is a bus plus the players that feed it;
## the crossfader is the relative gain between them, and the EQ/FX rack is a per-deck
## instance that the single UI binds to whichever deck is live.
##
## The gain is applied to the BUS, not to the players. Every player's own volume_db is
## already spoken for by the track-to-track fade tween in player.gd, and two systems
## writing one property is how a fade ends up stuck at -80 dB with nothing to say which
## of them left it there.
##
## Each deck owns TWO players, not one: a deck without a partner cannot cross-fade
## between consecutive tracks, and that is a shipped feature (FADE TIME in the settings).
## The primaries are created here; player.gd hands over the two scene players as the
## partners, so each deck's pair is primary + spare.
const DECK_BUSES := ["DeckA", "DeckB"]
const DECK_NAMES := ["DECK A", "DECK B"]
## Silence floor. linear_to_db(0) is -inf, which propagates into tweens and comparisons
## as a value nothing recovers from; -80 dB is inaudible and is a number.
const DECK_SILENT_DB := -80.0

signal deck_changed(deck: int)

## 0 = deck A, 1 = deck B: the deck the library transport plays into.
var deck := 0
## 0.0 = deck A alone, 1.0 = deck B alone. Defaults to 0.0 rather than the middle,
## because a centred fader on first launch would drop the only deck anyone has been
## using to -6 dB and read as the program getting quieter for no reason.
var crossfader := 0.0
var _deck_players: Array[AudioStreamPlayer] = []

func _ready() -> void:
	_setup_master_limiter()
	_setup_master_mono()
	_setup_master_curve()
	_setup_decks()

## Ceiling for the Master safety limiter. A hair under 0 dBFS, same reasoning as the
## per-deck one: it exists to be hit, not to be a tone control.
const MASTER_CEILING_DB := -0.5

## The only thing in the program that sees the SUM. Each deck's rack ends in its own
## limiter, but that one sits INSIDE the deck, ahead of the crossfader -- and the
## crossfader is bus volume, applied on send, so until now nothing looked at the combined
## level at all. Deck A, deck B and the %Video node (which has no bus of its own, so it
## lands straight on Master) all arrive here already mixed.
##
## Inserted at slot 0, which keeps it AHEAD of the analyser AudioDirector appends: the
## visualizer is meant to show what you hear, and what you hear includes the limiting.
func _setup_master_limiter() -> void:
	var m := AudioServer.get_bus_index("Master")
	# scan before inserting, the same rule AudioDirector uses for its analyser: buses
	# outlive the scene, so a second _ready must not stack a second limiter
	for i in AudioServer.get_bus_effect_count(m):
		if AudioServer.get_bus_effect(m, i) is AudioEffectHardLimiter:
			return
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = MASTER_CEILING_DB
	AudioServer.add_bus_effect(m, lim, 0)

var _mono_bus_idx := -1
var _mono_effect_idx := -1

## MONO folds L/R to (L+R)/2 in both channels using AudioEffectStereoEnhance at
## pan_pullout 0.0 -- not a custom effect. Godot decomposes into a mid/side pair
## internally (mid=(L+R)/2, side scaled by pan_pullout); at pan_pullout 0 the side
## term drops out entirely and both channels become the mid alone, which is an exact
## fold, not an approximation. surround stays 0 for the same reason fx_rack.gd
## keeps it 0 on BBE: that tap is a delayed mono sum added back into both channels,
## and it would smuggle a comb-filtered image back in on top of the fold.
##
## It sits right after the limiter, slot 1, and before whatever AudioDirector appends,
## since MONO is a monitoring fold on the final, already-limited signal -- not a mix
## decision. Same idempotency rule as the limiter above: a second _ready must not
## stack a second fold. True-bypassed by set_bus_effect_enabled, never added/removed
## at runtime -- that is what invalidates AudioDirector's cached analyser handle.
func _setup_master_mono() -> void:
	_mono_bus_idx = AudioServer.get_bus_index("Master")
	for i in AudioServer.get_bus_effect_count(_mono_bus_idx):
		if AudioServer.get_bus_effect(_mono_bus_idx, i) is AudioEffectStereoEnhance:
			_mono_effect_idx = i
			return
	var fold := AudioEffectStereoEnhance.new()
	fold.pan_pullout = 0.0
	fold.surround = 0.0
	fold.time_pullout_ms = 0.0
	AudioServer.add_bus_effect(_mono_bus_idx, fold, 1)
	_mono_effect_idx = 1
	AudioServer.set_bus_effect_enabled(_mono_bus_idx, _mono_effect_idx, false)

func set_mono(on: bool) -> void:
	if _mono_effect_idx >= 0:
		AudioServer.set_bus_effect_enabled(_mono_bus_idx, _mono_effect_idx, on)

## LISTENING MODE (TBS). AUDIOPHILE (DIRECT), the default, puts nothing between the decks and the
## Master limiter. CASUAL (SMOOTH) switches in SsCasualCurve (libsoundscape_dsp, ss_casual.h): a
## warm, phase-linear curve for harsh masterings -- +2.2 dB below 120 Hz, -0.8 dB around 3 kHz, rolling
## off from 8.5 kHz to -1.5 dB at 16 kHz -- 6.3 ms late.
## DIRECT switches the effect OUT rather than zeroing it -- a disabled bus effect is skipped
## outright, so DIRECT is bit-exact and costs nothing.
enum ListeningMode { AUDIOPHILE, CASUAL }
const LISTENING_MODE_NAMES := ["AUDIOPHILE (DIRECT)", "CASUAL (SMOOTH)"]

var listening_mode := ListeningMode.AUDIOPHILE
var _curve: AudioEffect   # SsCasualCurve, or null without libsoundscape_dsp

## Inserted just AHEAD of the Master limiter, so the limiter catches the +1 dB the curve adds, and
## ahead of AudioDirector's analyser and the recorder's capture, so both see what is heard. Built
## once and switched, never added at runtime, for the same reason as the fold. Same idempotency rule.
func _setup_master_curve() -> void:
	if not ClassDB.class_exists("SsCasualCurve"):
		push_warning("AudioEngine: libsoundscape_dsp did not load, so LISTENING MODE CASUAL has no curve")
		return
	var m := AudioServer.get_bus_index("Master")
	var at := -1
	for i in AudioServer.get_bus_effect_count(m):
		var effect := AudioServer.get_bus_effect(m, i)
		if effect.is_class("SsCasualCurve"):
			_curve = effect
			return
		if effect is AudioEffectHardLimiter and at < 0:
			at = i
	at = maxi(at, 0)
	_curve = ClassDB.instantiate("SsCasualCurve")
	AudioServer.add_bus_effect(m, _curve, at)
	AudioServer.set_bus_effect_enabled(m, at, false)
	if _mono_effect_idx >= at:
		_mono_effect_idx += 1   # the fold sits after the limiter, which just moved one along

func set_listening_mode(mode: int) -> void:
	listening_mode = clampi(mode, 0, LISTENING_MODE_NAMES.size() - 1) as ListeningMode
	var at := curve_slot()
	if at < 0:
		return
	var m := AudioServer.get_bus_index("Master")
	var on := listening_mode == ListeningMode.CASUAL
	if AudioServer.is_bus_effect_enabled(m, at) == on:
		return
	if on:
		_curve.call("reset")   # or its first 8 ms would be whatever played the last time it was on
	AudioServer.set_bus_effect_enabled(m, at, on)

## The curve's slot on Master, found by identity; -1 without the extension.
func curve_slot() -> int:
	if _curve == null:
		return -1
	var m := AudioServer.get_bus_index("Master")
	for i in AudioServer.get_bus_effect_count(m):
		if AudioServer.get_bus_effect(m, i) == _curve:
			return i
	return -1

## What CASUAL delays the output by, in ms; 0 while DIRECT or without the extension.
func curve_latency_ms() -> float:
	if _curve == null or listening_mode != ListeningMode.CASUAL:
		return 0.0
	return 1000.0 * float(_curve.call("get_latency_frames")) / AudioServer.get_mix_rate()

func _setup_decks() -> void:
	for i in DECK_BUSES.size():
		var bus: String = DECK_BUSES[i]
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			var at := AudioServer.get_bus_count() - 1
			AudioServer.set_bus_name(at, bus)
			AudioServer.set_bus_send(at, "Master")
		var p := AudioStreamPlayer.new()
		p.name = "Deck%s" % ["A", "B"][i]
		p.bus = bus
		add_child(p)
		_deck_players.append(p)
	set_crossfader(crossfader)

## The deck's primary player. `which` defaults to the active deck.
func deck_player(which := -1) -> AudioStreamPlayer:
	return _deck_players[which if which >= 0 else deck]

func deck_bus(which := -1) -> String:
	return DECK_BUSES[which if which >= 0 else deck]

func set_deck(which: int) -> void:
	deck = clampi(which, 0, DECK_BUSES.size() - 1)
	deck_changed.emit(deck)

## Relative channel gain in dB, from a linear 0..1 fader. Linear rather than equal-power
## on purpose: this fader doubles as the mute for a deck nobody is using, and an
## equal-power law never quite reaches silence at its ends.
## Both decks at unity with the crossfader ignored -- the deck button's third state.
## set_crossfader refuses to write while this is on, so a config load or a stray call
## cannot silently fade one deck back out from under it; player.gd clears BOTH first
## when the user actually grabs the crossfader.
var both := false

func set_both(on: bool) -> void:
	both = on
	if not on:
		set_crossfader(crossfader)
		return
	for bus in DECK_BUSES:
		var b := AudioServer.get_bus_index(bus)
		if b >= 0:
			AudioServer.set_bus_volume_db(b, 0.0)

func set_crossfader(x: float) -> void:
	crossfader = clampf(x, 0.0, 1.0)
	if both:
		return
	for i in DECK_BUSES.size():
		var gain: float = (1.0 - crossfader) if i == 0 else crossfader
		var b := AudioServer.get_bus_index(DECK_BUSES[i])
		if b >= 0:
			AudioServer.set_bus_volume_db(b, deck_gain_db(gain))

static func deck_gain_db(gain: float) -> float:
	return DECK_SILENT_DB if gain <= 0.001 else linear_to_db(gain)

static func deck_test() -> bool:
	return is_equal_approx(deck_gain_db(1.0), 0.0) \
		and deck_gain_db(0.0) == DECK_SILENT_DB \
		and absf(deck_gain_db(0.5) - (-6.0206)) < 0.01 \
		and deck_gain_db(0.25) < deck_gain_db(0.5)

# --- queue ----------------------------------------------------------------
## `current` re-anchors the play position after the queue is rebuilt. Re-sorting or
## rescanning reorders the queue underneath a playing track, and keeping the old integer
## index would make auto-advance jump to whatever now happens to sit in that slot --
## so the index is recovered from the path instead.
func set_queue(paths: Array[String], current: String = "") -> void:
	queue = paths.duplicate()
	index = queue.find(current) if not current.is_empty() else -1
	queue_changed.emit()

## Returns the index that should play next, or -1 when the queue is exhausted.
## Kept pure so the wrap/repeat/shuffle rules are testable without playing anything.
static func peek_next(from: int, wrapped_repeat: Repeat, is_shuffle: bool, size: int, rng_pick: int) -> int:
	if size <= 0:
		return -1
	if wrapped_repeat == Repeat.ONE:
		return from
	if is_shuffle:
		# a pick landing on the track already playing would repeat it, which reads as the
		# shuffle being broken. Step off by one rather than re-rolling, so the caller's RNG
		# stays the only source of randomness and this function stays pure.
		return (rng_pick + 1) % size if rng_pick == from and size > 1 else rng_pick
	if from + 1 < size:
		return from + 1
	return 0 if wrapped_repeat == Repeat.ALL else -1

func next_index() -> int:
	return peek_next(index, repeat, shuffle, queue.size(), randi() % maxi(queue.size(), 1))

func prev_index() -> int:
	if queue.is_empty():
		return -1
	if shuffle:
		return randi() % queue.size()
	return index - 1 if index > 0 else (queue.size() - 1 if repeat == Repeat.ALL else -1)

# --- request ---------------------------------------------------------------
## Asks for a track. Emits track_ready on the main thread when the stream and its
## metadata are both available. Any work that can block (ffmpeg, ffprobe, reading a
## 90 MB wav) happens on a worker; only the newest request PER DECK is honoured.
func request(i: int, for_deck := -1) -> void:
	if i < 0 or i >= queue.size() or _shutdown:
		return
	# The deck is captured HERE, at request time. A cold FLAC transcode takes seconds, and
	# switching decks inside that window must not redirect the result: it belongs to the
	# deck that asked for it, and track_ready carries that deck back to player.gd.
	var d := deck if for_deck < 0 else for_deck
	if d == deck:
		index = i   # the queue position is the DRIVEN deck's; loading the other one must not move it
	load_on(d, queue[i])

## Decodes `path` for deck `d` whether or not the queue holds it: the undriven deck's pick from
## its own track list, leaving the queue and the driven deck's place in it untouched.
func load_on(d: int, path: String) -> void:
	if _shutdown:
		return
	_tokens[d] += 1
	var token: int = _tokens[d]
	if path == _next_path and _next_stream:  # preloaded by the previous track
		var s := _next_stream
		_next_stream = null
		_next_path = ""
		_deliver(d, token, path, s)
		return
	run_task(func() -> void:
		# The pool QUEUES tasks, so by the time this one starts several more skips may have
		# landed. Testing the token here rather than only in _deliver is what stops a
		# superseded track decoding anyway -- which for a FLAC means a full ffmpeg spawn and
		# 35-160 MB of PCM materialised for a track nobody is going to hear.
		if token != _tokens[d] or _shutdown:
			return
		var s := decode(path)
		var m := metadata(path)
		_deliver.bind(d, token, path, s, m).call_deferred())

func _deliver(d: int, token: int, path: String, s: AudioStream, m: Dictionary = {}) -> void:
	if _shutdown or token != _tokens[d]:
		return  # superseded on this deck, or closing; drop it rather than hijack playback
	if not s:
		# what failed, in the caller's terms: the extension is the difference between "this file
		# is broken" and "this build cannot play this format at all"
		var why := "decode failed"
		match path.get_extension().to_lower():
			"flac":
				why = "decode failed" if native_flac_available() else "FLAC needs libsoundscape_dsp"
			"dsf", "dff":
				why = "decode failed" if ClassDB.class_exists("SsDsdStream") else "DSD needs libsoundscape_dsp"
			"mp4":
				why = "decode failed" if video_test else "Video TEST is off"
		track_failed.emit(path, why, d)
		return
	track_ready.emit(path, s, m if not m.is_empty() else metadata(path), d)
	_preload(next_index(), d)

## Warms the NEXT track's stream AND its metadata on a worker, so a transition costs no
## disk I/O and no process spawn.
##
## The metadata call is not incidental. Without it the probe had never run by the time
## the preloaded stream was consumed, so _deliver fell through to metadata() on the MAIN
## thread and shelled out to ffprobe there -- measured at 54 ms, 3.3 dropped frames, on
## every gapless transition. Probing here costs nothing: the worker is already waiting on
## the decode, and the result lands in the same session cache either way.
##
## Holds one decoded stream in RAM (~90 MB for a 4 min 96 kHz stereo track) -- that is
## the price of gapless-feeling transitions. Drop this call to trade smoothness for RAM.
func _preload(i: int, d: int) -> void:
	if i < 0 or i >= queue.size() or queue[i] == _next_path:
		return
	var path := queue[i]
	_next_path = path
	# Whatever was warmed for the PREVIOUS next-track is dead weight the moment the queue
	# points somewhere else -- 35-160 MB of decoded PCM for a track nothing is heading to.
	# Dropped here, so at most one preloaded stream is ever resident.
	_next_stream = null
	var token: int = _tokens[d]
	run_task(func() -> void:
		if token != _tokens[d] or _shutdown:
			return   # queue moved on while this sat in the pool: no decode, no ffmpeg
		var s := decode(path)
		metadata(path)   # so _deliver never has to probe on the main thread
		(func() -> void:
			# re-tested on the main thread, which is where the tokens and _next_path settle
			if token == _tokens[d] and _next_path == path and not _shutdown:
				_next_stream = s).call_deferred())

# --- decoding --------------------------------------------------------------
func decode(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"mp3": return AudioStreamMP3.load_from_file(path)
		"ogg": return AudioStreamOggVorbis.load_from_file(path)
		"wav": return native_wav(path)
		"flac": return native_flac(path)
		"dsf", "dff": return native_dsd(path)
		"mp4": return mp4_sound(path) if video_test else null   # the Video TEST gate, below
	return null

## True when libsoundscape_dsp loaded and registered SsFlacStream. Without it a FLAC does not
## play at all: the ffmpeg transcode fallback is gone on purpose, rather than kept as a second,
## 16-bit path that would quietly mask a library that failed to load.
static func native_flac_available() -> bool:
	return ClassDB.class_exists("SsFlacStream")

## The COMPRESSED bytes are what stays resident -- about 130 MB for 4 min of 96 kHz/24-bit,
## 30 MB at CD rate -- and frames decode block by block inside the mix, so there is no decoded
## copy at all. Called on a worker by request()/_preload(), like every other decode.
static func native_flac(path: String) -> AudioStream:
	if not native_flac_available():
		push_warning("%s: FLAC needs libsoundscape_dsp, which did not load" % path.get_file())
		return null
	var s: AudioStream = ClassDB.instantiate("SsFlacStream")
	return s if int(s.call("load", path)) == OK else null

## DSD exists only through libsoundscape_dsp: nothing in Godot or on the ffmpeg path plays it as DSD.
static func native_dsd(path: String) -> AudioStream:
	if not ClassDB.class_exists("SsDsdStream"):
		push_warning("%s: DSD needs libsoundscape_dsp, which did not load" % path.get_file())
		return null
	var s: AudioStream = ClassDB.instantiate("SsDsdStream")
	return s if int(s.call("load", path)) == OK else null

## SsWavStream when libsoundscape_dsp loaded; AudioStreamWAV otherwise, so an unbuilt extension
## still plays ordinary 16-bit WAVs -- just not 24-bit, float or EXTENSIBLE ones, which it refuses.
static func native_wav(path: String) -> AudioStream:
	if not ClassDB.class_exists("SsWavStream"):
		return AudioStreamWAV.load_from_file(path)
	var s: AudioStream = ClassDB.instantiate("SsWavStream")
	return s if int(s.call("load", path)) == OK else null

## Deletes every file in `dir` whose name starts with `prefix`; returns the bytes reclaimed.
##   "pcm_" -- every build before native FLAC cached an ffmpeg transcode of each FLAC here as
##             pcm_<hash>.wav, 30-120 MB apiece, plus .part/.pcm leftovers. Nothing reads them.
##   "rev_" -- reverse renders. REV re-renders on demand, so they are swept at every launch;
##             before this nothing ever removed them (one short session left 30 MB).
static func purge_cache(prefix: String, dir := "user://") -> int:
	var freed := 0
	for f in DirAccess.get_files_at(dir):
		if not f.begins_with(prefix):
			continue
		var path := dir.path_join(f)
		var file := FileAccess.open(path, FileAccess.READ)
		var size := file.get_length() if file else 0
		if file:
			file.close()
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK:
			freed += size
	return freed

# --- Video TEST (TBS) ---------------------------------------------------------
## Off by default, and while it is off an .mp4 does not exist to this program: the scan skips
## it (player.gd _is_track), decode() refuses it whatever list it came from, and nothing
## below ever runs.
##
## On, an MP4 is two renders, cached per file version in video_dir:
##   SOUND   -- its audio stream decoded once to 24-bit FLAC at the source's own rate, then
##              played through the native FLAC path like any other track, so the EQ, FX,
##              beat tracker, sync and recorder all get it. Nothing is resampled and nothing
##              is re-encoded lossy: 24-bit holds the decoded AAC to within a step
##              (test_video_test.gd measures it against ffmpeg's own float decode).
##   PICTURE -- a VIDEO_W-wide, VIDEO_FPS Theora proxy, because VideoStreamPlayer decodes
##              nothing else. Small on purpose: the terminal look throws the detail away
##              (video_test.gdshader), and a proxy this size renders fast.
## ponytail: AAC decodes to float, and overs above 0 dBFS in a hot master clip at the 24-bit
## step. Float WAV would keep them, but AudioStreamWAV truncates to 16-bit, which costs more.
## ponytail: the cache is unbounded while the toggle is on (about 8 MB per minute of 48 kHz
## sound); turning the toggle off purges it.
signal video_ready(path: String, ogv: String)

const VIDEO_DIR := "user://video_test"
const VIDEO_W := 160
const VIDEO_FPS := 15

var video_test := false
var video_dir := VIDEO_DIR   # tests point this away from a real cache

func mp4_sound(path: String) -> AudioStream:
	var af := dither_filter(24) if decodes_to_float(path) else "anull"
	var flac := ffmpeg_render(path, "flac", ["-map", "0:a:0", "-af", af, "-c:a", "flac",
		"-sample_fmt", "s32", "-bits_per_raw_sample", "24"], video_dir, "", is_shut_down)
	return native_flac(flac) if not flac.is_empty() else null

## The picture, rendered on a worker and announced on the main thread. Asked for once the sound
## is already playing: pulling the audio out of an MP4 never decodes its video, while this has
## to decode every frame of it -- seconds per minute for a 1080p H.264 stream.
func request_video(path: String) -> void:
	if not video_test or _shutdown:
		return
	var dir := video_dir
	run_task(func() -> void:
		if _shutdown:
			return
		var ogv := ffmpeg_render(path, "ogv", ["-map", "0:v:0", "-an",
			"-vf", "scale=%d:-2:flags=area,fps=%d" % [VIDEO_W, VIDEO_FPS],
			"-c:v", "libtheora", "-q:v", "5", "-g", str(VIDEO_FPS)], dir, "", is_shut_down)
		if not ogv.is_empty():
			call_deferred("emit_signal", "video_ready", path, ogv))

## TPDF dither for an integer render, as an ffmpeg -af filter (swr): triangular noise of +/-1 LSB
## added before quantising, so the error is noise independent of the signal rather than distortion
## that follows it, and swr clamps at full scale instead of wrapping (measured: +/-1.2 in gives
## 32767 / -32768 and 8388607 / -8388608). `bits` is the output word length. 24-bit needs
## output_sample_bits: ffmpeg carries 24-bit samples in 32-bit ones, and without it swr sizes the
## dither for a 32-bit LSB, 256 times too small to do anything (measured: variance 0.000 LSB^2).
## 32-bit gets no dither. `rate` > 0 resamples in the same swr pass, in float, before the dither.
## ponytail: ffmpeg's 24-bit encoders truncate rather than round, so the dithered error sits half an
## LSB low -- a -144 dBFS DC offset, below the dither's own noise.
static func dither_filter(bits: int, rate := 0) -> String:
	var opts: Array[String] = []
	if rate > 0:
		opts.append("osr=%d" % rate)
	if bits < 32:
		opts.append("osf=%s" % ("s16" if bits <= 16 else "s32"))
		opts.append("dither_method=triangular")
		if bits > 16:
			opts.append("output_sample_bits=%d" % bits)
	return "aresample=" + ":".join(opts) if not opts.is_empty() else "anull"

## Whether ffmpeg decodes `path` to floating point (MP3, AAC, Vorbis, float WAV, DSD) rather than to
## integers (FLAC, integer PCM). Only a float source is dithered on its way into an integer render:
## the same filter on an integer source changes samples that were already exact (measured: 23695 of
## 48000 on a 24-bit WAV), which is noise added for nothing and breaks a bit-exact REV. A failed
## probe answers false, so nothing is dithered on a guess.
static func decodes_to_float(path: String) -> bool:
	var out := []
	OS.execute("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_fmt",
		"-of", "csv=p=0", path], out, true)
	var fmt := str(out[0]).strip_edges() if not out.is_empty() else ""
	return fmt.begins_with("flt") or fmt.begins_with("dbl")

## One ffmpeg render of `path` into `dir`: its absolute path, or "" when ffmpeg fails (no such
## stream, not a media file) or is killed. Named `prefix` + md5 of path + mtime + size, so an
## edited or replaced file renders again. Written under a per-thread name and renamed in, because
## preload and play can render the same file at once, and a render killed halfway must never pass
## for a cache hit. Video TEST's sound and picture and every REV render come through here.
static func ffmpeg_render(path: String, ext: String, args: Array, dir: String, prefix := "",
		cancelled := Callable()) -> String:
	var base := ProjectSettings.globalize_path(dir)
	var out := base.path_join("%s%s.%s" % [prefix, (path + str(file_stamp(path))).md5_text(), ext])
	if FileAccess.file_exists(out):
		return out
	DirAccess.make_dir_recursive_absolute(base)
	var tmp := "%s.%d.%s" % [out.get_basename(), OS.get_thread_caller_id(), ext]
	var ok := run_process("ffmpeg", ["-v", "error", "-y", "-nostdin", "-i", path] + args + [tmp], cancelled) == 0
	if ok and not FileAccess.file_exists(out):
		# Two workers finishing together both see no `out` and both rename. The loser's rename
		# can fail outright -- Windows will not replace a file the winner has just opened to
		# decode -- which is still a success: the finished file is there (test_video_test #3).
		ok = DirAccess.rename_absolute(tmp, out) == OK or FileAccess.file_exists(out)
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)   # failed, killed, or another worker renamed its copy in first
	return out if ok else ""

## Everything a Video TEST render wrote. Run when the toggle goes off, and at launch while it is off,
## which catches a render that was still finishing when the toggle flipped.
static func purge_video_cache(dir := VIDEO_DIR) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))

# --- metadata --------------------------------------------------------------
## Godot cannot read FLAC/Vorbis/ID3 tags, so this shells out to ffprobe, which ships
## with ffmpeg and is therefore already a dependency. Results never change for a given
## file, so they are cached for the session.
## Thread safe, and deliberately does NOT hold the lock across the probe.
##
## ffprobe takes ~55 ms. Holding _meta_lock for that would serialise every worker behind
## whichever one is probing, and block the main thread outright the moment it asked for
## any track's metadata -- reintroducing the stall the preload fix just removed. So the
## lock is taken twice, briefly, around the container access only, and the probe runs
## unlocked in between. Two threads can therefore probe the same file at once; that
## costs a duplicate ffprobe and nothing else, because the second writer defers to the
## first so every caller ends up holding the same Dictionary instance.
## What metadata() has already cached, or {} when this path has never been probed.
## Never probes. The TRACKS readout sums durations across every visible row, and an
## ffprobe spawn per row would turn a search keystroke into a multi-second stall.
## An empty result means "unknown", NOT "zero length" -- a probe that failed still
## caches its defaults, so the caller can tell "not looked at yet" from "looked at and
## the file would not say", and sweep each path at most once.
func cached_meta(path: String) -> Dictionary:
	_meta_lock.lock()
	var d: Variant = _meta.get(path)
	_meta_lock.unlock()
	if d == null:
		d = _from_disk(path)   # a stat, never a probe
	return d if d else {}

func metadata(path: String) -> Dictionary:
	_meta_lock.lock()
	var cached: Variant = _meta.get(path)
	_meta_lock.unlock()
	if cached != null:
		return cached
	var indexed: Variant = _from_disk(path)
	if indexed != null:
		return indexed   # probed in an earlier session and unchanged since: no ffprobe
	var stamp := file_stamp(path)
	var d := default_meta(path)
	# ffprobe emits UTF-8, but OS.execute decodes its output with the system ANSI codepage,
	# which mojibakes any non-Latin tag (Japanese album names came back as "ä¸­åŽŸ").
	# Writing to a file and reading it back with FileAccess decodes UTF-8 correctly.
	# thread id in the name as well as the path hash: with two workers able to probe the
	# same file concurrently, a path-only name would have them clobbering one temp file
	var tmp := ProjectSettings.globalize_path("user://probe_%d_%d.json" % [
		hash(path), OS.get_thread_caller_id()])
	# duration rides along in the pass that was already being spawned for this file, so a
	# track that plays (or gets preloaded) costs nothing extra to know the length of
	var args := ["-v", "error", "-select_streams", "a:0", "-show_entries",
		"format=duration:stream=sample_rate,channels,bits_per_raw_sample,codec_name:format_tags:stream_tags",
		"-of", "json", "-o", tmp, path]
	# A probe that fails is not fatal: `d` already holds a filename-derived title and
	# sane defaults, so the track still plays and still shows -- metadata is decoration
	# here, never a gate. What was missing is that a non-zero exit left its temp JSON
	# behind and said nothing, so a file that probed badly did so silently forever.
	var probed := run_process("ffprobe", args, is_shut_down) == 0
	if not probed:
		push_warning("ffprobe failed on %s; using filename metadata" % path.get_file())
	if probed:
		var raw := FileAccess.get_file_as_string(tmp)
		var j = JSON.parse_string(raw)
		DirAccess.remove_absolute(tmp)
		if j == null and not raw.is_empty():
			push_warning("ffprobe JSON unparseable for %s" % path.get_file())
		if j is Dictionary:
			var st: Dictionary = (j.get("streams", []) as Array)[0] if (j.get("streams", []) as Array).size() > 0 else {}
			d["sample_rate"] = int(st.get("sample_rate", 44100))
			d["channels"] = int(st.get("channels", 2))
			d["bits"] = int(st.get("bits_per_raw_sample", 16)) if st.get("bits_per_raw_sample") else 16
			d["codec"] = str(st.get("codec_name", d["codec"])).to_upper()
			# ffprobe writes it as a string ("253.500000"); float() parses that directly
			d["duration"] = float(j.get("format", {}).get("duration", 0.0))
			var tags: Dictionary = j.get("format", {}).get("tags", {})
			# Vorbis comments sometimes ride on the stream instead of the container.
			# merge() keeps what is already there, so container tags still win.
			tags.merge(st.get("tags", {}))
			# ID3 writes TKEY, Vorbis/FLAC writes KEY or INITIALKEY, and ffprobe hands
			# each back in whatever case the file used -- so match case-insensitively
			# rather than betting on one canonical spelling.
			for k in tags:
				if str(k).to_lower() in ["key", "initialkey", "initial_key", "tkey"]:
					var parsed := format_key_tag(str(tags[k]))
					if not str(parsed["text"]).is_empty():
						d["key"] = parsed
						break
			for k in ["title", "artist", "album"]:
				for variant in [k, k.capitalize(), k.to_upper()]:
					if tags.has(variant) and str(tags[variant]) != "":
						d[k] = str(tags[variant])
						break
	if not probed:
		DirAccess.remove_absolute(tmp)   # nothing read it, so it would sit there forever
	# First writer wins. A racing thread that probed the same path already published its
	# result, and handing back that instance rather than this one keeps every caller
	# pointing at the same Dictionary.
	_meta_lock.lock()
	probes += 1
	var winner: Variant = _meta.get(path)
	if winner == null:
		_meta[path] = d
		_stamps[path] = stamp
		winner = d
	_meta_lock.unlock()
	return winner

# --- persistent library index ------------------------------------------------------
## Everything metadata() learns is kept across sessions in user://library_index.dat, and
## trusted only while the file it describes is unchanged: each entry carries that file's
## modification time and size, and a mismatch drops the entry so the track is probed afresh.
## A cold start therefore runs ffprobe only for what is new or edited -- durations, tags and
## keys for everything else are dictionary reads, which is what lets TRACKS sort by ARTIST,
## ALBUM and KEY the moment the library appears.
const INDEX_PATH := "user://library_index.dat"
const INDEX_VERSION := 1

var probes := 0      # ffprobe runs this session, under _meta_lock; test_library_index.gd reads it
var _stamps := {}    # path -> [mtime, size] for each _meta entry probed or validated this session
var _disk := {}      # path -> [mtime, size, meta] loaded from the index, not yet re-validated

static func default_meta(path: String) -> Dictionary:
	return {
		"title": path.get_file().get_basename(), "artist": "", "album": "",
		"sample_rate": 44100, "channels": 2, "bits": 16, "codec": path.get_extension().to_upper(),
		"key": {"text": "", "pc": -1, "minor": false}, "duration": 0.0,
	}

## [mtime, size], or [] when the file cannot be opened. Opening a handle reads no audio, so
## a OneDrive placeholder is not hydrated by being checked.
static func file_stamp(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return []
	var size := f.get_length()
	f.close()
	return [FileAccess.get_modified_time(path), size]

## Main thread, before any worker exists. Every field is type-checked against default_meta,
## because a stale or hand-damaged index must degrade to "probe again", never to a crash.
func load_index(path := INDEX_PATH) -> int:
	_disk.clear()
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return 0
	var blob: Variant = f.get_var()   # plain data only: get_var never instantiates objects
	f.close()
	if not (blob is Dictionary and blob.get("version") == INDEX_VERSION and blob.get("entries") is Dictionary):
		return 0
	var entries: Dictionary = blob["entries"]
	for p in entries:
		var e: Variant = entries[p]
		if not (p is String and e is Array and (e as Array).size() == 3 and e[2] is Dictionary):
			continue
		var clean := default_meta(p)
		var got: Dictionary = e[2]
		for k in clean:
			if got.has(k) and typeof(got[k]) == typeof(clean[k]):
				clean[k] = got[k]
		var key: Dictionary = clean["key"]
		if not (key.get("pc") is int and key.get("minor") is bool and key.get("text") is String):
			clean["key"] = default_meta(p)["key"]
		_disk[p] = [e[0], e[1], clean]
	return _disk.size()

## An index entry promoted into the session cache if its file still matches, else null.
## ponytail: one stat per indexed track on first use, on whichever thread asks -- for the
## TRACKS readout that is the main thread. Validate on a worker if huge libraries ever stall.
func _from_disk(path: String) -> Variant:
	_meta_lock.lock()
	var e: Variant = _disk.get(path)
	_meta_lock.unlock()
	if e == null:
		return null
	var stamp := file_stamp(path)
	_meta_lock.lock()
	_disk.erase(path)
	var result: Variant = _meta.get(path)
	if result == null and stamp.size() == 2 and stamp[0] == e[0] and stamp[1] == e[1]:
		_meta[path] = e[2]
		_stamps[path] = stamp
		result = e[2]
	_meta_lock.unlock()
	return result

## Writes what is known about `keep` (the library as scanned). Entries for anything else are
## dropped, so a deleted or unchecked-and-forgotten track does not live in the index forever.
func save_index(keep: Array[String], path := INDEX_PATH) -> Error:
	var live := {}
	for p in keep:
		live[p] = true
	var entries := {}
	_meta_lock.lock()
	for p in _meta:
		if live.has(p) and _stamps.has(p):
			entries[p] = [_stamps[p][0], _stamps[p][1], _meta[p]]
	for p in _disk:   # indexed, not visited this session: still valid as far as anyone knows
		if live.has(p) and not entries.has(p):
			entries[p] = _disk[p]
	_meta_lock.unlock()
	var target := ProjectSettings.globalize_path(path)
	var f := FileAccess.open(target + ".tmp", FileAccess.WRITE)
	if not f:
		return FileAccess.get_open_error()
	f.store_var({"version": INDEX_VERSION, "entries": entries})
	f.close()
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(target)   # a cache, not the config: a lost race only re-probes
	return DirAccess.rename_absolute(target + ".tmp", target)

# --- key tags ---------------------------------------------------------------
## The key comes from the file's own tag, read in the ffprobe pass above -- there is no
## DSP here and there must not be. Estimating a key from PCM in GDScript costs a second
## of tight-loop CPU and a second concurrent ffmpeg per track, and it competes with the
## decode and the mix to produce a guess. A tag is what a DJ library already carries, it
## is free, and it is right where an estimate is not.

## Whatever the tagger wrote, normalised to "8A (Am)".
##
## Taggers do not agree: Mixxx writes "Am", Rekordbox "8A", Traktor "Amin", foobar
## "A minor", plenty write "Ebm" and some write a bare "10A". Anything that will not
## parse is passed through verbatim -- an unreadable tag is still something the user put
## there deliberately, and blanking it would be a lie about the file.
##
## Returns {"text": String, "pc": int, "minor": bool}. pc is -1 when the tag did not
## parse, which is the flag the UI reads to mean "show it, but do not transpose it".
static func format_key_tag(raw: String) -> Dictionary:
	var s := raw.strip_edges()
	if s.is_empty():
		return {"text": "", "pc": -1, "minor": false}
	# Camelot in, Camelot out: "8A", "10B", "1a"
	var cam := RegEx.create_from_string("^(\\d{1,2})\\s*([ABab])$").search(s)
	if cam:
		var n := int(cam.get_string(1))
		if n >= 1 and n <= 12:
			var minor: bool = cam.get_string(2).to_lower() == "a"
			# inverse of camelot(): the wheel number is a circle-of-fifths position, and
			# a minor number belongs to the RELATIVE major, so step back three semitones
			var pc: int = ((n + 4) % 12) * 7 % 12
			if minor:
				pc = posmod(pc - 3, 12)
			return {"text": key_label(pc, minor), "pc": pc, "minor": minor}
	var letter := "CDEFGAB".find(s[0].to_upper())
	if letter < 0:
		return {"text": s.to_upper(), "pc": -1, "minor": false}
	var pc: int = [0, 2, 4, 5, 7, 9, 11][letter]
	var i := 1
	if s.length() > 1 and (s[1] == "#" or s[1] == "♯"):
		pc = posmod(pc + 1, 12)
		i = 2
	# a note letter never follows a note letter, so an uppercase B here is a flat, not B
	elif s.length() > 1 and (s[1] == "b" or s[1] == "B" or s[1] == "♭"):
		pc = posmod(pc - 1, 12)
		i = 2
	var rest := s.substr(i).strip_edges().to_lower()
	var minor: bool = rest == "m" or rest.begins_with("min")
	if not (minor or rest.is_empty() or rest.begins_with("maj")):
		return {"text": s.to_upper(), "pc": -1, "minor": false}   # "Cmaj7#11" and friends
	return {"text": key_label(pc, minor), "pc": pc, "minor": minor}

## Camelot wheel position. The number is the place on the circle of fifths with C major
## pinned at 8B; a minor key borrows the number of its RELATIVE major (A minor shares 8
## with C major), which is the entire point of the notation -- same number, compatible.
static func camelot(pc: int, minor: bool) -> String:
	var root: int = (pc + 3) % 12 if minor else pc
	return "%d%s" % [((root * 7 + 7) % 12) + 1, "A" if minor else "B"]

## "8A (Am)" -- Camelot for mixing, letter name for reading.
static func key_label(pc: int, minor: bool) -> String:
	if pc < 0:
		return ""
	return "%s (%s%s)" % [camelot(pc, minor), KEY_NAMES[pc], "m" if minor else ""]

## Transposed pitch class, for showing where KEY SHIFT has moved a tagged key to.
static func key_shifted(pc: int, semitones: int) -> int:
	return pc if pc < 0 else posmod(pc + semitones, 12)

## Self-check for the tag parser, asserted from player.gd's _ready. This is the part
## that fails silently when it is wrong: a misparsed key is still a plausible key, and
## the Camelot corners are where an off-by-one hides.
static func key_tag_test() -> bool:
	for probe in [["Am", "8A (Am)"], ["8A", "8A (Am)"], ["A minor", "8A (Am)"],
			["Amin", "8A (Am)"], ["A", "11B (A)"], ["Ebm", "2A (D#m)"],
			["10B", "10B (D)"], ["1A", "1A (G#m)"], ["B", "1B (B)"],
			["Bb", "6B (A#)"], ["F#m", "11A (F#m)"], ["  8a ", "8A (Am)"],
			["", ""], ["ZZTOP", "ZZTOP"], ["13A", "13A"]]:
		if format_key_tag(probe[0])["text"] != probe[1]:
			return false
	return format_key_tag("ZZTOP")["pc"] == -1 and format_key_tag("Am")["pc"] == 9 \
		and key_shifted(9, 2) == 11 and key_shifted(-1, 5) == -1

# --- reverse playback ---------------------------------------------------------
## AudioStreamPlayer cannot play backwards -- pitch_scale has no negative half -- so a reversed
## take is a real file: ffmpeg -af areverse, rendered once per file version through ffmpeg_render
## as user://rev_<md5 of path+mtime+size>.flac. 24-bit FLAC at the source's own rate, played back
## through SsFlacStream. The old render was forced to 44.1 kHz / 16-bit WAV because Godot's WAV
## loader refused anything else, which cut a hi-res track to CD resolution and resampled it back
## up; it was also keyed by path alone, so a file replaced in place reversed the OLD audio.
## Compression level 0: fast to encode, still about half the size of the same take as float WAV.
## player.gd sweeps rev_* at launch -- nothing needs them across sessions.
signal reversed_ready(path: String, stream: AudioStream)

func request_reversed(path: String) -> void:
	if path.is_empty() or _shutdown:
		return
	run_task(func() -> void:
		if _shutdown:
			return
		# a float-decoded source (MP3, AAC, DSD) is TPDF-dithered onto the 24-bit render; an integer
		# one (FLAC, PCM WAV) reverses sample-exact with no dither at all
		var af := "areverse," + dither_filter(24) if decodes_to_float(path) else "areverse"
		var out := ffmpeg_render(path, "flac", ["-map", "0:a:0", "-af", af, "-c:a", "flac",
			"-compression_level", "0", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"],
			"user://", "rev_", is_shut_down)
		var stream := native_flac(out) if not out.is_empty() else null
		if stream:
			call_deferred("emit_signal", "reversed_ready", path, stream)
		elif not _shutdown:
			push_warning("could not reverse %s" % path.get_file()))

# --- offline spectral key estimation ------------------------------------------------
## Everything above is what runs at playtime, and stays true to its own rule: no DSP
## here. This is the one exception, and it earns it by breaking every part of that
## rule's original complaint -- it never runs at playtime (nothing on the
## request()/_open() path touches it), it never competes with the decode or the mix
## (it is a WorkerThreadPool task queued from a folder SCAN, not from playback), and it
## only ever runs for a track whose tag was silent, which is the one case a tag genuinely
## has nothing to say. The actual chroma/Krumhansl-Schmuckler analysis lives in
## spectral_key.gd, a separate module, so this file's own DSP-free boundary stays literal.
signal spectral_key_ready(path: String, pc: int, minor: bool)

## Guards _spectral_cache/_spectral_pending exactly the way _meta_lock guards _meta
## above: a worker thread writes a result the instant it lands, the main thread reads
## it to paint a readout or to decide whether to queue another file, and a plain
## Dictionary is not safe under that without a lock around each access.
var _spectral_lock := Mutex.new()
var _spectral_cache := {}     # str(hash(path)) -> [pc, minor] -- loaded from library.cfg
var _spectral_pending := {}   # path -> true, so a rescan never queues the same file twice
var _spectral_queue: Array[String] = []   # waiting to be analysed, drained by ONE worker
var _spectral_running := false
## Every WorkerThreadPool task this engine starts -- decodes, preloads, reverse renders,
## the spectral drain -- plus the duration sweeps player.gd routes through run_task.
## Main thread only. The old shutdown() joined just the spectral and reverse tasks, so a
## decode or a sweep still running when the tree was freed called back into a dead object.
var _tasks: Array[int] = []

## Set by shutdown(). Every worker checks it between items, so a queue with hundreds of
## tracks left in it abandons them immediately instead of holding the process open.
var _shutdown := false

## Starts `fn` on the pool and keeps its id for shutdown(). Finished ids are reaped on the
## way in: the pool keeps a task's record until something waits on it, so an id nobody
## ever joins is a small leak on every track change.
func run_task(fn: Callable) -> void:
	if _shutdown:
		return
	reap_tasks(_tasks)
	_tasks.append(WorkerThreadPool.add_task(fn))

func is_shut_down() -> bool:
	return _shutdown

static func reap_tasks(ids: Array[int]) -> void:
	for k in range(ids.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(ids[k]):
			WorkerThreadPool.wait_for_task_completion(ids[k])
			ids.remove_at(k)

static func join_tasks(ids: Array[int]) -> void:
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	ids.clear()

## Called before the scene tree frees this node: explicitly from player.gd's close
## handler, and from _exit_tree for everything else (a headless test that just quits).
## The flag goes up first, so every queued task returns on its first check; then every ffmpeg
## and ffprobe still running is killed, so a worker blocked inside one is released in
## milliseconds instead of holding the window open for the rest of a render (10.6 s measured
## before this); then ALL tasks are joined. Idempotent, so the second call on the way out is free.
func shutdown() -> void:
	_shutdown = true
	kill_processes()
	join_tasks(_tasks)

## Every external process this program starts, so shutdown() can end them rather than wait them
## out. Static because the recorder's conversions run through here too. Guarded by _pid_lock.
static var _pids := {}
static var _pid_lock := Mutex.new()

## Runs `program` to completion on the CALLING thread -- a worker, or the main thread where a
## caller already accepted blocking -- and returns its exit code, or -1 when it would not start or
## was killed. `cancelled` is read under the lock kill_processes() takes, right after the pid is
## registered: a spawn racing a shutdown is either in the registry when the kill sweep reads it,
## or sees its flag already up and ends itself. Either way it does not outlive the shutdown.
static func run_process(program: String, args: Array, cancelled := Callable()) -> int:
	var pid := OS.create_process(program, PackedStringArray(args))
	if pid <= 0:
		return -1
	_pid_lock.lock()
	_pids[pid] = true
	var doomed: bool = cancelled.is_valid() and cancelled.call()
	_pid_lock.unlock()
	if doomed:
		OS.kill(pid)
	while OS.is_process_running(pid):
		OS.delay_msec(4)
	_pid_lock.lock()
	_pids.erase(pid)
	_pid_lock.unlock()
	return OS.get_process_exit_code(pid)

## Kills everything run_process has running. Callers raise their own cancel flag FIRST. Under the
## lock, so no pid is unregistered (and its number freed for reuse) between reading and killing.
static func kill_processes() -> void:
	_pid_lock.lock()
	for pid in _pids:
		OS.kill(pid)
	_pid_lock.unlock()

func _exit_tree() -> void:
	shutdown()

static func spectral_cache_key(path: String) -> String:
	return str(hash(path))

## Whatever queue_spectral_key has already found for this path, or {} if it has not
## been analysed (or analysis found nothing conclusive) yet.
func spectral_key_for(path: String) -> Dictionary:
	_spectral_lock.lock()
	var v = _spectral_cache.get(spectral_cache_key(path))
	_spectral_lock.unlock()
	if v == null:
		return {}
	return {"pc": int(v[0]), "minor": bool(v[1])}

## A locked snapshot for library.cfg to iterate at save time -- iterating the live
## Dictionary directly from the main thread while a worker might still be writing to it
## is exactly the unsafe access the lock exists to prevent.
func spectral_cache_snapshot() -> Dictionary:
	_spectral_lock.lock()
	var copy: Dictionary = _spectral_cache.duplicate()
	_spectral_lock.unlock()
	return copy

## Only ever called at startup, before any worker exists -- no concurrent writer yet,
## so no lock is needed here the way every other access takes one.
func load_spectral_cache(k: String, pc: int, minor: bool) -> void:
	_spectral_cache[k] = [pc, minor]

## Queued, not fanned out. One task per track meant a folder scan handed the pool a
## thousand of them at once -- ffprobe plus ffmpeg plus an FFT on every core, which
## starves the main thread and shows up as the visualizer stuttering and track loads
## hanging while a scan runs. A single drain task keeps the whole feature on ONE core
## and leaves the rest of the pool for decode and preload, which are the tasks a user
## is actually waiting on.
func queue_spectral_key(path: String) -> void:
	if _shutdown:
		return
	var ck := spectral_cache_key(path)
	var launch := false
	_spectral_lock.lock()
	if not (_spectral_cache.has(ck) or _spectral_pending.has(path)):
		_spectral_pending[path] = true
		_spectral_queue.append(path)
		if not _spectral_running:
			_spectral_running = true
			launch = true
	_spectral_lock.unlock()
	if launch:
		run_task(_drain_spectral_queue)

## The single worker. Takes the queue one path at a time and stops the moment it runs
## dry -- the running flag is cleared under the SAME lock as the empty check, so a path
## queued a microsecond later cannot slip in between and be left with no worker.
func _drain_spectral_queue() -> void:
	while not _shutdown:
		_spectral_lock.lock()
		if _spectral_queue.is_empty():
			_spectral_running = false
			_spectral_lock.unlock()
			return
		var path: String = _spectral_queue.pop_front()
		_spectral_lock.unlock()

		var result := _run_spectral_key(path)
		_spectral_lock.lock()
		_spectral_pending.erase(path)
		if not result.is_empty():
			_spectral_cache[spectral_cache_key(path)] = [int(result["pc"]), bool(result["minor"])]
		_spectral_lock.unlock()
		# deferred, never emitted from this thread: a signal handler repaints UI, and
		# touching a Control from a worker is a crash waiting for the wrong frame
		if not result.is_empty():
			call_deferred("emit_signal", "spectral_key_ready", path,
				int(result["pc"]), bool(result["minor"]))
	_spectral_lock.lock()
	_spectral_running = false
	_spectral_lock.unlock()

## metadata() already reads the file's own tag; that one probe is cheap (it rides the
## ffprobe pass every track gets anyway) and is the gate that keeps this from ever
## running on a tagged file. ffmpeg does the decode, downmix and resample -- the same
## external dependency the FLAC transcode already relies on, rather than a hand-rolled
## resampler in GDScript on top of an already CPU-heavy FFT.
func _run_spectral_key(path: String) -> Dictionary:
	if int((metadata(path).get("key", {}) as Dictionary).get("pc", -1)) >= 0:
		return {}   # tagged -- nothing for a spectral guess to add
	var tmp := ProjectSettings.globalize_path("user://spectral_%d_%d.raw" % [
		hash(path), OS.get_thread_caller_id()])
	var args := ["-v", "error", "-nostdin", "-i", path, "-ac", "1", "-ar", str(SpectralKey.SAMPLE_RATE),
		"-f", "s16le", "-y", tmp]
	var ok := run_process("ffmpeg", args, is_shut_down) == 0
	var result := {}
	if ok:
		result = SpectralKey.estimate(tmp)
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	return result

## One line for the status ticker: what the file is, and what the engine actually plays.
func ticker_line(path: String) -> String:
	var m := metadata(path)
	var who: String = "%s - %s" % [m["artist"], m["title"]] if m["artist"] != "" else m["title"]
	# what the mixer is actually handed: every decoder here delivers float, except the
	# AudioStreamWAV fallback an unbuilt extension leaves WAV on. See FIDELITY at the top.
	var engine_fmt := "16 BIT" if path.get_extension().to_lower() == "wav" \
		and not ClassDB.class_exists("SsWavStream") else "FLOAT"
	# the key rides along with the rest of the ffprobe result, so it is already there
	# on the first frame of the track -- there is nothing to wait for and nothing to poll
	var k: Dictionary = m.get("key", {})
	var key_txt: String = "" if str(k.get("text", "")).is_empty() else "KEY %s // " % k["text"]
	return "// %s // %s %d HZ %d BIT %s // %sENGINE %d HZ %s // MIX %d HZ " % [
		who.to_upper(), m["codec"], m["sample_rate"], m["bits"],
		"STEREO" if m["channels"] >= 2 else "MONO", key_txt,
		m["sample_rate"], engine_fmt, int(AudioServer.get_mix_rate())]
