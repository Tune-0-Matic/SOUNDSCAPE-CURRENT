class_name Recorder
extends Node
## Records the live Master bus for as long as you leave it running.
##
## AudioEffectRecord is the obvious node and is the wrong one: it accumulates the whole
## take in RAM as an AudioStreamWAV, so "indefinitely" means ~10 MB per minute of heap
## until something gives. AudioEffectCapture instead hands frames back a buffer at a
## time, so this pulls them every frame and streams them straight to disk -- RAM stays
## flat at one capture buffer no matter how long the take is, and the only real limit
## is free space.
##
## The intermediate is 32-bit FLOAT wav, which is what the bus actually hands us: any
## conversion (16/24-bit, FLAC, a different sample rate) happens ONCE after stop, through
## ffmpeg on a worker, so neither the live path nor the STOP press ever waits on format work.
## 16- and 24-bit takes are TPDF-dithered on the way down (AudioEngine.dither_filter), resampling
## first in the same float pass; 32-bit WAV is not, and FLAC is 24-bit.
##
## ponytail: the capture rate is the AudioServer's mix rate, not the requested one --
## an effect cannot resample the bus it is on. SAMPLE RATE resamples on the way out.
##
## LENGTH. A RIFF header counts bytes in 32 bits, so a take passes 4 GiB -- 93 minutes at a
## 96 kHz stereo float mix -- and every size field wraps: the file on disk then describes a
## few megabytes of audio and the rest is unreachable. A set is exactly the recording nobody
## can make again, so the header is written in the RF64 shape instead (EBU Tech 3306): a
## reserved JUNK chunk sits where ds64 goes, and at stop a take that outgrew 32 bits turns
## that chunk into ds64 and the RIFF tag into RF64, in place, without moving a byte of audio.
## Under 4 GiB the file stays an ordinary WAV carrying one ignored chunk.
##
## FAILURE. Every write is checked, because the ones that matter are the silent ones: a full
## disk, a pulled drive, a folder that went read-only mid-take. store_buffer() answers false
## and get_error() only sometimes says why (measured: a closed handle returns false with
## get_error OK), so both are read. A failed write ends the take where it stopped, patches the
## header so what DID land is playable, and says so through `failed` -- a recorder that quietly
## stops recording is worse than one that stops.

signal finished(path: String, ok: bool)
## Emitted when a take ends because a write failed, never on a normal stop. `path` is the raw
## float take, kept exactly as far as it got.
signal failed(path: String, reason: String)

const BUS := "Master"
## Two seconds of headroom. The buffer only drains from _process, so it has to outlast the
## longest thing the main thread ever does synchronously -- a rescan, a skin switch, a big
## save -- while the mixer keeps filling it. Measured with test_recorder.gd stalling the main
## thread 1.2 s mid-take: at 0.5 s the take dropped 53760 frames, over a second of audio; at
## 2.0 s it dropped none and held 99% of the wall-clock span. About 2 MB at a 96 kHz mix.
const BUFFER_SEC := 2.0
const FILE_TYPES := ["WAV", "FLAC"]
const RATES := [44100, 48000, 96000]
## WAV: output bit depth. FLAC: ffmpeg compression level, 0 fastest .. 8 smallest.
const WAV_DEPTHS := [16, 24, 32]
const FLAC_LEVELS := [0, 5, 8]
const FLAC_BITS := 24
const QUALITY_NAMES := ["LOW", "STANDARD", "HIGH"]
## RIFF/RF64 header: 12 tag + 36 reserved (JUNK / ds64) + 24 fmt + 8 data. Fixed, so the audio
## always starts at the same offset whether or not the take ends up needing ds64.
const HEADER_BYTES := 80
## What a 32-bit size field can hold. Past this the take is written as RF64.
const MAX_U32 := 4294967295
## Stereo 32-bit float: 8 bytes a frame, which is what the fmt chunk below promises.
const BYTES_PER_FRAME := 8

var recording := false
var elapsed := 0.0
var frames_written := 0
## Why the last take stopped, or "" when it ended normally. Cleared by the next start().
var error := ""
var discarded := 0          # frames the capture buffer dropped THIS take: must stay 0
## get_discarded_frames() counts for the life of the effect, not the take, so a second
## recording would inherit the first one's drops and look like it lost audio it never
## touched. Every reading is taken against where the counter stood at start().
var _discard_base := 0

var _capture: AudioEffectCapture
var _bus_idx := -1
var _slot := -1
var _file: FileAccess
var _raw_path := ""
var _tasks: Array[int] = []   # conversions still out on a worker; joined in _exit_tree
var _mix_rate := 44100.0

