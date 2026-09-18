extends SceneTree
## Video TEST against the real music video on this machine -- a local fixture, not a portable test:
##   C:\Users\gavin\Music\SOUNDSCAPE\MP4 Test\Caramella Girls - Caramelldansen HD Version (Swedish Original).mp4
## Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED when that file or libsoundscape_dsp is not here.
##   1. sound: audio_engine.gd renders it to a 24-bit SsFlacStream at the MP4's own sample rate
##      and channel count (read back with ffprobe), for the full length, and its first 10 s equal
##      ffmpeg's float decode of the AAC to within two 24-bit steps
##   2. picture: request_video delivers a VIDEO_W-wide Theora proxy running the length of the video
##   3. both colour modes: 2 s following the sound in ORIGINAL, then 2 s in PALETTE on a skin ramp
##      with a kick, each mode reaching the shader, the picture advancing with no re-seek. The picture
##      is re-synced onto the sound as PALETTE starts, so each window measures its own 2 s: headless,
##      the Dummy audio driver's clock runs slow under CPU load, and PALETTE used to inherit ORIGINAL's
##      lag on top of its own (0.120-0.123 s against the 0.12 s bound, with either DSP build)
## A headless run never compiles the shader, so the drawing itself needs a windowed run.
## Renders go to user://video_fixture_test and are removed.
##   godot --headless --path . --script res://test_video_fixture.gd

const FIXTURE := "C:/Users/gavin/Music/SOUNDSCAPE/MP4 Test/Caramella Girls - Caramelldansen HD Version (Swedish Original).mp4"
const DIR := "user://video_fixture_test"

