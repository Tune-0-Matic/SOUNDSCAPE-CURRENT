extends SceneTree
## Runnable check for the gradient offset-drag strip: dragging a tick moves ONLY that
## stop's offset, a motion event with no prior press on this strip changes nothing, and
## a drag cannot push a stop past its neighbour (Gradient does not resort out-of-order
## points, so crossing would leave them silently unsorted).
##   godot --headless --path . --script res://test_grad_strip.gd

func _initialize() -> void:
	var p := PanelContainer.new()
	p.set_script(load("res://player.gd"))

	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([Color.RED, Color.GREEN])

	var strip: Control = p.call("_make_grad_strip", grad, func() -> void: pass)
	strip.size = Vector2(100, 24)

	var ok := true

	# no press yet: a stray motion event must not move anything
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = Vector2(50, 0)
	strip.emit_signal("gui_input", motion)
	var untouched := is_equal_approx(grad.get_offset(0), 0.0) and is_equal_approx(grad.get_offset(1), 1.0)
	ok = ok and untouched
	print("motion with no prior press changes nothing: %s" % untouched)

	# press near the second tick (offset 1.0 * width 100 = x100), then drag to the middle
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(96, 0)
	strip.emit_signal("gui_input", press)
	motion.position = Vector2(50, 0)
	strip.emit_signal("gui_input", motion)
	var moved := absf(grad.get_offset(1) - 0.5) < 0.02 and is_equal_approx(grad.get_offset(0), 0.0)
	ok = ok and moved
	print("dragged tick 1 to the middle, tick 0 untouched: offset1=%.3f offset0=%.3f (%s)" % [
		grad.get_offset(1), grad.get_offset(0), moved])

	# try to drag it PAST tick 0 (offset 0.0) -- must clamp just above it, never cross
	motion.position = Vector2(-50, 0)
	strip.emit_signal("gui_input", motion)
	var clamped := grad.get_offset(1) > grad.get_offset(0) and grad.get_offset(1) < 0.02
	ok = ok and clamped
	print("dragged past the other tick: offset1=%.4f offset0=%.4f, still ordered (%s)" % [
		grad.get_offset(1), grad.get_offset(0), clamped])

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	strip.emit_signal("gui_input", release)
	var after_release := grad.get_offset(1)
	motion.position = Vector2(80, 0)
	strip.emit_signal("gui_input", motion)
	var no_move_after_release := is_equal_approx(grad.get_offset(1), after_release)
	ok = ok and no_move_after_release
	print("motion after release changes nothing further: %s" % no_move_after_release)

	print("RESULT ", "PASS" if ok else "FAIL")
	strip.free()
	p.free()
	quit(0 if ok else 1)
