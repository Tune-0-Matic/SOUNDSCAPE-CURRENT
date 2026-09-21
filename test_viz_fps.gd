extends SceneTree
## Runnable check that the visualizer is time-invariant across frame-rate caps, and that an
## idle feed empties every mode while the ambient animation keeps moving:
##   1. bar attack/release and the peak caps hold the same values at the same wall-clock
##      instants whether _process runs at 60, 144 or 240 Hz
##   2. the stepped modes advance at one rate: WATERFALL writes 60 rows a second at all three
##   3. playback stopped: bars and caps read exactly 0, and GRID, WATERFALL and FIRE empty
##      themselves instead of freezing on their last frame -- while the hue keeps drifting
## The director never enters the tree, so nothing but this script writes its levels; a real,
## playing AudioStreamPlayer is what makes is_live() true.
##   4. nobody can see it: inside a SubViewport switched to UPDATE_DISABLED -- what its container
##      does while a Video TEST picture hides the cell -- _process does no work, and wakes when on
##   5. the field shader is on for WATERFALL and FIRE only, and comes off when either is left
##   6. the MUSTANG car's silhouette holds up, and SNAKE is still the last mode in the enum
##   godot --headless --path . --script res://test_viz_fps.gd

const RATES := [60.0, 144.0, 240.0]
## Every probe is a whole number of frames at all three rates (1/12 s is 5, 12 and 20).
const PROBE_TWELFTHS := [1, 3, 6, 12]

func _viz(director: AudioDirector) -> Visualizer:
	var viz := Visualizer.new()
	viz._ready()   # never enters a tree; this builds the band buffers _process indexes
	viz.director = director
	return viz

## Steps `viz` for one second at `hz`, returning _v[0] and _peak[0] at each probe instant.
func _probe(viz: Visualizer, hz: float) -> Array[float]:
	var out: Array[float] = []
	var frame := 0
	for twelfths in PROBE_TWELFTHS:
		var until: int = int(hz) * twelfths / 12
		while frame < until:
			viz._process(1.0 / hz)
			frame += 1
		out.append(viz._v[0])
		out.append(viz._peak[0])
	return out

func _run(viz: Visualizer, hz: float, secs: float) -> void:
	for _i in int(roundf(hz * secs)):
		viz._process(1.0 / hz)

func _start(player: AudioStreamPlayer) -> void:
	player.play()
	var guard := 0
	while not player.playing and guard < 120:
		await process_frame
		guard += 1

