extends SceneTree
## Runnable check for the ONE path through SsWavStream / resampler.h that nothing in SOUNDSCAPE
## drives yet: AudioStreamPlayer.pitch_scale, which arrives as `rate_scale` in StreamPlayer::mix
## and makes the sinc interpolate between kernel rows instead of walking one row per frame.
## resampler.h calls that path "untested audio"; this is the test.
##
##   1. the tone comes out at f0 * pitch, at 0.5, 1.0, 1.5 and 2.0
##   2. nothing tears: no silence gap (an underrun), no sample-to-sample jump a sine of that
##      frequency cannot make (a click), no NaN and no wild overshoot
##   3. changing pitch MID-PLAY leaves no click behind, and going back to 1.0 measures f0 again,
##      so the resampler's phase and window state survive the change
##   4. a stream played fast still ENDS, at about length / pitch
## Plays into its own bus and captures there, so no other effect is in the way.
##   godot --headless --path . --script res://test_pitch_scale.gd

const TONE_HZ := 1000.0
const TONE_SECS := 8.0
const SRC_RATE := 44100
const AMPLITUDE := 0.5
## Windows of this many frames must all carry signal: a gap means the mix ran dry.
const RMS_WINDOW := 256
const RMS_FLOOR := 0.05

var _player: AudioStreamPlayer
var _cap: AudioEffectCapture

func _wav(path: String) -> void:
	var n := int(SRC_RATE * TONE_SECS)
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		var v := int(sin(TAU * TONE_HZ * float(i) / float(SRC_RATE)) * AMPLITUDE * 32767.0)
		data.encode_s16(i * 4, v)
		data.encode_s16(i * 4 + 2, v)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("RIFF")
	f.store_32(36 + data.size())
	f.store_string("WAVEfmt ")
	f.store_32(16)
	f.store_16(1)
	f.store_16(2)
	f.store_32(SRC_RATE)
	f.store_32(SRC_RATE * 4)
	f.store_16(4)
	f.store_16(16)
	f.store_string("data")
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()

## Everything one capture can say about the audio in it.
func _measure(secs: float) -> Dictionary:
	_cap.clear_buffer()
	await create_timer(secs).timeout
	var buf := _cap.get_buffer(_cap.get_frames_available())
	var out := {"frames": buf.size(), "hz": 0.0, "peak": 0.0, "jump": 0.0, "quiet": 0, "bad": 0}
	if buf.is_empty():
		return out
	var crossings := 0
	var prev := buf[0].x
	var win := 0.0
	var win_n := 0
	for i in buf.size():
		var v := buf[i].x
		if is_nan(v) or is_inf(v):
			out["bad"] = int(out["bad"]) + 1
			continue
		out["peak"] = maxf(float(out["peak"]), absf(v))
		if i > 0:
			out["jump"] = maxf(float(out["jump"]), absf(v - prev))
			if (v >= 0.0) != (prev >= 0.0):
				crossings += 1
		prev = v
		win += v * v
		win_n += 1
		if win_n == RMS_WINDOW:
			if sqrt(win / float(RMS_WINDOW)) < RMS_FLOOR:
				out["quiet"] = int(out["quiet"]) + 1
			win = 0.0
			win_n = 0
	var mix := AudioServer.get_mix_rate()
	out["hz"] = float(crossings) * 0.5 * mix / float(buf.size())
	return out

## The biggest step a clean sine of `hz` can take between two frames at the mix rate, with room
## for the resampler's own ripple. Anything past this is a discontinuity, not a waveform.
func _max_step(hz: float) -> float:
	return TAU * hz / AudioServer.get_mix_rate() * AMPLITUDE * 3.0

func _initialize() -> void:
	if not ClassDB.class_exists("SsWavStream"):
		print("SKIP: libsoundscape_dsp did not load, so there is no sinc to drive")
		print("RESULT SKIP")
		quit(0)
		return
	var dir := ProjectSettings.globalize_path("user://pitch_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var tone := dir.path_join("tone.wav")
	_wav(tone)

	AudioServer.add_bus()
	var bus := AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus, "PitchTest")
	_cap = AudioEffectCapture.new()
	_cap.buffer_length = 1.0
	AudioServer.add_bus_effect(bus, _cap)
	_player = AudioStreamPlayer.new()
	_player.bus = "PitchTest"
	_player.stream = AudioEngine.native_wav(tone)
	root.add_child(_player)
	await process_frame
	var ok: bool = _player.stream != null
	print("tone loaded through SsWavStream: %s" % ok)

	# 1 + 2. each pitch on its own, from a fresh start
	for pitch in [1.0, 0.5, 1.5, 2.0]:
		_player.pitch_scale = pitch
		_player.play(1.0)
		await create_timer(0.3).timeout
		var m: Dictionary = await _measure(0.4)
		var want: float = TONE_HZ * float(pitch)
		var hz_ok: bool = absf(float(m["hz"]) - want) / want < 0.03
		var clean: bool = int(m["quiet"]) == 0 and int(m["bad"]) == 0 and float(m["peak"]) < 1.01 \
			and float(m["jump"]) < _max_step(want)
		ok = ok and hz_ok and clean
		print("pitch %.2f: %.0f Hz (want %.0f) %s | peak %.3f, worst step %.4f (max %.4f), gaps %d, NaN %d: %s" % [
			pitch, m["hz"], want, hz_ok, m["peak"], m["jump"], _max_step(want), m["quiet"], m["bad"], clean])
		_player.stop()

	# 3. the pitch changes UNDER a playing stream, twice, and the state survives it
	_player.pitch_scale = 1.0
	_player.play(1.0)
	await create_timer(0.3).timeout
	var during := {}
	for pitch in [1.5, 1.0]:
		_player.pitch_scale = pitch
		during[pitch] = await _measure(0.4)
	var shifted: Dictionary = during[1.5]
	var back: Dictionary = during[1.0]
	var live_ok: bool = absf(float(shifted["hz"]) - 1500.0) / 1500.0 < 0.03 \
		and absf(float(back["hz"]) - TONE_HZ) / TONE_HZ < 0.03 \
		and int(shifted["quiet"]) == 0 and int(back["quiet"]) == 0 \
		and float(shifted["jump"]) < _max_step(1500.0) and float(back["jump"]) < _max_step(TONE_HZ)
	ok = ok and live_ok
	print("pitch changed mid-play 1.0 -> 1.5 -> 1.0: %.0f then %.0f Hz, no gap, worst steps %.4f / %.4f: %s" % [
		shifted["hz"], back["hz"], shifted["jump"], back["jump"], live_ok])
	_player.stop()

	# 4. played at 2x, an 8 s tone ends in about 4 s rather than running on or hanging
	_player.pitch_scale = 2.0
	_player.play(TONE_SECS - 1.0)   # one second of source left, so half a second of output
	var started := Time.get_ticks_msec()
	while _player.playing and Time.get_ticks_msec() - started < 4000:
		await process_frame
	var took := (Time.get_ticks_msec() - started) / 1000.0
	var ended: bool = not _player.playing and took < 1.5
	ok = ok and ended
	print("the last second of source at 2x ended after %.2f s (want ~0.5, never hanging): %s" % [took, ended])

	_player.queue_free()
	await process_frame
	AudioServer.remove_bus(AudioServer.get_bus_index("PitchTest"))
	DirAccess.remove_absolute(tone)
	DirAccess.remove_absolute(dir)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
