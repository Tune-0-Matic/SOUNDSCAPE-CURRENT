extends SceneTree
## Native FLAC through libsoundscape_dsp (SsFlacStream, dr_flac). Exit codes match
## test_ss_effect.gd: 0 PASS, 1 FAIL, 2 SKIPPED when the extension is not built on this machine.
##   1. a 24-bit 96 kHz stereo FLAC (encoded by ffmpeg from an asymmetric two-tone signal)
##      loads and reports its real format
##   2. decoded samples are BIT-IDENTICAL to ffmpeg's own float decode of the same file --
##      exact float equality, both channels, no tolerance
##   3. through AudioEngine.decode: an SsFlacStream comes back and no pcm_* transcode appears
##   4. on a real AudioStreamPlayer (muted bus): it sounds, the position advances, a seek
##      lands, and finished fires at the end of the file
## Files live in user://flac_test and are removed.
##   godot --headless --path . --script res://test_flac_native.gd

const DIR := "user://flac_test"
const RATE := 96000
const SECS := 3.0

func _initialize() -> void:
	if not ClassDB.class_exists("SsFlacStream"):
		print("SKIPPED: SsFlacStream is not registered -- libsoundscape_dsp is not built here.")
		print("RESULT SKIPPED")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var base := ProjectSettings.globalize_path(DIR)
	var flac := base.path_join("tone_24_96.flac")
	var raw := base.path_join("reference.f32")
	var ok := true

	var gen := OS.execute("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i",
		"aevalsrc=0.5*sin(2*PI*441*t)|0.3*sin(2*PI*660*t+1):s=%d:d=%.1f" % [RATE, SECS],
		"-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", flac], [], true)
	var ref := OS.execute("ffmpeg", ["-v", "error", "-y", "-i", flac, "-f", "f32le", "-c:a", "pcm_f32le", raw], [], true)
	if gen != 0 or ref != 0 or not FileAccess.file_exists(flac):
		print("could not build the test FLAC with ffmpeg (encode %d, reference %d)" % [gen, ref])
		print("RESULT FAIL")
		quit(1)
		return

	# 1. format
	var stream: AudioStream = _load(flac)
	var fmt: bool = stream != null and stream.call("get_sample_rate") == RATE and stream.call("get_channels") == 2 \
		and stream.call("get_bits_per_sample") == 24 and absf(stream.get_length() - SECS) < 0.01
	ok = ok and fmt
	print("1. loads as %s Hz / %s ch / %s bit, %.3f s: %s" % [
		stream.call("get_sample_rate") if stream else -1, stream.call("get_channels") if stream else -1,
		stream.call("get_bits_per_sample") if stream else -1, stream.get_length() if stream else -1.0, fmt])
	if not stream:
		print("RESULT FAIL")
		quit(1)
		return

	# 2. bit-identical to ffmpeg's float decode
	var reference := FileAccess.get_file_as_bytes(raw).to_float32_array()
	var frames := int(RATE * SECS)
	var mine: PackedFloat32Array = stream.call("decode_frames", 0, frames)
	var n := mini(mine.size(), reference.size())
	var mismatches := 0
	var worst := 0.0
	for i in n:
		if mine[i] != reference[i]:
			mismatches += 1
			worst = maxf(worst, absf(mine[i] - reference[i]))
	var peak_l := 0.0
	var peak_r := 0.0
	for i in range(0, n, 2):
		peak_l = maxf(peak_l, absf(mine[i]))
		peak_r = maxf(peak_r, absf(mine[i + 1]))
	var identical: bool = n == frames * 2 and reference.size() == frames * 2 and mismatches == 0 \
		and absf(peak_l - 0.5) < 0.01 and absf(peak_r - 0.3) < 0.01
	ok = ok and identical
	print("2. %d samples compared to ffmpeg: %d mismatches (worst %.9f), L peak %.4f / R peak %.4f: %s" % [
		n, mismatches, worst, peak_l, peak_r, identical])

	# 3. through the engine, with no transcode written
	var before := _pcm_files()
	var engine := AudioEngine.new()
	var decoded := engine.decode(flac)
	var native: bool = decoded != null and decoded.get_class() == "SsFlacStream" and _pcm_files() == before
	ok = ok and native
	print("3. AudioEngine.decode returns %s, pcm_* files %d -> %d: %s" % [
		decoded.get_class() if decoded else "null", before, _pcm_files(), native])
	engine.free()

	# 4. real playback
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "FlacVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus, capture)
	var player := AudioStreamPlayer.new()
	player.bus = "FlacVerify"
	player.stream = stream
	root.add_child(player)
	await process_frame
	var finished := [false]
	player.finished.connect(func() -> void: finished[0] = true)
	player.play()
	await create_timer(0.6).timeout
	var got := capture.get_buffer(capture.get_frames_available())
	var energy := 0.0
	for fr in got:
		energy = maxf(energy, absf(fr.x))
	var moving := player.get_playback_position() > 0.3
	player.seek(2.2)
	await create_timer(0.2).timeout
	var landed := player.get_playback_position() >= 2.2 and player.get_playback_position() < 2.8
	var guard := 0
	while not finished[0] and guard < 400:
		await process_frame
		guard += 1
	var plays: bool = energy > 0.2 and moving and landed and finished[0]
	ok = ok and plays
	print("4. sounds (peak %.3f) %s, position advances %s, seek lands %s, finished fires %s: %s" % [
		energy, energy > 0.2, moving, landed, finished[0], plays])
	player.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)

	DirAccess.remove_absolute(flac)
	DirAccess.remove_absolute(raw)
	DirAccess.remove_absolute(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _load(path: String) -> AudioStream:
	var s: AudioStream = ClassDB.instantiate("SsFlacStream")
	return s if int(s.call("load", path)) == OK else null

func _pcm_files() -> int:
	var n := 0
	for f in DirAccess.get_files_at("user://"):
		if f.begins_with("pcm_"):
			n += 1
	return n