## Pre-allocated once, disabled, exactly like every other effect this program puts on a
## bus: adding it at record time would rebuild every instance on Master and take the
## driver lock mid-set, which is the one moment that must not glitch.
func setup() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS)
	for i in AudioServer.get_bus_effect_count(_bus_idx):
		if AudioServer.get_bus_effect(_bus_idx, i) is AudioEffectCapture:
			_capture = AudioServer.get_bus_effect(_bus_idx, i)
			_slot = i
			return
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = BUFFER_SEC
	AudioServer.add_bus_effect(_bus_idx, _capture)
	_slot = AudioServer.get_bus_effect_count(_bus_idx) - 1
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, false)

## `dir` is a real filesystem directory. Returns "" and records nothing if it cannot be
## written to -- a take that silently goes nowhere is worse than one that refuses.
func start(dir: String) -> String:
	if recording or not _capture:
		return ""
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	# Down to the microsecond, and checked against the disk on top of that. A second is long
	# enough to stop and start again by hand, and two takes a second apart used to share one
	# name -- so the new take opened the file the previous take's conversion was still reading
	# and truncated it, losing both.
	var t := Time.get_datetime_dict_from_system()
	var micros := int(fposmod(Time.get_unix_time_from_system(), 1.0) * 1000000.0)
	var base := "SOUNDSCAPE_%04d%02d%02d_%02d%02d%02d_%06d" % [t["year"], t["month"], t["day"],
		t["hour"], t["minute"], t["second"], micros]
	_raw_path = dir.path_join("%s.f32.wav" % base)
	var dup := 2
	while FileAccess.file_exists(_raw_path) and dup < 1000:
		_raw_path = dir.path_join("%s_%d.f32.wav" % [base, dup])
		dup += 1
	_file = FileAccess.open(_raw_path, FileAccess.WRITE)
	if not _file:
		return ""
	error = ""
	_mix_rate = AudioServer.get_mix_rate()
	if not _write_header(0):
		# the first write already failed: the directory is not writable in practice, whatever
		# dir_exists_absolute said, and a take that goes nowhere must refuse rather than run
		error = "could not write the header to %s" % _raw_path.get_file()
		_file.close()
		_file = null
		return ""
	frames_written = 0
	discarded = 0
	elapsed = 0.0
	_capture.clear_buffer()
	_discard_base = _capture.get_discarded_frames()
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, true)
	recording = true
	return _raw_path

## Stops and patches the RIFF sizes the header could not know up front. From there the take is
## complete and valid on disk, so converting it -- as long as the take is long, about 55 s per
## hour to FLAC, measured -- runs on a worker, and `finished` arrives when it is done. The path
## is captured here, so a new take started meanwhile cannot redirect this one.
func stop(type_i: int, rate_i: int, quality_i: int) -> void:
	if not recording:
		return
	recording = false
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, false)
	_drain()
	if not _file:
		return   # a write failed mid-take; _fail already closed the file and reported it
	if not _write_header(frames_written):   # seeks back over the placeholder
		push_warning("could not patch the take's header; its sizes describe less than it holds")
	_file.close()
	_file = null
	var raw := _raw_path
	AudioEngine.reap_tasks(_tasks)
	_tasks.append(WorkerThreadPool.add_task(func() -> void:
		var out := _convert(raw, type_i, rate_i, quality_i)
		_finish.bind(out if not out.is_empty() else raw, not out.is_empty()).call_deferred()))

func _finish(path: String, ok: bool) -> void:
	finished.emit(path, ok)

## The raw float take this recorder last opened, kept after a failure so the UI can name the
## file the audio is actually in.
func last_take() -> String:
	return _raw_path

## Never waits out a conversion at exit: player.gd's close path runs AudioEngine.shutdown(),
## which kills every ffmpeg first, so the worker fails fast and the float take stays intact.
func _exit_tree() -> void:
	AudioEngine.join_tasks(_tasks)

func _process(delta: float) -> void:
	if not recording:
		return
	elapsed += delta
	_drain()

## Pull whatever the bus has handed over since the last frame. Interleaved float32,
## which is byte-for-byte what the f32 wav header above promises.
func _drain() -> void:
	if not _capture or not _file:
		return
	discarded = _capture.get_discarded_frames() - _discard_base
	var n := _capture.get_frames_available()
	if n <= 0:
		return
	var frames := _capture.get_buffer(n)
	var bytes := PackedByteArray()
	bytes.resize(frames.size() * BYTES_PER_FRAME)
	for i in frames.size():
		bytes.encode_float(i * BYTES_PER_FRAME, frames[i].x)
		bytes.encode_float(i * BYTES_PER_FRAME + 4, frames[i].y)
	# BOTH answers: store_buffer returns false for a handle that cannot take the write, and
	# get_error() carries the reason when the driver has one. Measured on 4.7: a read-only
	# handle answers false with ERR_FILE_CANT_WRITE, a closed one answers false with OK.
	var wrote := _file.store_buffer(bytes)
	var err := _file.get_error()
	if not wrote or err != OK:
		_fail("disk write failed%s" % ("" if err == OK else " (%s)" % error_string(err)))
		return
	frames_written += frames.size()

