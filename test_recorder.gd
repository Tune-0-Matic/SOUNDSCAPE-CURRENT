extends SceneTree
## The recorder against a live Master bus: it must capture real audio, drop NOTHING even
## across a STALL_MS main-thread stall mid-take, lose nothing the drop counter would miss,
## keep RAM flat (it streams to disk rather than accumulating an AudioStreamWAV), and
## produce a file ffmpeg will actually open -- converted on a worker, so stop() returns at once.
## Then the conversion itself, offline, on float takes written here:
##   - 16-bit and 24-bit are TPDF-dithered: a DC input of 0.3 LSB comes out as a signal whose
##     error variance is 0.25 LSB^2 (TPDF's 1/6 plus quantisation's 1/12) over at least three
##     codes, with the mean carried rather than rounded away (16-bit +0.3 LSB; ffmpeg's 24-bit
##     encoders truncate, so -0.2)
##   - 32-bit WAV is not dithered: the same input comes out as a single code
##   - +/-1.2 full-scale overs clamp at the top and bottom codes, never wrap
##   - FLAC is 24-bit and dithered the same way
## Then the two things that only show up on a long or a failing take:
##   - the RF64 container: a header written in the 64-bit form is one ffmpeg reads, with the
##     rate, channels and duration it was written with (the size arithmetic past 4 GiB is
##     Recorder.recorder_test(), which needs no disk)
##   - a write that cannot land ends the take, keeps what reached the disk, and says so
##   - two takes started back to back never share a filename
##   godot --headless --path . --script res://test_recorder.gd

## Main-thread stall injected mid-take -- about what a synchronous rescan of a large
## library costs. The capture buffer only drains from _process, so this is the whole risk.
const STALL_MS := 1200

