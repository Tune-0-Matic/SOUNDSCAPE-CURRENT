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

	player.stop()
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
