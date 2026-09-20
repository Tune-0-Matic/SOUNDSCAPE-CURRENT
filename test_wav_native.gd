extends SceneTree
## Native WAV through libsoundscape_dsp (SsWavStream, dr_wav), and REV rendered through the native
## decoders. Exit codes match test_flac_native.gd: 0 PASS, 1 FAIL, 2 SKIPPED without the extension.
##   1. three WAVs -- 24-bit/96 kHz and 32-bit float/44.1 kHz, which Godot's own loader refuses
##      (EXTENSIBLE) or cuts to 16-bit, plus a plain 16-bit/48 kHz baseline -- load with their real
##      rate, channel count, bit depth and length
##   2. every sample of all three BIT-IDENTICAL to ffmpeg's own float decode of the same file
##   3. AudioEngine.decode hands back an SsWavStream for each
##   4. the 24-bit file on a real AudioStreamPlayer: sounds, advances, seeks, finishes
##   5. REV of the 24-bit/96 kHz file comes back at 96 kHz and 24 bits, the same length and
##      sample-exact backwards; asking again is a cache hit; the same path rewritten with new
##      content renders afresh instead of serving the old take (audit C5)
##   6. the native resampler on every case, 192 kHz included: rendered to 96 kHz through the real
##      _mix path, exactly 96000 frames per second of source, the 441 Hz / 660 Hz tones within
##      0.001 dB of their level, and THD+N below -110 dB -- or below -85 dB for the 16-bit file,
##      whose own quantisation noise sits near -92 dB
##   7. the TBS DSP AUTOPSY describes each stream from what the stream itself reports: codec, native
##      rate / depth and channels; the resampler with its exact phase step (passthrough at the mix
##      rate); Godot's cubic for a stream Godot decodes; a render named as a render; and the master
##      line's LISTENING MODE and TPDF dither for every recording format
##   8. the scrub bar's overview is built in stereo and folded per channel, the raw PCM it came
##      from is deleted, and the folded result is what gets cached and re-read
## Files live in user://wav_test; the rev_ renders this test made are removed.
##   godot --headless --path . --script res://test_wav_native.gd

const DIR := "user://wav_test"
const SECS := 2.0
const CASES := [[96000, "pcm_s24le", 24], [44100, "pcm_f32le", 32], [48000, "pcm_s16le", 16], [192000, "pcm_s24le", 24]]

func _gen(path: String, rate: int, codec: String, secs: float, hz: int) -> bool:
	return OS.execute("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i",
		"aevalsrc=0.5*sin(2*PI*%d*t)|0.3*sin(2*PI*660*t+1):s=%d:d=%.2f" % [hz, rate, secs],
		"-c:a", codec, path], [], true) == 0

func _rev_files() -> Dictionary:
	var out := {}
	for f in DirAccess.get_files_at("user://"):
		if f.begins_with("rev_"):
			out[f] = FileAccess.get_modified_time("user://" + f)
	return out

## Least-squares amplitude of `hz` on channel `ch` of interleaved stereo at `rate`, over a window of
## whole cycles, and the THD+N (dB) of what is left once that tone and DC are removed.
static func _fit(x: PackedFloat32Array, ch: int, hz: float, rate: int, from: int, n: int) -> Array:
	var ss := 0.0
	var sc := 0.0
	var sd := 0.0
	for i in n:
		var v: float = x[(from + i) * 2 + ch]
		var ph := TAU * hz * float(from + i) / rate
		ss += v * sin(ph)
		sc += v * cos(ph)
		sd += v
	var a := 2.0 * ss / n
	var b := 2.0 * sc / n
	var c := sd / n
	var res := 0.0
	for i in n:
		var ph := TAU * hz * float(from + i) / rate
		var e: float = x[(from + i) * 2 + ch] - a * sin(ph) - b * cos(ph) - c
		res += e * e
	var amp := sqrt(a * a + b * b)
	return [amp, 10.0 * log(res / n / maxf(amp * amp * 0.5, 1e-30)) / log(10.0)]

func _until(cond: Callable, secs: float) -> void:
	var t := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t < int(secs * 1000.0):
		await process_frame

