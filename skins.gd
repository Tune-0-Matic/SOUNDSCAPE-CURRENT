class_name Skins
## Whole-program colour schemes. Every stylebox in player.tscn is a shared sub-resource,
## so recolouring the resource in place repaints every panel that uses it -- no need to
## rebuild the theme or touch individual nodes.

const NAMES := ["WIN98", "MAROON", "MIDNIGHT", "AMBER", "TOKYO", "TERMINAL", "ICE",
	"VAPORWAVE", "MIAMI", "C64", "HAZARD", "BLACK"]

## Schemes may set a second accent. Where they do, "accent2" drives the filled
## indicators (progress bars, fader tracks, list selection) while "accent" keeps the
## text highlights -- that split is what makes the two-tone skins read as two-tone
## instead of one hue smeared over everything. Mono skins just omit it.

const SCHEMES := {
	# Default: Windows 98 industrial grey chassis, black material parts.
	"WIN98": {
		"window": Color(0.847, 0.855, 0.827), "panel": Color(0.886, 0.886, 0.875),
		"border": Color(0.29, 0.333, 0.408), "header": Color(0, 0, 0),
		"header_text": Color(1, 1, 1), "text": Color(0, 0, 0),
		"screen": Color(0, 0, 0), "screen_text": Color(0.769, 0.788, 0.741),
		"accent": Color(0.18, 0.8, 0.443),
	},
	"MAROON": {
		"window": Color(0.192, 0.075, 0.086), "panel": Color(0.259, 0.106, 0.118),
		"border": Color(0.463, 0.212, 0.227), "header": Color(0, 0, 0),
		"header_text": Color(0.976, 0.827, 0.694), "text": Color(0.949, 0.788, 0.647),
		"screen": Color(0.055, 0.016, 0.02), "screen_text": Color(0.882, 0.667, 0.545),
		"accent": Color(0.847, 0.267, 0.271), "accent2": Color(0.902, 0.663, 0.259),
	},
	"VAPORWAVE": {
		"window": Color(0.145, 0.098, 0.216), "panel": Color(0.208, 0.137, 0.298),
		"border": Color(0.443, 0.290, 0.612), "header": Color(0, 0, 0),
		"header_text": Color(0.482, 0.933, 0.945), "text": Color(0.925, 0.780, 0.988),
		"screen": Color(0.043, 0.020, 0.086), "screen_text": Color(0.792, 0.671, 0.973),
		"accent": Color(1.0, 0.353, 0.749), "accent2": Color(0.365, 0.918, 0.937),
	},
	"MIAMI": {
		"window": Color(0.055, 0.243, 0.263), "panel": Color(0.086, 0.325, 0.345),
		"border": Color(0.192, 0.514, 0.529), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.855, 0.400), "text": Color(0.902, 0.976, 0.969),
		"screen": Color(0.016, 0.086, 0.098), "screen_text": Color(0.706, 0.937, 0.925),
		"accent": Color(1.0, 0.290, 0.549), "accent2": Color(1.0, 0.804, 0.290),
	},
	"C64": {
		"window": Color(0.416, 0.353, 0.804), "panel": Color(0.518, 0.463, 0.859),
		"border": Color(0.259, 0.204, 0.643), "header": Color(0, 0, 0),
		"header_text": Color(0.647, 0.596, 0.918), "text": Color(0.106, 0.075, 0.353),
		"screen": Color(0.157, 0.118, 0.482), "screen_text": Color(0.702, 0.663, 0.937),
		"accent": Color(0.647, 0.596, 0.918), "accent2": Color(0.925, 0.859, 0.588),
	},
	"HAZARD": {
		"window": Color(0.118, 0.114, 0.098), "panel": Color(0.180, 0.169, 0.137),
		"border": Color(0.376, 0.337, 0.196), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.843, 0.161), "text": Color(0.906, 0.859, 0.678),
		"screen": Color(0.043, 0.039, 0.031), "screen_text": Color(0.859, 0.780, 0.478),
		"accent": Color(1.0, 0.796, 0.078), "accent2": Color(1.0, 0.427, 0.086),
	},
	"MIDNIGHT": {
		"window": Color(0.07, 0.078, 0.11), "panel": Color(0.106, 0.118, 0.157),
		"border": Color(0.227, 0.247, 0.322), "header": Color(0, 0, 0),
		"header_text": Color(0.902, 0.902, 0.902), "text": Color(0.784, 0.8, 0.847),
		"screen": Color(0.02, 0.024, 0.039), "screen_text": Color(0.6, 0.64, 0.72),
		"accent": Color(0.18, 0.8, 0.443),
	},
	"AMBER": {
		"window": Color(0.169, 0.129, 0.094), "panel": Color(0.227, 0.173, 0.118),
		"border": Color(0.42, 0.325, 0.204), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.761, 0.4), "text": Color(1.0, 0.702, 0.278),
		"screen": Color(0.039, 0.027, 0.016), "screen_text": Color(1.0, 0.651, 0.169),
		"accent": Color(1.0, 0.651, 0.169),
	},
	"TOKYO": {
		"window": Color(0.102, 0.071, 0.149), "panel": Color(0.141, 0.102, 0.2),
		"border": Color(0.353, 0.239, 0.478), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.373, 0.824), "text": Color(0.847, 0.776, 1.0),
		"screen": Color(0.024, 0.012, 0.063), "screen_text": Color(0.788, 0.62, 1.0),
		"accent": Color(1.0, 0.184, 0.71),
	},
	"TERMINAL": {
		"window": Color(0.039, 0.059, 0.039), "panel": Color(0.063, 0.094, 0.063),
		"border": Color(0.184, 0.29, 0.184), "header": Color(0, 0, 0),
		"header_text": Color(0.49, 1.0, 0.49), "text": Color(0.271, 0.851, 0.271),
		"screen": Color(0, 0, 0), "screen_text": Color(0.224, 1.0, 0.078),
		"accent": Color(0.224, 1.0, 0.078),
	},
	"ICE": {
		"window": Color(0.8, 0.839, 0.871), "panel": Color(0.867, 0.898, 0.918),
		"border": Color(0.29, 0.373, 0.42), "header": Color(0, 0, 0),
		"header_text": Color(1, 1, 1), "text": Color(0.063, 0.133, 0.169),
		"screen": Color(0, 0.031, 0.059), "screen_text": Color(0.616, 0.792, 0.867),
		"accent": Color(0.216, 0.835, 0.949),
	},
	# Pitch black: window, panel, header and screen are all literal (0,0,0), not a dark
	# shade of one -- an OLED-off background, not a "dark theme". Border and text sit at
	# just enough grey to stay legible against it; the accent is neutral white rather
	# than a hue, so nothing here reads as a tint of black.
	"BLACK": {
		"window": Color(0, 0, 0), "panel": Color(0, 0, 0),
		"border": Color(0.18, 0.18, 0.18), "header": Color(0, 0, 0),
		"header_text": Color(1, 1, 1), "text": Color(0.85, 0.85, 0.85),
		"screen": Color(0, 0, 0), "screen_text": Color(1, 1, 1),
		"accent": Color(1, 1, 1),
	},
}