func _initialize() -> void:
	Engine.max_fps = 60
	var engine := AudioEngine.new()
	root.add_child(engine)
	await process_frame
	await process_frame

	var rec := Recorder.new()
	root.add_child(rec)
	rec.setup()
	await process_frame

	var player := AudioStreamPlayer.new()
	player.bus = engine.deck_bus(0)
	root.add_child(player)
	var sr := 44100
	var n := int(sr * 10.0)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in n:
		buf.encode_s16(i * 2, int(sin(TAU * 440.0 * float(i) / sr) * 0.6 * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	player.stream = s
	player.play()
	var guard := 0
	while not player.playing and guard < 120:
		await process_frame
		guard += 1

	var dir := ProjectSettings.globalize_path("user://rec_test")
	var raw := rec.start(dir)
	var ok := not raw.is_empty()
	print("start() opened a take: %s" % ok)
	if not ok:
		print("RESULT FAIL")
		quit(1)
		return

	# WAV / 44100 / STANDARD, collected when the take is finalised
	var done := [false]
	var out_ok := [false]
	var out_path := [""]
	rec.finished.connect(func(path: String, good: bool) -> void:
		done[0] = true
		out_ok[0] = good
		out_path[0] = path)

	# ~2 s of real bus output, a STALL_MS main-thread stall, then ~2 s more. The mixer keeps
	# filling the capture buffer through the stall; nothing drains it until _process runs.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2000:
		await process_frame
	OS.delay_msec(STALL_MS)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 2000:
		await process_frame
	var wall_s := float(Time.get_ticks_msec() - t0) / 1000.0
	var stop_at := Time.get_ticks_usec()
	rec.stop(0, 0, 1)   # drains what is left and patches the header; the conversion runs on a worker
	var stop_ms := (Time.get_ticks_usec() - stop_at) / 1000.0
	var async_finish: bool = not done[0]   # a synchronous conversion would have emitted finished inside stop()
	var captured := rec.frames_written
	var dropped := rec.discarded
	guard = 0
	while not done[0] and guard < 600:
		await process_frame
		guard += 1
	player.stop()

	var got_frames := captured > sr   # at least a second's worth at the mix rate
	ok = ok and got_frames
	print("captured real audio off the bus: %s (%d frames)" % [got_frames, captured])

	var clean := dropped == 0
	ok = ok and clean
	print("capture buffer dropped nothing: %s (discarded %d)" % [clean, dropped])

	# nothing DROPPED is not the same as nothing LOST: the take has to span the whole
	# wall-clock time, stall included, or audio went missing somewhere the counter misses
	var expect := wall_s * AudioServer.get_mix_rate()
	var whole := float(captured) >= expect * 0.95
	ok = ok and whole
	print("the take spans the whole wall-clock time, stall included: %s (%d of ~%d frames)" % [
		whole, captured, int(expect)])

	ok = ok and out_ok[0]
	print("ffmpeg produced the requested file: %s (%s)" % [out_ok[0], out_path[0].get_file()])

	var size := 0
	if FileAccess.file_exists(out_path[0]):
		var f := FileAccess.open(out_path[0], FileAccess.READ)
		size = f.get_length()
		f.close()
	var big_enough := size > 100000   # ~2 s of 16-bit stereo is ~350 KB
	ok = ok and big_enough
	print("the take is a real file on disk: %s (%d bytes)" % [big_enough, size])

	# the float intermediate is cleaned up once the conversion succeeded
	var no_temp := not FileAccess.file_exists(raw)
	ok = ok and no_temp
	print("float intermediate cleaned up after conversion: %s" % no_temp)

	var nonblocking: bool = async_finish and stop_ms < 250.0
	ok = ok and nonblocking
	print("stop() returned in %.1f ms, before the conversion finished on its worker: %s" % [stop_ms, nonblocking])

	if FileAccess.file_exists(out_path[0]):
		DirAccess.remove_absolute(out_path[0])

	# the conversion, offline: TPDF dither, no dither at 32 bits, and clean full scale
	for spec in [["WAV", 0, 16], ["WAV", 1, 24], ["WAV", 2, 32], ["FLAC", 1, 24]]:
		var good := _dither_case(rec, dir, spec[0], spec[1], spec[2])
		ok = ok and good

	# the pure half: option tables and the header arithmetic at sizes past 4 GiB. Asserted at
	# boot too, but nothing in the suite boots player.tscn, so it is run here as well.
	var pure := Recorder.recorder_test()
	ok = ok and pure
	print("header arithmetic and option tables (Recorder.recorder_test): %s" % pure)

	ok = _rf64_case(dir) and ok
	ok = await _write_failure_case(rec, dir, player) and ok
	ok = _unique_name_case(rec, dir) and ok

	for leftover in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(leftover))
	DirAccess.remove_absolute(dir)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

## One conversion at the mix rate (no resampling): 1 s of DC at 0.3 of the TARGET's LSB, then
## +1.2 and -1.2 overs. Read back as 32-bit integers and measured in target LSBs.
func _dither_case(rec: Recorder, dir: String, type: String, quality: int, bits: int) -> bool:
	var rate := 96000
	var lsb := 1.0 / float(1 << (bits - 1)) if bits < 32 else 1.0 / 32768.0
	var n := rate
	var raw := dir.path_join("dither_%s_%d.f32.wav" % [type, bits])
	var f := FileAccess.open(raw, FileAccess.WRITE)
	var data := PackedByteArray()
	data.resize((n + 200) * 8)
	for i in n:
		data.encode_float(i * 8, 0.3 * lsb)
		data.encode_float(i * 8 + 4, 0.3 * lsb)
	for i in 200:
		var v := 1.2 if i < 100 else -1.2
		data.encode_float((n + i) * 8, v)
		data.encode_float((n + i) * 8 + 4, v)
	f.store_string("RIFF")
	f.store_32(36 + data.size())
	f.store_string("WAVEfmt ")
	f.store_32(16)
	f.store_16(3)
	f.store_16(2)
	f.store_32(rate)
	f.store_32(rate * 8)
	f.store_16(8)
	f.store_16(32)
	f.store_string("data")
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	var out := rec._convert(raw, Recorder.FILE_TYPES.find(type), Recorder.RATES.find(rate), quality)
	var pcm := dir.path_join("dither_%s_%d.s32" % [type, bits])
	var read_back := not out.is_empty() and OS.execute("ffmpeg", ["-v", "error", "-y", "-i", out,
		"-f", "s32le", "-c:a", "pcm_s32le", pcm], [], true) == 0
	var probe := []
	OS.execute("ffprobe", ["-v", "error", "-show_entries", "stream=bits_per_raw_sample,bits_per_sample",
		"-of", "csv=p=0", out], probe, true)
	var ints := FileAccess.get_file_as_bytes(pcm) if read_back else PackedByteArray()
	var scale := float(1 << (32 - bits)) if bits < 32 else 65536.0
	var sum := 0.0
	var sq := 0.0
	var codes := {}
	for i in n * 2:
		var v := float(ints.decode_s32(i * 4)) / scale
		sum += v
		sq += v * v
		codes[v] = true
	var mean := sum / float(n * 2)
	var variance := sq / float(n * 2) - mean * mean
	var top := float(ints.decode_s32(n * 2 * 4 + 100)) / scale if ints.size() > (n + 150) * 8 else 0.0
	var bottom := float(ints.decode_s32((n + 150) * 2 * 4)) / scale if ints.size() > (n + 150) * 8 else 0.0
	var hi := float((1 << (bits - 1)) - 1) if bits < 32 else 32767.99998
	var lo := -float(1 << (bits - 1)) if bits < 32 else -32768.0
	var good: bool
	if bits < 32:
		good = read_back and absf(variance - 0.25) < 0.03 and codes.size() >= 3 and mean > -0.3 and mean < 0.35 \
			and absf(top - hi) < 0.001 and absf(bottom - lo) < 0.001
	else:
		good = read_back and codes.size() == 1 and top > 32767.0 and bottom <= -32768.0
	print("dither %s %d-bit: 0.3 LSB DC -> mean %+.3f LSB, error variance %.3f LSB^2 over %d codes; +/-1.2 overs -> %.1f / %.1f (limits %.1f / %.1f); stream bits %s: %s" % [
		type, bits, mean, variance, codes.size(), top, bottom, hi, lo, str(probe[0]).strip_edges() if not probe.is_empty() else "?", good])
	for p in [raw, out, pcm]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	return good

## The 64-bit container, at a size nobody has to wait for: a take written in the RF64 form has
## to be a file ffmpeg opens, not merely one that parses here. Half a second of tone, written
## through the same header builder with force_rf64, then read back with ffprobe.
func _rf64_case(dir: String) -> bool:
	var rate := 48000
	var frames := rate / 2
	var path := dir.path_join("rf64_probe.wav")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		print("RF64: could not write the probe file")
		return false
	f.store_buffer(Recorder.header_bytes(frames, rate, true))
	var data := PackedByteArray()
	data.resize(frames * 8)
	for i in frames:
		var v := sin(TAU * 440.0 * float(i) / float(rate)) * 0.25
		data.encode_float(i * 8, v)
		data.encode_float(i * 8 + 4, v)
	f.store_buffer(data)
	f.close()
	var head := FileAccess.get_file_as_bytes(path).slice(0, 16)
	var shaped: bool = head.slice(0, 4).get_string_from_ascii() == "RF64" \
		and head.slice(12, 16).get_string_from_ascii() == "ds64"
	var probe := []
	OS.execute("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries",
		"stream=codec_name,sample_rate,channels:format=duration", "-of", "csv=p=0", path], probe, true)
	var reply := str(probe[0] if not probe.is_empty() else "").strip_edges()
	var secs := 0.0
	for line in reply.split("\n", false):
		var last: String = line.split(",")[-1].strip_edges()
		if last.is_valid_float() and float(last) > 0.0 and float(last) < 5.0:
			secs = float(last)
	var read: bool = reply.contains("pcm_f32le") and reply.contains("48000") \
		and absf(secs - 0.5) < 0.01
	DirAccess.remove_absolute(path)
	var good := shaped and read
	print("RF64: header is RF64 + ds64 %s; ffmpeg reads it as %s, %.3f s: %s" % [
		shaped, reply.split("\n", false)[0] if not reply.is_empty() else "(nothing)", secs, good])
	return good