## Writes the header for a take of `frames` frames. Written once with zero lengths at start and
## again with the real ones at stop, which is the whole reason this takes a frame count.
## Returns false when the write did not land, which is the caller's cue to stop the take.
func _write_header(frames: int) -> bool:
	_file.seek(0)
	var wrote := _file.store_buffer(header_bytes(frames, int(_mix_rate)))
	var err := _file.get_error()
	if frames > 0:
		_file.seek_end()
	return wrote and err == OK

## The 80-byte header for a stereo 32-bit float take, as bytes. Pure and static, so the size
## arithmetic that only shows itself past 4 GiB is checked by recorder_test() rather than by
## recording for an hour and a half.
##
## Layout, fixed at HEADER_BYTES whichever form it takes:
##   0  RIFF / RF64     4    the tag is the only thing that says which form this is
##   4  riff size       4    bytes after this field; 0xFFFFFFFF once ds64 carries the real one
##   8  WAVE            4
##   12 JUNK / ds64     4    reserved at start, upgraded in place at stop if the take outgrew 32 bits
##   16 28              4    ds64 payload size, so JUNK and ds64 are byte-for-byte the same size
##   20 riff size       8    ds64 only: the real sizes, as 64-bit
##   28 data size       8
##   36 sample count    8    frames per channel
##   44 table length    4    no table entries: this file has one data chunk
##   48 fmt             24   format 3 (IEEE float), 2 channels, rate, byte rate, block align, bits
##   72 data            4
##   76 data size       4    0xFFFFFFFF once ds64 carries the real one
## `force_rf64` writes the 64-bit form for a take that would fit in 32 bits. Nothing in the
## program asks for it; test_recorder.gd does, to prove ffmpeg reads this layout without
## anyone having to record 4 GiB first.
static func header_bytes(frames: int, rate: int, force_rf64 := false) -> PackedByteArray:
	var data_bytes := frames * BYTES_PER_FRAME
	var riff_bytes := HEADER_BYTES - 8 + data_bytes
	var big: bool = force_rf64 or riff_bytes > MAX_U32 or data_bytes > MAX_U32
	var out := PackedByteArray()
	out.resize(HEADER_BYTES)
	out.fill(0)
	_put_tag(out, 0, "RF64" if big else "RIFF")
	out.encode_u32(4, MAX_U32 if big else riff_bytes)
	_put_tag(out, 8, "WAVE")
	_put_tag(out, 12, "ds64" if big else "JUNK")
	out.encode_u32(16, 28)
	if big:
		out.encode_u64(20, riff_bytes)
		out.encode_u64(28, data_bytes)
		out.encode_u64(36, frames)
		out.encode_u32(44, 0)
	_put_tag(out, 48, "fmt ")
	out.encode_u32(52, 16)
	out.encode_u16(56, 3)                          # IEEE float
	out.encode_u16(58, 2)                          # stereo
	out.encode_u32(60, rate)
	out.encode_u32(64, rate * BYTES_PER_FRAME)     # byte rate
	out.encode_u16(68, BYTES_PER_FRAME)            # block align
	out.encode_u16(70, 32)                         # bits per sample
	_put_tag(out, 72, "data")
	out.encode_u32(76, MAX_U32 if big else data_bytes)
	return out

static func _put_tag(buf: PackedByteArray, at: int, tag: String) -> void:
	var ascii := tag.to_ascii_buffer()
	for i in ascii.size():
		buf.encode_u8(at + i, ascii[i])

## A write that did not land. The take stops where it stopped, its header is patched so the
## audio that DID reach the disk is playable, and the UI is told: the alternative is a REC
## indicator counting up beside a file nothing is being added to.
func _fail(reason: String) -> void:
	error = reason
	recording = false
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, false)
	var path := _raw_path
	if _file:
		_write_header(frames_written)   # best effort; if this fails too the sizes stay as written
		_file.close()
		_file = null
	push_warning("recording stopped: %s (take kept at %s)" % [reason, path])
	failed.emit(path, reason)

