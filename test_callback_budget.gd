extends SceneTree
## How much of one audio callback the native decode + resample path costs, worst case.
## Exit codes match the other native tests: 0 PASS, 1 FAIL, 2 SKIPPED without libsoundscape_dsp.
##
## One callback at a 96 kHz mix is 512 frames = 5.33 ms. Deck A plays DSD128 (the 1-bit FIR at
## 5.6 MHz, then the sinc from 352.8 kHz), deck B a 24-bit 44.1 kHz FLAC of white noise (the
## hardest-to-decode FLAC, through the sinc's worst ratio, 320:147). Both are rendered through
## render(), which drives the exact _mix the mixer calls in 512-frame blocks, and timed.
##
## shortcut: this times OUR code only, on the main thread. Godot's own effects (EQ21, the rack,
## reverb, limiters) and the mix itself are not reachable from script; timing the whole callback
## needs a C++ probe effect. The pass line is a QUARTER of the deadline, leaving the rest for them.
##   godot --headless --path . --script res://test_callback_budget.gd

const DIR := "user://budget_test"
const MIX := 96000
const BLOCK := 512
const SECS := 10.0
const DSD128 := 5644800
const DSF_BLOCK := 4096
const BUDGET_MS := 1000.0 * BLOCK / MIX   # 5.33
const PASS_SHARE := 0.25

func _initialize() -> void:
	if not ClassDB.class_exists("SsDsdStream") or not ClassDB.class_exists("SsFlacStream"):
		print("SKIPPED: libsoundscape_dsp is not built on this machine")
		print("RESULT SKIPPED")
		quit(2)
		return
	var base := ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(base)
	var dsf := base.path_join("deck_a.dsf")
	var flac := base.path_join("deck_b.flac")
	_write_dsf(dsf, int(DSD128 / 8 * SECS), DSD128)
	var made := OS.execute("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i",
		"anoisesrc=d=%d:r=44100:a=0.5" % int(SECS), "-ac", "2", "-c:a", "flac",
		"-sample_fmt", "s32", "-bits_per_raw_sample", "24", flac], [], true) == 0

	var ok := made
	var deck_ms := []
	for path in [dsf, flac]:
		var s: AudioStream = AudioEngine.native_dsd(path) if path.ends_with(".dsf") else AudioEngine.native_flac(path)
		if s == null:
			ok = false
			deck_ms.append(INF)
			continue
		deck_ms.append(_ms_per_block(s))
	var total: float = deck_ms[0] + deck_ms[1]
	var share := total / BUDGET_MS
	ok = ok and share < PASS_SHARE
	print("deck A DSD128 -> 96 kHz: %.4f ms per %d-frame block" % [deck_ms[0], BLOCK])
	print("deck B FLAC 24/44.1 noise -> 96 kHz: %.4f ms per block" % deck_ms[1])
	print("both decks: %.4f ms of the %.2f ms deadline = %.2f%% (pass under %d%%): %s" % [
		total, BUDGET_MS, share * 100.0, int(PASS_SHARE * 100.0), ok])

	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(base.path_join(f))
	DirAccess.remove_absolute(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

## Steady-state cost of one block. render() designs the kernel before it plays, so a one-block
## render is timed too and taken off: what is left is the per-block work the audio thread does.
## Best of three runs, so a scheduler hiccup on this machine does not read as the code's cost.
static func _ms_per_block(s: AudioStream) -> float:
	# from the stream's own length, a little inside it: DSD's comes out a hair under the nominal SECS
	var frames := int((s.get_length() - 0.1) * MIX)
	var best := INF
	for run in 3:
		var t0 := Time.get_ticks_usec()
		s.call("render", MIX, 0.0, BLOCK)
		var t1 := Time.get_ticks_usec()
		var out: PackedFloat32Array = s.call("render", MIX, 0.0, frames)
		var t2 := Time.get_ticks_usec()
		if out.size() < frames * 2:
			return INF   # the render came up short: a broken stream, not a fast one
		best = minf(best, float((t2 - t1) - (t1 - t0)) / 1000.0 / float(frames / BLOCK - 1))
	return best

## A DSF the decoder walks like any other. The bytes are a varied pattern, not a tone: the
## stage-1 FIR is one table lookup per byte whatever the byte is, so its cost does not care.
static func _write_dsf(path: String, per_channel: int, rate: int) -> void:
	var data := PackedByteArray()
	data.resize(DSF_BLOCK)
	for i in DSF_BLOCK:
		data[i] = (i * 37 + 11) & 0xFF
	while data.size() < per_channel * 2:
		data.append_array(data)
	data.resize(per_channel * 2)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("DSD ".to_ascii_buffer())
	f.store_64(28)
	f.store_64(28 + 52 + 12 + data.size())
	f.store_64(0)
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_64(52)
	for v in [1, 0, 2, 2, rate, 1]:   # version, format id, channel type, channels, rate, bits
		f.store_32(v)
	f.store_64(per_channel * 8)
	f.store_32(DSF_BLOCK)
	f.store_32(0)
	f.store_buffer("data".to_ascii_buffer())
	f.store_64(12 + data.size())
	f.store_buffer(data)
	f.close()