## A write that cannot land. The take's own handle is swapped for a read-only one mid-take,
## which is what a full disk or a pulled drive looks like from inside _drain: the take must end
## itself, keep the audio that already reached the disk, and report why.
func _write_failure_case(rec: Recorder, dir: String, player: AudioStreamPlayer) -> bool:
	player.play()
	var take := rec.start(dir)
	if take.is_empty():
		print("write failure: could not start a take")
		return false
	var reported := [""]
	rec.failed.connect(func(_path: String, reason: String) -> void: reported[0] = reason, CONNECT_ONE_SHOT)
	for _f in 25:
		await process_frame
	var before := rec.frames_written
	rec._file = FileAccess.open(take, FileAccess.READ)   # the next drain cannot write
	var guard := 0
	while rec.recording and guard < 180:
		await process_frame
		guard += 1
	player.stop()
	var size := 0
	if FileAccess.file_exists(take):
		var f := FileAccess.open(take, FileAccess.READ)
		size = f.get_length()
		f.close()
	var good: bool = not rec.recording and not reported[0].is_empty() and not rec.error.is_empty() \
		and before > 0 and size > Recorder.HEADER_BYTES
	print("write failure: take stopped %s, reported \"%s\", %d frames and %d bytes kept: %s" % [
		not rec.recording, reported[0], before, size, good])
	if FileAccess.file_exists(take):
		DirAccess.remove_absolute(take)
	return good

## Two takes started back to back. The name carries microseconds, so the second one cannot land
## on the file the first one is still being converted from -- which used to truncate both.
func _unique_name_case(rec: Recorder, dir: String) -> bool:
	var first := rec.start(dir)
	rec._fail("ending the first probe take")   # closes it without spawning a conversion
	var second := rec.start(dir)
	rec._fail("ending the second probe take")
	var good: bool = not first.is_empty() and not second.is_empty() and first != second \
		and FileAccess.file_exists(first) and FileAccess.file_exists(second)
	print("two takes in a row: %s and %s: %s" % [first.get_file(), second.get_file(), good])
	for p in [first, second]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	rec.error = ""   # the probe takes are not a real failure state for anything that follows
	return good
