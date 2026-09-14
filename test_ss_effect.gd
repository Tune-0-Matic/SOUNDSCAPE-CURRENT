extends SceneTree
## The pass-through milestone for the native DSP bridge (Phase 9, Step 1).
##
## Proves four things about SsEffect running on a REAL bus with REAL audio flowing,
## because every native kernel that follows -- gate, bit crusher, FFT tap -- replaces
## the copy in SsEffectInstance::_process and changes nothing else. If a bit-identical
## copy does not hold here, nothing built on top of it can be trusted either.
##
##   1. the extension loaded and registered its classes
##   2. output is BIT-IDENTICAL to input: exact float equality, not "close enough"
##   3. the analyser sees the same energy with the effect on as with it off
##   4. the RT contract's preconditions hold: the rings are lock-free, the callback
##      ran on real audio, and it never saw a null buffer
##
##   godot --headless --path . --script res://test_ss_effect.gd
##
## Exit codes are three-way on purpose, so CI can tell "not built yet" from "broken":
##   0 = PASS    1 = FAIL    2 = SKIPPED (extension not built on this machine)

const BUS := "SsVerify"
const TEST_FRAMES := 4096
## Exact float equality. Not a tolerance -- a pass-through that is within 1e-9 of the
## input is a pass-through that is doing arithmetic, and the whole point of this test
## is that it is doing none.
const EXACT := true

