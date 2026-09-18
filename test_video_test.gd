extends SceneTree
## Video TEST (TBS): MP4 isolation, full-fidelity sound, and a picture that follows it. Exit
## codes match test_flac_native.gd: 0 PASS, 1 FAIL, 2 SKIPPED when libsoundscape_dsp is not
## built here (an MP4's sound plays through the native FLAC path).
##   1. OFF: the library walk skips .mp4 at any depth and in any case, decode() refuses one
##      and request_video renders nothing; ON: the walk finds them
##   2. ON, sound: an AAC MP4 plays as a 24-bit SsFlacStream at the MP4's own 48 kHz, equal to
##      ffmpeg's float decode of that AAC to within two 24-bit steps (-132 dB); decoding it
##      again is a cache hit that renders nothing new
##   3. two workers decoding the same MP4 at once both get a stream, and leave one file
##   4. a ".mp4" that is not a video fails cleanly: null, nothing left behind
##   5. request_video delivers a VIDEO_W-wide Theora proxy, on the main thread
##   6. VideoTest.follow on a real player: hidden until the sound plays, keeps pace with no
##      re-seek, lands on a seek, holds on pause, steps aside for another stream and for STOP,
##      refuses a stale render; the palette and kick it is handed reach the shader, and a
##      frame with no palette keeps the last one; the colour mode reaches the shader both ways
##   7. purge_video_cache empties the render dir, and a missing dir is not an error
##   8. VideoTest.kick maps a band magnitude onto the visualizer's dB scale: floor -> 0, 0 dB -> 1
## Everything lives in user://video_test_suite and is removed.
##   godot --headless --path . --script res://test_video_test.gd

const DIR := "user://video_test_suite"

