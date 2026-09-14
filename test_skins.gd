extends SceneTree
## Runnable check for user skins (Skins.load_user_skins / parse_skin / apply):
##   1. a partial palette with [style] overrides loads; missing colours fall back to WIN98's
##   2. a file with an unparseable colour, a name that would shadow a built-in, and a
##      non-.cfg file are all refused
##   3. applying the user skin paints its colours, puts its border width ONLY on boxes that
##      already had a border, and rounds corners
##   4. switching back to a built-in restores the stock 1 px borders and square corners
## Works in user://skin_test and removes it; the real user://skins is never touched.
##   godot --headless --path . --script res://test_skins.gd

const DIR := "user://skin_test"

func _write(name: String, body: String) -> void:
	var f := FileAccess.open(DIR.path_join(name), FileAccess.WRITE)
	f.store_string(body)
	f.close()

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_write("neon.cfg", "[colors]\npanel=\"#102030\"\naccent=\"#39ff14\"\n\n[style]\nborder_width=2\ncorner_radius=3\n")
	_write("broken.cfg", "[colors]\npanel=\"not a colour\"\n")
	_write("win98.cfg", "[colors]\npanel=\"#ff0000\"\n")
	_write("notes.txt", "[colors]\npanel=\"#00ff00\"\n")
	var ok := true

	var loaded := Skins.load_user_skins(DIR)
	var only_neon: bool = loaded == ["NEON"] and "NEON" in Skins.names() and not "BROKEN" in Skins.names()
	var neon: Dictionary = Skins.user_schemes.get("NEON", {})
	var fallback: bool = not neon.is_empty() and neon["header"] == Skins.SCHEMES["WIN98"]["header"] \
		and neon["panel"] == Color.html("#102030") and neon["border_width"] == 2 and neon["corner_radius"] == 3
	ok = ok and only_neon and fallback
	print("loaded %s; broken, shadowing and non-cfg files refused: %s; missing keys fall back to WIN98: %s" % [
		loaded, only_neon, fallback])

	var root: Control = load("res://player.tscn").instantiate()   # never enters the tree: no _ready
	var theme: Theme = root.theme
	Skins.apply(theme, root, "NEON")
	var panel := theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat
	var fill := theme.get_stylebox("fill", "ProgressBar") as StyleBoxFlat
	var painted: bool = panel.bg_color == Color.html("#102030") \
		and theme.get_color("font_color", "Green") == Color.html("#39ff14")
	var styled: bool = panel.border_width_left == 2 and fill.border_width_left == 0 \
		and panel.corner_radius_top_left == 3
	ok = ok and painted and styled
	print("NEON painted %s; 2 px border on bordered boxes only, 3 px corners: %s" % [painted, styled])

	Skins.apply(theme, root, "WIN98")
	var restored: bool = panel.border_width_left == 1 and fill.border_width_left == 0 \
		and panel.corner_radius_top_left == 0 and panel.bg_color == Skins.SCHEMES["WIN98"]["panel"]
	ok = ok and restored
	print("back on WIN98: stock borders, square corners and colours restored: %s" % restored)

	root.free()
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	Skins.user_schemes.clear()
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
