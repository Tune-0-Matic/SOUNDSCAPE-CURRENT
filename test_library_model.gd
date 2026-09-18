extends SceneTree
## Runnable check for LibraryModel, the library's data layer:
##   1. the pure rules (path nesting, sort keys, track ids, RELOCATE, id migration)
##   2. a real disk scan on a worker thread: progress arrives, the walk finds what is there,
##      and the folder filter drops what is switched off
##   3. a scan can be cancelled mid-walk and leaves the library it was replacing untouched
##   4. cues and labels survive the library MOVING, which is the whole point of keying by id
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

	var model := LibraryModel.new()
	root.add_child(model)
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
	var scanned: bool = started and not double_start and found == 9 and not was_cancelled \
		and model.paths.size() == 9 and model.index.size() == 9
	ok = ok and scanned
	print("2. worker scan found %d tracks (want 9, cover.jpg ignored), %d progress ticks, refused a second start: %s" % [
		found, ticks, scanned])

	# a folder switched off leaves the disk alone and only shortens the visible list
	model.enabled_folders.erase(base.path_join("jazz"))
	model.apply_folder_filter()
	var filtered: bool = model.paths.size() == 6 and model.all_paths.size() == 9
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
	var kept: bool = roots_moved == 1 and found == 9 and same_id == id \
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

	model.free()
	_rm(moved_base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
