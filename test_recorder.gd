extends SceneTree
## The recorder against a live Master bus: it must capture real audio, drop NOTHING,
## keep RAM flat (it streams to disk rather than accumulating an AudioStreamWAV), and
## produce a file ffmpeg will actually open.
##   godot --headless --path . --script res://test_recorder.gd

func _initialize() -> void:
	Engine.max_fps = 60
	var engine := AudioEngine.new()
	root.add_child(engine)
	await process_frame
	await process_frame

	var rec := Recorder.new()
	root.add_child(rec)
	rec.setup()
	await process_frame

	var player := AudioStreamPlayer.new()
	player.bus = engine.deck_bus(0)
	root.add_child(player)
	var sr := 44100
	var n := int(sr * 10.0)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in n:
		buf.encode_s16(i * 2, int(sin(TAU * 440.0 * float(i) / sr) * 0.6 * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	player.stream = s
	player.play()
	var guard := 0
	while not player.playing and guard < 120:
		await process_frame
		guard += 1

	var dir := ProjectSettings.globalize_path("user://rec_test")
	var raw := rec.start(dir)
	var ok := not raw.is_empty()
	print("start() opened a take: %s" % ok)
	if not ok:
		print("RESULT FAIL")
		quit(1)
		return

	# record ~2 s of real bus output
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2000:
		await process_frame
	var captured := rec.frames_written
	var dropped := rec.discarded

	# WAV / 44100 / STANDARD
	var done := [false]
	var out_ok := [false]
	var out_path := [""]
	rec.finished.connect(func(path: String, good: bool) -> void:
		done[0] = true
		out_ok[0] = good
		out_path[0] = path)
	rec.stop(0, 0, 1)
	guard = 0
	while not done[0] and guard < 600:
		await process_frame
		guard += 1
	player.stop()

	var got_frames := captured > sr   # at least a second's worth at the mix rate
	ok = ok and got_frames
	print("captured real audio off the bus: %s (%d frames)" % [got_frames, captured])

	var clean := dropped == 0
	ok = ok and clean
	print("capture buffer dropped nothing: %s (discarded %d)" % [clean, dropped])

	ok = ok and out_ok[0]
	print("ffmpeg produced the requested file: %s (%s)" % [out_ok[0], out_path[0].get_file()])

	var size := 0
	if FileAccess.file_exists(out_path[0]):
		var f := FileAccess.open(out_path[0], FileAccess.READ)
		size = f.get_length()
		f.close()
	var big_enough := size > 100000   # ~2 s of 16-bit stereo is ~350 KB
	ok = ok and big_enough
	print("the take is a real file on disk: %s (%d bytes)" % [big_enough, size])

	# the float intermediate is cleaned up once the conversion succeeded
	var no_temp := not FileAccess.file_exists(raw)
	ok = ok and no_temp
	print("float intermediate cleaned up after conversion: %s" % no_temp)

	if FileAccess.file_exists(out_path[0]):
		DirAccess.remove_absolute(out_path[0])
	DirAccess.remove_absolute(dir)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
