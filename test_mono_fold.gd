extends SceneTree
## Runnable check for the MONO toggle: a hard-panned stereo tone must read as clearly
## unequal L/R with MONO off, and fold to equal L/R with MONO on.
##   godot --headless --path . --script res://test_mono_fold.gd

func _initialize() -> void:
	Engine.max_fps = 60
	var engine := AudioEngine.new()
	root.add_child(engine)
	var director := AudioDirector.new()
	root.add_child(director)
	await process_frame
	await process_frame

	var player := AudioStreamPlayer.new()
	player.bus = engine.deck_bus(0)
	root.add_child(player)
	await process_frame

	# hard left: right channel silent, left full tone
	var sr := 44100
	var secs := 3.0
	var n := int(sr * secs)
	var buf := PackedByteArray()
	buf.resize(n * 4)   # 16-bit stereo
	for i in n:
		var v := int(sin(TAU * 220.0 * float(i) / sr) * 0.8 * 32767.0)
		buf.encode_s16(i * 4, v)       # left
		buf.encode_s16(i * 4 + 2, 0)   # right silent
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.stereo = true
	s.mix_rate = sr
	s.data = buf
	player.stream = s
	player.play()
	director.attach(player)

	var guard := 0
	while not player.playing and guard < 120:
		await process_frame
		guard += 1
	for _f in 20:
		await process_frame

	var stereo_off: Vector2 = director.stereo
	engine.set_mono(true)
	for _f in 20:
		await process_frame
	var stereo_on: Vector2 = director.stereo

	player.stop()

	var was_unequal := absf(stereo_off.x - stereo_off.y) > 0.05
	var now_equal := absf(stereo_on.x - stereo_on.y) < 0.01
	print("MONO off: L=%.4f R=%.4f  (unequal=%s)" % [stereo_off.x, stereo_off.y, was_unequal])
	print("MONO on:  L=%.4f R=%.4f  (equal=%s)" % [stereo_on.x, stereo_on.y, now_equal])
	var ok := was_unequal and now_equal
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