# --- user skins ------------------------------------------------------------------
## Palettes dropped into user://skins as .cfg files, no rebuild needed:
##
##   [colors]
##   window="#101418"
##   accent="#39ff14"          ; any SCHEME_KEYS entry, "#rrggbb" or a Color(...) literal
##   [style]
##   border_width=2            ; 0..4, applied only to boxes that have a border already
##   corner_radius=0           ; 0..12
##
## Missing colours fall back to WIN98's, so a three-line file is a whole skin. A value that
## will not parse rejects the FILE rather than guessing at it, and a name that collides with
## a built-in is refused, so a stray win98.cfg can never silently replace the default.
const USER_SKIN_DIR := "user://skins"
const SCHEME_KEYS := ["window", "panel", "border", "header", "header_text", "text",
	"screen", "screen_text", "accent"]

static var user_schemes := {}      # NAME -> scheme Dictionary, same shape as SCHEMES
static var _base_border := {}      # StyleBoxFlat -> its border width as player.tscn built it

static func names() -> Array:
	var out: Array = NAMES.duplicate()
	for n in user_schemes:
		out.append(n)
	return out

## A built-in or user scheme by name; anything unknown is WIN98.
static func scheme(name: String) -> Dictionary:
	return SCHEMES.get(name, user_schemes.get(name, SCHEMES["WIN98"]))

## The Video TEST picture's palette for a skin, dark to light as video_test.gdshader samples
## it: the screen's own background, through the accent, up to the screen's text colour. The
## picture then reads as part of that skin's screen instead of a green terminal pasted in.
## An accent that repeats an end (AMBER, TERMINAL and BLACK use their text colour) is left
## out: the shader draws four stops, and a repeated colour would spend one of them twice.
static func video_ramp(name: String) -> Gradient:
	var s := scheme(name)
	var g := Gradient.new()
	if s.accent.is_equal_approx(s.screen) or s.accent.is_equal_approx(s.screen_text):
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([s.screen, s.screen_text])
	else:
		g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
		g.colors = PackedColorArray([s.screen, s.accent, s.screen_text])
	return g

