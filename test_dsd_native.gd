extends SceneTree
## Native DSD through libsoundscape_dsp (SsDsdStream: .dsf and .dff). Exit codes match
## test_flac_native.gd: 0 PASS, 1 FAIL, 2 SKIPPED when the extension is not built on this machine.
## Nothing on this machine encodes DSD, so the test writes its own: a 2nd-order sigma-delta
## modulator turns 1 kHz (left, 0.5) and 3 kHz (right, 0.35) into ONE bit stream per channel, saved
## as a DSF (planar blocks, LSB first) and a DFF (interleaved, MSB first).
##   1. both load with their real container, DSD64 rate, channel count, sample count and length
##   2. stage 1 (the byte-table FIR to 352.8 kHz) decodes the DSF and the DFF BIT-IDENTICALLY
##   3. rendered to 44.1 kHz through the real _mix path: each tone at its encoded level (±0.05 dB),
##      THD+N inside 20 kHz below -60 dB -- the modulator's own noise floor, not the decoder's -- and
##      each channel carrying under -60 dB of the other's tone
##   4. rendered to 96 kHz: the exact frame count for the length, and a seek to 0.25 s lands on
##      exactly the samples a continuous render gives there
##   5. AudioEngine.decode returns an SsDsdStream for both, and it plays, advances and finishes on a
##      real AudioStreamPlayer
##   6. hostile input: a chunk size of 2^63, a DST-compressed DFF and a non-DSD rate are refused
##      with an error, not a hang or a crash
##   7. a 64 MB file is MAPPED rather than read: loading it barely moves Godot's static memory,
##      and the frames at the very end of it -- pages nothing has touched -- still decode
## Files live in user://dsd_test and are removed.
##   godot --headless --path . --script res://test_dsd_native.gd

const DIR := "user://dsd_test"
const DSD_RATE := 2822400
const PCM_RATE := 352800
const SECS := 0.6
const BLOCK := 4096