func _initialize() -> void:
	if not ClassDB.class_exists("SsEffect"):
		print("")
		print("SKIPPED: SsEffect is not registered -- libsoundscape_dsp is not built here.")
		print("  Build it:  cd extension && scons target=template_debug")
		print("  Needs:     a C++ toolchain (MSVC Build Tools w/ C++ workload, or clang)")
		print("             python -m pip install scons")
		print("             git clone --depth 1 --branch master \\")
		print("                 https://github.com/godotengine/godot-cpp.git extension/godot-cpp")
		print("RESULT SKIPPED")
		quit(2)
		return

	var ok := true

	# ---- 1. registration -------------------------------------------------------
	var inst_ok := ClassDB.class_exists("SsEffectInstance")
	var parent_ok := ClassDB.get_parent_class("SsEffect") == "AudioEffect"
	var inst_parent_ok := ClassDB.get_parent_class("SsEffectInstance") == "AudioEffectInstance"
	ok = ok and inst_ok and parent_ok and inst_parent_ok
	print("1. registered: SsEffect<-%s  SsEffectInstance exists=%s <-%s" % [
		ClassDB.get_parent_class("SsEffect"), inst_ok,
		ClassDB.get_parent_class("SsEffectInstance")])

	var fx = ClassDB.instantiate("SsEffect")
	if fx == null:
		print("   could not instantiate SsEffect")
		print("RESULT FAIL")
		quit(1)
		return

	# ---- 2. the RT contract's one platform precondition ------------------------
	# std::atomic<uint32_t> falling back to a mutex would make every ring push a lock
	# on the audio thread -- exactly the failure the design exists to avoid. Better to
	# fail the build than to ship a "lock-free" ring that locks.
	var lock_free: bool = fx.is_lock_free()
	ok = ok and lock_free
	print("2. SPSC rings are lock-free on this platform: %s" % lock_free)

	# ---- bus under test --------------------------------------------------------
	# A dedicated bus, so nothing in the deck chain or on Master can be blamed for a
	# difference. Order matters: the effect first, then the analyser reading what the
	# effect produced, then the capture tapping the same point.
	var bus_idx := AudioServer.bus_count
	AudioServer.add_bus(bus_idx)
	AudioServer.set_bus_name(bus_idx, BUS)
	AudioServer.set_bus_send(bus_idx, "Master")
	AudioServer.set_bus_volume_db(bus_idx, 0.0)   # unity: any other value is a multiply
	AudioServer.set_bus_mute(bus_idx, true)       # headless or not, do not make noise

	AudioServer.add_bus_effect(bus_idx, fx, 0)
	var analyser := AudioEffectSpectrumAnalyzer.new()
	analyser.buffer_length = AudioDirector.BUFFER_LENGTH
	AudioServer.add_bus_effect(bus_idx, analyser, 1)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus_idx, capture, 2)
	var spectrum: AudioEffectSpectrumAnalyzerInstance = AudioServer.get_bus_effect_instance(bus_idx, 1)

	# ---- the source ------------------------------------------------------------
	# mix_rate matched to the server's so nothing resamples: a resampler in the path
	# would make "bit-identical" impossible to assert and impossible to interpret.
	var player := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.5
	player.stream = gen
	player.bus = BUS
	player.volume_db = 0.0
	root.add_child(player)
	await process_frame        # play() needs the node already inside the tree
	player.play()
	await process_frame
	var pb: AudioStreamGeneratorPlayback = player.get_stream_playback()

	# A deterministic signal with awkward mantissas on purpose. A pure sine would be
	# smooth enough that a subtly lossy path could still look right; these values are
	# chosen so any rounding at all changes the bits.
	var sent := PackedVector2Array()
	sent.resize(TEST_FRAMES)
	for i in TEST_FRAMES:
		var t := float(i) / float(TEST_FRAMES)
		sent[i] = Vector2(
			sin(float(i) * 0.10730) * 0.6137 + t * 0.0131,
			cos(float(i) * 0.07310) * 0.4391 - t * 0.0177)

	# ---- push, then drain ------------------------------------------------------
	capture.clear_buffer()
	fx.reset_counters()
	var pushed := 0
	var guard := 0
	while pushed < TEST_FRAMES and guard < 600:
		var room: int = mini(pb.get_frames_available(), TEST_FRAMES - pushed)
		for i in room:
			pb.push_frame(sent[pushed + i])
		pushed += room
		await process_frame
		guard += 1
	# let the tail flush through the bus before reading the capture
	for _f in 30:
		await process_frame

	var got := capture.get_buffer(capture.get_frames_available())
	print("   pushed %d frames, captured %d, discarded %d" % [
		pushed, got.size(), capture.get_discarded_frames()])

	# ---- 3. bit-identical ------------------------------------------------------
	# The capture starts wherever the mixer happened to be, so the sent signal is
	# located inside it by exact match on a run of frames rather than assumed to be at
	# index 0. If the path were lossy there would BE no exact run to find, which is
	# itself the assertion.
	var offset := -1
	var probe := mini(64, sent.size())
	var limit: int = got.size() - probe
	for start in range(0, maxi(limit, 0)):
		var hit := true
		for i in probe:
			if got[start + i] != sent[i]:
				hit = false
				break
		if hit:
			offset = start
			break

	var compared := 0
	var mismatches := 0
	var worst := 0.0
	if offset >= 0:
		var n: int = mini(sent.size(), got.size() - offset)
		for i in n:
			compared += 1
			var a: Vector2 = sent[i]
			var b: Vector2 = got[offset + i]
			if a != b:
				mismatches += 1
				worst = maxf(worst, maxf(absf(a.x - b.x), absf(a.y - b.y)))
	var identical: bool = offset >= 0 and compared > 0 and mismatches == 0
	ok = ok and identical
	print("3. bit-identical: %s  (aligned at %d, compared %d frames, %d mismatches, worst delta %.9f)"
		% [identical, offset, compared, mismatches, worst])

	# ---- 4. the callback actually ran on real audio ----------------------------
	var frames_done: int = fx.get_frames_processed()
	var blocks_done: int = fx.get_blocks_processed()
	var saw_null: bool = fx.get_saw_null_buffer()
	var ran: bool = frames_done > 0 and blocks_done > 0 and not saw_null
	ok = ok and ran
	print("4. callback ran: %s  (%d frames over %d blocks, max block %d, null buffers seen: %s)"
		% [ran, frames_done, blocks_done, fx.get_max_block_seen(), saw_null])

	# ---- 5. the parameter ring accepts traffic ---------------------------------
	# Not used by the pass-through kernel, but the boundary is exercised here rather
	# than first being tried by the gate. A drop at this volume would mean the ring is
	# mis-sized before any real parameter stream exists.
	var accepted := 0
	for i in 128:
		if fx.push_param(0, 0, float(i) * 0.01):
			accepted += 1
	var ring_ok: bool = accepted == 128 and fx.get_params_dropped() == 0
	ok = ok and ring_ok
	print("5. param ring took %d/128 with %d dropped: %s" % [
		accepted, fx.get_params_dropped(), ring_ok])

	# ---- 6. analyser energy is invariant across the effect ---------------------
	# The claim is that inserting the bridge changes nothing the rest of the program
	# can observe. AudioDirector reads the analyser; if the energy it sees moves when
	# the effect is switched in, the "transparent" claim is false whatever the sample
	# comparison said.
	var feed := func() -> void:
		var ph := 0.0
		for _f in 25:
			for i in pb.get_frames_available():
				ph += TAU * 440.0 / gen.mix_rate
				pb.push_frame(Vector2.ONE * sin(ph) * 0.5)
			await process_frame

	AudioServer.set_bus_effect_enabled(bus_idx, 0, false)
	await feed.call()
	var off_energy := _band_energy(spectrum)
	AudioServer.set_bus_effect_enabled(bus_idx, 0, true)
	await feed.call()
	var on_energy := _band_energy(spectrum)
	# 1% of the off reading. Not exact: the analyser is a trailing FFT window and two
	# separate feeds never land on the same phase. What would fail here is a real gain
	# or filtering change, which is the thing being tested.
	var drift := absf(on_energy - off_energy)
	var energy_ok: bool = off_energy > 0.0 and drift <= off_energy * 0.01
	ok = ok and energy_ok
	print("6. analyser energy invariant: %s  (off %.6f -> on %.6f, drift %.6f, tol %.6f)"
		% [energy_ok, off_energy, on_energy, drift, off_energy * 0.01])

	# ---- teardown --------------------------------------------------------------
	player.stop()
	root.remove_child(player)
	player.free()
	AudioServer.remove_bus(bus_idx)

	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _band_energy(spectrum: AudioEffectSpectrumAnalyzerInstance) -> float:
	var total := 0.0
	for i in AudioDirector.BAND_COUNT:
		var lo: float = 30.0 * pow(16000.0 / 30.0, float(i) / AudioDirector.BAND_COUNT)
		var hi: float = 30.0 * pow(16000.0 / 30.0, float(i + 1) / AudioDirector.BAND_COUNT)
		total += spectrum.get_magnitude_for_frequency_range(lo, hi).length()
	return total
