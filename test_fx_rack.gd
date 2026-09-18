extends SceneTree
## The RT-safety guarantee, asserted against a live bus with audio running through it:
## adding and removing rack modules must allocate NOTHING and must not interrupt the
## feed. Concretely --
##   1. the bus effect COUNT is identical before, during and after every rack change
##      (nothing is inserted or removed at runtime, so the driver lock is never taken
##      to rebuild the chain and no cached effect instance is ever invalidated);
##   2. the analyser's energy never collapses while modules are cycled through, i.e.
##      no starved buffer and no silence gap;
##   3. enabling a module actually flips its slot, so "costs nothing" is not achieved
##      by the rack quietly doing nothing at all.
##   5. CLEAR ALL with every module in at once: one pass switches every slot out (fourteen effects for
##      eleven modules, TAPE, T-BASS and BBE being two each, plus a TAP and a BLEND around each), the count holds,
##      and the Master analyser keeps the exact instance it bound -- nothing on any bus was rebuilt.
##   6. the deck limiter ends the bus, after every rack slot, and the Equalizer still switches its
##      boost and limiter on by identity now that the rack has moved the limiter
##   7. MIX is a true parallel crossfade (SsParallel): around a -12 dB wet path on a live bus, MIX 0
##      is the dry signal BIT-IDENTICAL, MIX 1 the wet signal alone, and MIX 0.25 exactly
##      0.75 dry + 0.25 wet -- not a depth control on the effect
##   8. the bypass contract, for T-BASS and BBE on a bus of their own: at MIX 1 each changes the signal;
##      at MIX 0 the whole module -- TAP, effects, BLEND -- is switched out once its BLEND has ramped
##      down, and the output is the dry signal BIT-IDENTICAL; removed, the same; and the DSP AUTOPSY
##      counts a MIX 0 module as switched out, not active
##   godot --headless --path . --script res://test_fx_rack.gd

