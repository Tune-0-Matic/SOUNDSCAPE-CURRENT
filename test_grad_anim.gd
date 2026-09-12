extends SceneTree
## Runnable check for the gradient animation modes and the rotator:
##   - STATIC never drifts frame to frame.
##   - FADE/LEFT_RIGHT/WAVE all visibly move over time.
##   - the rotator advances color_index to the next gradient after its period, and
##     only while a gradient is actually selected.
##   godot --headless --path . --script res://test_grad_anim.gd

func _initialize() -> void:
	var viz := Visualizer.new()
	viz._ready()   # never entered a tree, so the band buffers _process indexes need
	               # this called directly -- same call Godot would make on add_child
	# _process bails out immediately with no director at all; a bare one with nothing
	# attached is enough -- levels/energy just read as their zero defaults
	viz.director = AudioDirector.new()

	var a := Gradient.new()
	a.offsets = PackedFloat32Array([0.0, 1.0])
	a.colors = PackedColorArray([Color.RED, Color.BLUE])
	var b := Gradient.new()
	b.offsets = PackedFloat32Array([0.0, 1.0])
	b.colors = PackedColorArray([Color.GREEN, Color.YELLOW])
	viz.gradients = [a, b]
	viz.color_index = viz.PRESETS.size() + 1   # first gradient

	var ok := true

	# STATIC: color_at(t) must not depend on _hue at all
	viz.color_anim = Visualizer.ColorAnim.STATIC
	var c1 := viz.color_at(0.5)
	viz._hue = 0.7   # simulate time having passed
	var c2 := viz.color_at(0.5)
	var static_ok := c1.is_equal_approx(c2)
	ok = ok and static_ok
	print("STATIC unaffected by _hue drift: %s" % static_ok)

	# FADE / LEFT_RIGHT / WAVE: color_at(t) must differ SOMEWHERE across a hue sweep.
	# A single before/after snapshot risks landing on a coincidental zero-crossing (WAVE's
	# sine term is exactly 0 at more than one hue), so this samples several points instead.
	for mode in [Visualizer.ColorAnim.FADE, Visualizer.ColorAnim.LEFT_RIGHT, Visualizer.ColorAnim.WAVE]:
		viz.color_anim = mode
		var first: Color = Color.BLACK
		var moved := false
		for step in 5:
			viz._hue = float(step) * 0.2
			var c := viz.color_at(0.5)
			if step == 0:
				first = c
			elif not c.is_equal_approx(first):
				moved = true
		ok = ok and moved
		print("mode %d animates over a hue sweep: %s" % [mode, moved])
	viz._hue = 0.0

	# rotator: two gradients, rotate on, tick past the period -- must land on the OTHER one
	viz.rotate_gradients = true
	viz.color_index = viz.PRESETS.size() + 1   # gradient 0 (a)
	for _f in 25:   # 25 * 1s = comfortably past ROTATE_PERIOD_SEC (20s)
		viz._process(1.0)
	var rotated := viz.gradient_index() == 1
	ok = ok and rotated
	print("rotator advanced past its period: gradient_index=%d (want 1): %s" % [
		viz.gradient_index(), rotated])

	# rotator must NOT touch color_index while a fixed preset (not a gradient) is active
	viz.color_index = 0
	for _f in 25:
		viz._process(1.0)
	var untouched := viz.color_index == 0
	ok = ok and untouched
	print("rotator leaves a fixed preset alone: %s" % untouched)

	print("RESULT ", "PASS" if ok else "FAIL")
	viz.free()
	quit(0 if ok else 1)