func _initialize() -> void:
	if not ClassDB.class_exists("SsFlacStream"):
		print("SKIPPED: SsFlacStream is not registered -- libsoundscape_dsp is not built here.")
		print("RESULT SKIPPED")
		quit(2)
		return
	var base := ProjectSettings.globalize_path(DIR)
	var lib := base.path_join("lib")
	var renders := DIR.path_join("renders")
	DirAccess.make_dir_recursive_absolute(lib.path_join("sub"))
	var mp4 := lib.path_join("clip.mp4")
	var made := OS.execute("ffmpeg", ["-v", "error", "-y",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4",
		"-f", "lavfi", "-i", "aevalsrc=0.5*sin(2*PI*440*t)|0.3*sin(2*PI*660*t):s=48000:d=4",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", mp4], [], true)
	if made != 0:
		print("could not build the test MP4 with ffmpeg (%d)" % made)
		print("RESULT FAIL")
		quit(1)
		return
	for f in ["a.mp3", "b.flac", "cover.jpg", "sub/c.ogg", "sub/DEEP.MP4"]:
		FileAccess.open(lib.path_join(f), FileAccess.WRITE).close()
	var ok := true

	# 1. OFF, then ON. The walk belongs to LibraryModel now, and what counts as a track is
	# its rule, so the gate is checked where it lives rather than through a detached UI node.
	var model := LibraryModel.new()
	model.folders = [lib]
	var off: Array[String] = []
	model.call("_walk", lib, off, false)
	var engine := AudioEngine.new()
	engine.video_dir = renders
	var pictures := [0]
	engine.video_ready.connect(func(_p: String, _o: String) -> void: pictures[0] += 1)
	var refused := engine.decode(mp4) == null
	engine.request_video(mp4)
	await create_timer(0.3).timeout
	var on: Array[String] = []
	model.call("_walk", lib, on, true)
	model.free()
	var gated: bool = off.size() == 3 and _mp4s(off) == 0 and on.size() == 5 and _mp4s(on) == 2 \
		and refused and pictures[0] == 0 and _files(renders) == 0
	ok = ok and gated
	print("1. OFF: walk %d tracks / %d mp4, decode refused %s, renders %d, pictures %d; ON: walk %d tracks / %d mp4: %s" % [
		off.size(), _mp4s(off), refused, _files(renders), pictures[0], on.size(), _mp4s(on), gated])

	# 2. ON: the sound, against ffmpeg's own float decode of the same AAC
	engine.video_test = true
	var sound := engine.decode(mp4)
	var ref_path := base.path_join("reference.f32")
	OS.execute("ffmpeg", ["-v", "error", "-y", "-i", mp4, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", ref_path], [], true)
	var reference := FileAccess.get_file_as_bytes(ref_path).to_float32_array()
	var fmt: bool = sound != null and sound.get_class() == "SsFlacStream" and sound.call("get_sample_rate") == 48000 \
		and sound.call("get_bits_per_sample") == 24 and sound.call("get_channels") == 2
	var frames := reference.size() / 2
	var mine: PackedFloat32Array = sound.call("decode_frames", 0, frames) if fmt else PackedFloat32Array()
	var worst := 0.0
	for i in mini(mine.size(), reference.size()):
		worst = maxf(worst, absf(mine[i] - reference[i]))
	var peak := Vector2.ZERO
	for i in range(0, mine.size() - 1, 2):
		peak = Vector2(maxf(peak.x, absf(mine[i])), maxf(peak.y, absf(mine[i + 1])))
	var step := 1.0 / 8388608.0
	var stamps := _stamps(renders)
	await create_timer(1.1).timeout   # mtimes are whole seconds: a re-render would now show
	var again := engine.decode(mp4)
	# the peaks only prove the comparison is not silence against silence: AAC rings past the
	# source's 0.5 / 0.3 at the onset, and the reference carries that ringing too
	var faithful: bool = fmt and frames > 48000 * 3 and mine.size() == reference.size() and worst <= 2.0 * step \
		and peak.x > 0.4 and peak.y > 0.2 and again != null \
		and stamps.size() == 1 and _stamps(renders) == stamps
	ok = ok and faithful
	print("2. ON: %s, %s Hz / %s bit / %s ch; %d frames vs ffmpeg's AAC decode: worst %.9f (%.2f steps), peaks L %.3f R %.3f; second decode a cache hit %s: %s" % [
		sound.get_class() if sound else "null", sound.call("get_sample_rate") if sound else -1,
		sound.call("get_bits_per_sample") if sound else -1, sound.call("get_channels") if sound else -1,
		frames, worst, worst / step, peak.x, peak.y, _stamps(renders) == stamps, faithful])

	# 3. two workers rendering the same MP4 at once
	AudioEngine.purge_video_cache(renders)
	var r0 := []
	var r1 := []
	var t0 := WorkerThreadPool.add_task(func() -> void: r0.append(engine.decode(mp4)))
	var t1 := WorkerThreadPool.add_task(func() -> void: r1.append(engine.decode(mp4)))
	WorkerThreadPool.wait_for_task_completion(t0)
	WorkerThreadPool.wait_for_task_completion(t1)
	var raced: bool = r0.size() == 1 and r0[0] != null and r1.size() == 1 and r1[0] != null and _files(renders) == 1
	ok = ok and raced
	print("3. two workers at once: streams %s / %s, files in the cache %d: %s" % [
		r0[0] != null if r0.size() else false, r1[0] != null if r1.size() else false, _files(renders), raced])

	# 4. not really an MP4
	var bogus := lib.path_join("notes.mp4")
	var w := FileAccess.open(bogus, FileAccess.WRITE)
	w.store_string("not a video")
	w.close()
	var before := _files(renders)
	var junk := engine.decode(bogus)
	var clean: bool = junk == null and _files(renders) == before
	ok = ok and clean
	print("4. text named .mp4: stream %s, cache files %d -> %d: %s" % [junk, before, _files(renders), clean])

	# 5. the picture render
	var landed := [""]
	var on_main := [false]
	engine.video_ready.connect(func(path: String, ogv: String) -> void:
		if path == mp4:
			landed[0] = ogv
			on_main[0] = OS.get_thread_caller_id() == OS.get_main_thread_id())
	engine.request_video(mp4)
	var waited := Time.get_ticks_msec()
	while (landed[0] as String).is_empty() and Time.get_ticks_msec() - waited < 30000:
		await process_frame
	var ogv: String = landed[0]
	var rendered: bool = ogv.ends_with(".ogv") and FileAccess.file_exists(ogv) and on_main[0]
	ok = ok and rendered
	print("5. picture render %s, delivered on the main thread %s: %s" % [ogv.get_file(), on_main[0], rendered])

	# 6. the picture on a real player
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "VideoTestVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var clock := AudioStreamPlayer.new()
	clock.bus = "VideoTestVerify"
	clock.stream = sound
	root.add_child(clock)
	var pic := VideoTest.new()
	root.add_child(pic)
	await process_frame
	var video: VideoStreamPlayer = pic.get("_video")
	pic.expect(mp4, sound)
	var stale: bool = not pic.open(lib.path_join("other.mp4"), ogv) and pic.texture == null
	var opened: bool = pic.open(mp4, ogv) and pic.texture != null \
		and pic.texture.get_size() == Vector2(AudioEngine.VIDEO_W, 120)
	pic.follow(clock)
	var idle_hidden := not pic.visible
	clock.play()
	await _follow_for(pic, clock, 0.2)
	var steady := 0.0
	var t_steady := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_steady < 1500:
		await process_frame
		steady = maxf(steady, absf(video.stream_position - clock.get_playback_position()))   # before any correction
		pic.follow(clock)
	var pace: bool = pic.visible and video.is_playing() and steady < VideoTest.DRIFT_MAX \
		and clock.get_playback_position() > 1.3
	clock.seek(3.0)
	await _follow_for(pic, clock, 0.15)
	var sought: bool = absf(video.stream_position - clock.get_playback_position()) < VideoTest.DRIFT_MAX \
		and video.stream_position > 2.9
	clock.stream_paused = true
	await _follow_for(pic, clock, 0.1)
	var held_at := video.stream_position
	await _follow_for(pic, clock, 0.4)
	var held: bool = pic.visible and absf(video.stream_position - held_at) < 0.001
	clock.stream_paused = false
	await _follow_for(pic, clock, 0.25)
	var resumed: bool = pic.visible and video.stream_position > held_at + 0.1
	clock.stream = _silence(2.0)
	clock.play()
	await _follow_for(pic, clock, 0.1)
	var aside: bool = not pic.visible and video.paused
	clock.stream = sound
	clock.play(1.0)
	await _follow_for(pic, clock, 0.25)
	var back: bool = pic.visible and absf(video.stream_position - clock.get_playback_position()) < VideoTest.DRIFT_MAX
	var grad := Visualizer.parse_hex_list("000000,ff0055,00ffcc,ffffff")
	pic.follow(clock, grad, 0.6)
	var mat := pic.material as ShaderMaterial
	var ramp: GradientTexture1D = mat.get_shader_parameter("ramp")
	var painted: bool = ramp != null and ramp.gradient == grad and is_equal_approx(float(mat.get_shader_parameter("pulse")), 0.6)
	pic.follow(clock)
	painted = painted and ramp.gradient == grad
	painted = painted and int(mat.get_shader_parameter("color_mode")) == VideoTest.ColorMode.PALETTE
	pic.color_mode = VideoTest.ColorMode.ORIGINAL
	painted = painted and int(mat.get_shader_parameter("color_mode")) == VideoTest.ColorMode.ORIGINAL
	pic.color_mode = VideoTest.ColorMode.PALETTE
	painted = painted and int(mat.get_shader_parameter("color_mode")) == VideoTest.ColorMode.PALETTE
	clock.stop()
	await _follow_for(pic, clock, 0.05)
	var stop_hidden := not pic.visible
	pic.expect("", null)
	var cleared: bool = pic.texture == null and not pic.visible
	var follows: bool = stale and opened and idle_hidden and pace and sought and held and resumed \
		and aside and back and painted and stop_hidden and cleared
	ok = ok and follows
	print("6. stale render refused %s, opened 160x120 %s, hidden while idle %s, steady drift %.3f s with no re-seek %s, seek lands %s, pause holds %s, resumes %s, steps aside for another stream %s, back on its own %s, palette, kick and colour mode reach the shader %s, hidden on STOP %s, cleared %s: %s" % [
		stale, opened, idle_hidden, steady, pace, sought, held, resumed, aside, back, painted, stop_hidden, cleared, follows])
	clock.queue_free()
	pic.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)

	# 7. purge
	AudioEngine.purge_video_cache(renders)
	AudioEngine.purge_video_cache(DIR.path_join("never_made"))
	var purged := _files(renders) == 0
	ok = ok and purged
	print("7. purge empties the render dir %s (and a missing dir is quiet)" % purged)

	# 8. kick scale
	var kicks: bool = VideoTest.kick(0.0, -60.0) == 0.0 and is_equal_approx(VideoTest.kick(1.0, -60.0), 1.0) \
		and is_equal_approx(VideoTest.kick(db_to_linear(-30.0), -60.0), 0.5) and VideoTest.kick(4.0, -60.0) == 1.0 \
		and VideoTest.kick(db_to_linear(-45.0), -60.0) < VideoTest.kick(db_to_linear(-15.0), -60.0)
	ok = ok and kicks
	print("8. kick: silence 0, 0 dB 1, -30 dB on a -60 dB floor 0.5, overs clamp, rises with level: %s" % kicks)

	engine.shutdown()
	engine.free()
	_rm(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _follow_for(pic: VideoTest, clock: AudioStreamPlayer, secs: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		await process_frame
		pic.follow(clock)

func _mp4s(paths: Array[String]) -> int:
	return paths.filter(func(x: String) -> bool: return x.get_extension().to_lower() == "mp4").size()

func _files(dir: String) -> int:
	return DirAccess.get_files_at(dir).size() if DirAccess.dir_exists_absolute(dir) else 0

func _stamps(dir: String) -> Dictionary:
	var out := {}
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			out[f] = FileAccess.get_modified_time(ProjectSettings.globalize_path(dir.path_join(f)))
	return out

func _silence(secs: float) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = 22050
	var buf := PackedByteArray()
	buf.resize(int(22050 * secs) * 2)
	s.data = buf
	return s

func _rm(dir: String) -> void:
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
