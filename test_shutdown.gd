extends SceneTree
## Closing never waits out ffmpeg (audit C3). Exit codes: 0 PASS, 1 FAIL.
##   1. a long ffmpeg encode running on an engine worker is killed by shutdown(): shutdown()
##      returns in well under a second, and the worker reads a failed exit instead of a result
##   2. a process spawned by a caller that is already cancelled is ended at birth -- the race
##      where a worker spawns just as the kill sweep runs
##   3. nothing sticks: a short process run afterwards exits 0 with its output written
##   godot --headless --path . --script res://test_shutdown.gd

const LONG := ["-v", "error", "-y", "-nostdin", "-f", "lavfi", "-i", "sine=d=600:sample_rate=192000",
	"-c:a", "flac", "-compression_level", "12"]

func _initialize() -> void:
	var dir := ProjectSettings.globalize_path("user://shutdown_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var ok := true

	# 1. killed mid-encode
	var engine := AudioEngine.new()
	var code := [999]
	engine.run_task(func() -> void:
		code[0] = AudioEngine.run_process("ffmpeg", LONG + [dir.path_join("long.flac")], engine.is_shut_down))
	await create_timer(0.6).timeout
	var running: bool = code[0] == 999
	var t := Time.get_ticks_usec()
	engine.shutdown()
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	var killed: bool = running and ms < 1000.0 and code[0] != 0 and code[0] != 999
	ok = ok and killed
	print("1. shutdown() with a 10-minute encode running returned in %.0f ms; the worker read exit %d: %s" % [ms, code[0], killed])

	# 2. a spawn whose caller is already cancelled
	var t2 := Time.get_ticks_usec()
	var late := AudioEngine.run_process("ffmpeg", LONG + [dir.path_join("late.flac")], func() -> bool: return true)
	var late_ms := (Time.get_ticks_usec() - t2) / 1000.0
	var born_dead := late != 0 and late_ms < 1000.0
	ok = ok and born_dead
	print("2. a spawn racing a shutdown ended in %.0f ms with exit %d: %s" % [late_ms, late, born_dead])

	# 3. nothing left sticky
	var out := dir.path_join("short.wav")
	var short := AudioEngine.run_process("ffmpeg", ["-v", "error", "-y", "-nostdin", "-f", "lavfi", "-i", "sine=d=0.2", out])
	var clean := short == 0 and FileAccess.file_exists(out)
	ok = ok and clean
	print("3. a short process afterwards exits %d with its output written: %s" % [short, clean])

	engine.free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
