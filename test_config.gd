extends SceneTree
## Runnable check for the config file on disk (player.gd save_cfg_atomic / load_cfg_safe):
##   1. a save over an existing file succeeds and keeps the previous one as .bak
##   2. no .tmp is left behind
##   3. a live file that will not parse is moved aside -- NOT overwritten -- and the .bak
##      is what loads
##   4. with nothing on disk at all, the load is simply empty
## Runs in its own user://cfg_test folder and removes it, so no real library.cfg is ever
## touched. Step 3 prints an engine parse ERROR: that is the input under test.
##   godot --headless --path . --script res://test_config.gd

const DIR := "user://cfg_test"

func _initialize() -> void:
	var player = load("res://player.gd")   # static helpers only; nothing enters a tree
	DirAccess.make_dir_recursive_absolute(DIR)
	var live := ProjectSettings.globalize_path(DIR.path_join("library.cfg"))
	_clean(live)
	var ok := true

	var first := ConfigFile.new()
	first.set_value("library", "sort", 1)
	var second := ConfigFile.new()
	second.set_value("library", "sort", 2)
	var saved: bool = player.save_cfg_atomic(first, live) == OK \
		and player.save_cfg_atomic(second, live) == OK
	var now := ConfigFile.new()
	var bak := ConfigFile.new()
	var swapped: bool = saved and now.load(live) == OK and now.get_value("library", "sort") == 2 \
		and bak.load(live + ".bak") == OK and bak.get_value("library", "sort") == 1 \
		and not FileAccess.file_exists(live + ".tmp")
	ok = ok and swapped
	print("second save swapped in, first kept as .bak, no .tmp left: %s" % swapped)

	var f := FileAccess.open(live, FileAccess.WRITE)
	f.store_string("[library\nsort=\"unterminated\n")
	f.close()
	var loaded := ConfigFile.new()
	var kept: String = player.load_cfg_safe(loaded, live)
	var kept_path := live.get_base_dir().path_join(kept)
	var recovered: bool = not kept.is_empty() and FileAccess.file_exists(kept_path) \
		and FileAccess.get_file_as_string(kept_path).begins_with("[library") \
		and not FileAccess.file_exists(live) \
		and loaded.get_value("library", "sort", -1) == 1
	ok = ok and recovered
	print("unparseable file kept intact as %s, .bak loaded instead: %s" % [kept, recovered])

	_clean(live)
	var empty := ConfigFile.new()
	var nothing: bool = player.load_cfg_safe(empty, live).is_empty() and empty.get_sections().is_empty()
	ok = ok and nothing
	print("nothing on disk loads empty and moves nothing: %s" % nothing)

	_clean(live)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _clean(live: String) -> void:
	for name in DirAccess.get_files_at(live.get_base_dir()):
		DirAccess.remove_absolute(live.get_base_dir().path_join(name))