func _initialize() -> void:
	var player := AudioStreamPlayer.new()
	root.add_child(player)
	await process_frame   # play() on a node added during _initialize fails until it is in the tree
	var silence := AudioStreamWAV.new()
	silence.format = AudioStreamWAV.FORMAT_16_BITS
	silence.mix_rate = 22050
	var buf := PackedByteArray()
	buf.resize(22050 * 2 * 120)
	silence.data = buf
	player.stream = silence
	await _start(player)
	var director := AudioDirector.new()
	director.attach(player)
	# Without a feed that is really live, every trace below is all zeros -- and zeros match
	# at every rate, so the invariance check would pass while measuring nothing.
	var ok: bool = player.playing and director.is_live()
	print("feed is live for the ballistics checks: %s" % ok)

	# 1. ballistics: a full-scale step up, then down, sampled at the same instants
	var curves := {}
	for hz in RATES:
		var viz := _viz(director)
		director.levels.fill(1.0)
		var trace := _probe(viz, hz)
		director.levels.fill(0.0)
		trace.append_array(_probe(viz, hz))
		curves[hz] = trace
		viz.free()
	var worst := 0.0
	for hz in RATES:
		var trace: Array = curves[hz]
		var ref: Array = curves[60.0]
		for k in trace.size():
			worst = maxf(worst, absf(float(trace[k]) - float(ref[k])))
	# ...and the traces must actually MOVE: bars near full height 1/12 s after the rise,
	# near the floor a second after the fall, so a flat-zero trace cannot pass as invariant
	var ref60: Array = curves[60.0]
	var moved: bool = float(ref60[0]) > 0.5 and float(ref60[ref60.size() - 2]) < 0.1
	var same := worst < 0.01 and moved
	ok = ok and same
	print("attack, release and peak fall match at 60/144/240 Hz: %s (worst gap %.5f of full height)" % [same, worst])
	print("   60 Hz [v, peak] at 1/12, 3/12, 6/12, 1 s after the rise, then after the fall: %s" % [curves[60.0]])

	# 2. stepped modes: one row per REF_FPS step whatever the render rate
	var rows: Array[int] = []
	for hz in RATES:
		var viz := _viz(director)
		viz.mode = Visualizer.Mode.WATERFALL
		director.levels.fill(1.0)
		var start: int = viz._wf_row
		_run(viz, hz, 1.0)
		rows.append(posmod(viz._wf_row - start, Visualizer.WF_HEIGHT))
		viz.free()
	var rate_ok := true
	for r in rows:
		rate_ok = rate_ok and absi(r - 60) <= 1
	ok = ok and rate_ok
	print("WATERFALL rows per second at 60/144/240 Hz: %s (want 60 each): %s" % [rows, rate_ok])

	# 3. stopped: every stepped mode empties, and the hue keeps moving
	for mode in [Visualizer.Mode.GRID, Visualizer.Mode.WATERFALL, Visualizer.Mode.FIRE]:
		await _start(player)
		var viz := _viz(director)
		viz.mode = mode
		viz.color_index = Visualizer.PRESETS.size()   # the rainbow slot, so the hue drifts
		director.levels.fill(1.0)
		_run(viz, 144.0, 1.0)
		var lit := _residue(viz, mode) > 0.0
		player.stop()
		var hue0: float = viz._hue
		_run(viz, 144.0, 8.0)
		var bars_zero := true
		for i in AudioDirector.BAND_COUNT:
			bars_zero = bars_zero and viz._v[i] == 0.0 and viz._peak[i] == 0.0
		var left := _residue(viz, mode)
		var drifting := not is_equal_approx(viz._hue, hue0)
		var empty := lit and bars_zero and left == 0.0 and drifting
		ok = ok and empty
		print("%s: lit while playing %s; stopped 8 s -> bars at 0 %s, residue %.5f, hue still drifting %s: %s" % [
			Visualizer.Mode.keys()[mode], lit, bars_zero, left, drifting, empty])
		viz.free()

	# 4. inside a disabled SubViewport nothing moves; switched back on, the bars rise. The viewport
	# is disabled BEFORE the visualizer enters it: the engine steps _process once on the way in,
	# and that frame must already see a viewport nobody can look at.
	await _start(player)
	var sub := SubViewport.new()
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(sub)
	var hidden := Visualizer.new()
	hidden.director = director
	director.levels.fill(1.0)
	sub.add_child(hidden)
	await process_frame
	hidden.set_process(false)   # stepped by hand from here on, as everywhere in this test
	hidden.color_index = Visualizer.PRESETS.size()   # the rainbow slot, so the hue would drift
	var hue_before: float = hidden._hue
	_run(hidden, 60.0, 0.5)
	var idle: bool = hidden._v[0] == 0.0 and hidden._hue == hue_before
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_run(hidden, 60.0, 0.5)
	var wakes: bool = hidden._v[0] > 0.5
	var skipped := idle and wakes
	ok = ok and skipped
	print("inside a disabled SubViewport: bars held at 0 and the hue still %s; viewport back on, bars rose %s: %s" % [
		idle, wakes, skipped])
	sub.queue_free()

	# 5. the field shader is on for WATERFALL and FIRE only: leaving FIRE takes it off again, or
	# every later mode draws through it and loses its colours
	var shader_viz := _viz(director)
	var mats := []
	for mode in [Visualizer.Mode.FIRE, Visualizer.Mode.CRUISE, Visualizer.Mode.WATERFALL, Visualizer.Mode.SEGMENTS]:
		shader_viz.mode = mode
		shader_viz._sync_field_material()
		mats.append(shader_viz.material != null)
	var field_only: bool = mats == [true, false, true, false]
	ok = ok and field_only
	print("field shader on for FIRE / CRUISE / WATERFALL / SEGMENTS in turn: %s: %s" % [mats, field_only])
	shader_viz.free()

	# 6. the New Edge silhouette: the tri-bar lights, the roof as the highest point, nothing
	# left ahead of the cabin to bleed through the trunk. Pure geometry, no viewport.
	var shape := Mustang.model_test()
	ok = ok and shape
	print("mustang rear silhouette (tri-bars, roofline, stance, nothing ahead): %s" % shape)
	# the car hides its own back faces against a camera it holds as a constant; if the
	# visualizer's camera moves, it is pruning itself for a view nobody is looking from
	# to a tolerance, not exactly: a Vector3 holds float32, so EYE.y is 1.2999999523 against
	# the const's float64 1.30 and an == here fails on a camera that has not moved at all
	var eye_agrees: bool = absf(Mustang.EYE.y - Visualizer.EYE_Y) < 0.001 \
		and absf(Mustang.EYE.z + Visualizer.CAR_Z) < 0.001 and absf(Mustang.EYE.x) < 0.001
	ok = ok and eye_agrees
	print("the car's cull camera still matches the visualizer's (%s vs %.2f up / %.2f back): %s" % [
		Mustang.EYE, Visualizer.EYE_Y, Visualizer.CAR_Z, eye_agrees])
	# and MUSTANG must not have landed after SNAKE, which is the slot player.gd hides
	var last_is_snake: bool = Visualizer.Mode.keys()[Visualizer.Mode.size() - 1] == "SNAKE"
	ok = ok and last_is_snake
	print("SNAKE is still the last mode (the unlock gate hides the last one): %s" % last_is_snake)

	player.stop()
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

## What a stepped mode is still showing: the brightest cell it would draw.
func _residue(viz: Visualizer, mode: int) -> float:
	var most := 0.0
	match mode:
		Visualizer.Mode.GRID:
			for row in viz._grid:
				for v in row:
					most = maxf(most, v)
		# both fields hold a MAGNITUDE per cell now, one byte each, and the shader decides
		# every colour -- so what is left on screen is read from the buffer that feeds the
		# GPU rather than from a colour the CPU no longer computes
		Visualizer.Mode.WATERFALL:
			for b in viz._wf_bytes:
				most = maxf(most, float(b) / 255.0)
		Visualizer.Mode.FIRE:
			for b in viz._fire_bytes:
				most = maxf(most, float(b) / 255.0)
	return most