func _initialize() -> void:
	if not FileAccess.file_exists(FIXTURE) or not ClassDB.class_exists("SsFlacStream"):
		print("SKIPPED: the fixture %s or libsoundscape_dsp is not on this machine." % FIXTURE.get_file())
		print("RESULT SKIPPED")
		quit(2)
		return
	var ok := true
	var probe := []
	OS.execute("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries",
		"stream=sample_rate,channels:format=duration", "-of", "json", FIXTURE], probe, true)
	var info: Variant = JSON.parse_string(probe[0] if probe.size() > 0 else "")
	if not (info is Dictionary and (info.get("streams", []) as Array).size() > 0 and info.has("format")):
		print("ffprobe could not read the fixture")
		print("RESULT FAIL")
		quit(1)
		return
	var rate := int(info["streams"][0]["sample_rate"])
	var channels := int(info["streams"][0]["channels"])
	var duration := float(info["format"]["duration"])

	# 1. the sound
	var engine := AudioEngine.new()
	engine.video_test = true
	engine.video_dir = DIR
	var t0 := Time.get_ticks_msec()
	var sound := engine.decode(FIXTURE)
	var sound_ms := Time.get_ticks_msec() - t0
	var ref_path := ProjectSettings.globalize_path(DIR).path_join("reference.f32")
	OS.execute("ffmpeg", ["-v", "error", "-y", "-i", FIXTURE, "-map", "0:a:0", "-t", "10",
		"-f", "f32le", "-c:a", "pcm_f32le", ref_path], [], true)
	var reference := FileAccess.get_file_as_bytes(ref_path).to_float32_array()
	var fmt: bool = sound != null and sound.get_class() == "SsFlacStream" and sound.call("get_sample_rate") == rate \
		and sound.call("get_channels") == channels and sound.call("get_bits_per_sample") == 24 \
		and absf(sound.get_length() - duration) < 0.1
	var frames := reference.size() / maxi(channels, 1)
	var mine: PackedFloat32Array = sound.call("decode_frames", 0, frames) if fmt else PackedFloat32Array()
	var worst := 0.0
	var loudest := 0.0
	for i in mini(mine.size(), reference.size()):
		worst = maxf(worst, absf(mine[i] - reference[i]))
		loudest = maxf(loudest, absf(mine[i]))
	var step := 1.0 / 8388608.0
	var faithful: bool = fmt and frames >= rate * 9 and mine.size() == reference.size() \
		and worst <= 2.0 * step and loudest > 0.05
	ok = ok and faithful
	print("1. sound in %d ms: %s, %s Hz / %s ch / %s bit, %.2f s of %.2f s; first %.1f s vs ffmpeg's AAC decode: worst %.9f (%.2f steps), peak %.3f: %s" % [
		sound_ms, sound.get_class() if sound else "null", sound.call("get_sample_rate") if sound else -1,
		sound.call("get_channels") if sound else -1, sound.call("get_bits_per_sample") if sound else -1,
		sound.get_length() if sound else -1.0, duration, float(frames) / rate, worst, worst / step, loudest, faithful])

	# 2. the picture
	var landed := [""]
	engine.video_ready.connect(func(path: String, ogv: String) -> void:
		if path == FIXTURE:
			landed[0] = ogv)
	t0 = Time.get_ticks_msec()
	engine.request_video(FIXTURE)
	while (landed[0] as String).is_empty() and Time.get_ticks_msec() - t0 < 180000:
		await process_frame
	var picture_ms := Time.get_ticks_msec() - t0
	var ogv: String = landed[0]
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "FixtureVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var clock := AudioStreamPlayer.new()
	clock.bus = "FixtureVerify"
	clock.stream = sound
	root.add_child(clock)
	var pic := VideoTest.new()
	root.add_child(pic)
	await process_frame
	var video: VideoStreamPlayer = pic.get("_video")
	pic.expect(FIXTURE, sound)
	var proxied: bool = not ogv.is_empty() and pic.open(FIXTURE, ogv) \
		and pic.texture.get_size() == Vector2(AudioEngine.VIDEO_W, 90) \
		and absf(video.get_stream_length() - duration) < 0.5
	ok = ok and proxied
	print("2. picture proxy in %d ms: %s, %s, %.2f s long: %s" % [picture_ms, ogv.get_file(),
		pic.texture.get_size() if pic.texture else Vector2.ZERO, video.get_stream_length(), proxied])

	# 3. both colour modes, on the real clock
	var mat := pic.material as ShaderMaterial
	clock.play(40.0)
	for mode: VideoTest.ColorMode in [VideoTest.ColorMode.ORIGINAL, VideoTest.ColorMode.PALETTE]:
		if video.is_playing():
			# re-sync the SECOND window onto the sound. Not the first: the picture is not playing yet,
			# follow() starts it on the sound, and a seek here as well doubled that 40 s Theora seek
			# into the measured window (0.213 s)
			video.stream_position = clock.get_playback_position()
		pic.color_mode = mode
		var palette: Gradient = Skins.video_ramp("WIN98") if mode == VideoTest.ColorMode.PALETTE else null
		var kick := 0.5 if mode == VideoTest.ColorMode.PALETTE else 0.0
		var t := Time.get_ticks_msec()
		var from := -1.0
		var drift := 0.0
		while Time.get_ticks_msec() - t < 2000:
			await process_frame
			if Time.get_ticks_msec() - t > 300:   # settled: the first frames seek the picture onto the sound
				if from < 0.0:
					from = video.stream_position
				drift = maxf(drift, absf(video.stream_position - clock.get_playback_position()))
			pic.follow(clock, palette, kick)
		var mode_ok: bool = int(mat.get_shader_parameter("color_mode")) == mode and pic.visible \
			and video.stream_position > from + 1.2 and drift < VideoTest.DRIFT_MAX \
			and (mode == VideoTest.ColorMode.ORIGINAL or (mat.get_shader_parameter("ramp") as GradientTexture1D).gradient == palette)
		ok = ok and mode_ok
		print("3. %s: shader mode %s, picture %.2f -> %.2f s against the sound at %.2f s, worst drift %.3f s: %s" % [
			VideoTest.ColorMode.keys()[mode], mat.get_shader_parameter("color_mode"), from, video.stream_position,
			clock.get_playback_position(), drift, mode_ok])

	clock.stop()
	clock.queue_free()
	pic.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)
	engine.shutdown()
	engine.free()
	AudioEngine.purge_video_cache(DIR)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
