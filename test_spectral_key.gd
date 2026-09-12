extends SceneTree
## Runnable check for the offline spectral key pipeline end to end: AudioEngine queues a
## real WorkerThreadPool task, ffmpeg does the downmix/resample, SpectralKey estimates a
## key, and the result lands in the persistent cache -- then a second queue on the same
## path is a cache hit, not a second analysis. Self-contained: synthesises its own test
## WAV (an A minor triad, A-C-E) into user:// rather than depending on a real library
## track, the same way test_director.gd builds its own click track.
##   godot --headless --path . --script res://test_spectral_key.gd

func _initialize() -> void:
	var sr := 44100
	var secs := 8.0
	var n := int(sr * secs)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	# A minor triad: A3 220 Hz, C4 261.63 Hz, E4 329.63 Hz -- unambiguous A/Am, and
	# nowhere near any tag, so metadata()'s ffprobe pass is guaranteed to find none
	for i in n:
		var t := float(i) / sr
		var v := (sin(TAU * 220.0 * t) + sin(TAU * 261.63 * t) + sin(TAU * 329.63 * t)) / 3.0
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0 * 0.8))
	var path := "user://spectral_test_track.wav"
	_write_wav(path, buf, sr)
	var abs_path := ProjectSettings.globalize_path(path)

	var engine := AudioEngine.new()
	root.add_child(engine)
	await process_frame

	# a boxed int, not a plain local: GDScript lambdas capture outer locals BY VALUE, so
	# a bare `ready_count += 1` inside the callback would only ever mutate its own copy
	var ready_count := [0]
	engine.spectral_key_ready.connect(func(_p: String, _pc: int, _minor: bool) -> void:
		ready_count[0] += 1)

	var t0 := Time.get_ticks_msec()
	engine.queue_spectral_key(abs_path)

	var guard := 0
	while engine.spectral_key_for(abs_path).is_empty() and guard < 600:   # up to 60 s
		await process_frame
		guard += 1
	# the cache write and the deferred signal both come off the same worker result, but
	# the poll above can observe the cache a frame before the deferred call actually
	# runs -- a couple more frames lets it land before ready_count is checked
	for _f in 5:
		await process_frame
	var dt := Time.get_ticks_msec() - t0

	var ok := true
	var found := not engine.spectral_key_for(abs_path).is_empty()
	ok = ok and found
	print("analysis landed in the cache within the guard: %s (%d ms)" % [found, dt])

	var result := engine.spectral_key_for(abs_path)
	var pc_valid := result.has("pc") and int(result["pc"]) >= 0 and int(result["pc"]) <= 11
	ok = ok and pc_valid
	print("result is a valid pitch class: %s (result=%s)" % [pc_valid, result])

	ok = ok and ready_count[0] == 1
	print("spectral_key_ready fired exactly once: %s (count=%d)" % [ready_count[0] == 1, ready_count[0]])

	# second queue on the same path: cache hit, no new task, no second signal
	engine.queue_spectral_key(abs_path)
	for _f in 10:
		await process_frame
	var no_repeat: bool = ready_count[0] == 1
	ok = ok and no_repeat
	print("re-queueing an already-cached path fires no second signal: %s" % no_repeat)

	# shutdown() must return promptly even with a full queue and must not deadlock on
	# _spectral_lock -- this is the Alt+F4 path, where a worker mid-write to the cache
	# used to be racing the main thread freeing the engine out from under it.
	for i in 40:
		engine.queue_spectral_key("%s#%d" % [abs_path, i])   # paths that do not exist
	var t_shut := Time.get_ticks_msec()
	engine.shutdown()
	var shut_ms := Time.get_ticks_msec() - t_shut
	var prompt := shut_ms < 15000
	ok = ok and prompt
	print("shutdown() joined its workers without deadlocking: %s (%d ms)" % [prompt, shut_ms])

	# and it must have actually stopped the queue rather than just returning
	var quiet := not engine._spectral_running
	ok = ok and quiet
	print("no worker left running after shutdown: %s" % quiet)

	DirAccess.remove_absolute(path)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

## Plain RIFF/WAV, mono 16-bit -- ffmpeg (and ffprobe) read it natively with no Godot
## resource machinery involved, which is exactly what the real pipeline hands them.
func _write_wav(path: String, pcm: PackedByteArray, sr: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var byte_rate := sr * 2
	f.store_string("RIFF")
	f.store_32(36 + pcm.size())
	f.store_string("WAVE")
	f.store_string("fmt ")
	f.store_32(16)
	f.store_16(1)    # PCM
	f.store_16(1)    # mono
	f.store_32(sr)
	f.store_32(byte_rate)
	f.store_16(2)    # block align
	f.store_16(16)   # bits per sample
	f.store_string("data")
	f.store_32(pcm.size())
	f.store_buffer(pcm)
	f.close()
