class_name AudioEngine
extends Node
## Decoding, caching, metadata and queue management for the media player.
##
## FIDELITY CEILING -- read this before trusting the word "lossless" anywhere below.
## Godot 4.7 has no FLAC decoder (AudioStreamFLAC does not exist; AudioStream recognizes
## only mp3str / oggvorbisstr / sample). AudioStreamWAV supports 8- and 16-bit PCM only.
## So a 24-bit source is ALWAYS truncated to 16-bit somewhere in this pipeline. There is
## no bit-transparent path in this engine version, and no arrangement of these functions
## creates one. What IS preserved:
##   - sample rate, exactly, at any rate (44.1 / 48 / 96 / 192 kHz all verified loading)
##   - channel count
##   - no lossy re-encode: FLAC is decoded straight to PCM, never through mp3/ogg
## Set audio/driver/mix_rate to match your material or the AudioServer resamples on output.

signal track_ready(path: String, stream: AudioStream, meta: Dictionary)
signal track_failed(path: String, reason: String)
signal queue_changed()

enum Repeat { OFF, ALL, ONE }

const CHUNK := 1 << 20  # 1 MiB streaming copy, so a 90 MB wav never sits in RAM twice

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
var _token := 0

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
## fold, not an approximation. surround stays 0 for the same reason equalizer.gd
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
## 90 MB wav) happens on a worker; only the newest request is honoured.
func request(i: int) -> void:
	if i < 0 or i >= queue.size():
		return
	index = i
	_token += 1
	var token := _token
	var path := queue[i]
	if path == _next_path and _next_stream:  # preloaded by the previous track
		var s := _next_stream
		_next_stream = null
		_next_path = ""
		_deliver(token, path, s)
		return
	WorkerThreadPool.add_task(func() -> void:
		# The pool QUEUES tasks, so by the time this one starts several more skips may have
		# landed. Testing the token here rather than only in _deliver is what stops a
		# superseded track decoding anyway -- which for a FLAC means a full ffmpeg spawn and
		# 35-160 MB of PCM materialised for a track nobody is going to hear.
		if token != _token:
			return
		var s := decode(path)
		var m := metadata(path)
		_deliver.bind(token, path, s, m).call_deferred())

func _deliver(token: int, path: String, s: AudioStream, m: Dictionary = {}) -> void:
	if token != _token:
		return  # superseded by a newer request; drop it rather than hijack playback
	if not s:
		track_failed.emit(path, "decode failed")
		return
	track_ready.emit(path, s, m if not m.is_empty() else metadata(path))
	_preload(next_index())

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
func _preload(i: int) -> void:
	if i < 0 or i >= queue.size() or queue[i] == _next_path:
		return
	var path := queue[i]
	_next_path = path
	# Whatever was warmed for the PREVIOUS next-track is dead weight the moment the queue
	# points somewhere else -- 35-160 MB of decoded PCM for a track nothing is heading to.
	# Dropped here, so at most one preloaded stream is ever resident.
	_next_stream = null
	var token := _token
	WorkerThreadPool.add_task(func() -> void:
		if token != _token:
			return   # queue moved on while this sat in the pool: no decode, no ffmpeg
		var s := decode(path)
		metadata(path)   # so _deliver never has to probe on the main thread
		(func() -> void:
			# re-tested on the main thread, which is where _token and _next_path settle
			if token == _token and _next_path == path:
				_next_stream = s).call_deferred())

