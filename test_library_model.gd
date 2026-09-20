extends SceneTree
## Runnable check for LibraryModel, the library's data layer:
##   1. the pure rules (path nesting, sort keys, track ids, RELOCATE, id migration)
##   2. a real disk scan on a worker thread: progress arrives, the walk finds what is there, each
##      new track's id is sized on the worker, and the folder filter drops what is switched off
##   3. a scan can be cancelled mid-walk and leaves the library it was replacing untouched
##   4. cues and labels survive the library MOVING, which is the whole point of keying by id
##   5. .ape and .tak index like any other track and decode to a playable stream through the
##      ffmpeg render, with a length the cached metadata agrees with
##   6. sorting by BPM orders on the tag, with untagged tracks last
## Touches only a scratch directory it makes and removes. No audio device, no user://.
##   godot --headless --path . --script res://test_library_model.gd

func _make_tree(base: String, dirs: Array, per_dir: int) -> void:
	for d in dirs:
		var dir := base.path_join(str(d))
		DirAccess.make_dir_recursive_absolute(dir)
		for i in per_dir:
			var f := FileAccess.open(dir.path_join("track_%d.mp3" % i), FileAccess.WRITE)
			f.store_buffer(("%s-%d" % [d, i]).to_utf8_buffer())   # distinct sizes per name
			f.close()
		var cover := FileAccess.open(dir.path_join("cover.jpg"), FileAccess.WRITE)
		cover.store_8(0)
		cover.close()