func _initialize() -> void:
	if not ClassDB.class_exists("SsDsdStream"):
		print("SKIPPED: SsDsdStream is not registered -- libsoundscape_dsp is not built here.")
		print("RESULT SKIPPED")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var base := ProjectSettings.globalize_path(DIR)
	var ok := true

	var bits := int(DSD_RATE * SECS)
	var chans: Array[PackedByteArray] = [_modulate(1000.0, 0.5, bits), _modulate(3000.0, 0.35, bits)]
	var dsf := base.path_join("tones.dsf")
	var dff := base.path_join("tones.dff")
	_write_dsf(dsf, chans, bits)
	_write_dff(dff, chans, DSD_RATE, "DSD ")

	# 1. format
	var a: AudioStream = _load(dsf)
	var b: AudioStream = _load(dff)
	var fmt := true
	for pair in [[a, "DSF"], [b, "DFF"]]:
		var s: AudioStream = pair[0]
		var good: bool = s != null and s.call("get_container") == pair[1] and s.call("get_sample_rate") == DSD_RATE \
			and s.call("get_pcm_rate") == PCM_RATE and s.call("get_channels") == 2 and s.call("get_bits_per_sample") == 1 \
			and int(s.call("get_frame_count")) >= bits and absf(s.get_length() - SECS) < 0.01
		print("1. %s loads as %s: %s Hz, pcm %s Hz, %s ch, %s samples, %.3f s: %s" % [pair[1],
			s.call("get_container") if s else "null", s.call("get_sample_rate") if s else -1, s.call("get_pcm_rate") if s else -1,
			s.call("get_channels") if s else -1, s.call("get_frame_count") if s else -1, s.get_length() if s else -1.0, good])
		fmt = fmt and good
	ok = ok and fmt
	if not (a and b):
		print("RESULT FAIL")
		quit(1)
		return

	# 2. DSF and DFF, one bit stream, two containers: identical stage-1 output
	var frames := int(PCM_RATE * SECS)
	var da: PackedFloat32Array = a.call("decode_frames", 0, frames)
	var db: PackedFloat32Array = b.call("decode_frames", 0, frames)
	var diff := 0
	for i in mini(da.size(), db.size()):
		if da[i] != db[i]:
			diff += 1
	var same: bool = da.size() == frames * 2 and db.size() == da.size() and diff == 0
	ok = ok and same
	print("2. stage 1 to %d Hz: DSF %d samples, DFF %d, %d differ: %s" % [PCM_RATE, da.size(), db.size(), diff, same])

	# 3. levels, noise and separation inside 20 kHz
	var cd: PackedFloat32Array = a.call("render", 44100, 0.0, int(44100 * SECS))
	var win := 22050   # 0.5 s: whole cycles of both tones
	var from := 2205
	var l := _fit(cd, 0, 1000.0, 44100, from, win)
	var r := _fit(cd, 1, 3000.0, 44100, from, win)
	var bleed_l := _fit(cd, 0, 3000.0, 44100, from, win)
	var bleed_r := _fit(cd, 1, 1000.0, 44100, from, win)
	var db_l := 20.0 * log(l[0] / 0.5) / log(10.0)
	var db_r := 20.0 * log(r[0] / 0.35) / log(10.0)
	var sep_l := 20.0 * log(maxf(bleed_l[0], 1e-12) / l[0]) / log(10.0)
	var sep_r := 20.0 * log(maxf(bleed_r[0], 1e-12) / r[0]) / log(10.0)
	var tones: bool = absf(db_l) < 0.05 and absf(db_r) < 0.05 and l[1] < -60.0 and r[1] < -60.0 and sep_l < -60.0 and sep_r < -60.0
	ok = ok and tones
	print("3. at 44.1 kHz: L 1 kHz %+.4f dB, THD+N %.1f dB, 3 kHz bleed %.1f dB | R 3 kHz %+.4f dB, THD+N %.1f dB, 1 kHz bleed %.1f dB: %s" % [
		db_l, l[1], sep_l, db_r, r[1], sep_r, tones])

	# 4. length and seek at the mix rate
	var full: PackedFloat32Array = a.call("render", 96000, 0.0, 96000)
	var want := int(ceil(float(frames) * 96000.0 / PCM_RATE))
	var part: PackedFloat32Array = a.call("render", 96000, 0.25, 24000)
	var exact := part.size() == 48000
	for i in part.size():
		if part[i] != full[48000 + i]:
			exact = false
			break
	var timing: bool = full.size() / 2 == want and exact
	ok = ok and timing
	print("4. at 96 kHz: %d frames (want %d); a seek to 0.25 s matches the continuous render sample for sample %s: %s" % [
		full.size() / 2, want, exact, timing])

	# 5. through the engine and onto a real player
	var engine := AudioEngine.new()
	var routed := true
	for path in [dsf, dff]:
		var st := engine.decode(path)
		routed = routed and st != null and st.get_class() == "SsDsdStream"
	engine.free()
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "DsdVerify")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.set_bus_mute(bus, true)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus, capture)
	var player := AudioStreamPlayer.new()
	player.bus = "DsdVerify"
	player.stream = a
	root.add_child(player)
	await process_frame
	var finished := [false]
	player.finished.connect(func() -> void: finished[0] = true)
	player.play()
	await create_timer(0.3).timeout
	var energy := 0.0
	for fr in capture.get_buffer(capture.get_frames_available()):
		energy = maxf(energy, absf(fr.x))
	var moving := player.get_playback_position() > 0.1
	var t := Time.get_ticks_msec()
	while not finished[0] and Time.get_ticks_msec() - t < 4000:
		await process_frame
	var plays: bool = routed and energy > 0.2 and moving and finished[0]
	ok = ok and plays
	print("5. AudioEngine.decode -> SsDsdStream for both %s; plays (peak %.3f) %s, advances %s, finishes %s: %s" % [
		routed, energy, energy > 0.2, moving, finished[0], plays])
	player.queue_free()
	await process_frame
	AudioServer.remove_bus(bus)

	# 6. hostile files
	var huge := base.path_join("huge.dsf")
	var hb := FileAccess.get_file_as_bytes(dsf).slice(0, 200)
	hb.encode_s64(28 + 4, -9223372036854775807 - 1)   # the fmt chunk's size: 2^63, as unsigned
	_save(huge, hb)
	var dst := base.path_join("dst.dff")
	_write_dff(dst, chans, DSD_RATE, "DST ")
	var odd := base.path_join("odd_rate.dff")
	_write_dff(odd, chans, 2000000, "DSD ")
	var refused := true
	for path in [huge, dst, odd]:
		var s: AudioStream = ClassDB.instantiate("SsDsdStream")
		refused = refused and int(s.call("load", path)) != OK
	ok = ok and refused
	print("6. a 2^63 chunk size, DST compression and a 2.0 MHz rate are all refused: %s" % refused)

	# 7. a BIG file costs no RAM. 64 MB is a short DSD64 track; a real album side is 170 MB+, and
	# every byte of it used to land in a PackedByteArray before the first sample played. Mapped,
	# what the engine allocates is the object -- the pages come and go behind it -- so the static
	# memory Godot itself is holding barely moves, and the far end of the file still decodes.
	var big := base.path_join("big.dsf")
	var per_channel := 32 * 1024 * 1024
	_write_big_dsf(big, per_channel)
	var file_bytes := FileAccess.open(big, FileAccess.READ).get_length()
	var before_mem := OS.get_static_memory_usage()
	var huge_stream: AudioStream = _load(big)
	var after_mem := OS.get_static_memory_usage()
	var grew := after_mem - before_mem
	# the last block of the file: pages nothing has touched, which is the half a mapping could
	# get wrong. A DSD byte is 8 bits, so this is the final 512 PCM frames of the stream.
	var frames_total: int = int(huge_stream.call("get_frame_count")) / 8 if huge_stream else 0
	var tail: PackedFloat32Array = huge_stream.call("decode_frames", frames_total - 512, 512) if huge_stream else PackedFloat32Array()
	var tail_live := false
	for v in tail:
		tail_live = tail_live or absf(v) > 0.0001
	var mapped: bool = huge_stream != null and bool(huge_stream.call("is_mapped")) \
		and int(huge_stream.call("file_size")) == file_bytes
	var lean: bool = mapped and grew < 8 * 1024 * 1024 and tail.size() == 1024 and tail_live
	ok = ok and lean
	print("7. a %.0f MB DSF: mapped %s, static memory +%.2f MB (was the whole file), last 512 frames decode %s: %s" % [
		file_bytes / 1048576.0, mapped, grew / 1048576.0, tail_live, lean])
	huge_stream = null

	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(base.path_join(f))
	DirAccess.remove_absolute(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _load(path: String) -> AudioStream:
	var s: AudioStream = ClassDB.instantiate("SsDsdStream")
	return s if int(s.call("load", path)) == OK else null

## 2nd-order sigma-delta: the bits, oldest first, packed LSB first per byte (DSF's order).
static func _modulate(hz: float, amp: float, bits: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize((bits + 7) / 8)
	var i1 := 0.0
	var i2 := 0.0
	var y := 1.0
	var w := TAU * hz / DSD_RATE
	for n in bits:
		var x := amp * sin(w * float(n))
		i1 += x - y
		i2 += i1 - y
		y = 1.0 if i2 >= 0.0 else -1.0
		if y > 0.0:
			out[n >> 3] |= 1 << (n & 7)
	return out

static func _reverse(v: int) -> int:
	var r := 0
	for b in 8:
		r = (r << 1) | ((v >> b) & 1)
	return r

func _write_dsf(path: String, chans: Array[PackedByteArray], bits: int) -> void:
	var per := int(ceil(float(chans[0].size()) / BLOCK)) * BLOCK
	var data := PackedByteArray()
	data.resize(per * chans.size())
	for blk in per / BLOCK:
		for ch in chans.size():
			for k in BLOCK:
				var src := blk * BLOCK + k
				if src < chans[ch].size():
					data[blk * BLOCK * chans.size() + ch * BLOCK + k] = chans[ch][src]
	var f := PackedByteArray()
	f.append_array("DSD ".to_ascii_buffer())
	f.append_array(_le64(28))
	f.append_array(_le64(28 + 52 + 12 + data.size()))
	f.append_array(_le64(0))
	f.append_array("fmt ".to_ascii_buffer())
	f.append_array(_le64(52))
	for v in [1, 0, 2, chans.size(), DSD_RATE, 1]:
		f.append_array(_le32(v))
	f.append_array(_le64(bits))
	f.append_array(_le32(BLOCK))
	f.append_array(_le32(0))
	f.append_array("data".to_ascii_buffer())
	f.append_array(_le64(12 + data.size()))
	f.append_array(data)
	_save(path, f)

## A BIG DSF, cheaply: one pattern block doubled up to size, wrapped in the same header
## _write_dsf writes. The bytes are not a modulated tone -- section 7 is about where they live,
## not what they sound like -- and doubling keeps a 64 MB fixture under a second, where the
## per-byte interleave loop above would be 64 million GDScript iterations.
func _write_big_dsf(path: String, per_channel: int, channels := 2) -> void:
	var data := PackedByteArray()
	data.resize(BLOCK)
	for i in BLOCK:
		data[i] = (i * 37 + 11) & 0xFF   # varied: an all-one-byte file compresses on some filesystems
	while data.size() < per_channel * channels:
		data.append_array(data)
	data.resize(per_channel * channels)
	var f := PackedByteArray()
	f.append_array("DSD ".to_ascii_buffer())
	f.append_array(_le64(28))
	f.append_array(_le64(28 + 52 + 12 + data.size()))
	f.append_array(_le64(0))
	f.append_array("fmt ".to_ascii_buffer())
	f.append_array(_le64(52))
	for v in [1, 0, 2, channels, DSD_RATE, 1]:
		f.append_array(_le32(v))
	f.append_array(_le64(per_channel * 8))
	f.append_array(_le32(BLOCK))
	f.append_array(_le32(0))
	f.append_array("data".to_ascii_buffer())
	f.append_array(_le64(12 + data.size()))
	f.append_array(data)
	_save(path, f)

func _write_dff(path: String, chans: Array[PackedByteArray], rate: int, cmpr: String) -> void:
	var n: int = chans[0].size()
	var sound := PackedByteArray()
	sound.resize(n * chans.size())
	for i in n:
		for ch in chans.size():
			sound[i * chans.size() + ch] = _reverse(chans[ch][i])
	var prop := PackedByteArray()
	prop.append_array("SND ".to_ascii_buffer())
	prop.append_array(_chunk("FS  ", _be32(rate)))
	var chnl := _be16(chans.size())
	chnl.append_array("SLFTSRGT".to_ascii_buffer())
	prop.append_array(_chunk("CHNL", chnl))
	var comp := cmpr.to_ascii_buffer()
	comp.append_array(PackedByteArray([14]))
	comp.append_array("not compressed".to_ascii_buffer())
	prop.append_array(_chunk("CMPR", comp))
	var body := PackedByteArray()
	body.append_array("DSD ".to_ascii_buffer())
	body.append_array(_chunk("FVER", _be32(0x01050000)))
	body.append_array(_chunk("PROP", prop))
	body.append_array(_chunk("DSD " if cmpr == "DSD " else "DST ", sound))
	var f := PackedByteArray()
	f.append_array("FRM8".to_ascii_buffer())
	f.append_array(_be64(body.size()))
	f.append_array(body)
	_save(path, f)

static func _chunk(id: String, data: PackedByteArray) -> PackedByteArray:
	var c := id.to_ascii_buffer()
	c.append_array(_be64(data.size()))
	c.append_array(data)
	if data.size() % 2 == 1:
		c.append(0)
	return c

static func _le32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

static func _le64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	return b

static func _be16(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 8) & 0xFF, v & 0xFF])

static func _be32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])

static func _be64(v: int) -> PackedByteArray:
	var hi := _be32(v >> 32)
	hi.append_array(_be32(v & 0xFFFFFFFF))
	return hi

static func _save(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

## Least-squares amplitude of `hz` on channel `ch` over a window of whole cycles, and the THD+N
## of what is left once that tone and DC are removed.
static func _fit(x: PackedFloat32Array, ch: int, hz: float, rate: int, from: int, n: int) -> Array:
	var ss := 0.0
	var sc := 0.0
	var sd := 0.0
	for i in n:
		var v: float = x[(from + i) * 2 + ch]
		var ph := TAU * hz * float(from + i) / rate
		ss += v * sin(ph)
		sc += v * cos(ph)
		sd += v
	var a := 2.0 * ss / n
	var b := 2.0 * sc / n
	var c := sd / n
	var res := 0.0
	for i in n:
		var ph := TAU * hz * float(from + i) / rate
		var e: float = x[(from + i) * 2 + ch] - a * sin(ph) - b * cos(ph) - c
		res += e * e
	var amp := sqrt(a * a + b * b)
	return [amp, 10.0 * log(res / n / maxf(amp * amp * 0.5, 1e-30)) / log(10.0)]