# --- decoding --------------------------------------------------------------
func decode(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"mp3": return AudioStreamMP3.load_from_file(path)
		"ogg": return AudioStreamOggVorbis.load_from_file(path)
		"wav": return AudioStreamWAV.load_from_file(path)
		"flac":
			var c := cache_path(path)
			return AudioStreamWAV.load_from_file(c) if _to_pcm(path, c) else null
	return null

func cache_path(src: String) -> String:
	return "user://pcm_%d.wav" % hash(src)

## Deletes cached PCM belonging to tracks that are no longer in the library. The cache is
## keyed by a hash of the ABSOLUTE source path, so renaming or moving a FLAC orphans its
## entry permanently and nothing would ever reclaim it -- and these files run 30-120 MB
## each. Called after every library scan; returns how many files were removed.
##
## Anything under user:// starting with "pcm_" is in scope, which also sweeps up the
## `.wav.pcm` and `.wav.part` temporaries a transcode killed part-way through leaves
## behind. A track mid-decode is safe: it is in the library, so its entry is kept.
func prune_cache(active: Array[String]) -> int:
	var keep := {}
	for p in active:
		if p.get_extension().to_lower() == "flac":
			keep[cache_path(p).get_file()] = true
	var dir := DirAccess.open("user://")
	if not dir:
		return 0
	var removed := 0
	for f in dir.get_files():
		if not f.begins_with("pcm_"):
			continue
		# "pcm_123.wav.part" and "pcm_123.wav.pcm" both belong to "pcm_123.wav"
		var owner := f
		var cut := f.find(".wav")
		if cut >= 0:
			owner = f.substr(0, cut + 4)
		if keep.has(owner):
			continue
		if dir.remove(f) == OK:
			removed += 1
	return removed

## FLAC -> PCM at the SOURCE sample rate.
##
## We deliberately do NOT let ffmpeg mux the wav. Above 48 kHz its wav muxer emits
## WAVE_FORMAT_EXTENSIBLE (fmt tag 0xFFFE, 40-byte fmt chunk) and Godot's parser rejects
## that outright -- load_from_file returns null with no error, which reads as "the track
## just will not switch". Piping raw s16le and writing a canonical 16-byte PCM header
## ourselves keeps the native rate AND loads: verified at 44.1 / 48 / 96 / 192 kHz.
## (The older workaround, -ar 44100, also loaded but threw away the hi-res rate.)
func _to_pcm(src: String, dst: String) -> bool:
	# A cache hit has to be a USABLE file, not merely a present one. A transcode killed
	# between creating the file and filling it leaves a zero-byte or header-only wav,
	# and the old existence check accepted it forever -- load_from_file then returned
	# null on every play with no error. Anything at or under a bare 44-byte RIFF header
	# holds no audio, so it is treated as a miss and re-transcoded.
	if FileAccess.file_exists(dst):
		var f := FileAccess.open(dst, FileAccess.READ)
		var usable := f != null and f.get_length() > 44
		if f:
			f.close()
		if usable:
			return true
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dst))
	var m := metadata(src)
	var rate: int = m.get("sample_rate", 44100)
	var ch: int = clampi(m.get("channels", 2), 1, 2)  # AudioStreamWAV is mono or stereo only
	# Thread id in the temp names, exactly as metadata() does for its probe JSON and for
	# exactly the same reason: two workers can legitimately be transcoding the SAME file at
	# once. The preload for track N+1 is still running when the user clicks track N+1, and
	# request() only takes the warmed stream if it has already ARRIVED -- otherwise it
	# starts a second decode of the same path. With names derived from the path alone the
	# two runs wrote over each other's .pcm and .part. Measured on a cold cache: one round
	# produced a file 176 bytes short that still LOADED -- a silently truncated track,
	# cached forever, because the >44-byte hit check accepts it -- and the next round
	# produced a zero-byte one.
	var tag := str(OS.get_thread_caller_id())
	var raw_rel := "%s.%s.pcm" % [dst, tag]
	var part_rel := "%s.%s.part" % [dst, tag]
	var raw := ProjectSettings.globalize_path(raw_rel)
	var out: Array = []
	# s16le because AudioStreamWAV has no 24-bit format. This is the truncation point.
	var args := ["-y", "-v", "error", "-i", src, "-map", "0:a:0",
		"-c:a", "pcm_s16le", "-ac", str(ch), "-f", "s16le", raw]
	if OS.execute("ffmpeg", args, out, true) != 0:
		push_warning("ffmpeg failed on %s: %s" % [src.get_file(), "".join(out)])
		DirAccess.remove_absolute(raw)
		return false
	var ok := _wrap_pcm(raw_rel, part_rel, rate, ch)
	DirAccess.remove_absolute(raw)
	if not ok:
		return false
	# rename last, so an interrupted run never leaves a half-written file in the cache
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(part_rel),
			ProjectSettings.globalize_path(dst)) == OK:
		return true
	# Lost the race: another worker finished the same file first. Its result is exactly as
	# good as ours, so drop ours and use it rather than reporting a decode failure.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(part_rel))
	return FileAccess.file_exists(dst)

func _wrap_pcm(raw: String, dst: String, rate: int, ch: int) -> bool:
	var src := FileAccess.open(raw, FileAccess.READ)
	if not src:
		return false
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if not f:
		src.close()
		return false
	f.store_buffer(wav_header(src.get_length(), rate, ch))
	while not src.eof_reached():
		f.store_buffer(src.get_buffer(CHUNK))
	f.close()
	src.close()
	return true