## A real 22.05 kHz mono WAV. Written under an .ape/.tak name in section 6: ffmpeg chooses its
## demuxer by content, so this exercises the render route without an encoder nothing here has.
func _wav(path: String, secs: float) -> void:
	var sr := 22050
	var n := int(sr * secs)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(sin(TAU * 440.0 * float(i) / sr) * 0.3 * 32767.0))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("RIFF")
	f.store_32(36 + data.size())
	f.store_string("WAVEfmt ")
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(sr)
	f.store_32(sr * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_string("data")
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()

func _rm(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)

func _initialize() -> void:
	var ok := true

	var pure := LibraryModel.model_test()
	ok = ok and pure
	print("1. path rules, sort keys, track ids, relocate, migration (model_test): %s" % pure)

	var base := OS.get_temp_dir().path_join("ss_libmodel_%d" % Time.get_ticks_usec())
	_make_tree(base, ["rock", "rock/live", "jazz"], 3)
	# lossless formats with no native decoder are ordinary library tracks: the walk takes them by
	# name, and AudioEngine renders them when one is actually played (section 6)
	for name in ["extra.ape", "extra.tak"]:
		var f := FileAccess.open(base.path_join("jazz").path_join(name), FileAccess.WRITE)
		f.store_buffer(name.to_utf8_buffer())
		f.close()

	var model := LibraryModel.new()
	root.add_child(model)
	model.engine = AudioEngine.new()   # never enters the tree: only its id map and file stamps are used
	model.folders = [base]
	for d in ["rock", "rock/live", "jazz"]:
		model.enabled_folders[base.path_join(d)] = true

	# a GDScript lambda captures by VALUE, so the counters live in containers the lambda
	# mutates rather than in locals it would only shadow
	var seen := {"ticks": 0, "found": -1, "cancelled": true}
	model.scan_progress.connect(func(_done: int, _total: int, _where: String) -> void:
		seen["ticks"] += 1)
	model.scan_finished.connect(func(n: int, cancelled: bool) -> void:
		seen["found"] = n
		seen["cancelled"] = cancelled)
	var started := model.scan()
	var double_start := model.scan()   # a second scan while one runs is refused, not queued
	var guard := 0
	while int(seen["found"]) < 0 and guard < 600:
		await process_frame
		guard += 1
	var found: int = seen["found"]
	var ticks: int = seen["ticks"]
	var was_cancelled: bool = seen["cancelled"]
	var scanned: bool = started and not double_start and found == 11 and not was_cancelled \
		and model.paths.size() == 11 and model.index.size() == 11
	# the ids the WORKER sized are the ones id_for would have stat'ed its way to on this thread
	var sized := model.engine.track_ids.size() == 11
	for p: String in model.all_paths:
		sized = sized and model.engine.track_ids.get(p) == LibraryModel.track_id(p, FileAccess.get_file_as_bytes(p).size())
	ok = ok and scanned and sized
	print("2. worker scan found %d tracks (want 11: 9 mp3 plus an .ape and a .tak, cover.jpg ignored), %d progress ticks, refused a second start: %s; ids sized on the worker: %s" % [
		found, ticks, scanned, sized])

	# a folder switched off leaves the disk alone and only shortens the visible list
	model.enabled_folders.erase(base.path_join("jazz"))
	model.apply_folder_filter()
	var filtered: bool = model.paths.size() == 6 and model.all_paths.size() == 11
	ok = ok and filtered
	print("3. unchecking a folder: %d of %d showing: %s" % [model.paths.size(), model.all_paths.size(), filtered])

	# cues and a label against ONE track, then the whole library moves
	var some := model.paths[0]
	var id := model.id_for(some)
	model.cues[id] = [{"time": 12.5, "color": "#ff0000"}]
	model.labels[id] = "RENAMED"
	var moved_base := base + "_moved"
	DirAccess.rename_absolute(base, moved_base)
	var roots_moved := model.relocate(base, moved_base)
	model.enabled_folders[moved_base.path_join("jazz")] = true
	seen["found"] = -1
	model.scan()
	guard = 0
	while int(seen["found"]) < 0 and guard < 600:
		await process_frame
		guard += 1
	found = seen["found"]
	var same_id := model.id_for(some.replace(base, moved_base))
	var kept: bool = roots_moved == 1 and found == 11 and same_id == id \
		and model.cues_for(some.replace(base, moved_base)).size() == 1 \
		and model.index[model.path_pos[some.replace(base, moved_base)]]["file"] == "RENAMED"
	ok = ok and kept
	print("4. library moved on disk: %d root re-pointed, id unchanged %s, cue and RENAME tag followed it: %s" % [
		roots_moved, same_id == id, kept])

	# cancellation: ask mid-walk and the previous library is still what is showing
	var before := model.all_paths.size()
	model.scan()
	model.stop_scan()
	var cancel_ok: bool = not model.scanning() and model.all_paths.size() == before
	ok = ok and cancel_ok
	print("5. scan cancelled mid-walk, library left at %d tracks: %s" % [model.all_paths.size(), cancel_ok])

	# 6 (listed as 5 above, after the cancellation check). APE and TAK reach a playable stream. Nothing on this machine ENCODES either format (ffmpeg
	# decodes both but encodes neither, and there is no Monkey's Audio or TAK tool here), so the
	# fixtures carry real WAV bytes under those names: ffmpeg picks its demuxer by CONTENT, so this
	# drives the whole route -- decode() routing, the ffmpeg render, the FLAC that comes back, its
	# length and its cached metadata -- and only ffmpeg's own APE/TAK decoders are left untested.
	var engine: AudioEngine = model.engine
	engine.lossless_dir = moved_base.path_join("renders")
	var decoded := []
	for ext in ["ape", "tak"]:
		var src := moved_base.path_join("tone.%s" % ext)
		_wav(src, 0.5)
		var stream := engine.decode(src)
		var meta := engine.metadata(src)
		decoded.append([ext, stream != null, 0.0 if stream == null else stream.get_length(),
			float(meta.get("duration", -1.0))])
	var renders := DirAccess.get_files_at(engine.lossless_dir).size()
	var plays: bool = AudioEngine.native_flac_available()
	if plays:
		for d in decoded:
			plays = plays and bool(d[1]) and absf(float(d[2]) - 0.5) < 0.02 and absf(float(d[3]) - 0.5) < 0.02
		plays = plays and renders == 2   # one render per source, cached by path + mtime + size
		ok = ok and plays
	else:
		print("   (libsoundscape_dsp absent: the render still runs, but nothing can play a FLAC)")
	print("6. .ape and .tak decode through an ffmpeg render [ext, stream, length, meta duration]: %s, %d renders cached: %s" % [
		decoded, renders, plays])

	# 7. sorting BY BPM orders on the tag, not on the filename. The keys being right is not
	# enough: the comparator has to reach for them, and BPM once sat in META_SORTS while the
	# comparator listed the metadata sorts by name, so it sorted by path and looked plausible.
	var tempos: Array[String] = []
	for spec in [["slow", "90"], ["mid", "128"], ["fast", "129"], ["untagged", ""]]:
		var made := moved_base.path_join("%s.flac" % spec[0])
		var args := ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2"]
		if not str(spec[1]).is_empty():
			args.append_array(["-metadata", "BPM=%s" % spec[1]])
		args.append(made)
		OS.execute("ffmpeg", args, [], true)
		engine.metadata(made)   # the sort reads what is cached, so probe them first
		tempos.append(made)
	model.paths = tempos
	var by_bpm := model.sorted("BPM")
	var order: Array[String] = []
	for path: String in by_bpm:
		order.append(path.get_file().get_basename())
	var bpm_sorted: bool = order == ["slow", "mid", "fast", "untagged"]
	ok = ok and bpm_sorted
	print("7. sorted by BPM (90, 128, 129, untagged last): %s: %s" % [order, bpm_sorted])

	model.engine.free()
	model.free()
	_rm(moved_base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
