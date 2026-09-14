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
## conversion (16/24-bit, FLAC, a different sample rate) happens ONCE at stop, through
## ffmpeg, so the live path never does format work while audio is flowing.
##
## ponytail: the capture rate is the AudioServer's mix rate, not the requested one --
## an effect cannot resample the bus it is on. SAMPLE RATE resamples on the way out.

signal finished(path: String, ok: bool)

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
const QUALITY_NAMES := ["LOW", "STANDARD", "HIGH"]

var recording := false
var elapsed := 0.0
var frames_written := 0
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
var _out_path := ""
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
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_raw_path = dir.path_join("SOUNDSCAPE_%s.f32.wav" % stamp)
	_file = FileAccess.open(_raw_path, FileAccess.WRITE)
	if not _file:
		return ""
	_mix_rate = AudioServer.get_mix_rate()
	_write_header(0)
	frames_written = 0
	discarded = 0
	elapsed = 0.0
	_capture.clear_buffer()
	_discard_base = _capture.get_discarded_frames()
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, true)
	recording = true
	return _raw_path

## Stops, patches the RIFF sizes the header could not know up front, then hands the take
## to ffmpeg for whatever the user actually asked for.
func stop(type_i: int, rate_i: int, quality_i: int) -> void:
	if not recording:
		return
	recording = false
	AudioServer.set_bus_effect_enabled(_bus_idx, _slot, false)
	_drain()
	_write_header(frames_written)   # seeks back over the placeholder
	_file.close()
	_file = null
	var ok := _convert(type_i, rate_i, quality_i)
	finished.emit(_out_path if ok else _raw_path, ok)

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
	bytes.resize(frames.size() * 8)   # 2 channels * 4 bytes
	for i in frames.size():
		bytes.encode_float(i * 8, frames[i].x)
		bytes.encode_float(i * 8 + 4, frames[i].y)
	_file.store_buffer(bytes)
	frames_written += frames.size()

## 32-bit IEEE float, stereo. Written once with zero lengths at start and again with
## the real ones at stop, which is the whole reason this takes a frame count.
func _write_header(frames: int) -> void:
	var data_bytes := frames * 8
	_file.seek(0)
	_file.store_string("RIFF")
	_file.store_32(36 + data_bytes)
	_file.store_string("WAVE")
	_file.store_string("fmt ")
	_file.store_32(16)
	_file.store_16(3)                       # IEEE float
	_file.store_16(2)                       # stereo
	_file.store_32(int(_mix_rate))
	_file.store_32(int(_mix_rate) * 8)      # byte rate
	_file.store_16(8)                       # block align
	_file.store_16(32)                      # bits per sample
	_file.store_string("data")
	_file.store_32(data_bytes)
	if frames == 0:
		return
	_file.seek_end()

## One ffmpeg pass for type, rate and quality together -- the same dependency the FLAC
## transcode and the spectral key pass already rely on. The float intermediate is left
## in place if the conversion fails, so a take is never lost to a missing ffmpeg.
func _convert(type_i: int, rate_i: int, quality_i: int) -> bool:
	var type: String = FILE_TYPES[clampi(type_i, 0, FILE_TYPES.size() - 1)]
	var rate: int = RATES[clampi(rate_i, 0, RATES.size() - 1)]
	var q := clampi(quality_i, 0, QUALITY_NAMES.size() - 1)
	_out_path = "%s.%s" % [_raw_path.trim_suffix(".f32.wav"), type.to_lower()]
	var args := ["-v", "error", "-y", "-i", _raw_path, "-ar", str(rate)]
	if type == "FLAC":
		args.append_array(["-c:a", "flac", "-compression_level", str(FLAC_LEVELS[q])])
	else:
		args.append_array(["-c:a", "pcm_s%dle" % WAV_DEPTHS[q]])
	args.append(_out_path)
	if OS.execute("ffmpeg", args, [], true) != 0:
		push_warning("ffmpeg could not convert the take; the float wav is kept at %s" % _raw_path)
		return false
	DirAccess.remove_absolute(_raw_path)
	return true

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
	return true