## The visualizer's SKIN swatch: accent to accent2. A mono skin has no accent2, so it draws flat
## in its one accent, the way a fixed preset does.
static func accent_ramp(name: String) -> Gradient:
	var s := scheme(name)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([s.accent, s.get("accent2", s.accent)])
	return g

## Rescans `dir` (created if missing, so the folder itself documents where skins go) and
## returns the names that loaded. Cheap enough to call on every SKIN click.
static func load_user_skins(dir := USER_SKIN_DIR) -> Array[String]:
	user_schemes.clear()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var loaded: Array[String] = []
	var files := Array(DirAccess.get_files_at(dir))
	files.sort()
	for f: String in files:
		if f.get_extension().to_lower() != "cfg":
			continue
		var skin_name := f.get_basename().to_upper()
		if skin_name in NAMES:
			push_warning("Skins: %s would shadow the built-in %s skin; ignored" % [f, skin_name])
			continue
		var s := parse_skin(dir.path_join(f))
		if s.is_empty():
			push_warning("Skins: %s did not parse as a skin; ignored" % f)
			continue
		user_schemes[skin_name] = s
		loaded.append(skin_name)
	return loaded

static func parse_skin(path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return {}
	var base: Dictionary = SCHEMES["WIN98"]
	var s := {}
	var any := false
	for key in SCHEME_KEYS + ["accent2"]:
		# has_section_key first: get_value with a null default counts as NO default, and
		# Godot logs an ERROR for every colour a partial skin leaves out
		if not cfg.has_section_key("colors", key):
			if key in SCHEME_KEYS:
				s[key] = base[key]
			continue
		var v: Variant = cfg.get_value("colors", key)
		if v is Color:
			s[key] = v
		elif v is String and Color.html_is_valid(v):
			s[key] = Color.html(v)
		else:
			return {}
		any = true
	if not any:
		return {}
	var bw: Variant = cfg.get_value("style", "border_width", 1)
	var cr: Variant = cfg.get_value("style", "corner_radius", 0)
	s["border_width"] = clampi(int(bw), 0, 4) if (bw is int or bw is float) else 1
	s["corner_radius"] = clampi(int(cr), 0, 12) if (cr is int or cr is float) else 0
	return s

static func apply(theme: Theme, root: Control, name: String) -> void:
	var s: Dictionary = scheme(name)
	var a2: Color = s.get("accent2", s.accent)
	# One theme-changed pass, not sixty-odd.
	#
	# Every set_color() below emits the theme's `changed`, and every StyleBoxFlat write
	# emits the box's own `changed`, which the Theme re-emits as its own. The writes
	# themselves are trivial; what costs a frame is that each emission walks the entire
	# Control tree with NOTIFICATION_THEME_CHANGED, and every Control re-fetches and
	# re-caches every style, font and colour it uses -- roughly 60 full-tree passes for
	# one skin switch, on a tree that includes 16 EQ faders, a 6-module FX rack and the
	# track list.
	#
	# Blocking the theme's signal collapses them into the single emit_changed() at the
	# end. Nothing is drawn in between: this all happens inside one call, well before the
	# frame is rendered, so there is no intermediate state to see.
	theme.set_block_signals(true)
	# root chassis is a per-node override, not a theme entry
	var chassis: StyleBoxFlat = root.get("theme_override_styles/panel")
	if chassis:
		chassis.bg_color = s.window

	for spec in [["PanelContainer", "panel"], ["Button", "normal"], ["Button", "hover"],
			["Button", "pressed"], ["Button", "focus"]]:
		var sb: StyleBoxFlat = theme.get_stylebox(spec[1], spec[0])
		if sb:
			sb.border_color = s.border
	_flat(theme, "PanelContainer", "panel").bg_color = s.panel
	_flat(theme, "Header", "panel").bg_color = s.header
	_flat(theme, "Screen", "panel").bg_color = s.screen
	_flat(theme, "Screen", "panel").border_color = s.border
	_flat(theme, "Button", "normal").bg_color = s.panel
	_flat(theme, "Button", "hover").bg_color = s.border
	_flat(theme, "Button", "pressed").bg_color = s.header
	_flat(theme, "ProgressBar", "background").bg_color = s.screen
	_flat(theme, "ProgressBar", "background").border_color = s.border
	_flat(theme, "ProgressBar", "fill").bg_color = a2
	_flat(theme, "ItemList", "panel").bg_color = s.screen
	_flat(theme, "ItemList", "panel").border_color = s.border
	_flat(theme, "ItemList", "selected").bg_color = a2
	_flat(theme, "ItemList", "selected_focus").bg_color = a2
	for style in ["grabber_area", "grabber_area_highlight"]:
		_flat(theme, "VSlider", style).bg_color = a2
	_flat(theme, "VSlider", "slider").bg_color = s.screen
	_flat(theme, "VSlider", "slider").border_color = s.border
	_flat(theme, "PopupMenu", "panel").bg_color = s.screen
	_flat(theme, "PopupMenu", "panel").border_color = s.border
	_flat(theme, "PopupMenu", "hover").bg_color = a2
	theme.set_color("font_color", "PopupMenu", s.screen_text)
	theme.set_color("font_hover_color", "PopupMenu", s.screen)
	theme.set_color("font_color", "LineEdit", s.screen_text)
	theme.set_color("font_placeholder_color", "LineEdit", Color(s.screen_text, 0.45))
	theme.set_color("caret_color", "LineEdit", a2)
	for axis in ["VScrollBar", "HScrollBar"]:
		_flat(theme, axis, "scroll").bg_color = s.screen
		_flat(theme, axis, "scroll").border_color = s.border
		_flat(theme, axis, "grabber").bg_color = s.panel
		_flat(theme, axis, "grabber").border_color = s.header

	theme.set_color("font_color", "Label", s.text)
	theme.set_color("font_color", "HeaderLabel", s.header_text)
	theme.set_color("font_color", "Green", s.accent)
	theme.set_color("font_color", "Button", s.text)
	theme.set_color("font_hover_color", "Button", s.header_text if s.window.get_luminance() < 0.4 else s.text)
	theme.set_color("font_pressed_color", "Button", s.accent)
	theme.set_color("font_color", "ItemList", s.screen_text)
	theme.set_color("font_selected_color", "ItemList", s.screen)
	# the folder Tree shares ItemList's styleboxes (SB_screen, SB_bar_fill), which are
	# already recoloured above -- only its font colours need naming separately
	theme.set_color("font_color", "Tree", s.screen_text)
	theme.set_color("font_selected_color", "Tree", s.screen)
	theme.set_color("font_selected_color", "TabContainer", s.header_text)
	theme.set_color("font_unselected_color", "TabContainer", s.text)
	theme.set_color("font_hovered_color", "TabContainer", s.text)
	_flat(theme, "TabContainer", "tab_unselected").bg_color = s.panel
	_flat(theme, "TabContainer", "tab_unselected").border_color = s.border
	_flat(theme, "TabContainer", "tab_selected").bg_color = s.header
	_flat(theme, "TabContainer", "tabbar_background").bg_color = s.window
	_flat(theme, "TabContainer", "panel").bg_color = s.panel

	# [style] from a user skin, or the built-in look for every other skin. A border only
	# changes on a box that HAS one in player.tscn: the fills and headers are borderless on
	# purpose, and a 2 px user border must not grow one onto them.
	var bw: int = int(s.get("border_width", 1))
	var cr: int = int(s.get("corner_radius", 0))
	for type in theme.get_type_list():
		for box in theme.get_stylebox_list(type):
			var sb := theme.get_stylebox(box, type) as StyleBoxFlat
			if not sb:
				continue
			if not _base_border.has(sb):
				_base_border[sb] = sb.border_width_left
			sb.set_border_width_all(bw if int(_base_border[sb]) > 0 else 0)
			sb.set_corner_radius_all(cr)

	theme.set_block_signals(false)
	theme.emit_changed()   # the one pass that repaints the program

## A miss returns a throwaway box so the caller's assignment is harmless -- but silence
## there means a renamed or deleted theme entry makes that widget quietly stop following
## the skin, with nothing anywhere to say so. The warning is the whole point of this
## function existing rather than calling get_stylebox() inline.
static func _flat(theme: Theme, type: String, name: String) -> StyleBoxFlat:
	# has_stylebox first, and that check is the important one. For an entry that simply
	# is not there, get_stylebox does NOT return null -- it hands back a fresh default
	# StyleBoxFlat, which sails through an `is StyleBoxFlat` test and is exactly the
	# throwaway this function is meant to warn about. Type-checking alone caught only a
	# wrong-typed entry and stayed silent on a renamed or deleted one.
	if not theme.has_stylebox(name, type):
		push_warning("Skins: theme has no stylebox %s/%s -- that part of the skin will not apply"
			% [type, name])
		return StyleBoxFlat.new()
	var sb := theme.get_stylebox(name, type)
	if sb is StyleBoxFlat:
		return sb
	push_warning("Skins: %s/%s is not a StyleBoxFlat -- that part of the skin will not apply"
		% [type, name])
	return StyleBoxFlat.new()