func _initialize() -> void:
	Engine.max_fps = 60
	var engine := AudioEngine.new()
	root.add_child(engine)
	var director := AudioDirector.new()
	root.add_child(director)
	await process_frame
	await process_frame

	var bus_name := engine.deck_bus(0)
	var eq := Equalizer.new()
	root.add_child(eq)
	eq.setup(bus_name)
	var rack := FxRack.new()
	root.add_child(rack)
	rack.setup(bus_name)
	director.rebind()
	await process_frame

	var bus := AudioServer.get_bus_index(bus_name)
	var baseline := AudioServer.get_bus_effect_count(bus)

	var player := AudioStreamPlayer.new()
	player.bus = bus_name
	root.add_child(player)
	var sr := 44100
	var n := int(sr * 20.0)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in n:
		var t := float(i) / sr
		var v := (sin(TAU * 220.0 * t) + sin(TAU * 277.2 * t) + sin(TAU * 330.0 * t)) / 3.0
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0 * 0.7))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	player.stream = s
	player.play()
	director.attach(player)
	var guard := 0
	while not player.playing and guard < 120:
		await process_frame
		guard += 1
	for _f in 25:
		await process_frame

	var ok := true
	var counts := {}
	var min_energy := INF
	var engaged := {}

	# cycle the whole rack in and out, twice, watching the bus the entire time
	for pass_i in 2:
		for type in FxRack.MODULES:
			rack.add_module(type)
			for _f in 4:
				await process_frame
				counts[AudioServer.get_bus_effect_count(bus)] = true
				min_energy = minf(min_energy, director.energy)
			# did the slot actually turn on?
			var any_on := false
			for slot in rack._idx[type]:
				any_on = any_on or AudioServer.is_bus_effect_enabled(bus, slot)
			engaged[type] = any_on
			rack.remove_module(type)
			for _f in 3:
				await process_frame
				counts[AudioServer.get_bus_effect_count(bus)] = true
				min_energy = minf(min_energy, director.energy)

	# 1. the effect count never moved
	var count_stable: bool = counts.size() == 1 and counts.has(baseline)
	ok = ok and count_stable
	print("effect count constant across every add/remove: %s (saw %s, baseline %d)"
		% [count_stable, counts.keys(), baseline])

	# 2. the feed never starved
	var fed := min_energy > 0.01
	ok = ok and fed
	print("analyser never starved while cycling the rack: %s (min energy %.5f)"
		% [fed, min_energy])

	# 3. every module actually engaged its slot
	var all_engaged := true
	var dead: Array[String] = []
	for type in engaged:
		if not engaged[type]:
			all_engaged = false
			dead.append(type)
	ok = ok and all_engaged
	print("every module engaged its pre-allocated slot: %s%s"
		% [all_engaged, "" if all_engaged else "  (dead: %s)" % ", ".join(dead)])

	# 4. a rack left switched off leaves every slot disabled -- an empty rack is silent,
	# not "all modules at zero depth"
	rack.clear()
	for _f in 5:
		await process_frame
	var all_off := true
	for type in FxRack.MODULES:
		for slot in rack._idx[type]:
			all_off = all_off and not AudioServer.is_bus_effect_enabled(bus, slot)
	ok = ok and all_off
	print("cleared rack leaves every slot switched out: %s" % all_off)

	# 5. CLEAR ALL from a FULL rack, in one pass, with the analyser handle checked by identity
	var master := AudioServer.get_bus_index("Master")
	var handle = director.get("_spectrum")
	var slots := 0
	for type in FxRack.MODULES:
		rack.add_module(type)
		slots += (rack._idx[type] as Array).size()
	for _f in 5:
		await process_frame
	var full := true
	for type in FxRack.MODULES:
		for slot in rack._idx[type]:
			full = full and AudioServer.is_bus_effect_enabled(bus, slot)
	rack.clear()
	rack._process(0.0)   # exactly one _push, no frame in between
	var one_pass := true
	for type in FxRack.MODULES:
		for slot in rack._idx[type]:
			one_pass = one_pass and not AudioServer.is_bus_effect_enabled(bus, slot)
	for _f in 10:
		await process_frame
	var handle_live := false
	for i in AudioServer.get_bus_effect_count(master):
		handle_live = handle_live or AudioServer.get_bus_effect_instance(master, i) == handle
	var want_slots := 14 + (2 * FxRack.MODULES.size() if ClassDB.class_exists("SsParallel") else 0)
	var cleared: bool = slots == want_slots and full and one_pass and handle_live \
		and AudioServer.get_bus_effect_count(bus) == baseline and director.energy > 0.01
	ok = ok and cleared
	print("CLEAR ALL: %d slots all on -> one pass all off %s, count %d == %d, analyser handle live %s, energy %.4f: %s" % [
		slots, one_pass, AudioServer.get_bus_effect_count(bus), baseline, handle_live, director.energy, cleared])

	# 6. the deck limiter is LAST on the bus, past every rack slot
	var last := AudioServer.get_bus_effect(bus, AudioServer.get_bus_effect_count(bus) - 1)
	var rack_max := 0
	for type in FxRack.MODULES:
		for slot in rack._idx[type]:
			rack_max = maxi(rack_max, slot)
	eq.set_boost(6.0)
	eq._push()
	var lim_slot := -1
	var boost_slot := -1
	for i in AudioServer.get_bus_effect_count(bus):
		if AudioServer.get_bus_effect(bus, i) == eq.get("_limiter"):
			lim_slot = i
		if AudioServer.get_bus_effect(bus, i) == eq.get("_boost"):
			boost_slot = i
	var limited: bool = last is AudioEffectHardLimiter and lim_slot == AudioServer.get_bus_effect_count(bus) - 1 \
		and rack_max < lim_slot and boost_slot < rack_max \
		and AudioServer.is_bus_effect_enabled(bus, lim_slot) and AudioServer.is_bus_effect_enabled(bus, boost_slot)
	ok = ok and limited
	print("deck limiter last on the bus at slot %d, rack ends at %d, boost at %d; boost + limiter switched on by identity: %s" % [
		lim_slot, rack_max, boost_slot, limited])

	player.stop()

	# 7. a true parallel crossfade around a wet path, measured on a bus of its own
	# 8. T-BASS and BBE: bit-exact dry at MIX 0 and removed
	if ClassDB.class_exists("SsParallel"):
		var par := await _parallel_crossfade()
		ok = ok and par
		var bypass := await _bypass_contract()
		ok = ok and bypass
	else:
		print("SsParallel not registered: parallel wet/dry not checked (libsoundscape_dsp not built)")

	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