## One ffmpeg pass for type, rate and quality together. WORKER THREAD: touches nothing but
## its arguments and the files. Returns the converted file's path, or "" -- in which case the
## float intermediate is left in place, so a take is never lost to a missing or killed ffmpeg.
func _convert(raw: String, type_i: int, rate_i: int, quality_i: int) -> String:
	var type: String = FILE_TYPES[clampi(type_i, 0, FILE_TYPES.size() - 1)]
	var rate: int = RATES[clampi(rate_i, 0, RATES.size() - 1)]
	var q := clampi(quality_i, 0, QUALITY_NAMES.size() - 1)
	var out := "%s.%s" % [raw.trim_suffix(".f32.wav"), type.to_lower()]
	var bits: int = FLAC_BITS if type == "FLAC" else WAV_DEPTHS[q]
	# rate change and word length in ONE swr pass: resampled in float, then dithered once. A separate
	# -ar would resample the already-dithered integers and quantise them a second time.
	var args := ["-v", "error", "-y", "-nostdin", "-i", raw, "-af", AudioEngine.dither_filter(bits, rate)]
	if type == "FLAC":
		args.append_array(["-c:a", "flac", "-compression_level", str(FLAC_LEVELS[q]),
			"-sample_fmt", "s32", "-bits_per_raw_sample", str(FLAC_BITS)])
	else:
		# rf64=auto for the same reason the take itself is RF64-shaped: ffmpeg's wav muxer
		# wraps its sizes past 4 GiB unless asked, and 32-bit/96 kHz output reaches that in
		# the same 93 minutes the float intermediate does.
		args.append_array(["-c:a", "pcm_s%dle" % bits, "-rf64", "auto"])
	args.append(out)
	if AudioEngine.run_process("ffmpeg", args) != 0:
		push_warning("ffmpeg did not convert the take; the float wav is kept at %s" % raw)
		return ""
	DirAccess.remove_absolute(raw)
	return out

## Self-check for the pure bits: the header maths and the option tables. The live
## capture path needs a running bus and lives in test_recorder.gd.
static func recorder_test() -> bool:
	# every option table lines up with the names shown for it
	if QUALITY_NAMES.size() != WAV_DEPTHS.size() or QUALITY_NAMES.size() != FLAC_LEVELS.size():
		return false
	if FILE_TYPES.size() != 2 or RATES.is_empty():
		return false
	for lvl in FLAC_LEVELS:
		if lvl < 0 or lvl > 8:          # ffmpeg refuses anything outside this
			return false
	for d in WAV_DEPTHS:
		if not d in [16, 24, 32]:       # pcm_s%dle only exists for these
			return false
	# The header, at the sizes that only show themselves after an hour and a half of recording.
	var tag := func(b: PackedByteArray, at: int) -> String:
		return b.slice(at, at + 4).get_string_from_ascii()
	var small := header_bytes(48000, 48000)
	if small.size() != HEADER_BYTES or tag.call(small, 0) != "RIFF" or tag.call(small, 8) != "WAVE":
		return false
	if tag.call(small, 12) != "JUNK" or small.decode_u32(16) != 28:
		return false
	if tag.call(small, 48) != "fmt " or small.decode_u16(56) != 3 or small.decode_u16(58) != 2:
		return false
	if small.decode_u32(60) != 48000 or small.decode_u32(64) != 48000 * BYTES_PER_FRAME:
		return false
	if small.decode_u16(68) != BYTES_PER_FRAME or small.decode_u16(70) != 32:
		return false
	if tag.call(small, 72) != "data" or small.decode_u32(76) != 48000 * BYTES_PER_FRAME:
		return false
	if small.decode_u32(4) != HEADER_BYTES - 8 + 48000 * BYTES_PER_FRAME:
		return false
	# the last take that still fits a 32-bit RIFF, and the first one that does not
	var edge: int = (MAX_U32 - (HEADER_BYTES - 8)) / BYTES_PER_FRAME
	if tag.call(header_bytes(edge, 96000), 0) != "RIFF":
		return false
	var big := header_bytes(edge + 1, 96000)
	if tag.call(big, 0) != "RF64" or tag.call(big, 12) != "ds64":
		return false
	# 32-bit fields say "look at ds64"; the real sizes are the 64-bit ones
	if big.decode_u32(4) != MAX_U32 or big.decode_u32(76) != MAX_U32:
		return false
	var data_bytes: int = (edge + 1) * BYTES_PER_FRAME
	if big.decode_u64(20) != HEADER_BYTES - 8 + data_bytes or big.decode_u64(28) != data_bytes:
		return false
	if big.decode_u64(36) != edge + 1 or big.decode_u32(44) != 0:
		return false
	# a 3-hour 96 kHz take: 8.3 GB, and every field still exact
	var long := header_bytes(96000 * 3600 * 3, 96000)
	return tag.call(long, 0) == "RF64" and long.decode_u64(28) == 96000 * 3600 * 3 * BYTES_PER_FRAME \
		and header_bytes(48000, 48000, true).slice(0, 4).get_string_from_ascii() == "RF64"