func _initialize() -> void:
	if not ClassDB.class_exists("SsWavStream"):
		print("SKIPPED: SsWavStream is not registered -- libsoundscape_dsp is not built here.")
		print("RESULT SKIPPED")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var base := ProjectSettings.globalize_path(DIR)
	var ok := true
	var engine := AudioEngine.new()
	var streams: Array[AudioStream] = []

	# 1-3. formats, samples, routing
	for c in CASES:
		var rate: int = c[0]
		var wav := base.path_join("tone_%s_%d.wav" % [c[1], rate])
		var raw := wav + ".f32"
		var made := _gen(wav, rate, c[1], SECS, 441) \
			and OS.execute("ffmpeg", ["-v", "error", "-y", "-i", wav, "-f", "f32le", "-c:a", "pcm_f32le", raw], [], true) == 0
		var s: AudioStream = ClassDB.instantiate("SsWavStream")
		var loaded: bool = made and int(s.call("load", wav)) == OK
		var fmt: bool = loaded and s.call("get_sample_rate") == rate and s.call("get_channels") == 2 \
			and s.call("get_bits_per_sample") == c[2] and absf(s.get_length() - SECS) < 0.01
		var reference := FileAccess.get_file_as_bytes(raw).to_float32_array()
		var mine: PackedFloat32Array = s.call("decode_frames", 0, int(rate * SECS)) if loaded else PackedFloat32Array()
		var mismatches := 0
		for i in mini(mine.size(), reference.size()):
			if mine[i] != reference[i]:
				mismatches += 1
		var identical: bool = reference.size() == int(rate * SECS) * 2 and mine.size() == reference.size() and mismatches == 0
		var decoded := engine.decode(wav)
		var routed: bool = decoded != null and decoded.get_class() == "SsWavStream"
		var good := fmt and identical and routed
		ok = ok and good
		print("1-3. %s %d Hz: loads as %s Hz / %s ch / %s bit, %.3f s %s; %d samples vs ffmpeg, %d mismatches %s; decode -> %s: %s" % [
			c[1], rate, s.call("get_sample_rate"), s.call("get_channels"), s.call("get_bits_per_sample"), s.get_length(), fmt,
			reference.size(), mismatches, identical, decoded.get_class() if decoded else "null", good])
		streams.append(s)
		DirAccess.remove_absolute(raw)

	# 4. real playback of the 24-bit file
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "WavVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus, capture)
	var player := AudioStreamPlayer.new()
	player.bus = "WavVerify"
	player.stream = streams[0]
	root.add_child(player)
	await process_frame
	var finished := [false]
	player.finished.connect(func() -> void: finished[0] = true)
	player.play()
	await create_timer(0.5).timeout
	var energy := 0.0
	for fr in capture.get_buffer(capture.get_frames_available()):
		energy = maxf(energy, absf(fr.x))
	var moving := player.get_playback_position() > 0.25
	player.seek(1.2)
	await create_timer(0.2).timeout
	var landed := player.get_playback_position() >= 1.2 and player.get_playback_position() < 1.8
	await _until(func() -> bool: return finished[0], 6.0)
	var plays: bool = energy > 0.2 and moving and landed and finished[0]
	ok = ok and plays
	print("4. 24-bit WAV sounds (peak %.3f) %s, advances %s, seek lands %s, finished fires %s: %s" % [
		energy, energy > 0.2, moving, landed, finished[0], plays])
	player.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)

	# 5. REV on the native decoders, keyed by content
	var p24 := base.path_join("tone_pcm_s24le_96000.wav")
	var before := _rev_files()
	var got: Array = [null]
	engine.reversed_ready.connect(func(path: String, st: AudioStream) -> void:
		if path == p24:
			got[0] = st)
	engine.request_reversed(p24)
	await _until(func() -> bool: return got[0] != null, 30.0)
	var rev: AudioStream = got[0]
	var n := int(96000 * SECS)
	var exact := false
	if rev:
		var head: PackedFloat32Array = rev.call("decode_frames", 0, 64)
		var tail: PackedFloat32Array = streams[0].call("decode_frames", n - 64, 64)
		exact = head.size() == 128 and tail.size() == 128
		for k in 64:
			exact = exact and head[k * 2] == tail[(63 - k) * 2] and head[k * 2 + 1] == tail[(63 - k) * 2 + 1]
	var rev_ok: bool = rev != null and rev.get_class() == "SsFlacStream" and rev.call("get_sample_rate") == 96000 \
		and rev.call("get_bits_per_sample") == 24 and rev.call("get_frame_count") == n and exact
	var renders := _rev_files()
	await create_timer(1.1).timeout   # mtimes are whole seconds: a re-render would now show
	got[0] = null
	engine.request_reversed(p24)
	await _until(func() -> bool: return got[0] != null, 30.0)
	var hit: bool = got[0] != null and _rev_files() == renders
	_gen(p24, 96000, "pcm_s24le", 1.0, 523)   # same path, new content, new length
	got[0] = null
	engine.request_reversed(p24)
	await _until(func() -> bool: return got[0] != null, 30.0)
	var fresh: bool = got[0] != null and absf((got[0] as AudioStream).get_length() - 1.0) < 0.01
	var rev_all := rev_ok and hit and fresh
	ok = ok and rev_all
	print("5. REV: %s, %s Hz / %s bit, %s frames (want %d), sample-exact backwards %s; second request a cache hit %s; rewritten file renders afresh (%.2f s) %s: %s" % [
		rev.get_class() if rev else "null", rev.call("get_sample_rate") if rev else -1, rev.call("get_bits_per_sample") if rev else -1,
		rev.call("get_frame_count") if rev else -1, n, exact, hit,
		(got[0] as AudioStream).get_length() if got[0] else -1.0, fresh, rev_all])

	# 6. the resampler on every case
	var rs_all := true
	for k in CASES.size():
		var s: AudioStream = streams[k]
		var bits: int = CASES[k][2]
		var out: PackedFloat32Array = s.call("render", 96000, 0.0, 96000 * 3)
		var l := _fit(out, 0, 441.0, 96000, 48000, 96000)
		var r := _fit(out, 1, 660.0, 96000, 48000, 96000)
		var floor_db := -85.0 if bits == 16 else -110.0
		var db_l := 20.0 * log(l[0] / 0.5) / log(10.0)
		var db_r := 20.0 * log(r[0] / 0.3) / log(10.0)
		var good: bool = out.size() == int(96000 * SECS) * 2 and absf(db_l) < 0.001 and absf(db_r) < 0.001 \
			and l[1] < floor_db and r[1] < floor_db
		rs_all = rs_all and good
		print("6. %s %d Hz -> 96 kHz: %d frames (want %d); 441 Hz %+.5f dB THD+N %.1f dB | 660 Hz %+.5f dB THD+N %.1f dB (bound %.0f): %s" % [
			CASES[k][1], CASES[k][0], out.size() / 2, int(96000 * SECS), db_l, l[1], db_r, r[1], floor_db, good])
	ok = ok and rs_all

	# 7. the DSP AUTOPSY text, at this project's 96 kHz mix
	var player_gd: GDScript = load("res://player.gd")
	var mix := int(AudioServer.get_mix_rate())
	var want_rs := {96000: ["NONE: PASSTHROUGH", "PHASE 1:1 | BIT-EXACT COPY"],
		44100: ["C++ WINDOWED-SINC (SincResampler)", "PHASE 320:147 | THD+N -124 DB (TESTED)"],
		48000: ["C++ WINDOWED-SINC (SincResampler)", "PHASE 2:1 | THD+N -124 DB (TESTED)"],
		192000: ["C++ WINDOWED-SINC (SincResampler)", "PHASE 1:2 | THD+N -124 DB (TESTED)"]}
	var autopsy := mix == 96000
	for k in CASES.size():
		var src: String = player_gd.autopsy_source(streams[k], {}, "tone.wav")
		var rs: Array = player_gd.autopsy_resampler(streams[k], {}, mix)
		var want_src := "WAV | %.1f KHZ / %d-BIT | STEREO" % [CASES[k][0] / 1000.0, CASES[k][2]]
		var good: bool = src == want_src and rs == want_rs[CASES[k][0]]
		autopsy = autopsy and good
		print("7. %s | %s: %s" % [src, " / ".join(rs), good])
	var godot_wav := AudioStreamWAV.new()
	godot_wav.mix_rate = 44100
	godot_wav.format = AudioStreamWAV.FORMAT_16_BITS
	var others := [
		[player_gd.autopsy_source(godot_wav, {}, "a.wav"), "WAV (GODOT) | 44.1 KHZ / 16-BIT | MONO"],
		[" / ".join(player_gd.autopsy_resampler(godot_wav, {}, mix)), "GODOT 4-POINT CUBIC (16-BIT STEP) / RATIO 320:147 | THD+N -26 DB @ 10 KHZ (TESTED)"],
		[player_gd.autopsy_source(AudioStreamMP3.new(), {"sample_rate": 48000, "channels": 2}, "b.mp3"), "MP3 | 48.0 KHZ / LOSSY | STEREO"],
		[player_gd.autopsy_source(streams[0], {}, "clip.mp4"), "WAV (RENDER OF MP4) | 96.0 KHZ / 24-BIT | STEREO"],
		[player_gd.autopsy_source(null, {}), "-- (NOTHING LOADED)"],
		[" / ".join(player_gd.autopsy_master(96000, 0, 0.0, 0, 0)), "96000 HZ / 32-BIT FLOAT | AUDIOPHILE (DIRECT) / TPDF DITHER: ON (REC WAV 16-BIT)"],
		[" / ".join(player_gd.autopsy_master(96000, 1, 6.29, 1, 2)), "96000 HZ / 32-BIT FLOAT | CASUAL (SMOOTH) +6.3 MS / TPDF DITHER: ON (REC FLAC 24-BIT)"],
		[" / ".join(player_gd.autopsy_master(96000, 0, 0.0, 0, 2)), "96000 HZ / 32-BIT FLOAT | AUDIOPHILE (DIRECT) / TPDF DITHER: OFF (REC WAV 32-BIT: NONE NEEDED)"],
	]
	for pair in others:
		var good: bool = pair[0] == pair[1]
		autopsy = autopsy and good
		print("7. %s: %s%s" % [pair[0], good, "" if good else "  (want %s)" % pair[1]])
	ok = ok and autopsy

	# 8. the scrub bar's overview: stereo, folded per channel, with the raw PCM cleaned up and the
	# 32 KB result cached. The 16-bit case carries 441 Hz at 0.5 on the left and 660 Hz at 0.3 on
	# the right, so a fold that averaged the channels -- or downmixed to mono, as this used to --
	# could not report two different peaks.
	var wav48 := base.path_join("tone_pcm_s16le_48000.wav")
	var wave := AudioEngine.read_waveform(wav48, DIR)
	var shaped: bool = wave.size() == AudioEngine.WAVE_BUCKETS * AudioEngine.WAVE_STRIDE
	var peaks := [1.0, -1.0, 1.0, -1.0]   # left min, left max, right min, right max
	if shaped:
		for b in AudioEngine.WAVE_BUCKETS:
			var at := b * AudioEngine.WAVE_STRIDE
			peaks[0] = minf(peaks[0], wave[at])
			peaks[1] = maxf(peaks[1], wave[at + 1])
			peaks[2] = minf(peaks[2], wave[at + 2])
			peaks[3] = maxf(peaks[3], wave[at + 3])
	var split: bool = shaped and absf(float(peaks[0]) + 0.5) < 0.02 and absf(float(peaks[1]) - 0.5) < 0.02 \
		and absf(float(peaks[2]) + 0.3) < 0.02 and absf(float(peaks[3]) - 0.3) < 0.02
	var cached := ""
	var raw_left := false
	for f in DirAccess.get_files_at(DIR):
		if f.begins_with("wave%d_" % AudioEngine.WAVE_BUCKETS):
			cached = f
		raw_left = raw_left or f.begins_with("rawwave_")
	var kept: bool = not cached.is_empty() and not raw_left \
		and FileAccess.get_file_as_bytes(base.path_join(cached)).size() == wave.size() * 4
	var again := AudioEngine.read_waveform(wav48, DIR)   # served from that file, not rebuilt
	var cache_hit: bool = again == wave
	ok = ok and split and kept and cache_hit
	print("8. overview %d buckets x %d: left %.2f..%.2f, right %.2f..%.2f (want +/-0.50 and +/-0.30) %s; cached as %s with no raw PCM left %s; second read is a cache hit %s" % [
		wave.size() / AudioEngine.WAVE_STRIDE, AudioEngine.WAVE_STRIDE, peaks[0], peaks[1], peaks[2], peaks[3],
		split, cached, kept, cache_hit])

	engine.shutdown()
	engine.free()
	for f in _rev_files():
		if not before.has(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + f))
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(base.path_join(f))
	DirAccess.remove_absolute(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