const PAR_FRAMES := 4096
const WET_DB := -12.0

func _parallel_crossfade() -> bool:
	var pbus := AudioServer.bus_count
	AudioServer.add_bus(pbus)
	AudioServer.set_bus_name(pbus, "ParallelVerify")
	AudioServer.set_bus_send(pbus, "Master")
	AudioServer.set_bus_mute(pbus, true)
	var tap: AudioEffect = ClassDB.instantiate("SsParallel")
	var blend: AudioEffect = tap.call("make_blend")
	var wet := AudioEffectAmplify.new()
	wet.volume_db = WET_DB
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	for effect in [tap, wet, blend, capture]:
		AudioServer.add_bus_effect(pbus, effect)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()   # nothing resamples between the push and the bus
	gen.buffer_length = 0.5
	var src := AudioStreamPlayer.new()
	src.stream = gen
	src.bus = "ParallelVerify"
	root.add_child(src)
	await process_frame
	src.play()
	await process_frame
	var pb: AudioStreamGeneratorPlayback = src.get_stream_playback()
	var gain := db_to_linear(WET_DB)
	var sent := PackedVector2Array()
	sent.resize(PAR_FRAMES)
	for i in PAR_FRAMES:
		sent[i] = Vector2(sin(float(i) * 0.1073) * 0.61 + 0.013, cos(float(i) * 0.0731) * 0.43 - 0.017)
	var ok := true
	for mix in [0.0, 1.0, 0.25]:
		tap.call("set_mix", mix)
		for _f in 10:   # let the per-block ramp land on the new MIX before measuring
			await process_frame
		var got := await _through(pb, capture, sent)
		var want := func(v: Vector2) -> Vector2: return v * (1.0 - mix) + v * gain * mix
		var at := -1
		for start in maxi(got.size() - 64, 0):
			var hit := true
			for i in 64:
				if (got[start + i] - want.call(sent[i])).length() > 1e-6:
					hit = false
					break
			if hit:
				at = start
				break
		var worst := INF
		var exact := false
		if at >= 0:
			worst = 0.0
			exact = true
			for i in mini(PAR_FRAMES, got.size() - at):
				worst = maxf(worst, (got[at + i] - want.call(sent[i])).length())
				exact = exact and got[at + i] == sent[i]
		var good: bool = at >= 0 and (exact if mix == 0.0 else worst <= 1e-6)
		ok = ok and good
		print("7. MIX %.2f around a %.0f dB wet path: output = %.2f dry + %.2f wet, worst error %s%s: %s" % [
			mix, WET_DB, 1.0 - mix, mix, "%.10f" % worst if at >= 0 else "(not found)",
			" (bit-identical to the dry signal)" if exact else "", good])
	src.stop()
	src.queue_free()
	await process_frame
	AudioServer.remove_bus(pbus)
	return ok