## Canonical 44-byte RIFF/WAVE header: 16-byte fmt chunk, wFormatTag = 1 (PCM).
## Godot accepts this at any sample rate; it is the extensible variant it refuses.
static func wav_header(data_bytes: int, rate: int, ch: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array("RIFF".to_ascii_buffer())
	b.append_array(_i32(36 + data_bytes))
	b.append_array("WAVEfmt ".to_ascii_buffer())
	b.append_array(_i32(16))          # fmt chunk size: 16, never 40
	b.append_array(_i16(1))           # WAVE_FORMAT_PCM
	b.append_array(_i16(ch))
	b.append_array(_i32(rate))
	b.append_array(_i32(rate * ch * 2))  # byte rate
	b.append_array(_i16(ch * 2))         # block align
	b.append_array(_i16(16))             # bits per sample
	b.append_array("data".to_ascii_buffer())
	b.append_array(_i32(data_bytes))
	return b

static func _i32(v: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(4)
	a.encode_s32(0, v)
	return a

static func _i16(v: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(2)
	a.encode_s16(0, v)
	return a

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
	return d if d else {}

func metadata(path: String) -> Dictionary:
	_meta_lock.lock()
	var cached: Variant = _meta.get(path)
	_meta_lock.unlock()
	if cached != null:
		return cached
	var d := {
		"title": path.get_file().get_basename(), "artist": "", "album": "",
		"sample_rate": 44100, "channels": 2, "bits": 16, "codec": path.get_extension().to_upper(),
		"key": {"text": "", "pc": -1, "minor": false}, "duration": 0.0,
	}
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
	var probed := OS.execute("ffprobe", args, [], true) == 0
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
	var winner: Variant = _meta.get(path)
	if winner == null:
		_meta[path] = d
		winner = d
	_meta_lock.unlock()
	return winner

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
## AudioStreamPlayer cannot play backwards -- pitch_scale has no negative half -- so a
## reversed take is a real file: ffmpeg -af areverse into the same user:// cache the
## FLAC transcode uses, keyed by path hash so a track is only ever reversed once.
##
## Forced to 44.1 kHz 16-bit PCM on the way out for the same reason the FLAC path is:
## above 48 kHz ffmpeg writes WAVE_FORMAT_EXTENSIBLE, which Godot's wav parser rejects
## by returning null with no error at all.
signal reversed_ready(path: String, stream: AudioStream)

func request_reversed(path: String) -> void:
	if path.is_empty() or _shutdown:
		return
	_reverse_tasks.append(WorkerThreadPool.add_task(func() -> void:
		if _shutdown:
			return
		var out := ProjectSettings.globalize_path("user://rev_%d.wav" % hash(path))
		if not FileAccess.file_exists(out):
			var args := ["-v", "error", "-y", "-i", path, "-af", "areverse",
				"-ar", "44100", "-c:a", "pcm_s16le", out]
			if OS.execute("ffmpeg", args, [], true) != 0:
				push_warning("could not reverse %s" % path.get_file())
				return
		var stream := AudioStreamWAV.load_from_file(out)
		if stream:
			call_deferred("emit_signal", "reversed_ready", path, stream)))

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
var _spectral_task := -1
var _reverse_tasks: Array[int] = []       # main thread only: request_reversed is UI-side

## Set by shutdown(). Every worker checks it between items, so a queue with hundreds of
## tracks left in it abandons them immediately instead of holding the process open.
var _shutdown := false

## Called before the scene tree frees this node. Without it, a worker can be midway
## through writing _spectral_cache under _spectral_lock while the main thread tears the
## engine down -- the lock outlives the object that owns it and the process wedges on
## exit instead of closing. Waits only for what is genuinely in flight: _shutdown makes
## the drain loop drop everything still queued rather than finish the backlog.
func shutdown() -> void:
	_shutdown = true
	if _spectral_task != -1:
		WorkerThreadPool.wait_for_task_completion(_spectral_task)
		_spectral_task = -1
	for id in _reverse_tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	_reverse_tasks.clear()

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
		_spectral_task = WorkerThreadPool.add_task(_drain_spectral_queue)

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
	var args := ["-v", "error", "-i", path, "-ac", "1", "-ar", str(SpectralKey.SAMPLE_RATE),
		"-f", "s16le", "-y", tmp]
	var ok := OS.execute("ffmpeg", args, [], true) == 0
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
	var served := 16  # AudioStreamWAV ceiling; see FIDELITY CEILING at the top
	# the key rides along with the rest of the ffprobe result, so it is already there
	# on the first frame of the track -- there is nothing to wait for and nothing to poll
	var k: Dictionary = m.get("key", {})
	var key_txt: String = "" if str(k.get("text", "")).is_empty() else "KEY %s // " % k["text"]
	return "// %s // %s %d HZ %d BIT %s // %sENGINE %d HZ %d BIT // MIX %d HZ " % [
		who.to_upper(), m["codec"], m["sample_rate"], m["bits"],
		"STEREO" if m["channels"] >= 2 else "MONO", key_txt,
		m["sample_rate"], served, int(AudioServer.get_mix_rate())]
