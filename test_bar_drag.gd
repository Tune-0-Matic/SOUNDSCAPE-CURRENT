extends SceneTree
## Runnable check for the fader mouse-grab fix. Godot delivers an uncaptured mouse-motion
## event (button held, pressed nowhere in particular) to whatever Control is currently
## under the pointer -- so a drag that started off every fader could sweep across one and
## start moving it, with no click ever landing inside that fader's own rect. _bar_drag
## must refuse a motion event for any bar except the one the button actually went down on.
##   godot --headless --path . --script res://test_bar_drag.gd

func _initialize() -> void:
	var p := PanelContainer.new()
	p.set_script(load("res://player.gd"))

	var bar_a := Control.new()
	bar_a.size = Vector2(100, 20)
	var bar_b := Control.new()
	bar_b.size = Vector2(100, 20)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame

	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT

	var ok := true
	var r1: bool = p.call("_bar_drag", press, bar_a)          # press lands on bar_a
	var r2: bool = p.call("_bar_drag", motion, bar_b)          # motion strays onto bar_b
	var r3: bool = p.call("_bar_drag", motion, bar_a)          # motion stays on bar_a
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame
	var r4: bool = p.call("_bar_drag", motion, bar_a)          # stale motion after release

	for pair in [[r1, true], [r2, false], [r3, true], [r4, false]]:
		if pair[0] != pair[1]:
			ok = false
	print("RESULT ", "PASS" if ok else "FAIL",
		" (press-on-armed=%s cross-to-other=%s stay-on-armed=%s after-release=%s)" % [r1, r2, r3, r4])

	bar_a.free()
	bar_b.free()
	p.free()
	quit(0 if ok else 1)