## Pushes `frames` through the generator in one run (its 0.5 s buffer holds them), lets the bus
## drain, and returns everything the capture saw.
func _through(pb: AudioStreamGeneratorPlayback, capture: AudioEffectCapture, frames: PackedVector2Array) -> PackedVector2Array:
	capture.clear_buffer()
	var pushed := 0
	var guard := 0
	while pushed < frames.size() and guard < 600:
		var room: int = mini(pb.get_frames_available(), frames.size() - pushed)
		# ONE push_buffer, not a GDScript loop of push_frame: the audio thread reads the generator while
		# frames go in, and a loop it overtakes leaves silence mid-run (caught: a gap at frame 489)
		pb.push_buffer(frames.slice(pushed, pushed + room))
		pushed += room
		await process_frame
		guard += 1
	# until the whole run has come through, not a fixed count of frames: a loaded suite run can leave
	# the audio thread behind the main loop, and a capture read early is a truncated one
	var margin := int(AudioServer.get_mix_rate() * 0.05)
	while capture.get_frames_available() < frames.size() + margin and guard < 1200:
		await process_frame
		guard += 1
	return capture.get_buffer(capture.get_frames_available())

## Whether `sent` came out of the bus untouched: found by an exact 64-frame run, then equal throughout.
static func _bit_identical(got: PackedVector2Array, sent: PackedVector2Array) -> bool:
	for start in maxi(got.size() - sent.size() + 1, 0):
		if got[start] != sent[0]:
			continue
		var same := true
		for i in sent.size():
			if got[start + i] != sent[i]:
				same = false
				break
		if same:
			return true
	return false

func _slots_all(rack: FxRack, type: String, bus: int, on: bool) -> bool:
	for slot in rack._idx[type]:
		if AudioServer.is_bus_effect_enabled(bus, slot) != on:
			return false
	return true

func _bypass_contract() -> bool:
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "BypassVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var rack := FxRack.new()
	root.add_child(rack)
	rack.setup("BypassVerify")
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus, capture)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.5
	var src := AudioStreamPlayer.new()
	src.stream = gen
	src.bus = "BypassVerify"
	root.add_child(src)
	await process_frame
	src.play()
	await process_frame
	var pb: AudioStreamGeneratorPlayback = src.get_stream_playback()
	# bass for T-BASS, treble and a real side channel for BBE, awkward mantissas for exactness
	var sent := PackedVector2Array()
	sent.resize(PAR_FRAMES)
	for i in PAR_FRAMES:
		var bass := sin(float(i) * 0.0041) * 0.37
		sent[i] = Vector2(bass + sin(float(i) * 0.4173) * 0.21 + 0.013, bass + cos(float(i) * 0.2731) * 0.19 - 0.017)
	var player_gd: GDScript = load("res://player.gd")
	var ok := true
	for type in ["tbass", "bbe"]:
		rack.add_module(type)
		rack.set_param(type, "mix", 1.0)
		for _f in 10:
			await process_frame
		var wet_in := _slots_all(rack, type, bus, true)
		var changed := not _bit_identical(await _through(pb, capture, sent), sent)
		rack.set_param(type, "mix", 0.0)
		var waited := 0
		while not _slots_all(rack, type, bus, false) and waited < 120:
			await process_frame
			waited += 1
		var parked := _slots_all(rack, type, bus, false)
		var counted: bool = player_gd.autopsy_fx(rack)[1] == "ACTIVE MODULES: 0  (+1 AT MIX 0, SWITCHED OUT)"
		var dry_at_zero := _bit_identical(await _through(pb, capture, sent), sent)
		rack.set_param(type, "mix", 1.0)
		for _f in 10:
			await process_frame
		var back := _slots_all(rack, type, bus, true)
		rack.remove_module(type)
		for _f in 5:
			await process_frame
		var removed_out := _slots_all(rack, type, bus, false)
		var dry_removed := _bit_identical(await _through(pb, capture, sent), sent)
		var good := wet_in and changed and parked and counted and dry_at_zero and back and removed_out and dry_removed
		ok = ok and good
		print("8. %s: MIX 1 in circuit %s, changes the signal %s; MIX 0 switched out after %d frames %s, autopsy counts it out %s, output BIT-IDENTICAL dry %s; back in at MIX 1 %s; removed: out %s, BIT-IDENTICAL dry %s: %s" % [
			FxRack.module_name(type), wet_in, changed, waited, parked, counted, dry_at_zero, back, removed_out, dry_removed, good])
	src.stop()
	src.queue_free()
	rack.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)
	return ok
