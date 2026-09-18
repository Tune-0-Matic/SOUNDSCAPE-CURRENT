extends SceneTree
## Runnable check that the FX rack's scroll wheel keeps every module parameter on its own
## scale. For each parameter of each module, through the real bar and its real handler:
##   1. one lone tick moves exactly BAR_WHEEL_FINE of that parameter's range, and ten lone
##      ticks land exactly ten steps up -- no drift through the 0..1 round trip
##   2. the bar and the stored value agree after the moves
##   3. ticks clamp at both ends of the range
##   4. a fast burst accelerates past ten plain steps and still never leaves the range
##   godot --headless --path . --script res://test_rack_wheel.gd

func _tick(p: Object, bar: ProgressBar, ev: InputEventMouseButton, lone: bool) -> void:
	if lone:
		p.set("_wheel_last_ms", -10000)   # far enough back that the accelerator is idle
	bar.gui_input.emit(ev)

func _initialize() -> void:
	var p := PanelContainer.new()
	p.set_script(load("res://player.gd"))
	var rack := FxRack.new()
	(p.get("_rack_decks") as Array).append(rack)   # deck 0's rack; the rows take a deck index
	var parent := VBoxContainer.new()
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	var fine: float = p.get("BAR_WHEEL_FINE")
	var ok := true
	var checked := 0
	for type in FxRack.MODULES:
		for key in FxRack._params(type):
			var spec: Array = FxRack._params(type)[key]
			var lo: float = spec[1]
			var hi: float = spec[2]
			var eps := (hi - lo) * 1e-6
			p.call("_rack_row", 0, parent, type, key)
			var bar: ProgressBar = (p.get("_rack_bars")[0] as Dictionary)["%s/%s" % [type, key]][0]
			rack.set_param(type, key, lo)
			_tick(p, bar, up, true)
			var one := absf(float(rack.fx[type][key]) - (lo + (hi - lo) * fine)) <= eps
			for _k in 9:
				_tick(p, bar, up, true)
			var ten := absf(float(rack.fx[type][key]) - (lo + (hi - lo) * fine * 10.0)) <= eps
			var synced := absf(bar.value - inverse_lerp(lo, hi, float(rack.fx[type][key])) * 100.0) <= 1e-6
			for _k in 80:
				_tick(p, bar, up, true)
			var top := absf(float(rack.fx[type][key]) - hi) <= eps
			for _k in 80:
				_tick(p, bar, down, true)
			var bottom := absf(float(rack.fx[type][key]) - lo) <= eps
			rack.set_param(type, key, lo)
			p.set("_wheel_last_ms", Time.get_ticks_msec())   # a spin already under way
			p.set("_wheel_gain", 1.0)
			for _k in 10:
				_tick(p, bar, up, false)
			var burst := float(rack.fx[type][key])
			var accel := burst > lo + (hi - lo) * fine * 10.0 + eps and burst <= hi
			var good := one and ten and synced and top and bottom and accel
			ok = ok and good
			checked += 1
			if not good:
				print("  %s/%s: one %s ten %s synced %s top %s bottom %s accel %s" % [
					type, key, one, ten, synced, top, bottom, accel])
	print("wheel steps exact, synced, clamped and accelerating on all %d rack parameters: %s" % [checked, ok])
	parent.free()
	rack.free()
	p.free()
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
