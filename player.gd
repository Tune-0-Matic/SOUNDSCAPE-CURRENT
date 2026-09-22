extends PanelContainer
## MEDIA_PLAYER_SYS.EXE -- retro tactical skin over AudioStreamPlayer / VideoStreamPlayer.
## FOLDERS tab collects library roots, TRACKS tab lists everything under them, sorted by path.

## Build number, shown at the head of the STATS panel. One constant rather than a literal
## at the readout, so the next bump is one edit -- boot.gd's POST banner and
## export_presets.cfg still carry their own copies and have to be bumped alongside it.

## The editor and an exported build share user:// on this machine, so an editor save
## would otherwise be the first thing a shipped player sees. A different filename per
## side keeps the two odometers, libraries and presets apart; on a player's machine
## neither file exists yet, so the export always starts clean.
var _cfg: String = "user://library_dev.cfg" if OS.has_feature("editor") else "user://library.cfg"

## Typed reads out of library.cfg. The file is plain text a user can and will hand-edit,
## and a value of the WRONG TYPE is not the clamped-away nuisance an out-of-range number
## is: it throws at that line, which aborts the rest of _load(), leaves the deck players
## unbound, and then _process throws on a null stream every frame for the rest of the
## session. Measured: a single `folders="x"` line produced 451 errors in 45 frames and a
## permanently dead window. Wrong type now reads as "absent" and falls back, which is the
## same outcome as a fresh install.
static func _cfg_arr(cfg: ConfigFile, sect: String, key: String, fallback := []) -> Array:
	var v: Variant = cfg.get_value(sect, key, fallback)
	return v if v is Array else fallback

static func _cfg_dict(cfg: ConfigFile, sect: String, key: String) -> Dictionary:
	var v: Variant = cfg.get_value(sect, key, {})
	return v if v is Dictionary else {}

## Scalars need the same treatment, and the clamps do NOT provide it: clampi("name", 0, 3)
## throws on the String rather than clamping it, so a hand-typed `sort=name` was just as
## fatal as a wrong-typed Array.
static func _cfg_num(cfg: ConfigFile, sect: String, key: String, fallback: float) -> float:
	var v: Variant = cfg.get_value(sect, key, fallback)
	return float(v) if (v is float or v is int) else fallback

static func _cfg_str(cfg: ConfigFile, sect: String, key: String, fallback := "") -> String:
	var v: Variant = cfg.get_value(sect, key, fallback)
	return v if v is String else fallback

static func _cfg_bool(cfg: ConfigFile, sect: String, key: String, fallback: bool) -> bool:
	var v: Variant = cfg.get_value(sect, key, fallback)
	return v if v is bool else fallback

static func _cfg_vec2(cfg: ConfigFile, sect: String, key: String, fallback: Vector2) -> Vector2:
	var v: Variant = cfg.get_value(sect, key, fallback)
	return v if v is Vector2 else fallback

## Shipped defaults, named rather than spelled out at each use. Every one of these was
## previously written twice -- once as a config fallback, once (or not at all) in the
## factory reset -- and "or not at all" is exactly how REBOOT came to leave six settings
## untouched. One constant each means the reset and the fallback cannot drift.
const VOLUME_DEFAULT := 80.0
const FADE_ON_DEFAULT := true
const FADE_MS_DEFAULT := 1000
const DELAY_MS_DEFAULT := 250
const SPLIT_FRAC_DEFAULT := 0.5
## The library's own lists, named here because this file reads them constantly. Appended to,
## never inserted into: the sort is persisted as an index into SORTS.
const SORTS := LibraryModel.SORTS
const META_SORTS := LibraryModel.META_SORTS

@export_file("*.ogv") var video_path := ""

## WHICH DECK IS DOING WHAT. The player pairs, the live references, the crossfader, the
## per-deck REV flag and the auto-advance failure counter belong to this, not to the UI --
## see deck_controller.gd. Added to the tree in _ready because its crossfade drives a Tween.
var _decks := DeckController.new()
var _eq_decks: Array = []       # deck -> Equalizer; the UI rack binds to one at a time
var _deck_btn: Button
var _xfade: ProgressBar
@onready var _video: VideoStreamPlayer = %Video
@onready var _scrub: ProgressBar = %Scrub
@onready var _vol: ProgressBar = %Vol
@onready var _elapsed: Label = %Elapsed
@onready var _total: Label = %Total
@onready var _stats: Label = %Stats
@onready var _status: Label = %Status
@onready var _ticker: Label = %Ticker
@onready var _clock: Label = %Clock
@onready var _nosignal: Label = %NoSignal
@onready var _tracks: ItemList = %TracksA
## Deck B's copy of the library list: the same rows, its own widget -- own scroll, own
## selection, and a double-click that loads deck B. Filled by _refill alongside %TracksA.
@onready var _tracks_b: ItemList = %TracksB
@onready var _folder_tree: Tree = %FolderTree
@onready var _count: Label = %Count
@onready var _dialog: FileDialog = %Dialog
@onready var _director: AudioDirector = %Director
@onready var _engine: AudioEngine = %Engine
@onready var _viz: Control = %Viz
var _eq: Equalizer               # the ACTIVE deck's rack; see _bind_deck
@onready var _tabs: TabContainer = %Tabs

## WHERE THE LIBRARY LIVES. Roots, the walked paths, the index, the sort orders, the search
## filters and everything the user made (playlists, cues, RENAME tags) belong to this, not to
## the UI -- see library_model.gd. player.gd owns the ItemLists and the folder Tree and asks
## the model what to put in them. Added to the tree in _ready so its scan worker can report.
var _library := LibraryModel.new()
var _current := ""
var _dragging := false
## Which bar the left button actually went down on, or null. Godot forwards an
## uncaptured mouse-motion event (button held, pressed nowhere in particular) to
## whatever Control is currently under the pointer -- so a drag that started on a
## label or a gap between rows would "grab" the next fader it crossed, with no click
## ever landing inside that fader's own rect. _bar_drag checks this before a motion
## event is allowed to move anything.
var _bar_armed: Control = null

# --- KEYBINDS ---------------------------------------------------------------
## action -> [label, default KEY_* constant]. This is the global transport shortcut
## table, edited from the TBS tab -- a different one from the per-marker jump keys
## (CUE_KEYS_RESERVED / key_reserved), which stay letter/digit only and are edited per
## cue on the bar itself. LEFT/RIGHT/UP/DOWN/TAB are not valid marker keys at all
## (norm_key rejects anything outside A-Z/0-9 and the reserved multi-char names), so
## they need no reservation; M is already reserved there for exactly this.
const KEYBIND_SPEC := {
	"pause":       ["PAUSE / PLAY", KEY_SPACE],
	"seek_back":   ["SEEK BACK", KEY_LEFT],
	"seek_fwd":    ["SEEK FORWARD", KEY_RIGHT],
	"vol_up":      ["MASTER VOLUME UP", KEY_UP],
	"vol_down":    ["MASTER VOLUME DOWN", KEY_DOWN],
	"deck_a": ["DECK A", KEY_1],
	"deck_b": ["DECK B", KEY_2],
	"deck_both": ["DECK A+B", KEY_TAB],
	"kb_nav":      ["KEYBOARD NAVIGATION", KEY_F2],
	"mark_mode":   ["MARK MODE", KEY_M],
	"cursor":      ["HIDE CURSOR", KEY_H],
	"simple_mode": ["VISUALIZER FULLSCREEN", KEY_F1],
	"fullscreen":  ["OS FULLSCREEN", KEY_F11],
	# the keyboard's own transport keys, rebindable like everything above. They arrive while
	# the program has focus; global media keys need the OS media session, which Godot lacks.
	"media_play":  ["MEDIA PLAY / PAUSE", KEY_MEDIAPLAY],
	"media_next":  ["MEDIA NEXT", KEY_MEDIANEXT],
	"media_prev":  ["MEDIA PREVIOUS", KEY_MEDIAPREVIOUS],
	"media_stop":  ["MEDIA STOP", KEY_MEDIASTOP],
}
var _keybinds := {}          # action -> keycode, seeded from KEYBIND_SPEC then config
var _rebind_btns := {}       # action -> the TBS button showing/capturing its key
var _awaiting_rebind := ""   # action currently capturing a key, or ""
## How long a key capture stays armed before it gives up on its own.
const REBIND_TIMEOUT_SEC := 10.0
var _note := ""
var _hover: Callable    # live value readout for the fader under the pointer, or unset
## TRK A and TRK B are two CRATES over the one library: each keeps its own search, sort and
## playlist, its own row order and its own row maps. Crate 0 is TRK A (deck A), crate 1 is
## TRK B (deck B). Everything below indexed by crate is one entry per list.
## FOLDER view inserts unselectable header rows, so list rows and _library.paths indices stop
## lining up. These two keep the mapping in both directions, per crate; in every other view
## they are simply the identity, so nothing downstream needs to branch.
var _row_paths := [PackedInt32Array(), PackedInt32Array()]
var _path_rows := [PackedInt32Array(), PackedInt32Array()]
var _unknown := [[], []]        # crate -> shown tracks never probed, for the duration sweep
var _busy := false
var _flash := 0.0
var _viz_cfg := {}
var _skin := "WIN98"
var _eq_cfg_decks := [{}, {}]   # deck -> saved Equalizer state
var _builtin_font: Font   # the compiled-in PX437, so BUILT-IN can be restored
var _total_secs := 0.0     # lifetime, carried across sessions
var _session_secs := 0.0
## Both periodic jobs are scheduled against _session_secs, which starts at zero every
## launch. _save_at used to run off _total_secs -- a lifetime counter loaded from the
## config -- which needed re-anchoring after load or the first frame tripped it.
var _save_at := 30.0
var _bpm_shown := 0.0   # EMA of _director.bpm, for the readout only
var _perf_frame_ms := 0.0  # smoothed real frame time, measured from _process's delta
var _perf_gpu := "--"
var _perf_ram := "--"
var _clock_12h := false   # false = 24-hour, the default this program shipped with
var _show_ms := false     # milliseconds on every playback position readout
var _show_ms_btn: Button
var _intro_on := true     # play the opening video, then the BIOS. On by default.
## No config on disk at launch: a true first run, or the first launch after REBOOT.
var _first_run := false
var _intro_btn: Button
var _clock_btn: Button
var _mono := false        # true: Master folds to mono, post-limiter, pre-analyser
var _mono_btn: Button
var _crt_on := true        # CRT scanline/glow pass over the visualizer feed
var _crt_btn: Button
## TBS LOWER USAGE IN BACKGROUND: cap the frame rate while another program has focus. Off by
## default -- see _apply_bg_throttle.
var _bg_throttle := false
var _bg_throttle_btn: Button
var _video_test := false      # TBS "Video TEST": .mp4 joins the library and plays with a low-fi picture
var _video_test_btn: Button
var _video_color: VideoTest.ColorMode = VideoTest.ColorMode.PALETTE   # TBS VIDEO COLOR
var _video_color_btn: Button
var _listening_mode := 0      # TBS LISTENING MODE: AudioEngine.ListeningMode, AUDIOPHILE by default
var _listening_btn: Button
var _autopsy: Label           # TBS DSP AUTOPSY / SIGNAL FLOW readout
var _autopsy_at := 0.0        # session time it is next due, like _stats_at
var _picture: VideoTest       # the MP4 picture over the visualizer (video_test.gd)
var _skin_ramp: Gradient      # the skin's picture palette, rebuilt on every skin switch
var _crt_mat: ShaderMaterial   # %VizBox's material, captured once so OFF can null it out
var _playbar_on := true    # bottom transport (scrub + deck) visible outside FULLSCREEN
## Whether the scrub bar draws the track's shape behind the cue markers. On by default: the
## overview is the point of having built it. Off restores the plain rail, which is what someone
## who finds the silhouette busy behind their markers actually wants.
var _show_playbar_wave := true
var _playbar_wave_btn: Button
var _playbar_btn: Button
var _skip_secs := 5.0      # LEFT/RIGHT seek amount in seconds, 1..30, set in TBS
var _skip_field: LineEdit
var _fade_speed := 1.0     # global tab-fade-in speed multiplier, 0.25..4.0
var _fade_speed_field: LineEdit
var _cheat_field: LineEdit   # dedicated CHEAT CODE entry -- the same LOCAL_CODES table
							  # keyboard typing (_push_code_key) already matches against
var _visual_windowed := false   # %LeftColumn (the visual EQ feed) torn into its own OS window
var _visual_win_btn: Button
var _visual_win: Window
var _visual_home_index := -1
var _dual_deck := false        # TBS DUAL DECK MODE: [DECK A TRACKS | FEED | DECK B SIDEBAR]
var _dual_deck_btn: Button
var _split_btn: Button         # the same switch on the transport, beside the deck button
var _dual_visual := false      # VIS DUAL VISUAL: the feed stacks deck A over deck B
var _dual_visual_btn: Button
var _viz_edit_btn: Button      # which half the VIS tab edits; only shown while split
var _viz_cfg_b := {}
var _reboot_armed := 0.0
var _user_name := ""
## Retained, though nothing writes to it any more: the staging UI is gone but the
## [library] tbs key is still loaded and saved, so an existing list survives untouched
## if the feature is ever put back.
var _tbs: Array[String] = []
# --- playlists and cue markers (schema documented above _setup_menus) ------
var _menu_crate := 0        # which crate the open track or playlist menu was raised from
var _mark_mode := false # deliberately NOT persisted; see _setup_menus
var _menu_ctx := {}     # what the one PopupMenu is currently about
var _ask_cb: Callable   # what to do with the text the prompt dialog collects
var _ask_cancel: Button # shown only for _confirm(), hidden for the prompts
var _swatch_cache := {}  # colour hex -> the 12 px chip drawn in the colour menu
var _cue_overlay: Control  # %CueOverlay: the markers' own canvas over %Scrub
var _drag_cue := {}     # the marker whose tab is held, {} when none
var _drag_from_x := 0.0 # where that press landed, for the click-vs-drag test
var _drag_moved := false
var _audition_gen := 0
var _max_fps := FPS_DEFAULT
var _layout := 0       # 0 auto, 1 force landscape, 2 force portrait
var _portrait := false
var _last_vp := Vector2.ZERO
var _last_screen := -1
## Geometry to hand back when leaving fullscreen. Session-only on purpose: a saved
## window rect that no longer fits the current monitor arrangement is worse than none.
var _windowed_rect := Rect2i()
var _feed := 0
var _feed_prev := 0
## Where the user parked the divider, as a FRACTION of the workspace (0..1), not as a
## pixel offset.
##
## Pixels do not survive a move to another monitor. The stretch base pins the viewport
## width at 1920 whatever the screen, so only the height changes -- 1080 on the landscape
## panel, 3413 on the portrait one -- and a single stored offset was being applied to a
## horizontal split on 1920 and a vertical split on 3413. It could not be correct in both,
## so dragging the window between displays moved the divider to the wrong place. A
## fraction is the same number in either orientation and on any screen.
var _split_frac := 0.5
## Generation counter for _split_to_fraction. It is a coroutine that spans several
## frames, so switching feed size twice in quick succession leaves two of them
## running and both writing the split position -- the loser lands last and wins, and
## the divider sticks on the previous mode's ratio. Same token rule AudioEngine uses to
## drop a superseded decode.
var _split_gen := 0
var _ez_faders: Array[VSlider] = []
var _adv_faders: Array[VSlider] = []
var _eq_off_note: Label   # shown only while EQ is OFF, so the tab is never blank
var _fader_base := PackedFloat32Array()
var _fader_sync := false
var _presets: Array = []
var _volume := 80.0
var _boost := 0        # 0..100 on the dial; 0 is unity, no boost

func _ready() -> void:
	_decks.name = "Decks"
	_decks.engine = _engine
	_decks.director = _director
	add_child(_decks)
	_library.name = "Library"
	_library.engine = _engine
	add_child(_library)
	_library.scan_progress.connect(_on_scan_progress)
	_library.scan_finished.connect(_on_scan_finished)
	assert(_fmt(61.0) == "01:01" and _ratio_at(-9.0, 100.0) == 0.0 and _ratio_at(999.0, 100.0) == 1.0)
	assert(LibraryModel.model_test())   # path rules, sort keys, track ids, RELOCATE, id migration
	assert(rev_landing("STOPPED", 3.0, 10.0, 10.0) == [false, false, 7.0] and rev_landing("PAUSED", 3.0, 10.0, 10.0) == [true, true, 7.0] and rev_landing("PLAYING", 12.0, 10.0, 10.0) == [true, false, 0.0])
	# shuffle must not hand back the track already playing, except in a one-track queue
	assert(AudioEngine.peek_next(2, AudioEngine.Repeat.ALL, true, 5, 2) != 2)
	assert(AudioEngine.peek_next(0, AudioEngine.Repeat.ALL, true, 1, 0) == 0)
	assert(AudioEngine.peek_next(4, AudioEngine.Repeat.OFF, false, 5, 0) == -1)
	assert(Equalizer.flat_test())      # a flat curve bypasses EQ21 instead of processing
	assert(Equalizer.from_dict_test()) # junk config members clamp instead of throwing
	assert(asset_test())               # cursor thumbnail cap keeps aspect at both extremes
	assert(Visualizer.gradient_test()) # hex list round trip and gradient sampling
	assert(code_test())                # cheat buffer tail-matches and stays capped
	assert(setlist_test())             # playlist reorder, including both end stops
	assert(license_test())             # the token signature binds to payload AND user
	assert(Visualizer.snake_test())    # snake wall and self-collision rules
	assert(AudioDirector.tempo_test())  # the sweep, now that it runs on a worker
	assert(AudioEngine.key_tag_test())  # key tag parsing and the Camelot wheel
	assert(AudioEngine.bpm_tag_test())  # BPM tag parsing, and what it refuses
	assert(marquee_test())              # the hover scroll's wrap
	assert(SpectralKey.spectral_key_test())  # FFT peak, chroma fold, K-S profile match
	assert(FxRack.rack_test())
	assert(Recorder.recorder_test())    # the take's option tables match ffmpeg          # rack boots blank, params clamp, MODULATE is exact
	assert(_viz.fps_lerp_test())        # visualizer speed is the same at any FPS
	assert(wheel_test())                # wheel steps: fine, coarse, and the accelerator
	assert(clock_test())                # 12-hour wrap: midnight and noon are both 12
	assert(count_test())                # TRACKS readout: both branches, partial marker
	assert(cue_test())                  # marker hit-testing and cue id allocation
	assert(DeckController.deck_test())  # cue mirroring under REV, and the skip-and-stop rule
	assert(settings_test())             # every settings row lands in exactly one group, and is findable
	assert(set_export_test())           # the recorded set's running order, as text and as a CUE sheet
	assert(ts_test())                   # MM:SS:MS formatting and its round trip
	assert(key_test())                  # reserved keys, collisions, and clearing
	assert(AudioEngine.deck_test())     # crossfader gain law and its silence floor
	assert(write_in_test())             # which rows the write-in is allowed to touch
	assert(AudioDirector.sync_test())   # beat-sync offset wraps to the nearest beat
	assert(MidiMap.midi_test())         # MIDI keys, both relative encodings, and clash refusal
	# same source as the BIOS POST line and STATS VERSION, so one bump in project.godot moves all three
	$Margin/Main/TopHeaderBar/HB/Title.text += " %s" % ProjectSettings.get_setting("application/config/version", "")
	# Nothing arrives until this is called -- no events, and an empty device list. Called before
	# the config loads so a binding read a moment later has somewhere to arrive from.
	OS.open_midi_inputs()
	# Deferred, so it runs after the config has been read: a remembered output device is honoured
	# at launch, and falls back to Default on its own if that interface is not on this machine.
	_set_output_device.call_deferred(_output_device)
	# seeded unconditionally, not inside the config branch below: a first run with no
	# library.cfg yet must still ship with working shortcuts, not a silently empty map
	for action in KEYBIND_SPEC:
		_keybinds[action] = KEYBIND_SPEC[action][1]
	var cfg := ConfigFile.new()
	# a file that exists but will not parse is moved aside and its .bak loaded instead;
	# loading nothing and saving defaults over it would erase every playlist and cue
	var corrupt := load_cfg_safe(cfg, _cfg)
	_first_run = cfg.get_sections().is_empty()
	if not cfg.get_sections().is_empty():
		_library.folders.assign(_cfg_arr(cfg, "library", "folders"))
		# an older config can hold un-normalised or nested roots; collapse them once here
		# so the folder tree never renders the same directory twice
		_library.dedupe_roots()
		# has_section_key, not an is_empty() check: "saved, and the user turned everything
		# off" has to survive a restart, and an empty Array cannot say that on its own
		_library.enabled_known = cfg.has_section_key("library", "enabled_folders")
		for dir in _cfg_arr(cfg, "library", "enabled_folders"):
			_library.enabled_folders[dir] = true
		# A config written before known_folders existed has no record of what the last
		# scan saw, so it falls back to the enabled set. The consequence is deliberate:
		# a folder that was switched off looks new once and comes back on. That is the
		# right trade, because the same ambiguity is what silently hid whole albums, and
		# a folder reappearing is one click to undo while a missing album is invisible.
		for dir in _cfg_arr(cfg, "library", "known_folders",
				_cfg_arr(cfg, "library", "enabled_folders")):
			_library.known_folders[dir] = true
		_library.sorts[0] = clampi(int(_cfg_num(cfg, "library", "sort", 0.0)), 0, SORTS.size() - 1)
		_library.sorts[1] = clampi(int(_cfg_num(cfg, "library", "sort_b", float(_library.sorts[0]))), 0, SORTS.size() - 1)
		_viz_cfg = _cfg_dict(cfg, "visual", "viz")
		_viz_cfg_b = _cfg_dict(cfg, "visual", "viz_b")
		_skin = _cfg_str(cfg, "visual", "skin", "WIN98")
		# "state" stays deck A's key, so a config written before decks existed loads
		# straight into the deck the user was already listening on
		_eq_cfg_decks[0] = _cfg_dict(cfg, "eq", "state")
		_eq_cfg_decks[1] = _cfg_dict(cfg, "eq", "state_b")
		_decks.crossfader = clampf(_cfg_num(cfg, "audio", "crossfader", 0.0), 0.0, 1.0)
		_beat_sync = _cfg_bool(cfg, "audio", "beat_sync", false)
		_engine.deck = clampi(int(_cfg_num(cfg, "audio", "deck", 0.0)), 0, 1)
		_engine.set_both(_cfg_bool(cfg, "audio", "both", false))
		_presets = _cfg_arr(cfg, "eq", "presets")
		_total_secs = _cfg_num(cfg, "stats", "total_seconds", 0.0)
		_user_name = _cfg_str(cfg, "stats", "user_name")
		_tbs.assign(_cfg_arr(cfg, "library", "tbs"))
		# Which id scheme the stores below are keyed by. Absent means 1, the name-and-size id:
		# the first scan on this build re-keys them to fingerprints and writes 2 back.
		_id_scheme = int(_cfg_num(cfg, "library", "id_scheme", 1.0))
		# All four are keyed by TRACK ID. A config written before ids existed keyed them by
		# absolute path, so it is converted on the way in -- once, here -- and saved back in
		# the new shape. A path that is no longer in the library keeps its own key rather
		# than being dropped: an unplugged drive must not eat a user's cues.
		_library.playlists = _library.migrate_keys(_cfg_dict(cfg, "playlists", "list"))
		for name in _library.playlists:
			var ids: Array = []
			for entry in (_library.playlists[name] as Array):
				ids.append(_library.id_for(str(entry)) if str(entry).contains("/") else entry)
			_library.playlists[name] = ids
		_library.pl_cues = _cfg_dict(cfg, "playlists", "cues")
		for name in _library.pl_cues:
			_library.pl_cues[name] = _library.migrate_keys(_library.pl_cues[name])
		_library.cues = _library.migrate_keys(_cfg_dict(cfg, "cues", "tracks"))
		_library.labels = _library.migrate_keys(_cfg_dict(cfg, "library", "track_labels"))
		# a playlist deleted by hand out of the config must not leave the list showing
		# an empty scope with no way back to ALL TRACKS
		for c in 2:
			var pl := _cfg_str(cfg, "library", ["playlist", "playlist_b"][c])
			_library.crate_pl[c] = pl if _library.playlists.has(pl) else ""
		# @onready, so _engine is already bound by the time the _ready body runs
		# the mode if this config has one, else the old bool: shuffle on meant TRUE random
		_engine.shuffle = _cfg_bool(cfg, "library", "shuffle", false)
		_engine.shuffle_mode = clampi(int(_cfg_num(cfg, "library", "shuffle_mode",
			float(_engine.shuffle_mode))), 0, 2) as AudioEngine.Shuffle
		_engine.repeat = clampi(int(_cfg_num(cfg, "library", "repeat", float(AudioEngine.Repeat.ALL))),
			0, 2) as AudioEngine.Repeat
		_volume = clampf(_cfg_num(cfg, "audio", "volume", VOLUME_DEFAULT), 0.0, 100.0)
		_boost = clampi(int(_cfg_num(cfg, "audio", "boost", 0.0)), 0, 100)
		_decks.fade_on = _cfg_bool(cfg, "audio", "fade", FADE_ON_DEFAULT)
		_decks.fade_ms = clampi(int(_cfg_num(cfg, "audio", "fade_ms", FADE_MS_DEFAULT)), FADE_MS_MIN, FADE_MS_MAX)
		_decks.delay_ms = clampi(int(_cfg_num(cfg, "audio", "play_delay_ms", DELAY_MS_DEFAULT)), DELAY_MS_MIN, DELAY_MS_MAX)
		_feed = clampi(int(_cfg_num(cfg, "visual", "feed_size", 0.0)), 0, FEED_NAMES.size() - 1)
		# split_offset was the old pixel key; it has no meaning across orientations, so a
		# config written before this simply starts from the middle.
		_split_frac = clampf(_cfg_num(cfg, "visual", "split_frac", SPLIT_FRAC_DEFAULT), 0.05, 0.95)
		_clock_12h = _cfg_bool(cfg, "visual", "clock_12h", false)
		_show_ms = _cfg_bool(cfg, "visual", "show_ms", false)
		_font_name = _cfg_str(cfg, "visual", "font")
		# clamped on the way in like every other config read: library.cfg is a plain
		# text file a user can and will hand-edit, and a 400 px font or a 40x cursor is
		# a UI nobody can click their way out of
		_font_size = clampi(int(_cfg_num(cfg, "visual", "font_size", FONT_SIZE_DEFAULT)),
			FONT_SIZE_MIN, FONT_SIZE_MAX)
		_setlist_b.assign(_cfg_arr(cfg, "library", "setlist_b"))
		_license_endpoint = _cfg_str(cfg, "secrets", "endpoint")
		_unlocked.clear()
		for u in _cfg_str(cfg, "secrets", "unlocked").split(",", false):
			_unlocked.append(u)
		# the signed file is additive: codes typed locally live in the cfg, codes
		# redeemed against a server live in license.dat, and boot merges the two
		for u in _read_license():
			if not (u in _unlocked):
				_unlocked.append(u)
		_gradients.clear()
		# numbered keys rather than one blob: library.cfg stays hand-editable, and a
		# gradient can be pasted straight into the file the same way COPY emits it
		for gi in GRAD_MAX:
			var raw := _cfg_str(cfg, "visual", _grad_key(gi))
			if raw.is_empty():
				continue
			var grad := Visualizer.parse_hex_list(raw)
			if grad and grad.get_point_count() >= 2:   # one stop is a colour, not a gradient
				_gradients.append(grad)
		# 0=STATIC 1=FADE 2=LEFT_RIGHT 3=WAVE; FADE is the default so an upgraded config
		# without this key starts animating rather than freezing
		_viz.color_anim = clampi(int(_cfg_num(cfg, "visual", "color_anim", 1.0)), 0, 3) \
			as Visualizer.ColorAnim
		_viz.rotate_gradients = _cfg_bool(cfg, "visual", "rotate_gradients", false)
		%VizB.color_anim = clampi(int(_cfg_num(cfg, "visual", "color_anim_b", 1.0)), 0, 3) \
			as Visualizer.ColorAnim
		%VizB.rotate_gradients = _cfg_bool(cfg, "visual", "rotate_gradients_b", false)
		_cursor_name = _cfg_str(cfg, "visual", "cursor")
		_cursor_scale = clampf(_cfg_num(cfg, "visual", "cursor_scale", 1.0),
			CURSOR_SCALE_MIN, CURSOR_SCALE_MAX)
		var hs := _cfg_vec2(cfg, "visual", "cursor_hotspot", Vector2.ZERO)
		_cursor_hotspot = Vector2(clampf(hs.x, 0.0, 1.0), clampf(hs.y, 0.0, 1.0))
		_intro_on = _cfg_bool(cfg, "visual", "intro_video", true)
		_layout = clampi(int(_cfg_num(cfg, "visual", "layout", 0.0)), 0, 2)
		_director.track_tempo = _cfg_bool(cfg, "audio", "track_tempo", false)
		var fps_cfg := int(_cfg_num(cfg, "visual", "max_fps", FPS_DEFAULT))
		_max_fps = FPS_UNCAPPED if fps_cfg == FPS_UNCAPPED else clampi(fps_cfg, FPS_MIN, FPS_MAX)
		_mono = _cfg_bool(cfg, "audio", "mono", false)
		_crt_on = _cfg_bool(cfg, "visual", "crt", true)
		_bg_throttle = _cfg_bool(cfg, "visual", "bg_throttle", false)
		_playbar_offset = int(_cfg_num(cfg, "visual", "playbar_split", 0.0))
		_now_playing = _cfg_bool(cfg, "visual", "now_playing", false)
		_meter_on = _cfg_bool(cfg, "visual", "meter", true)
		_dual_bars = _cfg_bool(cfg, "visual", "dual_bars", false)
		_output_device = _cfg_str(cfg, "audio", "output_device", "Default")
		_now_mode = clampi(int(_cfg_num(cfg, "visual", "now_mode", 1.0)), 0, NOW_MODES.size() - 1)
		_video_test = _cfg_bool(cfg, "visual", "video_test", false)
		_video_color = clampi(int(_cfg_num(cfg, "visual", "video_color", 1.0)), 0, 1) as VideoTest.ColorMode
		_listening_mode = clampi(int(_cfg_num(cfg, "visual", "listening_mode", 0.0)), 0,
			AudioEngine.LISTENING_MODE_NAMES.size() - 1)
		_playbar_on = _cfg_bool(cfg, "visual", "playbar", true)
		# [display] rather than [visual] with the rest of the screen settings, as asked. Nothing
		# else lives in that section yet; ConfigFile does not mind, and a missing section reads
		# as the default.
		_show_playbar_wave = _cfg_bool(cfg, "display", "playbar_waveform", true)
		_visual_windowed = _cfg_bool(cfg, "visual", "visual_windowed", false)
		_dual_deck = _cfg_bool(cfg, "visual", "dual_deck_mode", false)
		_dual_visual = _cfg_bool(cfg, "visual", "dual_visual", false)
		_skip_secs = clampf(_cfg_num(cfg, "input", "skip_secs", 5.0), 1.0, 30.0)
		_fade_speed = clampf(_cfg_num(cfg, "visual", "fade_speed", 1.0), 0.25, 4.0)
		if cfg.has_section("keybinds"):
			# Duplicates are dropped on the way in, not tolerated. A config written before
			# an action existed comes back with that action on its spec default, which can
			# collide with a key the user had already moved something else onto -- and
			# _finish_rebind refuses any key that clashes, so from the UI the collision is
			# unfixable and one of the two keys is simply dead. Last writer loses: the
			# colliding action falls back to its own default, and if THAT is taken too it
			# is left unbound rather than stealing a third key.
			var seen := {}
			for action in KEYBIND_SPEC:
				var k := int(_cfg_num(cfg, "keybinds", action, float(KEYBIND_SPEC[action][1])))
				if seen.has(k):
					k = int(KEYBIND_SPEC[action][1])
					if seen.has(k):
						push_warning("keybinds: %s left unbound, its key was already taken" % action)
						k = KEY_NONE
				if k != KEY_NONE:
					seen[k] = true
				_keybinds[action] = k
		# MidiMap validates and de-duplicates on the way in the same way the block above does,
		# because this is a hand-editable file and one bad entry must cost that entry only
		_midi.from_dict(_cfg_dict(cfg, "midibinds", "map"))
		# the spectral estimate cache, keyed by str(hash(path)) -- this is what makes a
		# background analysis pass a ONE-TIME cost rather than something every rescan repeats
		_rack_cfg_decks[0] = _cfg_dict(cfg, "rack", "state")
		_rack_cfg_decks[1] = _cfg_dict(cfg, "rack", "state_b")
		_rack_presets = _cfg_dict(cfg, "rack", "presets")
		_rec_dir = _cfg_str(cfg, "record", "dir")
		_rec_rate = clampi(int(_cfg_num(cfg, "record", "rate", 0.0)), 0, Recorder.RATES.size() - 1)
		_rec_type = clampi(int(_cfg_num(cfg, "record", "type", 0.0)), 0, Recorder.FILE_TYPES.size() - 1)
		_rec_quality = clampi(int(_cfg_num(cfg, "record", "quality", 1.0)), 0, Recorder.QUALITY_NAMES.size() - 1)
		if cfg.has_section("spectral_keys"):
			for k in cfg.get_section_keys("spectral_keys"):
				var v = cfg.get_value("spectral_keys", k)
				if v is Array and v.size() == 2:
					_engine.load_spectral_cache(k, int(v[0]), bool(v[1]))
		# [effects] and [effects_b] are deliberately NOT read. The fixed rack that owned them
		# has no controls any more, so a saved reverb, filter or key shift would be audio
		# processing nobody could see or switch off. _save() no longer writes them either.
	# deck B's rack is a second instance of the same class on a second bus -- the UI is
	# never duplicated, only re-bound
	var eq_b := Equalizer.new()
	eq_b.name = "EqB"
	add_child(eq_b)
	_eq_decks = [%Eq, eq_b]
	if video_path:
		_video.stream = load(video_path)
	%Play.pressed.connect(_toggle)
	%Stop.pressed.connect(func() -> void: _stop(_bar_deck()))
	%AddFolder.pressed.connect(_dialog.popup_centered)
	# TRK A and TRK B carry the same header, but each drives only its own crate: searching,
	# sorting or picking a playlist in one list never touches the other.
	for crate in 2:
		var search: LineEdit = [%Search, %SearchB][crate]
		# The library's own way in, on the tab people actually land on. ADD FOLDER lived only on
		# DIRS, so a first launch opened onto an empty TRACKS list with no visible way forward.
		var add_music := Button.new()
		add_music.name = "AddMusic"
		add_music.text = "[ ADD MUSIC FOLDER ]"
		add_music.pressed.connect(_dialog.popup_centered)
		search.add_sibling(add_music)
		_hover_note(add_music, func() -> String:
			return "PICK A MUSIC FOLDER  //  OR DRAG FOLDERS STRAIGHT ONTO THE WINDOW")
		search.text_changed.connect(func(t: String) -> void:
			_library.filters[crate] = t.strip_edges()
			_refill(crate))
	get_window().files_dropped.connect(_on_files_dropped)
	%RemoveFolder.pressed.connect(_remove_folder)
	%Rescan.pressed.connect(_rescan)
	_scan_btn = %Rescan
	_add_relocate_button()
	%Sort.pressed.connect(_cycle_sort.bind(0))
	%SortB.pressed.connect(_cycle_sort.bind(1))
	%Reboot.pressed.connect(_on_reboot)
	_setup_decks()
	_setup_fade()
	_setup_feed()
	_setup_fps()
	_setup_boost()
	_setup_meter()
	_setup_layout()
	_setup_beat()
	_setup_playbar_split()
	_setup_tbs()
	_setup_tbs_window()
	_setup_tear_off()
	_setup_menus()
	_setup_tab_arrows()
	_setup_tab_fade()
	_setup_focus_policy()
	_label_clipped_controls.call_deferred()   # after the first layout has given everything a width
	_crt_mat = %VizBox.material as ShaderMaterial
	_apply_crt()
	_apply_mono()
	_engine.set_listening_mode(_listening_mode)
	if _visual_windowed:
		_toggle_visual_window(true)
	if _now_playing:
		_toggle_now_playing(true)
	%Sort.text = "SORT: %s" % SORTS[_library.sorts[0]]
	%SortB.text = "SORT: %s" % SORTS[_library.sorts[1]]
	_dialog.dir_selected.connect(func(d: String) -> void: _add_folder(d))
	_folder_tree.item_edited.connect(_on_folder_tree_item_edited)
	_folder_tree.gui_input.connect(_on_folder_tree_input)
	for deck in 2:
		var list: ItemList = [_tracks, _tracks_b][deck]
		list.item_activated.connect(_on_row_activated.bind(deck))
		list.gui_input.connect(_on_list_scroll.bind(list))
		# a crate is something you pull a handful of tracks out of at once
		list.select_mode = ItemList.SELECT_MULTI
		list.gui_input.connect(_on_list_pointer.bind(deck))
		list.mouse_exited.connect(_marquee_stop)
	_engine.track_ready.connect(_on_track_ready)
	_engine.reversed_ready.connect(func(path: String, stream: AudioStream) -> void:
		if path != _current:
			return   # the track changed while ffmpeg was working; drop the stale take
		# The transport as it stands NOW, not as it stood when REV was pressed: a STOP or PAUSE
		# pressed while ffmpeg worked is the user's latest word, and the take used to override
		# it by starting playback regardless (audit C1). Untouched since the press, this IS the
		# press-time state. _pos()/_len() answer for whichever backend is live, so all of it is
		# read BEFORE the swap.
		var land := rev_landing(_state(), _pos(), _len(), stream.get_length())
		# A crossfade owns _decks.audio's volume and ends by stopping the outgoing player and
		# nulling its stream -- so a REV that swapped the stream mid-fade would either be
		# ramped by a fade that no longer means anything or stopped outright a moment
		# later. Cancel it first and settle the level.
		_kill_fade(_engine.deck)
		_decks.audio.volume_db = ACTIVE_DB
		if _vid():
			# a video's audio cannot be swapped out from under its picture: pushing the
			# reversed track onto _decks.audio would play both at once, out of sync
			_video.stop()
			_video.stream = null
		_decks.audio.stream = stream
		if land[0]:
			# at the MIRRORED position, so REV picks up where you were rather than dropping
			# you at the top of the reversed file
			_decks.audio.play(land[2])
			_decks.audio.stream_paused = land[1]
		_sync_attach(_engine.deck)
		_set_reversed(_engine.deck, true)
		_refresh_rev_btn()
		_note = ""
		_clear_note_later())
	_engine.track_failed.connect(_on_track_failed)
	# the overview arrives from a worker some seconds after the track starts; without this the
	# bar would only pick it up at the next redraw it happened to do for another reason
	_engine.waveform_ready.connect(func(path: String) -> void:
		if path == _bar_path() and is_instance_valid(_cue_overlay):
			_cue_overlay.queue_redraw())
	# a spectral estimate arrives asynchronously, well after the track may already be
	# playing (or may have already changed) -- only worth repainting for the track it
	# is actually about
	_engine.spectral_key_ready.connect(func(path: String, _pc: int, _minor: bool) -> void:
		if path == _current and int(_key.get("pc", -1)) < 0:
			_key = _resolved_key(path))   # STATS rebuilds every frame, so nothing to repaint
	%Prev.pressed.connect(_prev)
	%Next.pressed.connect(_next)
	%Shuffle.pressed.connect(func() -> void:
		# OFF -> TRUE -> JAM -> OFF: one button, because it is one decision (how the next
		# track gets chosen) and the transport has no room for two
		_engine.shuffle_mode = ((_engine.shuffle_mode + 1) % 3) as AudioEngine.Shuffle
		_refresh_transport()
		_save())
	_hover_note(%Shuffle, func() -> String:
		return ["SHUFFLE OFF: THE LIST IN ITS OWN ORDER",
			"TRUE SHUFFLE: RANDOM, NOTHING TWICE UNTIL EVERYTHING HAS PLAYED",
			"JAM SHUFFLE: RANDOM, WEIGHTED TOWARD TRACKS THAT MIX WITH THIS ONE (KEY AND BPM)",
		][_engine.shuffle_mode])
	%Repeat.pressed.connect(func() -> void:
		_engine.repeat = ((_engine.repeat + 1) % 3) as AudioEngine.Repeat
		_refresh_transport()
		_save())
	_refresh_transport()
	_builtin_font = theme.default_font
	_setup_pixel_font()
	_scan_fonts()
	if not _font_name.is_empty():
		_apply_font(_font_name)
	_apply_font_size(_font_size)   # independent of WHICH font: the built-in scales too
	_setup_eq()
	_setup_rack_tab(0)    # FX A and FX B: boot blank, modules added at runtime
	_setup_rack_tab(1)
	_setup_record_tab()   # the RECORD SET tab, added before the capture below
	_setup_tools_tab()
	_setup_queue_tab()
	_capture_tab_order()
	_shorten_tab_titles()   # 9 tabs do not fit the bar at its natural widths   # every tab now exists, including the runtime-built ones
	_set_dual_deck(_dual_deck)   # after the capture, so every tab has a home slot to return to
	for dock: TabContainer in [_tabs, %DeckADock]:
		sleep_hidden_pages(dock)   # every page lives in one of the two docks until a drag moves it
		dock.tab_changed.connect(func(_i: int) -> void:
			_stats_at = 0.0   # a switch onto STATS paints this frame, not up to 250 ms late
			# only a switch ONTO the track list reveals it. With two docks the list can already be
			# on screen in the other one, and re-typing it on every click over there is noise.
			if dock.get_current_tab_control() == _tracks.get_parent():
				_write_in())
	_setup_cursor()
	_setup_visual()
	_picture = VideoTest.new()
	_picture.color_mode = _video_color
	%VizStack.add_sibling(_picture)   # the same screen cell: sized with the visualizer, docked or windowed
	_engine.video_ready.connect(_picture.open)
	_director.attach(_decks.audio)
	_director.beat.connect(func(_i: int) -> void: _flash = 0.10)
	_scrub.gui_input.connect(_on_scrub_input)
	_vol.gui_input.connect(_on_vol_input)
	_hover_note(_vol, func() -> String: return "VOLUME: %d%%" % int(_vol.value))
	# A marker under the pointer takes the readout over, which is where its label, its
	# time and its jump key live -- the bar itself has no room to print any of them.
	# Otherwise the bar's own value, not _pos(): mid-drag that IS the seek target, and
	# the ELAPSED readout beside it still shows where playback actually is until release.
	# The hover readout is the one thing that changes the status line's LENGTH, and a
	# Label's text is part of its minimum size: without this, every marker the pointer
	# crossed re-fit %StatusBar, which re-fit Main, which re-fit the Workspace split and
	# resized the visualizer's SubViewport -- a layout pass per mouse move, which is the
	# flicker. Clipped, the label reports a fixed minimum and nothing above it moves.
	_status.clip_text = true
	_hover_note(_cue_overlay, func() -> String:
		var c := _cue_at(_cue_overlay.get_local_mouse_position().x)
		if not c.is_empty():
			var key := str(c.get("key", ""))
			return "%s @ %s%s  //  SHIFT-CLICK AUDITIONS" % [c["label"],
				_time_text(float(c["time"])), "" if key.is_empty() else "  //  KEY [%s]" % key]
		return "SEEK: %s / %s" % [_time_text(_scrub.value / 100.0 * _len()), _time_text(_len())])
	%TickTimer.timeout.connect(func() -> void:
		# [0] on an empty string is an index error, and this fires eight times a second
		if _ticker.text.is_empty():
			return
		_ticker.text = _ticker.text.substr(1) + _ticker.text[0])
	_vol.value = _volume
	_apply_volume()   # the bus was never actually set here, so the slider lied
	_engine.video_test = _video_test   # before the first scan and the first decode
	_engine.load_index()   # before the first scan: known tracks cost a stat, not an ffprobe
	var reclaimed := AudioEngine.purge_cache("pcm_")
	AudioEngine.purge_cache("rev_")   # reverse renders last one session: REV re-renders on demand
	# the raw PCM the old overview builder kept, ~9.6 MB a track. Nothing reads it now: what is
	# cached is the folded overview itself, and the decode it comes from cleans up after itself.
	reclaimed += AudioEngine.purge_cache("wave_", AudioEngine.WAVE_DIR)
	reclaimed += AudioEngine.purge_cache("rawwave_", AudioEngine.WAVE_DIR)   # a killed render's leftovers
	if not _video_test:
		AudioEngine.purge_video_cache()
	_rescan()
	%Boot.finished.connect(func(who: String) -> void:
		_user_name = who
		_save())
	_start_intro()
	_save()   # write a full config immediately, so nothing depends on a later edit
	if _library.paths.is_empty() and not _video.stream:
		_decks.audio.stream = _demo_tone()
	_stop()
	if not corrupt.is_empty():
		# not cleared on a timer: the intro and POST cover the status bar for the first
		# several seconds, and this is the one note the user has to actually get to read
		_note = "  //  CONFIG UNREADABLE, KEPT AS %s" % corrupt
	elif reclaimed > 0:
		_note = "  //  RECLAIMED %s OF OLD FLAC TRANSCODES  //  FLAC NOW DECODES NATIVELY" % _bytes(reclaimed)

# --- library --------------------------------------------------------------
func _cycle_sort(crate: int) -> void:
	_library.sorts[crate] = (_library.sorts[crate] + 1) % SORTS.size()
	([%Sort, %SortB][crate] as Button).text = "SORT: %s" % SORTS[_library.sorts[crate]]
	_save()
	# re-sort this crate only; no reason to re-walk the disk or touch the other list
	_library.orders[crate] = _library.sorted(SORTS[_library.sorts[crate]])
	_refill(crate)
	if crate == 0:
		_write_in()

## SCAN SONGS: re-walks every root from disk, on a WORKER. The walk used to run right here
## on the main thread, so a cold network share or a sleeping external drive froze the whole
## program -- picture, meters, transport and all -- for as long as the filesystem took to
## answer, with no way to stop it. Now the button starts it, the note reports where it has
## got to, and pressing it again stops it.
func _rescan() -> void:
	if _library.scanning():
		_library.stop_scan()
		_note = "  //  SCAN STOPPED"
		_clear_note_later()
		_refresh_scan_btn()
		return
	var sel := _folder_tree.get_selected()
	_scan_watch = sel.get_metadata(0) if sel else ""
	_library.video_test = _video_test
	_library.scan()
	_refresh_scan_btn()

## Where the scan had got to when the last frame drew. Only the directory is worth showing:
## a total is not knowable until the walk has finished, and a fake percentage is worse than
## the truth.
func _on_scan_progress(done: int, _total: int, where: String) -> void:
	_note = "  //  SCANNING %s  //  %d TRACKS" % [where.get_file().to_upper(), done]

func _on_scan_finished(_found: int, cancelled: bool) -> void:
	_refresh_scan_btn()
	if cancelled:
		return
	# Once per library: the cues, labels and playlists of a library keyed by the old name-and-size
	# ids move to the fingerprints this scan just read. Before the reindex, because the row a
	# track shows is its label, which has just changed key.
	var moved := 0
	if _id_scheme < LibraryModel.ID_SCHEME:
		moved = _library.migrate_ids(_library.scan_ids)
		_id_scheme = LibraryModel.ID_SCHEME
	# LibraryModel already filtered with the enabled set it had; only a tree that switched new
	# folders on needs a second pass (3 s of reindex at 20k tracks, for nothing, on every boot)
	var was := _library.enabled_folders.duplicate()
	_build_folder_tree()
	if _library.enabled_folders != was:
		_library.apply_folder_filter()
	elif moved > 0:
		_library.reindex()   # the labels are under different keys now
	_after_reindex()
	if moved > 0:
		_save()   # the re-keyed stores and the scheme they are now in, together
	# the list is up; the index's durations, tags and keys are confirmed off this thread, then
	# the readout (or a metadata sort) catches up in one repaint
	var paths := _library.all_paths.duplicate()
	# the count line, cheap enough to run every few hundred tracks while the fill below works
	var climbing := func() -> void:
		if not _engine.is_shut_down():
			_recount()
	_engine.run_task(func() -> void:
		if _engine.validate_index(paths) > 0:   # a fresh import has no index: nothing to repaint
			(func() -> void:
				if not _engine.is_shut_down():
					_meta_arrived()).call_deferred()
		# ...then whatever the index is still missing: durations for tracks nothing has probed
		# (which is what leaves TOTAL TIME reading "+"), and tempos for anything indexed before
		# BPM was read. One ffprobe each, on this worker, behind everything above.
		if _engine.refresh_meta(paths, climbing) > 0:
			(func() -> void:
				if not _engine.is_shut_down():
					_engine.save_index(_library.all_paths)   # so the next launch re-probes nothing
					_meta_arrived()).call_deferred())
	# Offline spectral key estimation: one background worker task per track, gated
	# inside queue_spectral_key by the persistent cache AND by whether the file even
	# has a tag (checked on the worker, not here) -- so a rescan of an already-processed
	# library queues thousands of calls that all return in a hash lookup, not a re-run.
	for path in _library.all_paths:
		_engine.queue_spectral_key(path)
	if _scan_watch.is_empty():
		_note = "  //  SCANNED %d TRACKS" % _library.paths.size()
	else:
		var n := 0
		for path in _library.paths:
			if path.begins_with(_scan_watch):
				n += 1
		_note = "  //  %s: %d TRACKS" % [_scan_watch.get_file().to_upper(), n]
	if moved > 0:
		_note += "  //  %d CUES AND LABELS RE-KEYED" % moved
	_clear_note_later()

var _scan_watch := ""
var _scan_btn: Button
## Which id scheme the saved cues, labels and playlists are keyed by; see LibraryModel.ID_SCHEME.
var _id_scheme := LibraryModel.ID_SCHEME   # a library with no config at all starts current

func _refresh_scan_btn() -> void:
	if is_instance_valid(_scan_btn):
		_scan_btn.text = "STOP SCAN" if _library.scanning() else "SCAN SONGS"

## Everything that is invariant under a search keystroke: the sort, the per-folder track
## counts, the queue hand-off, and the row strings themselves. Typing used to re-run all of
## it per character -- an O(n log n) sort plus an O(folders x tracks) prefix scan -- so it
## is split out here and called only when the library or the sort order actually changes.
## `_library.index` stays index-aligned with `_library.paths`, which is what `_row_paths` and the queues mean.
func _reindex() -> void:
	_library.reindex()
	_after_reindex()

## The UI half of a reindex: the queue hand-off moved into _refill(), because the queue is
## the VISIBLE list now and the visible list is what a search keystroke changes.
func _after_reindex() -> void:
	_refill()
	_write_in()

## Rebuilds the visible list of one crate, or of both with no argument, matching that crate's
## filter against the cached lowercase haystack. Cheap enough to run on every keystroke.
func _refill(crate := -1) -> void:
	# Before the list stops existing. A write-in tween holds ROW INDICES into the list it
	# was armed on; rebuilding underneath it made _write_step index past the end of a
	# shorter list (seven engine errors on one search keystroke) and _write_restore paint
	# the OLD track names onto the NEW rows. Cancel rather than restore -- restoring into
	# rows that are about to be cleared is the bug, not the fix. The write-in is TRK A's.
	if crate != 1:
		_write_cancel()
	_marquee_stop()   # before the rows go: it restores text into the list it started on
	for c in 2:
		if crate < 0 or crate == c:
			_fill(c)
	# SEARCH scopes PLAYBACK, not just the view. The queue is the DRIVEN deck's visible list,
	# so NEXT, PREV, shuffle and auto-advance all stay inside that crate's result until it is
	# cleared -- AudioEngine re-anchors its index on _current, so a track that is still
	# visible keeps playing from where it was, and one that is filtered out simply hands
	# the next advance to the top of the new queue.
	if crate < 0 or crate == _engine.deck:
		_engine.set_queue(_library.shown[_engine.deck], _current)
	# both crates' unprobed tracks in one sweep: a sweep supersedes the last, so sweeping only
	# the crate that changed would cancel the other one's
	# a Dictionary for the seen-check: `path in todo` on an Array was O(n^2), and with 20k
	# unprobed tracks it froze the program for 44 s every time the list filled
	var todo: Array[String] = []
	var seen := {}
	for c in 2:
		for path: String in _unknown[c]:
			if not seen.has(path):
				seen[path] = true
				todo.append(path)
	if todo.size() <= SWEEP_MAX:
		_sweep_durations(todo)
	_mark_decks()

func _fill(crate: int) -> void:
	var list: ItemList = [_tracks, _tracks_b][crate]
	var playlist: String = _library.crate_pl[crate]
	list.clear()
	var row_path := PackedInt32Array()
	var path_row := PackedInt32Array()
	path_row.resize(_library.index.size())
	path_row.fill(-1)          # a filtered-out track has no row at all
	var needle: String = (_library.filters[crate] as String).to_lower()
	# Viewing a playlist shows ITS OWN stored order, not the crate's SORT -- that is what
	# MOVE UP/DOWN in the track menu rearranges, and there would be nothing to see it
	# rearrange if this still iterated the sorted library regardless. Folder grouping is a
	# library concept and does not apply to a playlist's deliberate order.
	var grouped: bool = SORTS[_library.sorts[crate]] == "FOLDER" and playlist.is_empty()
	# .assign(), NOT a direct assignment: ConfigFile hands back an UNTYPED Array, and
	# GDScript refuses untyped -> Array[String] outright ("Trying to assign an array of
	# type Array"). A playlist built this session is already typed and worked; one
	# reloaded from library.cfg threw here and took the whole track list down with it.
	var order: Array[String] = []
	if playlist.is_empty():
		order.assign(_library.orders[crate])
	else:
		# a playlist stores IDS; what it shows is wherever those tracks are today, and an id
		# the library no longer holds simply has no row
		for id in (_library.playlists.get(playlist, []) as Array):
			var at := _library.path_for(str(id))
			if not at.is_empty():
				order.append(at)
	var header := theme.get_color("font_color", "Green")
	var last_dir := ""
	var shown: Array[String] = []
	var unknown: Array[String] = []
	var pl_num := 0
	for path in order:
		var i: int = _library.path_pos.get(path, -1)
		if i < 0:
			continue   # a playlist entry whose file is no longer on disk
		var e: Dictionary = _library.index[i]
		# matched against folder + filename, which is what the row actually shows
		if not needle.is_empty() and not (e["hay"] as String).contains(needle):
			continue
		if grouped:
			if e["dir"] != last_dir:
				last_dir = e["dir"]
				list.add_item((e["dir"] as String).get_file().to_upper() + "/")
				# headers are labels, not tracks: unselectable so a double-click or an
				# arrow key can never land on one
				list.set_item_selectable(list.item_count - 1, false)
				list.set_item_custom_fg_color(list.item_count - 1, header)
				row_path.append(-1)
			list.add_item("  " + e["file"])
		elif not playlist.is_empty():
			pl_num += 1
			list.add_item("%2d. %s" % [pl_num, e["row"]])
		else:
			list.add_item(e["row"])
		# FIRST row wins. A playlist may legitimately list the same track twice, and the
		# later row used to overwrite this mapping -- after which selecting the playing
		# track jumped to the wrong copy and the highlight followed a row the transport
		# was not on. row_path still points every row at its own path, so opening
		# either copy works; only this reverse lookup has to pick one.
		if path_row[i] < 0:
			path_row[i] = list.item_count - 1
		row_path.append(i)
		shown.append(_library.paths[i])
		# memory only -- an unprobed track is counted as unknown here and swept below, never
		# probed inline, and an indexed one is not even stat'ed: that was 20k file opens on
		# this thread (14 s measured). _on_scan_finished validates the index on a worker.
		if _engine.peek_meta(_library.paths[i]).is_empty():
			unknown.append(_library.paths[i])
	# assigned back whole: a packed array read out of an Array is a copy
	_row_paths[crate] = row_path
	_path_rows[crate] = path_row
	_library.shown[crate] = shown
	_unknown[crate] = unknown
	if crate == 0:   # the count line lives under TRK A
		_recount()

## TRK A's count line, from what its list shows. Its own function so metadata landing from a
## worker repaints this one line rather than refilling 20k rows (a 2.9 s frame at 20k tracks).
func _recount() -> void:
	var secs := 0.0
	var partial := false
	for path: String in _library.shown[0]:
		var m := _engine.peek_meta(path)
		if m.is_empty():
			partial = true
		else:
			secs += float(m.get("duration", 0.0))
	# the playlist name wins the readout when both are on: it is the scope you chose and stays
	# chosen, where a search is transient
	var playlist: String = _library.crate_pl[0]
	var scope := playlist if not playlist.is_empty() \
		else ("FILTERED" if not (_library.filters[0] as String).is_empty() else "")
	_count.text = count_text(_library.paths.size(), (_library.shown[0] as Array).size(),
		_library.folders.size(), secs, scope, partial, _up_next.size())
	_queue_refresh()   # the QUEUE tab shows the same queue this line counts

## Each list highlights ITS deck's track, not whichever deck happens to be driven. A track
## filtered out of that crate's view simply has no row to select.
func _mark_decks() -> void:
	for deck in 2:
		var i: int = _library.path_pos.get(_current if deck == _engine.deck else _decks.deck_cur[deck], -1)
		var path_row: PackedInt32Array = _path_rows[deck]
		if i >= 0 and i < path_row.size() and path_row[i] >= 0:
			([_tracks, _tracks_b][deck] as ItemList).select(path_row[i])

## The line under the track list. Pure, so count_test() covers both branches and the
## partial marker without a library on disk.
##
## SORT dropped out of the unfiltered form: the SORT button sits directly above this
## label and already says the same word. `partial` prints a trailing "+" -- the total is
## a floor, not a guess, because some visible track has never been probed.
##
## Two short fixed lines rather than one long one, for the reason the EQ tab's note is:
## measured at 1920x1080 the sidebar sits on its 575 px floor and fits ~36 characters of
## this font, and the filtered form is 45. One line would either clip the total off the
## right edge or, without clip_text, push the whole sidebar wider.
## `scope` is "" for the whole library, "FILTERED" for a search, or the playlist's name
## -- one parameter for both narrowing kinds, because the line says the same thing either
## way: how many of the library you are looking at, and under what name.
static func count_text(total: int, shown: int, folders: int, secs: float,
		scope: String, partial: bool, queued := 0) -> String:
	var t := _dur_text(secs) + ("+" if partial else "")
	# the queue rides on the TIME line rather than the count line: it is not a count OF the
	# library, and the count line is already the longer of the two
	if queued > 0:
		t += "  //  QUEUE: %d" % queued
	if not scope.is_empty():
		return "%d TRACKS [%s: %d]\nTOTAL TIME: %s" % [total, scope, shown, t]
	return "%d TRACKS  //  %d FOLDERS\nTOTAL TIME: %s" % [total, folders, t]

static func count_test() -> bool:
	return count_text(78, 12, 3, 2535.0, "FILTERED", false) \
			== "78 TRACKS [FILTERED: 12]\nTOTAL TIME: 42:15" \
		and count_text(78, 9, 3, 600.0, "LATE NIGHT", false) \
			== "78 TRACKS [LATE NIGHT: 9]\nTOTAL TIME: 10:00" \
		and count_text(78, 78, 3, 0.0, "", true) \
			== "78 TRACKS  //  3 FOLDERS\nTOTAL TIME: 00:00+" \
		and count_text(2, 2, 1, 3661.0, "", false) \
			== "2 TRACKS  //  1 FOLDERS\nTOTAL TIME: 01:01:01" \
		and count_text(78, 78, 3, 600.0, "", false, 4) \
			== "78 TRACKS  //  3 FOLDERS\nTOTAL TIME: 10:00  //  QUEUE: 4" \
		and count_text(78, 9, 3, 600.0, "LATE NIGHT", true, 2) \
			== "78 TRACKS [LATE NIGHT: 9]\nTOTAL TIME: 10:00+  //  QUEUE: 2" \
		and _dur_text(3725.0) == "01:02:05" and _dur_text(125.0) == "02:05"

## How many unprobed tracks one readout may probe. A search result, or a small library,
## lands well under it; a 5,000-track library shown unfiltered does not, and its total
## stays marked partial rather than spawning 5,000 processes for a line of text.
# ponytail: one ffprobe per unknown track, and nothing is remembered across sessions.
# If exact cold totals for a big library ever matter, persist durations in library.cfg
# rather than raising this cap.
const SWEEP_MAX := 600
var _sweep_token := 0

## Fills in the lengths the readout is missing, on a worker, then repaints once.
##
## Every path is probed at most once per session even when the probe fails: metadata()
## caches its defaults either way, so `cached_meta` going non-empty is what ends this --
## a length of 0 does not, and testing for that would re-probe the same broken file
## forever.
func _sweep_durations(todo: Array[String]) -> void:
	_sweep_token += 1
	if todo.is_empty():
		return
	var token := _sweep_token
	# through the engine, so its shutdown() joins this sweep too -- up to SWEEP_MAX ffprobe
	# spawns, which is exactly the kind of task that used to outlive a window close
	_engine.run_task(func() -> void:
		for p in todo:
			if token != _sweep_token or _engine.is_shut_down():
				return   # superseded by a newer search, or the program is closing
			_engine.metadata(p)
		(func() -> void:
			if token == _sweep_token and not _engine.is_shut_down():
				# what the sweep learned is kept for the next launch
				_engine.save_index(_library.all_paths)
				_meta_arrived()).call_deferred())

## Metadata landed from a worker: a metadata sort re-sorts now that the artists, albums and keys
## are known; anything else only needs the count line repainted -- the rows show no metadata.
func _meta_arrived() -> void:
	if SORTS[_library.sorts[0]] in META_SORTS or SORTS[_library.sorts[1]] in META_SORTS:
		_reindex()
	else:
		_recount()

## Whether `dir` actually joined the library. What may join is LibraryModel's rule; the note
## about what happened belongs here, with the rest of the UI. `apply` false leaves the save and
## the rescan to the caller, so a drop of several folders costs one of each rather than one per.
func _add_folder(dir: String, apply := true) -> bool:
	var got := _library.add_folder(dir)
	if not got["added"]:
		# already inside a root, so its tracks are in the library either way
		_note = "  //  ALREADY COVERED BY %s" % str(got["covered_by"]).get_file().to_upper()
		_clear_note_later()
		return false
	if apply:
		_save()
		_rescan()
	return true

## Folders dropped anywhere on the window join the library in ONE save and ONE rescan,
## however many arrive together. Loose files are ignored rather than guessed at: adding a
## dropped track's whole parent folder is not what dropping one track means.
func _on_files_dropped(files: PackedStringArray) -> void:
	var dirs := 0
	var added := 0
	for f in files:
		if not DirAccess.dir_exists_absolute(f):
			continue
		dirs += 1
		if _add_folder(f, false):
			added += 1
	if added == 0:
		if dirs == 0:
			_note = "  //  DROP A MUSIC FOLDER TO ADD IT -- LOOSE FILES ARE IGNORED"
			_clear_note_later()
		return   # a folder that was already covered left its own note
	_save()
	_rescan()
	_note = "  //  ADDED %d FOLDER%s  //  %d TRACKS" % [added, "" if added == 1 else "S", _library.paths.size()]
	_clear_note_later()


# --- folder tree -----------------------------------------------------------
## The tree is derived from the walked track paths, NOT from a second recursive DirAccess
## pass. Every directory worth showing is one that holds audio or leads to one, and that
## set is already implied by _library.all_paths -- a folder with no music anywhere under it is not
## something anyone wants to filter by, and walking the disk twice to find it is wasted IO.
##
## Rebuilt only from _rescan(), never from _reindex(): folder counts change when the disk
## changes, not when the sort order does, and rebuilding would throw away the user's
## expand/collapse state every time they cycled SORT.
func _build_folder_tree() -> void:
	_folder_tree.clear()
	var own := _own_counts()
	var counts := _folder_counts(own)
	var root := _folder_tree.create_item()
	for base in _library.folders:
		var made := {base: _folder_item(root, base, counts)}
		for d in _dirs_under(base, own):
			# _dirs_under sorts, and for path strings a parent always sorts before its
			# own children -- so the parent item is guaranteed to exist by now
			made[d] = _folder_item(made[d.get_base_dir()], d, counts)
	_sync_enabled_from_tree()

func _folder_item(parent: TreeItem, path: String, counts: Dictionary) -> TreeItem:
	var item := _folder_tree.create_item(parent)
	item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	item.set_editable(0, true)
	item.set_text(0, "%s/  [%d]" % [path.get_file(), counts.get(path, 0)])
	item.set_metadata(0, path)
	# Three ways a folder ends up checked, and the third one is the fix: a directory the
	# last scan never saw is NEW, not switched off. Before this, a newly dropped album
	# was absent from the enabled set exactly like a folder the user had unticked, so it
	# was created unchecked and _apply_folder_filter dropped every track under it -- the
	# album simply never appeared, with no error anywhere.
	item.set_checked(0, not _library.enabled_known                 # fresh library: all on
		or not _library.known_folders.has(path)                    # never seen before: new, on
		or _library.enabled_folders.has(path))                     # seen before and left on
	return item

## Recursive track count for every directory, in one pass up each track's ancestor chain:
## O(tracks x depth). The obvious alternative -- begins_with() for every folder against
## every track -- is O(folders x tracks), which the old flat list got away with because it
## only ever had two rows. A tree has one row per directory.
##
## Tracks are counted into their own directory first and only the distinct directories walk up:
## walking every TRACK to the drive root was 20k x depth string splits (1.2 s at 20k tracks).
func _folder_counts(own: Dictionary) -> Dictionary:
	var counts := {}
	for leaf: String in own:
		var dir := leaf
		while true:
			counts[dir] = counts.get(dir, 0) + own[leaf]
			var up := dir.get_base_dir()
			if up == dir or up.is_empty():
				break
			dir = up
	return counts

## directory -> how many tracks sit directly in it.
func _own_counts() -> Dictionary:
	var own := {}
	for path in _library.all_paths:
		var dir := path.get_base_dir()
		own[dir] = own.get(dir, 0) + 1
	return own

## Every directory under `base` that holds audio, plus the ancestors linking them back to
## base. Sorted, because for path strings sorting puts a parent ahead of its children.
func _dirs_under(base: String, own: Dictionary) -> Array[String]:
	var seen := {}
	var prefix := base + "/"
	for leaf: String in own:
		if not leaf.begins_with(prefix):
			continue
		var dir := leaf
		while dir != base and dir.length() > base.length():
			seen[dir] = true
			dir = dir.get_base_dir()
	var out: Array[String] = []
	out.assign(seen.keys())
	out.sort()
	return out

## A parent's checkbox owns its whole subtree: unchecking a root turns off everything under
## it. Deliberately no tri-state -- a half-checked parent needs a third icon and a rule for
## what clicking it does, and neither earns its keep in a folder filter.
func _on_folder_tree_item_edited() -> void:
	var item := _folder_tree.get_edited()
	if not item:
		return
	_set_subtree_checked(item, item.is_checked(0))
	_sync_enabled_from_tree()
	_library.apply_folder_filter()
	_save()

static func _set_subtree_checked(item: TreeItem, on: bool) -> void:
	item.set_checked(0, on)
	var child := item.get_first_child()
	while child:
		_set_subtree_checked(child, on)
		child = child.get_next()

## RMB on a folder offers MAKE PLAYLIST -- direct files only, sub-folders ignored, which
## is what the checkbox filter already treats as a separate thing one level down.
func _on_folder_tree_input(e: InputEvent) -> void:
	if not (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT):
		return
	var item := _folder_tree.get_item_at_position(e.position)
	if not item:
		return
	var path: String = item.get_metadata(0)
	if path.is_empty():
		return
	_menu_ctx = {"kind": "folder", "path": path}
	%Menu.clear()
	%Menu.add_item("MAKE PLAYLIST", MENU_MAKE_PLAYLIST)
	_popup_at_mouse()

## Reads the tree back into the set. Iterative rather than recursive purely because the
## hidden root has no metadata and would need special-casing in a recursive version.
func _sync_enabled_from_tree() -> void:
	_library.enabled_folders.clear()
	# rebuilt rather than added to, so directories that have been deleted from disk drop
	# out of the known set instead of accumulating in the config forever
	_library.known_folders.clear()
	_library.enabled_known = true
	var stack: Array[TreeItem] = []
	if _folder_tree.get_root():
		stack.append(_folder_tree.get_root())
	while not stack.is_empty():
		var item: TreeItem = stack.pop_back()
		var meta = item.get_metadata(0)
		if meta != null:
			_library.known_folders[meta] = true   # it exists now; the next scan has seen it
			if item.is_checked(0):
				_library.enabled_folders[meta] = true
		var child := item.get_first_child()
		while child:
			stack.append(child)
			child = child.get_next()

## Unchecking a folder removes its tracks from the LIBRARY, not merely from the visible
## list. _library.paths feeds the play queue as well as the rows, so a track in an unchecked folder
## must not be reachable with NEXT either -- which is why the filter lives here and not in
## _refill(), which is only ever a view of _library.paths and is also what SEARCH filters.
## Transient status text: the note sits in the status bar rather than a popup, so it
## needs clearing or it would still be there ten minutes later.
func _clear_note_later() -> void:
	var keep := _note
	if not is_inside_tree():
		return   # a detached instance has no tree to time against; the note just stays
	await get_tree().create_timer(4.0).timeout
	if _note == keep:
		_note = ""

## Only a ROOT can be removed. A subfolder is not something the library owns, it is just
## something found on disk -- unchecking is how you exclude one, and removing it would only
## have it reappear on the next scan.
func _remove_folder() -> void:
	var sel := _folder_tree.get_selected()
	if not sel:
		return
	var gone: String = sel.get_metadata(0)
	if not gone in _library.folders:
		_note = "  //  SELECT A ROOT FOLDER TO REMOVE"
		_clear_note_later()
		return
	_library.folders.erase(gone)
	_save()
	_rescan()
	_note = "  //  REMOVED %s" % gone.get_file().to_upper()
	_clear_note_later()

## RELOCATE FOLDER: the library moved and the paths in the config did not. Typing the new
## location re-points every root that sat under the old one, in one step, instead of removing
## and re-adding each root and losing the folder checkboxes with them.
##
## Cues, RENAME tags and playlists need no part in this and are not touched. They are keyed by
## track id (LibraryModel.track_id), and an id does not know where the file is -- which is the
## entire reason they are keyed by id. Moving a library used to orphan every one of them.
func _add_relocate_button() -> void:
	var host: Control = %RemoveFolder.get_parent()
	var btn := Button.new()
	btn.name = "RelocateFolder"
	btn.text = "RELOCATE"
	btn.tooltip_text = "The library moved to another drive or folder: re-point its roots without losing your cues, tags or playlists."
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(btn)
	host.move_child(btn, %RemoveFolder.get_index() + 1)
	btn.pressed.connect(_relocate_folder)

func _relocate_folder() -> void:
	if _library.folders.is_empty():
		_note = "  //  NO LIBRARY FOLDERS TO RELOCATE"
		_clear_note_later()
		return
	var sel := _folder_tree.get_selected()
	var guess: String = sel.get_metadata(0) if sel else ""
	if not guess in _library.folders:
		guess = _library.folders[0]
	_ask("RELOCATE: OLD PATH", guess, func(old_path: String) -> void:
		if old_path.strip_edges().is_empty():
			return
		_ask("RELOCATE: NEW PATH", old_path, func(new_path: String) -> void:
			var moved := _library.relocate(old_path, new_path)
			if moved == 0:
				_note = "  //  NOTHING UNDER %s" % old_path.to_upper()
				_clear_note_later()
				return
			_save()
			_rescan()
			_note = "  //  RELOCATED %d ROOT%s TO %s" % [moved, "" if moved == 1 else "S", new_path.to_upper()]
			_clear_note_later()))

func _save() -> void:
	# REBOOT has already moved the config aside; a periodic or debounced save landing in
	# the frame before quit() would otherwise write the old settings straight back. And a
	# node that never ran _ready has loaded nothing, so a save from it would write pure
	# defaults over the real file -- test scripts drive methods on a detached player.gd.
	if _rebooting or not is_node_ready():
		return
	_write_cfg_async(_build_cfg())

## Every setting, cue, playlist, tag and keybind as a ConfigFile, built from live state on the
## main thread.
##
## Split out of _save() so EXPORT SETUP can have the same object WITHOUT going through the
## file. _save() hands the write to a worker, so loading the config back in the line after
## calling it races that worker and reads the PREVIOUS save -- which is precisely how the
## first version of the export came out carrying last session's tags while the note cheerfully
## reported the current ones.
func _build_cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("library", "folders", _library.folders)
	cfg.set_value("library", "enabled_folders", _library.enabled_folders.keys())
	cfg.set_value("library", "known_folders", _library.known_folders.keys())
	cfg.set_value("library", "sort", _library.sorts[0])
	cfg.set_value("library", "sort_b", _library.sorts[1])
	cfg.set_value("library", "tbs", _tbs)
	cfg.set_value("library", "track_labels", _library.labels)
	cfg.set_value("library", "id_scheme", _id_scheme)
	cfg.set_value("library", "playlist", _library.crate_pl[0])
	cfg.set_value("library", "playlist_b", _library.crate_pl[1])
	cfg.set_value("playlists", "list", _library.playlists)
	cfg.set_value("playlists", "cues", _library.pl_cues)
	cfg.set_value("cues", "tracks", _library.cues)
	cfg.set_value("library", "shuffle", _engine.shuffle)
	cfg.set_value("library", "shuffle_mode", int(_engine.shuffle_mode))
	cfg.set_value("library", "repeat", int(_engine.repeat))
	cfg.set_value("audio", "volume", _volume)
	cfg.set_value("audio", "boost", _boost)
	cfg.set_value("audio", "fade", _decks.fade_on)
	cfg.set_value("audio", "fade_ms", _decks.fade_ms)
	cfg.set_value("audio", "play_delay_ms", _decks.delay_ms)
	cfg.set_value("audio", "track_tempo", _director.track_tempo)
	# never persist FULLSCREEN: it would boot into a UI with no visible way out
	cfg.set_value("visual", "feed_size", _feed_prev if _feed == Feed.FULLSCREEN else _feed)
	cfg.set_value("visual", "split_frac", _split_frac)
	cfg.set_value("visual", "clock_12h", _clock_12h)
	cfg.set_value("visual", "show_ms", _show_ms)
	cfg.set_value("visual", "font", _font_name)
	cfg.set_value("visual", "font_size", _font_size)
	# erased first: deleting a gradient shortens the list, and a leftover user_grad_4
	# would be read back on the next launch as a gradient that no longer exists
	for gi in GRAD_MAX:
		if cfg.has_section_key("visual", _grad_key(gi)):
			cfg.erase_section_key("visual", _grad_key(gi))
	for gi in _gradients.size():
		cfg.set_value("visual", _grad_key(gi), Visualizer.to_hex_list(_gradients[gi]))
	cfg.set_value("library", "setlist_b", _setlist_b)
	cfg.set_value("secrets", "unlocked", ",".join(PackedStringArray(_unlocked)))
	cfg.set_value("secrets", "endpoint", _license_endpoint)
	cfg.set_value("visual", "cursor", _cursor_name)
	cfg.set_value("visual", "cursor_scale", _cursor_scale)
	cfg.set_value("visual", "cursor_hotspot", _cursor_hotspot)
	cfg.set_value("visual", "intro_video", _intro_on)
	cfg.set_value("visual", "max_fps", _max_fps)
	cfg.set_value("visual", "layout", _layout)
	cfg.set_value("visual", "skin", _skin)
	cfg.set_value("audio", "mono", _mono)
	cfg.set_value("visual", "crt", _crt_on)
	cfg.set_value("visual", "bg_throttle", _bg_throttle)
	cfg.set_value("visual", "playbar_split", _playbar_offset)
	cfg.set_value("visual", "now_playing", _now_playing)
	cfg.set_value("visual", "now_mode", _now_mode)
	cfg.set_value("visual", "meter", _meter_on)
	cfg.set_value("visual", "dual_bars", _dual_bars)
	cfg.set_value("audio", "output_device", _output_device)
	cfg.set_value("visual", "video_test", _video_test)
	cfg.set_value("visual", "listening_mode", _listening_mode)
	cfg.set_value("visual", "video_color", int(_video_color))
	cfg.set_value("visual", "playbar", _playbar_on)
	cfg.set_value("display", "playbar_waveform", _show_playbar_wave)
	cfg.set_value("visual", "visual_windowed", _visual_windowed)
	cfg.set_value("visual", "dual_deck_mode", _dual_deck)
	cfg.set_value("visual", "dual_visual", _dual_visual)
	# %Viz / %VizB, never _viz: that is whichever half the VIS tab happens to be editing
	cfg.set_value("visual", "color_anim", int(%Viz.color_anim))
	cfg.set_value("visual", "rotate_gradients", %Viz.rotate_gradients)
	cfg.set_value("visual", "color_anim_b", int(%VizB.color_anim))
	cfg.set_value("visual", "rotate_gradients_b", %VizB.rotate_gradients)
	cfg.set_value("input", "skip_secs", _skip_secs)
	cfg.set_value("visual", "fade_speed", _fade_speed)
	for action in KEYBIND_SPEC:
		cfg.set_value("keybinds", action, _keybinds[action])
	# one key holding the whole map, rather than key-per-action: [keybinds] is shaped that way
	# because KEYBIND_SPEC is its schema, and a binding here is a dictionary, not an int
	cfg.set_value("midibinds", "map", _midi.to_dict())
	if _rack_decks.size() == 2:
		cfg.set_value("rack", "state", _rack_decks[0].to_dict())
		cfg.set_value("rack", "state_b", _rack_decks[1].to_dict())
	cfg.set_value("rack", "presets", _rack_presets)
	cfg.set_value("record", "dir", _rec_dir)
	cfg.set_value("record", "rate", _rec_rate)
	cfg.set_value("record", "type", _rec_type)
	cfg.set_value("record", "quality", _rec_quality)
	var spectral_snapshot := _engine.spectral_cache_snapshot()
	for k in spectral_snapshot:
		cfg.set_value("spectral_keys", k, spectral_snapshot[k])
	cfg.set_value("eq", "state", _eq_decks[0].to_dict())
	cfg.set_value("eq", "state_b", _eq_decks[1].to_dict())
	cfg.set_value("audio", "crossfader", _decks.crossfader)
	cfg.set_value("audio", "beat_sync", _beat_sync)
	cfg.set_value("audio", "deck", _engine.deck)
	cfg.set_value("audio", "both", _engine.both)
	cfg.set_value("eq", "presets", _presets)
	cfg.set_value("stats", "total_seconds", _total_secs)
	cfg.set_value("stats", "user_name", _user_name)
	for pair in [["viz", %Viz], ["viz_b", %VizB]]:
		var v: Visualizer = pair[1]
		cfg.set_value("visual", pair[0], {
			"mode": int(v.mode), "color": v.color_index, "custom": v.custom_color.to_html(false),
			"sens": v.sensitivity,
			"tilt": v.tilt_db, "height": v.height_scale, "speed": v.speed})
	return cfg

## The config is BUILT on the main thread -- every value above is read straight off live state,
## and snapshotting it anywhere else would be a data race -- but the three file operations that
## follow are not. A library with thousands of cached spectral keys, a few hundred cues and a
## setlist serialises to a file big enough that ConfigFile.save() plus two renames is a visible
## hitch, and _save_soon fires it every time a fader moves, a cue is dropped or a track is
## filed. The finished ConfigFile is handed to a worker, which nothing else touches.
##
## One at a time, and in order: two overlapping writers would race over the same .tmp and .bak.
var _cfg_task := -1

func _write_cfg_async(cfg: ConfigFile) -> void:
	if _cfg_task != -1:
		WorkerThreadPool.wait_for_task_completion(_cfg_task)
	var path := _cfg
	_cfg_task = WorkerThreadPool.add_task(func() -> void:
		var err := save_cfg_atomic(cfg, path)
		if err != OK:
			_on_cfg_write_failed.call_deferred(error_string(err)))

func _on_cfg_write_failed(reason: String) -> void:
	_log_fault("CONFIG SAVE FAILED", "%s: %s" % [_cfg, reason])
	_note = "  //  CONFIG SAVE FAILED (%s)" % reason

## Nothing may outlive the write. A quit with a save still in flight would take the process
## down mid-rename, which is exactly the window save_cfg_atomic exists to close.
func _finish_cfg_write() -> void:
	if _cfg_task != -1:
		WorkerThreadPool.wait_for_task_completion(_cfg_task)
		_cfg_task = -1

## The config on disk is never half-written. The new file goes to .tmp first; only once
## that write has fully succeeded does the live file move aside to .bak and the .tmp take
## its place. Every step is a rename, so at any instant a complete copy exists as the live
## file, the .bak or the .tmp -- and load_cfg_safe reads the .bak when the live one is
## missing. Static, so test_config.gd can drive it without a scene.
static func save_cfg_atomic(cfg: ConfigFile, path: String) -> Error:
	var live := ProjectSettings.globalize_path(path)
	var err := cfg.save(live + ".tmp")
	if err != OK:
		return err   # the live file was never touched
	if FileAccess.file_exists(live):
		if FileAccess.file_exists(live + ".bak"):
			DirAccess.remove_absolute(live + ".bak")
		err = DirAccess.rename_absolute(live, live + ".bak")
		if err != OK:
			return err   # the .tmp is left beside an untouched live file
	return DirAccess.rename_absolute(live + ".tmp", live)

## Loads `path` into `cfg`. A file that EXISTS but will not parse is renamed to
## .corrupt-<unix time> and the .bak is loaded in its place. The old load fell through to
## defaults, and _ready's save then wrote those defaults over every playlist, cue and
## preset -- one hand-edit typo away. Returns the kept file's name, or "".
static func load_cfg_safe(cfg: ConfigFile, path: String) -> String:
	var err := cfg.load(path)
	if err == OK:
		return ""
	cfg.clear()   # a failed parse can leave behind the sections it got through first
	var live := ProjectSettings.globalize_path(path)
	var kept := ""
	if FileAccess.file_exists(live):
		kept = "%s.corrupt-%d" % [live.get_file(), int(Time.get_unix_time_from_system())]
		DirAccess.rename_absolute(live, live.get_base_dir().path_join(kept))
		push_warning("%s would not parse (%s); kept as %s" % [path.get_file(), error_string(err), kept])
	if FileAccess.file_exists(live + ".bak") and cfg.load(live + ".bak") != OK:
		cfg.clear()
	return kept

## Closing the window is the only way out of the app, and the odometer only flushes every
## 30 s, so without this the last half-minute of every session is lost. This is the ONLY
## exit write: _exit_tree() used to duplicate it, and both fired on a normal close.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready():
		# ORDER MATTERS, and every step is about not losing work on the way out.
		# A take still running has a placeholder RIFF header claiming zero bytes of audio;
		# stop() patches the real sizes in and hands the conversion to a worker. The config is
		# saved NEXT, before any worker is joined, so a close that stalls or is force-killed
		# after this point has already written everything. shutdown() then kills every
		# ffmpeg/ffprobe still running -- that conversion included, whose float take stays
		# intact -- and joins the workers, which now takes milliseconds rather than the rest of
		# a render. The index goes last, once no worker can still be writing _meta.
		if _recorder and _recorder.recording:
			_recorder.stop(_rec_type, _rec_rate, _rec_quality)
		_save()
		if _engine:
			_engine.shutdown()
			_engine.save_index(_library.all_paths)   # after the join, so no worker is still writing _meta
		_library.stop_scan()   # a walk still running has nothing left to report to
		_finish_cfg_write()    # the config write is on a worker; the process may not outrun it
		OS.close_midi_inputs()   # hands the device back rather than holding it until the OS notices
	# A drag begins somewhere and ends somewhere; Godot tells every Control about both
	# but never says where. So the tab under the cursor is noted at the start, and at the
	# end the cursor is asked again -- if the drag was not consumed by anything (the tab
	# bar did not reorder it, no other Control took it) and the cursor is outside both tab
	# docks, that is a tear-off. Over the OTHER dock it is a move into that dock.
	#
	# The move is done here with reparent() rather than by giving the two TabContainers one
	# tabs_rearrange_group. Godot's own cross-container drop is remove_child + add_child, which
	# clears the owner of every scene-built node in the tab -- %TracksA, %Search, %EqMode and the
	# rest would stop resolving. reparent() keeps owners (see _move_row).
	elif what == NOTIFICATION_DRAG_BEGIN:
		# The drag data names the dragged tab and its bar exactly. Hit-testing the pointer here
		# instead read whatever tab it had travelled onto by the time the drag threshold tripped
		# -- the neighbour, for a press near a tab's edge.
		_drag_dock = null
		_drag_tab = -1
		var data: Variant = get_viewport().gui_get_drag_data()
		if data is Dictionary and data.get("type") == "tab" and data.has("from_path"):
			for dock: TabContainer in [_tabs, %DeckADock]:
				if get_node_or_null(data["from_path"]) == dock.get_tab_bar():
					_drag_dock = dock
					_drag_tab = int(data.get("tab_index", -1))
	elif what == NOTIFICATION_DRAG_END:
		var idx := _drag_tab
		var from := _drag_dock
		_drag_tab = -1
		_drag_dock = null
		if idx < 0 or not is_instance_valid(from) or get_viewport().gui_is_drag_successful():
			return
		var over: TabContainer = null
		for dock: TabContainer in [_tabs, %DeckADock]:
			if dock.is_visible_in_tree() and dock.get_global_rect().has_point(dock.get_global_mouse_position()):
				over = dock
		if over == null:
			_tear_off_tab(from, idx)
		elif over != from:
			_move_tab(from.get_tab_control(idx), over)
	# Application focus, not the main window's: clicking into a torn-off FX or settings
	# window is still using the program, and throttling there would make its faders stutter.
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_apply_bg_throttle(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_apply_bg_throttle(true)

## The frame cap for the focus state, under LOWER USAGE IN BACKGROUND. Off by default, because a
## visualizer someone put on a second monitor to WATCH while they work in another program is the
## normal way this gets left unfocused, and 30 FPS is visible on it.
##
## Focus returning always restores the user's cap, throttle on or off: switching the toggle off
## while the program sits in the background must not leave it capped for the rest of the session.
func _apply_bg_throttle(focused: bool) -> void:
	if focused or not _bg_throttle:
		Engine.max_fps = _max_fps
		return
	Engine.max_fps = UNFOCUSED_FPS if _max_fps == FPS_UNCAPPED or _max_fps > UNFOCUSED_FPS \
		else _max_fps

# --- playback (decoding, metadata and preload live in AudioEngine) ---------
## `i` indexes the ENGINE QUEUE, which is the visible list -- not _library.paths. The two are the
## same array until a search narrows it, and bounds-checking against the wrong one is how
## a filtered queue would load the wrong track.
##
## `auto` says a track ENDED and this is the queue moving on, rather than somebody asking for
## this track. Only that case may skip past a file that will not decode: a track picked by hand
## stays picked, and the failure is reported instead of quietly playing something else.
func _open(i: int, auto := false) -> void:
	if i < 0 or i >= _engine.queue.size():
		return
	_decks.auto_advancing = auto
	_video.stream = null
	# The outgoing track is NOT stopped here any more. Stopping up front cut to silence
	# the instant a track was picked and held it until the decode landed -- which for an
	# uncached FLAC is an ffmpeg transcode, so the gap was seconds long and read as "play
	# is slow to start". _on_track_ready already calls _stop() before it swaps the stream
	# in, so the old track simply keeps playing until the new one is genuinely ready and
	# the changeover is immediate. A decode that fails now leaves the current track
	# playing rather than leaving the deck silent.
	_busy = true
	_note = "  //  LOADING %s" % _engine.queue[i].get_file()
	_engine.request(i)

func _on_track_ready(path: String, stream: AudioStream, _meta: Dictionary, deck: int) -> void:
	_busy = false
	_set_reversed(deck, false)   # a new track always loads forward, on whichever deck it lands on
	# requested on `deck`; if the user has switched away since, it plays there and nothing
	# about the live deck changes
	if deck != _engine.deck:
		_load_parked(deck, path, stream)
		return
	_note = ""
	_current = path
	_note_track_for_set(path)     # the running order of a take, if one is recording
	_decks.fail_streak = 0        # something played: whatever came before it was a run of bad files
	_decks.auto_advancing = false
	_refresh_rev_btn()
	if _decks.fade_on and _decks.audio.playing:
		_crossfade(stream, deck)
	else:
		_stop()
		_decks.audio.stream = stream  # already decoded on a worker, or handed over from preload
		_decks.audio.volume_db = ACTIVE_DB
		_decks.audio.play()
	# the spectrum feed follows whichever player is live, and attach() resets the tempo
	# lock for us -- it is per-track, and carrying it over would fight the new song
	_director.attach(_decks.audio)
	_sync_attach(deck)   # a new track on this deck: its tracker starts a fresh lock
	_arm_picture(path, stream)
	_ticker.text = _engine.ticker_line(path)
	_cue_overlay.queue_redraw()   # the new track's cue markers, not the old one's
	# already cached by the worker that decoded the track: a dictionary read, no I/O
	_key = _resolved_key(path)
	_mark_decks()

## Video TEST: an MP4's picture renders after its sound is already playing, and only for the
## deck being looked at. Any other track clears whatever picture was up.
## ponytail: an MP4 loaded onto the PARKED deck plays sound only; a picture per deck is the
## upgrade if mixing two videos ever matters.
func _arm_picture(path: String, stream: AudioStream) -> void:
	var mp4 := _video_test and path.get_extension().to_lower() == "mp4"
	_picture.expect(path if mp4 else "", stream if mp4 else null)
	if mp4:
		_engine.request_video(path)

## The picture's palette: the user gradient picked on the VISUAL tab when one is, else the
## skin's own screen colours. Read every frame, so gradient rotation and a new pick land at once.
## levels[0] drives the kick: at the 96 kHz mix the analyser's lowest FFT bin spans about
## 0-94 Hz, so that band carries the kick fundamental as well as the sub-bass.
func _video_palette() -> Gradient:
	var gi: int = _viz.gradient_index()
	return _gradients[gi] if gi >= 0 and gi < _gradients.size() else _skin_ramp

## The skip-and-stop rule, and the counters it reads, belong to DeckController.
const MAX_AUTO_SKIPS := DeckController.MAX_AUTO_SKIPS

## A decode that did not produce a stream. On a track the user picked, that is a note and
## nothing else. During AUTO-ADVANCE it used to be the end of the set: one FLAC on a build
## without the extension, one DST-compressed DSD, one track whose cloud copy is not on this
## disk, and playback simply stopped behind a note that cleared itself four seconds later.
func _on_track_failed(path: String, reason: String, deck: int) -> void:
	_busy = false
	_decks.failed_tracks[path] = reason
	_log_fault("CANNOT PLAY", "%s (%s)" % [path, reason])
	match DeckController.fail_action(_decks.auto_advancing, deck == _engine.deck, _decks.fail_streak):
		DeckController.Fail.REPORT:
			_note = "  //  %s: %s" % [reason.to_upper(), path.get_file()]
			_clear_note_later()
		DeckController.Fail.SKIP:
			_decks.fail_streak += 1
			_note = "  //  SKIPPED %s (%s)" % [path.get_file(), reason.to_upper()]
			_clear_note_later()
			_next(true)
		DeckController.Fail.STOP:
			_decks.auto_advancing = false
			_decks.fail_streak = 0
			_stop(deck)
			# left on screen: playback has stopped, and the reason is the only way to tell that
			# from the end of a queue
			_note = "  //  [!] PLAYBACK STOPPED: %d TRACKS IN A ROW WOULD NOT PLAY  //  LAST %s (%s)" % [
				MAX_AUTO_SKIPS, path.get_file(), reason.to_upper()]

func _load_parked(deck: int, path: String, stream: AudioStream) -> void:
	if _decks.fade_on and _live_player(deck).playing:
		_crossfade(stream, deck)
	else:
		_kill_fade(deck)
		var pl := _live_player(deck)
		for other: AudioStreamPlayer in _decks.pair[deck]:
			other.stop()
			other.stream_paused = false
			other.volume_db = ACTIVE_DB
		pl.stream = stream
		pl.play()
		_decks.deck_live[deck] = pl
	_decks.deck_cur[deck] = path
	_sync_attach(deck)
	_mark_decks()
	_note = "  //  LOADED ON %s: %s" % [AudioEngine.DECK_NAMES[deck], path.get_file()]
	_clear_note_later()

# --- UP NEXT: the hand-built queue ------------------------------------------------------
## Tracks the user put in front of the running order, by path, in play order. PLAY NEXT pushes to
## the FRONT (the next thing that plays), ADD TO QUEUE appends.
##
## This sits ON TOP of AudioEngine.queue, which is the crate's visible list and is what SHUFFLE,
## REPEAT and auto-advance walk. While anything is in here it wins: every advance takes from this
## first, and only when it runs dry does the running order carry on from where it was. That is
## the whole rule, and it is why nothing here touches _engine.index -- a queued track plays and
## the crate's place in its own list is exactly where it was.
##
## ponytail: session state, not saved. A queue is what you are doing in the next ten minutes, and
## restoring one from three days ago is a list nobody asked for. Persist it if that turns out to
## be wrong.
var _up_next: Array[String] = []

## The next queued track that still exists, played on the driven deck. Returns false when the
## queue is empty or everything left in it has gone from disk.
func _play_queued(auto: bool) -> bool:
	while not _up_next.is_empty():
		var path: String = _up_next.pop_front()
		if not FileAccess.file_exists(path):
			continue   # deleted or unplugged since it was queued; the queue is not a promise
		var at := _engine.queue.find(path)
		if at >= 0:
			_open(at, auto)
		else:
			# queued from the other crate, or from under a search that has since changed: it
			# still plays, by path, and the crate's own position stays where it is
			_decks.auto_advancing = auto
			_busy = true
			_note = "  //  LOADING %s" % path.get_file()
			_engine.load_on(_engine.deck, path)
		_recount()   # the QUEUE count on the track readout
		return true
	return false

## Adds `paths` to the queue and says so. `front` is PLAY NEXT: the run lands in front of whatever
## was queued, in the order it was picked, so queueing three tracks plays them in that order.
func _queue_tracks(paths: Array[String], front: bool) -> void:
	if paths.is_empty():
		return
	if front:
		for i in range(paths.size() - 1, -1, -1):
			_up_next.push_front(paths[i])
	else:
		_up_next.append_array(paths)
	_recount()
	_note = "  //  %s: %s" % ["PLAYING NEXT" if front else "QUEUED",
		paths[0].get_file() if paths.size() == 1 else "%d TRACKS" % paths.size()]
	_clear_note_later()

func _clear_queue() -> void:
	var was := _up_next.size()
	_up_next.clear()
	_recount()
	_note = "  //  QUEUE CLEARED (%d)" % was
	_clear_note_later()

# --- the QUEUE tab: what is actually in _up_next -----------------------------------------
## The queue was write-only. Tracks went in from the track menu and the readout counted them,
## but there was no way to see what was in there, take one back out, or change the order --
## which for the one list you build by hand is the wrong half of the job to have shipped.
##
## The list is rebuilt whole on every change rather than patched: a queue is tens of rows, and
## _recount() already runs on every change the queue has, so there is one hook and no bookkeeping.
var _queue_list: ItemList

func _setup_queue_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "QUEUE"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	_queue_list = ItemList.new()
	_queue_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_queue_list.allow_reselect = true
	tab.add_child(_queue_list)
	# double-click plays it now rather than waiting its turn: moved to the front and handed to
	# the same _play_queued() an auto-advance uses, so there is no second way to start a track
	_queue_list.item_activated.connect(func(row: int) -> void:
		if row >= 0 and row < _up_next.size():
			_up_next.push_front(_up_next.pop_at(row))
			if not _play_queued(false):
				_recount())
	var row := HFlowContainer.new()
	tab.add_child(row)
	# A symbol and a short word each. The glyphs are CHECKED against the program's own font
	# rather than chosen from a character map: Px437 IBM BIOS has the two triangles at U+25B2
	# and U+25BC, and does NOT have the heavy X at U+2716 or the wastebasket at U+1F5D1 -- a
	# button carrying either of those would have drawn empty, which is the bug being fixed
	# here. X and the filled block are in the font and say the same thing.
	#
	# Short words, not the full sentences these had: REMOVE alone reads as "off the disk" with
	# a track list on the same screen, and DEL beside an X does not. The hover line carries the
	# rest, and this is the one tab where a mis-click silently throws away a hand-built order.
	for spec in [["[ ▲ UP ]", -1], ["[ ▼ DOWN ]", 1]]:
		var delta: int = spec[1]
		var b := _queue_button(row, str(spec[0]))
		b.pressed.connect(func() -> void: _queue_move(delta))
		var way: String = "UP" if delta < 0 else "DOWN"
		_hover_note(b, func() -> String:
			return "MOVES THE SELECTED TRACK ONE PLACE %s THE QUEUE" % way)
	var drop := _queue_button(row, "[ X DEL ]")
	drop.pressed.connect(_queue_drop)
	_hover_note(drop, func() -> String:
		return "TAKES THE SELECTED TRACK OUT OF THE QUEUE  //  THE FILE AND THE LIBRARY ARE UNTOUCHED")
	var clear := _queue_button(row, "[ ■ CLEAR ]")
	clear.pressed.connect(_clear_queue)
	_hover_note(clear, func() -> String:
		return "EMPTIES THE QUEUE: %d TRACK%s  //  PLAYBACK CARRIES ON FROM THE CRATE" % [
			_up_next.size(), "" if _up_next.size() == 1 else "S"])
	var note := Label.new()
	note.text = "PLAY NEXT GOES TO THE TOP\nADD TO QUEUE GOES TO THE BOTTOM"
	note.theme_type_variation = &"Green"
	tab.add_child(note)
	_queue_refresh()

## ponytail: rebuilt whole, unconditionally. It is worth saying why there is no "only when the
## tab is showing" guard, because I wrote one and it was wrong: an ItemList holding tens of rows
## costs nothing to refill, while `is_visible_in_tree()` is false for a tab nobody has clicked --
## so the guard left the list permanently empty and only the first visit would have filled it.
## The 20k-row relayout that guards like that exist for is the TRACK list's problem, not this one.
## One queue button, added and then PINNED. The order matters: _drop_focus runs off node_added
## and sets clip_text on everything under the tabs, so the pin has to be taken after the button
## is in the tree or the clip wins and the button collapses to a couple of characters. Pinning
## also survives the re-walk that toggling KEYBOARD NAVIGATION does, where simply clearing
## clip_text here would not.
func _queue_button(row: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	row.add_child(b)
	b.custom_minimum_size.y = 24   # a comfortable target for a destructive button
	_pin_label(b)
	return b

func _queue_refresh() -> void:
	if not is_instance_valid(_queue_list):
		return   # _recount() runs during boot, before the tab is built
	var keep := _queue_list.get_selected_items()
	_queue_list.clear()
	for i in _up_next.size():
		var path: String = _up_next[i]
		_queue_list.add_item("%2d. %s" % [i + 1,
			_library.labels.get(_library.id_for(path), path.get_file())])
	if keep.size() > 0 and keep[0] < _queue_list.item_count:
		_queue_list.select(keep[0])

## MOVE UP / MOVE DOWN, on the same pure helper the playlist reorder uses. The selection
## follows the row it was on, because moving a track three places means clicking UP three times.
func _queue_move(delta: int) -> void:
	var sel := _queue_list.get_selected_items()
	if sel.is_empty():
		return
	var to := setlist_move(_up_next, sel[0], delta)
	_queue_refresh()
	if to >= 0 and to < _queue_list.item_count:
		_queue_list.select(to)

func _queue_drop() -> void:
	var sel := _queue_list.get_selected_items()
	if sel.is_empty():
		return
	var at: int = sel[0]
	if at >= _up_next.size():
		return
	_note = "  //  OUT OF THE QUEUE: %s" % (_up_next[at] as String).get_file()
	_clear_note_later()
	_up_next.remove_at(at)
	_recount()   # the readout's count and this list, in that one call
	if _queue_list.item_count > 0:
		_queue_list.select(mini(at, _queue_list.item_count - 1))

func _next(auto := false) -> void:
	if _play_queued(auto):
		return
	_open(_engine.next_index(), auto)

func _prev() -> void:
	_open(_engine.prev_index())

# --- backend switch: the only place audio vs video APIs differ -------------
## The deck the transport bar shows AND drives -- times, scrub, PLAY/PAUSE, STOP, arrow seeks
## and the cue markers. Normally the focused deck. But a focused deck holding NOTHING hands
## the bar to the other deck while that one is playing or paused: moving focus onto an empty
## deck to load it must not blank the bar, the markers and the analyser under the music you
## can hear. The first track loaded on the focused deck takes the bar back.
func _bar_deck() -> int:
	if _decks.audio.stream or _vid():
		return _engine.deck
	var other := _live_player(1 - _engine.deck)
	return 1 - _engine.deck if other.stream and (other.playing or other.stream_paused) else _engine.deck

func _bar() -> AudioStreamPlayer: return _live_player(_bar_deck())
func _bar_path() -> String: return _current if _bar_deck() == _engine.deck else _decks.deck_cur[1 - _engine.deck]

func _vid() -> bool: return _video.stream != null
func _len() -> float: return _video.get_stream_length() if _vid() else (_bar().stream.get_length() if _bar().stream else 0.0)
func _pos() -> float: return _video.stream_position if _vid() else _bar().get_playback_position()
func _playing() -> bool: return _video.is_playing() if _vid() else _bar().playing
func _paused() -> bool: return _video.paused if _vid() else _bar().stream_paused
func _seek(t: float) -> void:
	# ponytail: VideoStreamPlayer seeks to the nearest keyframe; exact only for audio.
	if _vid(): _video.stream_position = t
	else: _bar().seek(t)

func _set_paused(v: bool) -> void:
	if _vid(): _video.paused = v
	else: _bar().stream_paused = v

# --- transport ------------------------------------------------------------
## Single play/pause control -- the button's label is derived from _state(), so it can
## never disagree with what the audio is actually doing.
func _toggle() -> void:
	if _state() == "PLAYING":
		_set_paused(true)
	else:
		_play()

func _play() -> void:
	_set_paused(false)
	if _playing():
		return
	if _vid(): _video.play()
	elif _bar().stream: _bar().play()

## Stops one deck: the focused one by default, which is what every internal caller means --
## a track landing on the focused deck must never stop the other. The STOP button and the
## media key pass _bar_deck(), so they stop what the bar is showing.
func _stop(deck := _engine.deck) -> void:
	_kill_fade(deck)   # this deck's fade only; the other deck keeps its own
	_video.stop()
	for pl: AudioStreamPlayer in _decks.pair[deck]:
		pl.stop()
		pl.stream_paused = false
		pl.volume_db = ACTIVE_DB
	_scrub.value = 0.0

func _state() -> String:
	# AudioStreamPlayer.playing goes false while stream_paused is set, so test paused first.
	if _paused(): return "PAUSED"
	return "PLAYING" if _playing() else "STOPPED"

# --- scrub / volume: click-drag on a ProgressBar, no slider grabber art ----
## Scrubbing now goes through the same _bar_drag predicate as every other bar in the
## program. The old hand-rolled version tracked the button with its own flag and cleared
## it on the release event -- which never arrives if the release lands outside the bar,
## so _dragging latched on and a later hover kept scrubbing with nothing held down.
##
## The release is no longer handled here at all; _process polls the button instead, so an
## off-bar release completes the seek exactly like an on-bar one.
func _on_scrub_input(e: InputEvent) -> void:
	# No cue handling here beyond MARK MODE: %CueOverlay takes marker presses first and
	# passes everything else down.
	#
	# While MARK MODE is on, the bar does not seek AT ALL -- not on the press, and not on
	# the drag that follows it. The press alone was already being swallowed, but any
	# twitch with the button still down fell through to _bar_drag below, set _dragging,
	# and _process seeked on release: dropping a marker moved the playhead nearly every
	# time. One gesture cannot both mark and seek.
	if _mark_mode:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_add_cue(_ratio_at(e.position.x, _scrub.size.x) * _len())
		return
	var w := _bar_wheel(e, _scrub.value / 100.0, BAR_WHEEL_COARSE)
	if w >= 0.0 and _len() > 0.0:
		_scrub.value = w * 100.0
		_seek(w * _len())
		return
	if not _bar_drag(e, _scrub):
		return
	_dragging = true
	_scrub.value = _ratio_at(e.position.x, _scrub.size.x) * 100.0

func _on_vol_input(e: InputEvent) -> void:
	var w := _bar_wheel(e, _volume / 100.0, BAR_WHEEL_COARSE)
	if w >= 0.0:
		_set_volume(w * 100.0)
		return
	if _bar_drag(e, _vol):
		_set_volume(_ratio_at(e.position.x, _vol.size.x) * 100.0)

# --- master level meter -------------------------------------------------------------------
## What is actually leaving the program, as opposed to where the volume fader is sitting. Those
## are different questions: a boosted track through a rack that is clipping reads 100 on the
## fader and -0.2 dBFS here, and only one of those tells you the room is about to get a crunch.
##
## Peak, not RMS. RMS is the better number for loudness and the wrong one for this: the thing
## worth seeing on a transport bar is whether anything TOUCHED full scale, and an average never
## shows that. AudioServer tracks peak per bus for free -- measured -20 dB while playing and
## -200 with nothing running -- so there is no analyser to add and nothing per-frame to compute.
const METER_FLOOR_DB := -48.0     # below this the bar is empty; quieter than anything musical
const METER_HOLD_SEC := 1.2       # how long the peak pip sits before it falls
const METER_FALL := 22.0          # dB a second, once it lets go
var _meter: Control
var _meter_on := true             # TBS MASTER METER, saved
var _meter_btn: Button
var _meter_peak := [METER_FLOOR_DB, METER_FLOOR_DB]   # the held pip, per channel
var _meter_held := [0.0, 0.0]

func _setup_meter() -> void:
	_meter = Control.new()
	_meter.name = "MasterMeter"
	_meter.custom_minimum_size = Vector2(90, 16)
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_meter.mouse_filter = Control.MOUSE_FILTER_PASS
	_meter.draw.connect(_draw_meter)
	# beside the volume bar it reports on, rather than off in the header: the fader and what
	# came out of it are read together or not at all
	var row := _vol.get_parent()
	row.add_child(_meter)
	row.move_child(_meter, _vol.get_index() + 1)
	_hover_note(_meter, func() -> String:
		return "MASTER OUTPUT PEAK: %s  //  %s" % [_meter_text(), "CLIPPING" if _meter_clipping() else "HEADROOM OK"])
	_meter.visible = _meter_on

func _meter_text() -> String:
	var l: float = _meter_peak[0]
	var r: float = _meter_peak[1]
	if maxf(l, r) <= METER_FLOOR_DB + 0.1:
		return "SILENT"
	return "L %+.1f  R %+.1f DB" % [l, r]

func _meter_clipping() -> bool:
	return maxf(_meter_peak[0], _meter_peak[1]) > -0.2

## Read once a frame from the bus itself. The fall is in dB per second rather than per frame so
## the pip drops at one speed whatever the FPS cap is doing -- the same rule the visualizer's
## own decay follows.
func _step_meter(delta: float) -> void:
	if not _meter_on or not is_instance_valid(_meter) or not _meter.is_visible_in_tree():
		return
	var bus := AudioServer.get_bus_index("Master")
	var now := [AudioServer.get_bus_peak_volume_left_db(bus, 0),
		AudioServer.get_bus_peak_volume_right_db(bus, 0)]
	for ch in 2:
		var v: float = maxf(float(now[ch]), METER_FLOOR_DB)
		if v >= _meter_peak[ch]:
			_meter_peak[ch] = v
			_meter_held[ch] = METER_HOLD_SEC
		else:
			_meter_held[ch] = maxf(_meter_held[ch] - delta, 0.0)
			if _meter_held[ch] <= 0.0:
				_meter_peak[ch] = maxf(_meter_peak[ch] - METER_FALL * delta, maxf(v, METER_FLOOR_DB))
	_meter.queue_redraw()

func _draw_meter() -> void:
	var w := _meter.size.x
	var h := _meter.size.y
	var lane := maxf((h - 2.0) * 0.5, 1.0)
	var accent := theme.get_color("font_color", "Green")
	for ch in 2:
		var y := ch * (lane + 2.0)
		_meter.draw_rect(Rect2(0.0, y, w, lane), Color(accent, 0.12))
		var frac: float = clampf(inverse_lerp(METER_FLOOR_DB, 0.0, float(_meter_peak[ch])), 0.0, 1.0)
		if frac <= 0.0:
			continue
		# red only at the very top, and only there: a meter that goes amber at -12 trains people
		# to ignore it, because most music lives there
		var col := accent if _meter_peak[ch] < -0.2 else REC_ERROR_COLOR
		_meter.draw_rect(Rect2(0.0, y, w * frac, lane), col)
	# the 0 dB mark, so the end of the scale is a place rather than just the end of the box
	_meter.draw_rect(Rect2(w - 1.0, 0.0, 1.0, h), Color(accent, 0.5))

## Master volume by NUMBER, 0-100. Extracted from the drag handler above because it was the only
## way in: every value this program can be set to should be reachable without a mouse, and a MIDI
## fader has no position to drag from.
func _set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 100.0)
	_vol.value = _volume
	_apply_volume()
	_save_soon()

# --- readout --------------------------------------------------------------
var _bar_seen: AudioStreamPlayer   # the player _process last saw the bar on

func _process(delta: float) -> void:
	var l := _len()
	var p := _pos()
	# End-of-drag is polled, not awaited: a release outside the bar is never delivered to
	# its gui_input, and waiting for one is what let _dragging latch on permanently.
	_drag_cue_step()   # a marker tab being dragged, polled like the scrub drag below
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
		if l > 0.0:
			_seek(_scrub.value / 100.0 * l)
	if not _dragging:
		# zero with nothing to show, rather than holding the last deck's position beside a
		# 00:00 readout
		_scrub.value = p / l * 100.0 if l > 0.0 else 0.0
	# The bar's player can change with no switch and no load -- the other deck stopping, a
	# fade swapping its player -- so it is watched: the analyser and the markers follow it.
	var bar := _bar()
	if bar != _bar_seen:
		_bar_seen = bar
		_director.attach(bar)
		_cue_overlay.queue_redraw()
	# A deck playing with the crossfader holding it silent is the fader working, not a fault --
	# but it reads as a dead deck, so the deck button marks it and the status line says why once.
	var silenced := AudioEngine.silenced_deck(_engine.both, _decks.crossfader,
		[_live_player(0).playing, _live_player(1).playing])
	if silenced != _silenced:
		_silenced = silenced
		_refresh_deck_ui()
		if silenced >= 0:
			_note = "  //  %s IS PLAYING, SILENT AT THIS CROSSFADER" % AudioEngine.DECK_NAMES[silenced]
			_clear_note_later()
	_elapsed.text = _time_text(p)
	_total.text = _time_text(l)
	_clock.text = _clock_text()
	_nosignal.visible = _state() == "STOPPED"
	_nosignal.text = "[ LOADING ]" if _busy else "[ NO SIGNAL ]"
	_picture.follow(_decks.audio, _video_palette(), VideoTest.kick(_director.levels[0], _viz.db_floor()))
	%VizStack.visible = not _picture.visible   # an MP4 picture takes the visualizer's place
	_session_secs += delta
	_total_secs += delta
	_reboot_armed = maxf(_reboot_armed - delta, 0.0)
	if _reboot_armed <= 0.0 and %Reboot.text != "REBOOT":
		%Reboot.text = "REBOOT"
	# Measured from the delta this callback is handed, NOT from Performance.TIME_PROCESS.
	# That monitor is not trustworthy here: sampled against the real frame time it
	# reported 43.55 ms of "process time" inside an 18.06 ms frame, which cannot happen,
	# and a percentage built on it read 377-999%. The delta is the frame, by definition.
	# Smoothed at 0.08 because the raw value swings several ms frame to frame.
	_perf_frame_ms = lerpf(_perf_frame_ms, delta * 1000.0, 0.08)
	# periodic flush so a crash or a kill loses at most half a minute of the odometer
	if _session_secs >= _save_at:
		_save_at = _session_secs + 30.0
		_save()
	var vp := get_viewport().get_visible_rect().size
	if vp != _last_vp:
		_last_vp = vp
		_update_orientation()
	# One trivial DisplayServer getter, polled because Godot exposes no "window changed
	# screen" notification. The first reading is recorded and never acted on: at boot the
	# window IS deliberately 72 px past the usable rect, because fullscreen covers the
	# taskbar, and repairing that would drop the program out of fullscreen on startup.
	var scr := DisplayServer.window_get_current_screen()
	if _last_screen < 0:
		_last_screen = scr
	elif scr != _last_screen:
		_last_screen = scr
		_refit_window_to_screen()
	_flash = maxf(_flash - delta, 0.0)
	_clamp_playbar()
	_now_update()
	_now_drag_step()
	_step_meter(delta)
	_step_dual_bars()
	_marquee_step(delta)
	%Play.text = "PAUSE" if _state() == "PLAYING" else "PLAY"
	# tracks the fit in wall-clock time, so the readout settles the same at any FPS
	if _director.bpm > 0.0:
		_bpm_shown = _director.bpm if _bpm_shown <= 0.0 else lerpf(
			_bpm_shown, _director.bpm, 1.0 - pow(0.02, delta))
	else:
		_bpm_shown = 0.0
	var hover := "  //  %s" % _hover.call() if _hover.is_valid() else ""
	_status.text = "STATE: %s  //  %s  //  ERR: %04d%s%s" % [
		_state(), _bpm_readout(), _log_errors, _note, hover]
	if _recorder and _recorder.recording:
		_refresh_rec()
	# STATS is rebuilt at 4 Hz, and only while it can actually be seen -- current in the
	# dock, or torn off into its own window. It used to rebuild ~30 formatted lines every
	# frame with the tab closed, opening both decks' files for their SIZE line each time.
	if _session_secs >= _stats_at and _stats.is_visible_in_tree():
		_stats_at = _session_secs + STATS_PERIOD
		_sample_perf()
		_refresh_stats()
	if is_instance_valid(_autopsy) and _session_secs >= _autopsy_at and _autopsy.is_visible_in_tree():
		_autopsy_at = _session_secs + STATS_PERIOD
		_refresh_autopsy()

# --- the system log --------------------------------------------------------
## ERR: 0000 in the status bar used to be `0 if _note.is_empty() else 1` -- it counted whether
## a note happened to be on screen, which made it a second copy of the note rather than an
## error count. A track that would not decode, a take that hit a full disk and a config that
## could not be written all read as ERR: 0000 while their note was clearing itself after four
## seconds, and then there was no record that any of them had happened.
##
## So: a real count of real faults, and somewhere to read them. Notes are not faults, and
## nothing here is written from a path that merely wants to say something on screen.
const LOG_MAX := 500
## What each entry is, which is also what the log window filters on.
const LOG_ERROR := "ERROR"
const LOG_WARN := "WARN"

var _log: Array[Dictionary] = []   # {at (session secs), kind, what, detail}
var _log_errors := 0               # ERROR entries only: what ERR: counts
var _log_win: Window
var _log_body: VBoxContainer
var _log_head: Label

## Records a fault. `what` is the short form the log lists; `detail` is whatever names the
## specific file, path or error code. Kept even when the log window is closed -- the whole
## point is that a fault survives the note that announced it.
func _log_fault(what: String, detail := "", kind := LOG_ERROR) -> void:
	_log.append({"at": _session_secs, "kind": kind, "what": what, "detail": detail})
	if _log.size() > LOG_MAX:
		# oldest first: a session that hits its cap has usually gone wrong in one way over
		# and over, and the recent copies are the ones with the current paths in them
		_log = _log.slice(_log.size() - LOG_MAX)
	if kind == LOG_ERROR:
		_log_errors += 1
	push_warning("%s: %s %s" % [kind, what, detail])
	if is_instance_valid(_log_win):
		_fill_log()

static func log_line(entry: Dictionary, clock: String) -> String:
	var detail := str(entry.get("detail", ""))
	return "%s  %-5s  %s%s" % [clock, entry.get("kind", LOG_ERROR), entry.get("what", ""),
		"  //  %s" % detail if not detail.is_empty() else ""]

## MESSAGE LOG, from TBS > ADVANCED or by clicking ERR in the status bar.
func _open_log_window() -> void:
	if _refocus_asset("MESSAGE LOG"):
		return
	var win := _asset_window("MESSAGE LOG", PackedStringArray())
	_log_win = win["window"]
	_log_body = win["list"]
	_log_head = win["status"]
	_log_win.close_requested.connect(func() -> void:
		_log_win = null
		_log_body = null
		_log_head = null)
	var clear := Button.new()
	clear.text = "CLEAR LOG"
	clear.pressed.connect(func() -> void:
		_log.clear()
		_log_errors = 0
		_fill_log())
	(win["controls"] as Control).add_child(clear)
	_fill_log()

func _fill_log() -> void:
	if not is_instance_valid(_log_body):
		return
	for child in _log_body.get_children():
		child.queue_free()
	if _log.is_empty():
		var quiet := Label.new()
		quiet.text = "NOTHING HAS GONE WRONG THIS SESSION."
		_log_body.add_child(quiet)
	else:
		# newest first: the thing that just happened is the thing being looked for
		for i in range(_log.size() - 1, -1, -1):
			var entry := _log[i]
			var line := Label.new()
			line.text = log_line(entry, _hms(float(entry["at"])))
			line.clip_text = true
			if str(entry["kind"]) == LOG_ERROR:
				line.add_theme_color_override("font_color", REC_ERROR_COLOR)
			_log_body.add_child(line)
	if is_instance_valid(_log_head):
		_log_head.text = "%d ENTRIES  //  %d ERROR%s THIS SESSION" % [
			_log.size(), _log_errors, "" if _log_errors == 1 else "S"]

const STATS_PERIOD := 0.25
var _stats_at := 0.0   # session time the STATS block is next due; zeroed on a tab switch

func _refresh_stats() -> void:
	# Three blocks: what the program is, then one per deck, then the machine. The deck
	# lines used to be a single un-labelled run of LENGTH/TRKPOS/REMAIN/STATE describing
	# whichever deck happened to be live, so with A+B running there was no way to read
	# what the other deck was doing -- or even to tell which one you were looking at.
	var lines: Array[String] = [
		"VERSION.%s" % ProjectSettings.get_setting("application/config/version", ""),
		"USER....%s" % (_user_name if _user_name else "-"),
		"SOURCE..%s" % _src(),
		"LIBRARY.%d" % _library.paths.size(),
		"FAILED..%d" % _decks.failed_tracks.size(),
		"MOUSE...[H] %s" % ("HIDDEN" if _cursor_hidden else "SHOWN"),
		"VOLUME..%03d%%" % int(_vol.value),
		"XFADE...%s" % _xfade_stat(),
	]
	for which in AudioEngine.DECK_NAMES.size():
		lines.append("")
		lines.append("--- %s%s" % [AudioEngine.DECK_NAMES[which],
			"  <<< LIVE" if _deck_is_live(which) else ""])
		lines.append_array(_deck_stat_lines(which))
	lines.append_array([
		"",
		"SESSION.%s" % _hms(_session_secs),
		"TOTAL...%s" % _hms(_total_secs),
		"CPU.....%.1f MS/FRAME @ %s" % [_perf_frame_ms,
			"%d FPS (%s)" % [int(Performance.get_monitor(Performance.TIME_FPS)),
				_fps_text(_max_fps)]],
		"GPU.....%s" % _perf_gpu,
		"RAM.....%s" % _perf_ram,
		"ADDONS..%d" % 0,   # placeholder: nothing plugs into this yet
	])
	_stats.text = "\n".join(lines)

# --- DSP AUTOPSY / SIGNAL FLOW ----------------------------------------------------
## The focused deck's signal path, stage by stage, from what the objects in it report about
## themselves -- never from what the settings say they should be.
func _refresh_autopsy() -> void:
	var which := _engine.deck
	var player: AudioStreamPlayer = _decks.deck_live[which] if _decks.deck_live[which] else _engine.deck_player(which)
	var stream: AudioStream = player.stream if is_instance_valid(player) else null
	var meta := _engine.cached_meta(_current) if _current else {}
	var mix := int(AudioServer.get_mix_rate())
	var lines: Array[String] = ["DECK.......%s" % AudioEngine.DECK_NAMES[which]]
	lines.append_array(_autopsy_block("SOURCE", [autopsy_source(stream, meta, _current)]))
	lines.append_array(_autopsy_block("RESAMPLER", autopsy_resampler(stream, meta, mix)))
	lines.append_array(_autopsy_block("FX ENGINE", autopsy_fx(_rack_decks[which] if which < _rack_decks.size() else null)))
	lines.append_array(_autopsy_block("MASTER OUT", autopsy_master(mix, _engine.listening_mode,
		_engine.curve_latency_ms(), _rec_type, _rec_quality)))
	_autopsy.text = "\n".join(lines)

static func _autopsy_block(caption: String, parts: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for i in parts.size():
		out.append((caption.rpad(11, ".") if i == 0 else " ".repeat(11)) + parts[i])
	return out

## THD+N of the C++ sinc on the worst case test_flac_native.gd measures: an 18 kHz tone, 44.1 kHz to
## 96 kHz, 24-bit (its image, 2 kHz into the stopband). A 1 kHz tone measures -139 dB.
const AUTOPSY_SINC_THDN_DB := -124
## Godot's own 4-point cubic, measured in the 2026-09-14 audit: a 10 kHz tone, 44.1 kHz to 96 kHz.
const AUTOPSY_CUBIC_THDN_DB := -26
const NATIVE_STREAMS := ["SsFlacStream", "SsWavStream", "SsDsdStream"]

## Codec | native rate / depth | channels of what the deck is ACTUALLY playing. The native streams
## report their own format; Godot's decoders fall back on the file's probed metadata. A render (REV,
## an MP4's sound) names what it was rendered from, since the stream is not the file.
static func autopsy_source(stream: AudioStream, meta: Dictionary, path := "") -> String:
	if stream == null:
		return "-- (NOTHING LOADED)"
	var cls := stream.get_class()
	var codec := ""
	var rate := 0
	var depth := ""
	var chans := 2
	if cls in NATIVE_STREAMS:
		rate = int(stream.call("get_sample_rate"))
		chans = int(stream.call("get_channels"))
		depth = "%d-BIT" % int(stream.call("get_bits_per_sample"))
		codec = {"SsFlacStream": "FLAC", "SsWavStream": "WAV"}.get(cls, "")
		if cls == "SsDsdStream":
			codec = "DSD%d %s" % [rate / (44100 if rate % 44100 == 0 else 48000), stream.call("get_container")]
	elif stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		codec = "WAV (GODOT)"
		rate = wav.mix_rate
		chans = 2 if wav.stereo else 1
		depth = ["8-BIT", "16-BIT", "IMA-ADPCM", "QOA"][clampi(wav.format, 0, 3)]
	else:
		codec = {"AudioStreamMP3": "MP3", "AudioStreamOggVorbis": "OGG VORBIS"}.get(cls, cls.to_upper())
		rate = int(meta.get("sample_rate", 0))
		chans = int(meta.get("channels", 2))
		depth = "LOSSY"
	var from := path.get_extension().to_upper()
	if from and not codec.begins_with(from) and not (from in ["DSF", "DFF"] and codec.begins_with("DSD")):
		codec += " (RENDER OF %s)" % from
	# two decimals with one trailing zero dropped: 22.05, 44.1, 96.0 -- a readout of rates must not round 22050 to 22.1
	return "%s | %s / %s | %s" % [codec, ("%.2f" % (rate / 1000.0)).trim_suffix("0") + " KHZ" if rate > 0 else "? KHZ", depth,
		{1: "MONO", 2: "STEREO"}.get(chans, "%d CH" % chans)]

## How the stream reaches the mix rate: the native C++ sinc (its exact rational phase step L:M), a
## straight copy at the mix rate, or Godot's cubic for the formats it still decodes itself.
static func autopsy_resampler(stream: AudioStream, meta: Dictionary, mix_rate: int) -> Array[String]:
	if stream == null:
		return ["--"]
	var cls := stream.get_class()
	if cls in NATIVE_STREAMS:
		var dsd := cls == "SsDsdStream"
		var rate := int(stream.call("get_pcm_rate" if dsd else "get_sample_rate"))
		var pre := "1-BIT FIR TO %.1f KHZ, THEN " % (rate / 1000.0) if dsd else ""
		if rate == mix_rate:
			return [pre + "NONE: PASSTHROUGH", "PHASE 1:1 | BIT-EXACT COPY"]
		var g := _gcd(rate, mix_rate)
		return [pre + "C++ WINDOWED-SINC (SincResampler)",
			"PHASE %d:%d | THD+N %d DB (TESTED)" % [mix_rate / g, rate / g, AUTOPSY_SINC_THDN_DB]]
	var src := (stream as AudioStreamWAV).mix_rate if stream is AudioStreamWAV else int(meta.get("sample_rate", 0))
	if src <= 0:
		return ["GODOT 4-POINT CUBIC", "RATE UNKNOWN"]
	var g := _gcd(src, mix_rate)
	return ["GODOT 4-POINT CUBIC (16-BIT STEP)",
		"RATIO %d:%d | THD+N %d DB @ 10 KHZ (TESTED)" % [mix_rate / g, src / g, AUTOPSY_CUBIC_THDN_DB]]

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := a % b
		a = b
		b = t
	return maxi(a, 1)

## The deck rack: whether MIX has a real dry path, and how many modules are actually in circuit.
static func autopsy_fx(rack: FxRack) -> Array[String]:
	if rack == null:
		return ["--"]
	var pairs := rack.pair_count()
	var counts := rack.circuit_counts()
	return ["PARALLEL WET/DRY: %d TAP/BLEND PAIRS" % pairs if pairs > 0 else "SERIAL: NO SsParallel, MIX INERT",
		"ACTIVE MODULES: %d%s" % [counts[0], "  (+%d AT MIX 0, SWITCHED OUT)" % counts[1] if counts[1] > 0 else ""]]

## The mix format, LISTENING MODE, and whether a recording would be TPDF-dithered: every take is
## captured as 32-bit float and dithered only on its way down to 16 or 24-bit integers.
static func autopsy_master(mix_rate: int, mode: int, latency_ms: float, rec_type: int, rec_quality: int) -> Array[String]:
	var curve: String = AudioEngine.LISTENING_MODE_NAMES[clampi(mode, 0, AudioEngine.LISTENING_MODE_NAMES.size() - 1)]
	if latency_ms > 0.0:
		curve += " +%.1f MS" % latency_ms
	var type: String = Recorder.FILE_TYPES[clampi(rec_type, 0, Recorder.FILE_TYPES.size() - 1)]
	var bits: int = Recorder.FLAC_BITS if type == "FLAC" \
		else Recorder.WAV_DEPTHS[clampi(rec_quality, 0, Recorder.WAV_DEPTHS.size() - 1)]
	return ["%d HZ / 32-BIT FLOAT | %s" % [mix_rate, curve],
		"TPDF DITHER: ON (REC %s %d-BIT)" % [type, bits] if bits < 32 else "TPDF DITHER: OFF (REC WAV 32-BIT: NONE NEEDED)"]

## A+B means both decks are live at once, which is exactly the case the old single-deck
## readout could not describe.
func _deck_is_live(which: int) -> bool:
	return _engine.both or _engine.deck == which

func _xfade_stat() -> String:
	if _engine.both:
		return "A+B (BOTH AT UNITY)"
	# read from the same law set_crossfader writes, so the readout cannot describe a fade the
	# buses are not doing -- it reported the old linear gains for a while after the curve
	# became equal power, which is -3 dB out at centre
	var gains := AudioEngine.deck_gains_db(_decks.crossfader)
	return "%s  //  A %+.1f DB  //  B %+.1f DB" % [
		("A" if _decks.crossfader < 0.02 else ("B" if _decks.crossfader > 0.98 else
			"%d%%" % int(_decks.crossfader * 100.0))),
		gains[0], gains[1]]

## Per-deck block. The ACTIVE deck reads through the same _len()/_pos()/_state() the
## transport uses, so the two can never disagree; a parked deck is read off its own
## player, since _decks.audio only ever points at the live one.
func _deck_stat_lines(which: int) -> Array[String]:
	var live := _engine.deck == which
	var path: String = _current if live else _decks.deck_cur[which]
	var player: AudioStreamPlayer = _decks.deck_live[which] if _decks.deck_live[which] \
		else _engine.deck_player(which)
	var dl := 0.0
	var dp := 0.0
	var st := "EMPTY"
	if live and _bar_deck() == which:   # else the bar is showing the other deck
		dl = _len()
		dp = _pos()
		st = _state()
	elif is_instance_valid(player) and player.stream:
		dl = player.stream.get_length()
		dp = player.get_playback_position()
		st = "PLAYING" if player.playing else "READY"
	return [
		# the built-in demo tone has no path at all, so falling back to _src() is what
		# keeps the live deck from reading TRACK..- while it is plainly playing something
		" TRACK..%s" % (_elide_head(path.get_file(), 30) if path else (_src() if live else "-")),
		" FORMAT.%s" % (path.get_extension().to_upper() if path else "-"),
		" SIZE...%s" % (_file_size_text(path) if path else "-"),
		" STREAM.%s" % (_stream_text_for(path) if path else "--"),
		" LENGTH.%s" % _time_text(dl),
		" TRKPOS.%s" % _time_text(dp),
		" REMAIN.%s" % _time_text(maxf(dl - dp, 0.0)),
		" STATE..%s" % st,
		" KEY....%s" % (_key_stat() if live else "-"),
	]

## What the file actually is, next to what the engine is doing with it -- the ticker
## has carried this since the beginning but the STATS column only ever showed the
## container. cached_meta NEVER probes, so an unprobed track reads "--" rather than
## costing an ffprobe spawn for a line of text.
func _stream_text() -> String:
	return _stream_text_for(_current)

## Split out of _stream_text so a PARKED deck's line can use it too -- the old version
## could only ever describe _current, which is the live deck by definition.
func _stream_text_for(path: String) -> String:
	if path.is_empty():
		return "--"
	var m := _engine.cached_meta(path)
	if m.is_empty():
		return "--"
	return "%d BIT // %.1f KHZ // %s" % [int(m.get("bits", 16)),
		float(m.get("sample_rate", 44100)) / 1000.0,
		"STEREO" if int(m.get("channels", 2)) >= 2 else "MONO"]

## File size for the STATS readout. FileAccess.get_length() opens the file, so this is
## only ever asked about the ONE track that is playing -- doing it per visible row is
## the same mistake ffprobe-per-row would be.
static func _file_size_text(path: String) -> String:
	if path.is_empty():
		return "--"
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return "--"
	var bytes := f.get_length()
	f.close()
	return _bytes(bytes)   # one formatter, not a second one that rounds differently

## 24-hour is Time.get_time_string_from_system() as-is. 12-hour has to be assembled,
## because that call has no format option -- and the two edge cases are the ones every
## hand-rolled clock gets wrong: midnight is 12 AM, not 0, and noon is 12 PM, not 0.
func _clock_text() -> String:
	if not _clock_12h:
		return Time.get_time_string_from_system()
	var t := Time.get_time_dict_from_system()
	var h: int = t["hour"]
	var half := "AM" if h < 12 else "PM"
	h = h % 12
	if h == 0:
		h = 12
	return "%d:%02d:%02d %s" % [h, t["minute"], t["second"], half]

## Self-check for the two hours that wrap. Asserted from _ready like the others.
static func clock_test() -> bool:
	var probe := func(hour: int) -> String:
		var half := "AM" if hour < 12 else "PM"
		var h: int = hour % 12
		if h == 0:
			h = 12
		return "%d:00:00 %s" % [h, half]
	return probe.call(0) == "12:00:00 AM" and probe.call(12) == "12:00:00 PM" \
		and probe.call(13) == "1:00:00 PM" and probe.call(11) == "11:00:00 AM" \
		and probe.call(23) == "11:00:00 PM"


## Repairs the window after it is moved to another display.
##
## Measured on this three-monitor desk, every screen reserves 72 px for the taskbar:
## 1920x1080 usable 1008, 1080x1920 usable 1848, 1646x1029 usable 957. The program boots
## FULLSCREEN (window/size/mode=3), which covers the taskbar, so at rest nothing is
## hidden. Shift+Win+Arrow moves it while leaving that mode in place, and the taskbar
## then draws on top of the bottom 72 px -- exactly the status bar plus half the
## transport deck, gone with nothing to say so.
##
## The repair is borderless + MAXIMIZED, and both halves were measured:
##   - WINDOWED is unreachable from a fullscreen state in this build. Setting it reports
##     EXCLUSIVE_FS back and window_set_size is refused outright.
##   - Re-asserting FULLSCREEN on the new screen changes nothing; still 72 px under.
##   - MAXIMIZED lands inside the usable rect on all three screens, portrait included.
##   - BORDERLESS keeps the chromeless look the fullscreen boot has, so the repair is
##     invisible apart from the taskbar no longer covering the transport.
func _refit_window_to_screen() -> void:
	var usable := DisplayServer.screen_get_usable_rect(
		DisplayServer.window_get_current_screen())
	var pos := DisplayServer.window_get_position()
	var size := DisplayServer.window_get_size()
	# Both axes. Only the vertical was checked before, which covered the taskbar case
	# this exists for but missed the other half: a window moved to a NARROWER display
	# overhangs the right edge without being any taller than the screen.
	var inside_y: bool = pos.y >= usable.position.y \
		and pos.y + size.y <= usable.position.y + usable.size.y
	var inside_x: bool = pos.x >= usable.position.x \
		and pos.x + size.x <= usable.position.x + usable.size.x
	if inside_x and inside_y:
		return   # already sitting inside the usable area; leave it alone
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


# --- performance readout ---------------------------------------------------
## Samples the GPU and RAM figures. The CPU line is not built here -- it is the frame
## time smoothed in _process, because Godot exposes no system-wide CPU percentage and
## Performance.TIME_PROCESS proved untrustworthy (it reported 43 ms of process time
## inside an 18 ms frame). What this panel shows is what can honestly be measured.
func _sample_perf() -> void:
	var vram := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_perf_gpu = "%s VRAM  %d DRAWS" % [_bytes(vram), draws]
	var mem: Dictionary = OS.get_memory_info()
	# `physical` and `free` are real RAM. `available` is deliberately NOT used: on
	# Windows it is the commit limit and reads 39 GB on a 16.9 GB machine, which looks
	# like a bug to anyone who knows how much memory they have.
	#
	# Kept short deliberately: the STATS panel is a Label, so its widest line sets the
	# tab's minimum width. The first draft read "114 MB APP  1.2 GB FREE OF 15.7 GB" and
	# pushed that minimum to 672 px, past the 575 px sidebar floor, clipping the tab.
	_perf_ram = "%s APP  %s/%s" % [
		_bytes(OS.get_static_memory_usage()),
		_bytes(int(mem.get("free", 0))),
		_bytes(int(mem.get("physical", 0)))]

## ONE size formatter for the whole program. `n / 1048576` was integer division, so
## 1.9 MB printed as "1 MB" while the (duplicate) track-size formatter beside it printed
## "1.9 MB" -- two conventions for the same quantity, one of them wrong.
static func _bytes(n: int) -> String:
	if n >= 1073741824:
		return "%.1f GB" % (float(n) / 1073741824.0)
	if n >= 1048576:
		return "%.1f MB" % (float(n) / 1048576.0)
	return "%.1f KB" % (float(n) / 1024.0)

func _src() -> String:
	if _current:
		return _current.get_file().to_upper()
	var f := video_path.get_file()
	return f.to_upper() if f else "DEMO_TONE.WAV"

# ponytail: synthesized so the player runs with an empty library -- harmless once folders are added.
func _demo_tone() -> AudioStreamWAV:
	var sr := 22050
	var buf := PackedByteArray()
	buf.resize(sr * 16 * 2)
	for i in sr * 16:
		var t := float(i) / sr
		var hz := 220.0 * pow(2.0, floor(fmod(t, 8.0)) / 12.0)
		buf.encode_s16(i * 2, int(sin(TAU * hz * t) * (1.0 - fmod(t, 1.0)) * 0.3 * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	return s

# ponytail: mm:ss only -- rolls past 60 min as "61:04", add hours when a source needs it.
static func _fmt(t: float) -> String:
	return "%02d:%02d" % [int(t) / 60, int(t) % 60]

## A DURATION as text: mm:ss, or hh:mm:ss from an hour up. Positions go through _time_text
## instead, which also honours SHOW MS.
static func _dur_text(secs: float) -> String:
	return _hms(secs) if secs >= 3600.0 else _fmt(secs)

## The one place a playback POSITION becomes text: the transport, the scrub hover, the
## STATS column and every marker timestamp go through here, which is what makes SHOW MS
## a single switch rather than a hunt for format strings.
##
## Durations that are not positions -- the library's TOTAL TIME, a track's LENGTH in
## TRACK INFO -- deliberately do not: milliseconds on a 3-hour library total is noise.
func _time_text(t: float) -> String:
	if _show_ms:
		return ts_text(t)
	return _hms(t) if t >= 3600.0 else _fmt(t)


static func _ratio_at(x: float, w: float) -> float:
	return clampf(x / maxf(w, 1.0), 0.0, 1.0)

## Left-click, or a drag with the left button still held. Every click-drag ProgressBar in
## the program -- volume, visualizer, EQ DSP, boost, the FX rack -- asks this, so the
## "click and drag also counts" rule is written once.
##
## `bar` is not optional paranoia. A Control that has not been laid out yet still receives
## input, and _ratio_at() on a zero-width bar returns 0 for ANY x -- which silently writes
## the minimum of the range into whatever parameter that bar owns. That is not theoretical:
## it flattened a whole config section to its floor values during testing.
## One wheel tick on a bar, as a NEW 0..1 value, or -1.0 when the event is not a wheel
## tick. Every drag bar in the program already funnels through _bar_drag; this is its
## wheel counterpart, so a bar gains scroll support by asking one question rather than
## by growing its own input branch.
##
## Deliberately a STEP from the current value, not a jump to the cursor: a wheel has no
## position, and mapping it through _ratio_at would snap the value to wherever the
## pointer happened to be sitting.
## Two sensitivities, because one step cannot serve both kinds of bar. A 5% tick on the
## scrub bar is a sensible jump through a track; the same 5% on a +/-12 dB EQ band is
## 1.2 dB per notch, far too coarse to dial anything in with. Fine is the default, since
## most bars in this program are parameters -- the four transport-scale ones ask for
## coarse explicitly.
const BAR_WHEEL_FINE := 0.02
const BAR_WHEEL_COARSE := 0.05
const BAR_WHEEL_STEP := BAR_WHEEL_COARSE   # kept: external callers/tests name this

## Spinning the wheel hard should cover ground faster than nudging it once, the way a
## scroll view already does. Ticks closer together than this accumulate gain; a lone
## tick always moves exactly one base step, so precision is never taken away.
const BAR_WHEEL_ACCEL_SEC := 0.14
const BAR_WHEEL_ACCEL_MAX := 4.0
var _wheel_last_ms := -10000
var _wheel_gain := 1.0

## One wheel tick on a bar, as a NEW 0..1 value, or -1.0 when the event is not a wheel
## tick. `step` picks the sensitivity; see the pair of constants above.
func _bar_wheel(e: InputEvent, current: float, step: float = BAR_WHEEL_FINE) -> float:
	if not (e is InputEventMouseButton and e.pressed):
		return -1.0
	var dir := 0.0
	if e.button_index == MOUSE_BUTTON_WHEEL_UP:
		dir = 1.0
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		dir = -1.0
	else:
		return -1.0
	# Exponential, not linear: gain climbs toward the ceiling while ticks keep arriving
	# and collapses to 1.0 the moment they stop, so a fast spin ramps smoothly instead of
	# jumping to full speed on the second notch.
	var now := Time.get_ticks_msec()
	var gap := float(now - _wheel_last_ms) / 1000.0
	_wheel_last_ms = now
	_wheel_gain = 1.0 if gap > BAR_WHEEL_ACCEL_SEC \
		else minf(lerpf(_wheel_gain, BAR_WHEEL_ACCEL_MAX, 0.35), BAR_WHEEL_ACCEL_MAX)
	return clampf(current + dir * step * _wheel_gain, 0.0, 1.0)

## Runnable check for the two sensitivities and the accelerator, asserted from _ready.
## The property that matters is that a LONE tick is exactly one base step: an
## accelerator that leaked into isolated ticks would quietly take fine control away.
func wheel_test() -> bool:
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	_wheel_last_ms = -10000
	_wheel_gain = 1.0
	var fine := _bar_wheel(up, 0.5, BAR_WHEEL_FINE)
	_wheel_last_ms = -10000
	_wheel_gain = 1.0
	var coarse := _bar_wheel(up, 0.5, BAR_WHEEL_COARSE)
	if not (is_equal_approx(fine, 0.5 + BAR_WHEEL_FINE)
			and is_equal_approx(coarse, 0.5 + BAR_WHEEL_COARSE)):
		return false
	# a burst must accelerate, and must still clamp inside 0..1
	_wheel_last_ms = Time.get_ticks_msec()
	_wheel_gain = 1.0
	var burst := _bar_wheel(up, 0.5, BAR_WHEEL_FINE)
	if burst <= 0.5 + BAR_WHEEL_FINE or burst > 1.0:
		return false
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	_wheel_last_ms = -10000
	_wheel_gain = 1.0
	return is_equal_approx(_bar_wheel(down, 0.0, BAR_WHEEL_COARSE), 0.0)

## Root-cause fix for the mouse-grab bug (every fader and bar in the rack routes
## through this one function): a press is only ever delivered to the Control the
## cursor is actually over, so it always arms the bar it lands on -- but Godot
## delivers an UNCAPTURED motion event (button held, armed nowhere) to whatever
## Control the pointer is currently crossing. Without _bar_armed a fast drag that
## started outside every bar could sweep across one mid-drag and start moving it.
func _bar_drag(e: InputEvent, bar: Control) -> bool:
	if bar.size.x < 2.0:
		return false
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_bar_armed = null
		return false
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		_bar_armed = bar
		return true
	return e is InputEventMouseMotion and _bar_armed == bar \
		and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0

## Hover readout: while the pointer is on a fader, that control's mapped value is appended
## to the status bar. No floating tooltip node, nothing to position, theme or time out --
## the status line is rebuilt from scratch every frame in _process anyway, so the whole
## feature costs one Callable call per frame.
##
## `text` is a Callable rather than a String because these values move while the pointer
## is on them: a string captured at mouse_entered would freeze mid-drag, which is exactly
## when a value readout is worth having.
func _hover_note(c: Control, text: Callable) -> void:
	c.mouse_entered.connect(func() -> void: _hover = text)
	# only the control that owns the current readout may clear it -- moving onto a
	# neighbouring fader delivers its mouse_entered BEFORE this one's mouse_exited,
	# and an unguarded clear would blank the readout that just arrived
	c.mouse_exited.connect(func() -> void:
		if _hover == text:
			_hover = Callable())


# --- visualizer settings (VISUAL tab) -------------------------------------
## The skin's colours outside the theme: the Video TEST picture's ramp, and the SKIN swatch
## on both visualizer halves.
func _refresh_skin_ramps() -> void:
	_skin_ramp = Skins.video_ramp(_skin)
	for v: Visualizer in [%Viz, %VizB]:
		v.skin_gradient = Skins.accent_ramp(_skin)

## SNAKE is last and only reachable once unlocked -- see _viz_mode_count().
const VIZ_NAMES := ["SEGMENTS", "MIRROR", "WATERFALL", "GRID", "RADIAL", "MATRIX",
	"TUNNEL", "CRUISE", "FIRE", "KALEIDO", "MUSTANG", "SNAKE"]
## Order matches Visualizer.ColorAnim exactly -- the enum is the index into this list.
const COLOR_ANIM_NAMES := ["STATIC", "FADE", "LEFT-RIGHT", "WAVE"]
var _anim_btn: Button
var _rotate_btn: Button
var _custom_btn: ColorPickerButton   # VIS tab: the one solid colour that beats every palette

func _setup_visual() -> void:
	# user skins are read before the saved name is resolved, so a custom palette survives a
	# restart -- and a saved name whose file has since been deleted falls back to WIN98
	Skins.load_user_skins()
	if not _skin in Skins.names():
		_skin = "WIN98"
	Skins.apply(theme, self, _skin)
	_refresh_skin_ramps()
	%Skin.text = "SKIN: %s" % _skin
	%Skin.pressed.connect(func() -> void:
		# rescanned per click, like FONT: a .cfg dropped into user://skins is one click away
		Skins.load_user_skins()
		var all := Skins.names()
		_skin = all[(all.find(_skin) + 1) % all.size()]
		Skins.apply(theme, self, _skin)
		_refresh_skin_ramps()
		_rebuild_color_row()   # the SKIN swatch shows the new accents
		%Skin.text = "SKIN: %s" % _skin
		_refill()  # folder headers carry the accent colour, so they need repainting
		_save())
	_hover_note(%Skin, func() -> String:
		return "CUSTOM SKINS: DROP .CFG PALETTES INTO %s" % ProjectSettings.globalize_path(Skins.USER_SKIN_DIR))
	# clamped against the UNLOCKED count: losing the unlock must not boot into SNAKE
	_apply_unlocks()
	# deck B's half is a second Visualizer with its own saved block; the gradients are the one
	# shared list, so a gradient built for either half is pickable on both
	for pair in [[%Viz, _viz_cfg], [%VizB, _viz_cfg_b]]:
		var v: Visualizer = pair[0]
		var c: Dictionary = pair[1]
		v.mode = clampi(c.get("mode", 0), 0, _viz_mode_count() - 1) as Visualizer.Mode
		# PRESETS.size() is the rainbow slot, one past the last fixed colour
		v.gradients = _gradients
		# one slot per gradient past the rainbow, so a saved gradient selection survives
		v.color_index = clampi(c.get("color", Visualizer.SKIN_INDEX), Visualizer.CUSTOM_INDEX, v.PRESETS.size() + _gradients.size())
		var picked: Variant = c.get("custom", "")
		if picked is String and Color.html_is_valid(str(picked)):
			v.custom_color = Color.html(str(picked))
		v.sensitivity = c.get("sens", 0.5)
		v.tilt_db = c.get("tilt", 20.0)
		v.height_scale = c.get("height", 0.62)
		v.speed = c.get("speed", 0.5)
	# the swatch row is rebuilt rather than inlined here: a gradient added or deleted
	# renumbers every slot after it, and color_index IS a position in this row
	_rebuild_color_row()

	# GRADIENTS lives here rather than in TBS: it edits what %ColorRow previews live,
	# right next to it, instead of a settings screen two tabs away.
	var visual_home: Control = %ColorRow.get_parent()
	var grad_btn := _add_setting_row("GRADIENTS", "GradRow", %ColorRow, visual_home)
	grad_btn.text = "[ MANAGE ]"
	grad_btn.pressed.connect(_open_gradient_window)
	_hover_note(grad_btn, func() -> String:
		return "BUILD VISUALIZER GRADIENTS  //  COPY AND PASTE THEM AS HEX LISTS")

	# One colour, picked outright, over every palette: the swatch row is a set of choices somebody
	# else made, and this is the one that is yours. Godot's own picker rather than a hex field --
	# it carries the wheel, the sliders AND a hex box, all themed, for one node.
	var custom_row := HBoxContainer.new()
	custom_row.name = "CustomColorRow"
	custom_row.add_theme_constant_override("separation", 6)
	visual_home.add_child(custom_row)
	visual_home.move_child(custom_row, %ColorRow.get_index() + 1)
	var custom_cap := Label.new()
	custom_cap.text = "CUSTOM COLOR"
	custom_row.add_child(custom_cap)
	_pin_label(custom_cap)
	_custom_btn = ColorPickerButton.new()
	_custom_btn.name = "CustomColor"
	_custom_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_btn.custom_minimum_size.y = 18
	_custom_btn.edit_alpha = false
	_custom_btn.color = _viz.custom_color
	# color_changed fires continuously while the wheel is dragged, so the save is debounced the
	# same way the gradient editor's pickers are
	_custom_btn.color_changed.connect(func(c: Color) -> void:
		_viz.custom_color = c
		_viz.color_index = Visualizer.CUSTOM_INDEX   # picking one is choosing it
		_rebuild_color_row()
		_save_soon())
	_hover_note(_custom_btn, func() -> String:
		return "ONE SOLID COLOUR, OVER EVERY PALETTE  //  HEX IS IN THE PICKER")
	custom_row.add_child(_custom_btn)

	_anim_btn = _add_setting_row("COLOR ANIMATION", "AnimRow", custom_row, visual_home)
	_anim_btn.pressed.connect(func() -> void:
		_viz.color_anim = ((_viz.color_anim + 1) % COLOR_ANIM_NAMES.size()) as Visualizer.ColorAnim
		_refresh_anim_btn()
		_save())
	_refresh_anim_btn()

	_rotate_btn = _add_setting_row("ROTATE GRADIENTS", "RotateRow", _anim_btn.get_parent(), visual_home)
	_rotate_btn.toggle_mode = true
	_rotate_btn.button_pressed = _viz.rotate_gradients
	_rotate_btn.pressed.connect(func() -> void:
		_viz.rotate_gradients = _rotate_btn.button_pressed
		_refresh_rotate_btn()
		_save())
	_refresh_rotate_btn()

	_dual_visual_btn = _add_setting_row("DUAL VISUAL", "DualVisualRow", _rotate_btn.get_parent(), visual_home)
	_dual_visual_btn.pressed.connect(func() -> void:
		_dual_visual = not _dual_visual
		_apply_dual_visual()
		_save())
	_hover_note(_dual_visual_btn, func() -> String:
		return "SPLITS THE FEED: DECK A ON TOP, DECK B BELOW  //  EACH HALF KEEPS ITS OWN MODE, COLOUR AND BARS")
	_viz_edit_btn = _add_setting_row("EDITING", "VizEditRow", _dual_visual_btn.get_parent(), visual_home)
	_viz_edit_btn.pressed.connect(func() -> void:
		_viz = %VizB if _viz == %Viz else %Viz
		_apply_dual_visual())
	_apply_dual_visual()

	%VizMode.pressed.connect(func() -> void: _cycle_viz_mode(1))
	for bar in [%Sens, %Tilt, %Height, %Speed]:
		bar.gui_input.connect(_on_viz_bar.bind(bar))
		# TILT is the one of the four that is not a percentage -- it is a dB slope
		_hover_note(bar, func() -> String: return "%s: %s" % [bar.name.to_upper(),
			("%.1f DB" % _viz.tilt_db) if bar == %Tilt else "%d%%" % int(bar.value)])
	_refresh_visual()

## The MODE button's own action, given a name so something other than a click can reach it.
## `step` is in whole modes, so an encoder walks the list in both directions.
func _cycle_viz_mode(step: int) -> void:
	_viz.mode = posmod(_viz.mode + step, _viz_mode_count()) as Visualizer.Mode
	_refresh_visual()
	_save()

## The same walk across the COLOUR row, which had no cycle of its own: every swatch is a button
## that hard-sets its own index, so there was nothing for a knob to turn. The row runs from
## CUSTOM_INDEX (-2) through SKIN (-1), the presets, the rainbow and then the saved gradients, and
## wrapping over that whole span is what makes one encoder reach all of them.
func _cycle_viz_color(step: int) -> void:
	# the exact span _rebuild_color_row draws, so a turn of the knob can reach every swatch that
	# is on screen and land on nothing that is not
	var first := Visualizer.CUSTOM_INDEX                                  # -2, the lowest slot
	var past_end: int = _viz.PRESETS.size() + 1 + _gradients.size()       # presets, rainbow, gradients
	_viz.color_index = first + posmod(_viz.color_index - first + step, past_end - first)
	_rebuild_color_row()
	_save()

func _refresh_visual() -> void:
	%VizMode.text = "MODE: %s" % VIZ_NAMES[_viz.mode]
	%Sens.value = _viz.sensitivity * 100.0
	%Tilt.value = _viz.tilt_db / 40.0 * 100.0
	%Height.value = _viz.height_scale * 100.0
	%Speed.value = _viz.speed * 100.0

func _refresh_anim_btn() -> void:
	if is_instance_valid(_anim_btn):
		_anim_btn.text = COLOR_ANIM_NAMES[_viz.color_anim]

func _refresh_rotate_btn() -> void:
	if is_instance_valid(_rotate_btn):
		# the toggle state too: switching which half is edited must not leave the button
		# holding the other half's value, or the next press would set what was already set
		_rotate_btn.set_pressed_no_signal(_viz.rotate_gradients)
		_rotate_btn.text = "[*] ON" if _viz.rotate_gradients else "[ ] OFF"

## DUAL VISUAL: %VizBoxB appears under %VizBox and each half draws its own deck from that
## deck's BEAT SYNC tracker -- the Master director hears the sum, so it cannot feed either.
## The trackers' analysers stay on for this even with SYNC off; their tempo fit does not.
## Off, the top half goes back to Master and the VIS tab back to editing it.
func _apply_dual_visual() -> void:
	%VizBoxB.visible = _dual_visual
	%Viz.director = _deck_directors[0] if _dual_visual else _director
	%VizB.director = _deck_directors[1]
	for i in _deck_directors.size():
		_deck_directors[i].set_tracking(_beat_sync, _beat_sync or _dual_visual)
	if not _dual_visual:
		_viz = %Viz
	_viz_edit_btn.get_parent().visible = _dual_visual
	_dual_visual_btn.text = "[*] ON" if _dual_visual else "[ ] OFF"
	_viz_edit_btn.text = "[DECK A]  DECK B" if _viz == %Viz else "DECK A  [DECK B]"
	_refresh_visual()
	_refresh_anim_btn()
	_refresh_rotate_btn()

func _on_viz_bar(e: InputEvent, bar: ProgressBar) -> void:
	var r := _bar_wheel(e, bar.value / 100.0)
	if r < 0.0:
		if not _bar_drag(e, bar):
			return
		r = _ratio_at(e.position.x, bar.size.x)
	bar.value = r * 100.0
	if bar == %Sens: _viz.sensitivity = r
	elif bar == %Tilt: _viz.tilt_db = r * 40.0
	elif bar == %Speed: _viz.speed = r
	else: _viz.height_scale = maxf(r, 0.2)
	_save()


## Wheel scrolling lands on whole rows instead of part-way through one.
## ItemList in Godot 4.7 has NO fixed_item_height (only fixed_column_width and
## fixed_icon_size), so the row height has to be measured off a real item.
## A double-click gives a LIST row, which is neither a library index nor a queue index.
func _on_row_activated(row: int, deck: int) -> void:
	var row_path: PackedInt32Array = _row_paths[deck]
	if row >= 0 and row < row_path.size() and row_path[row] >= 0:
		_open_deck(deck, _library.paths[row_path[row]])

## Plays `path` on `deck` whichever deck is driven, and never changes which one that is:
## %TracksA always loads deck A, %TracksB deck B. The driven deck goes through _open as ever;
## the other decodes by path and lands in _load_parked, leaving the queue -- and the driven
## deck's place in it -- alone.
func _open_deck(deck: int, path: String) -> void:
	if deck != _engine.deck:
		_note = "  //  LOADING ON %s: %s" % [AudioEngine.DECK_NAMES[deck], path.get_file()]
		_engine.load_on(deck, path)
		return
	# row -> queue index. Not a no-op under a search: the queue holds only the matches, so a
	# row's queue position is not its library one. A path outside this deck's view (PLAY ON
	# DECK A from TRK B's menu, under a different search) still plays, by path.
	var qi := _engine.queue.find(path)
	if qi >= 0:
		_open(qi)
	else:
		_engine.load_on(deck, path)

# --- TOOLS ---------------------------------------------------------------------------------
## Utilities that work on ONE track -- the one on the transport -- and want room of their own.
## Each opens a real OS window rather than a tab panel, because a form you are half way through
## typing into is not something you want to lose by clicking another tab.
##
## Every tool writes a NEW FILE beside the original and never touches it. That is the whole
## safety story here: an edit that goes wrong costs a file you can delete, not the master.
const TOOLS := [
	["METADATA", "meta", "TITLE, ARTIST AND ALBUM, WRITTEN INTO A TAGGED COPY"],
	["FILE INFO", "info", "WHAT THE FILE IS: CODEC, RATE, DEPTH, TAGS, SIZE AND PATH"],
	["EXPORT SETUP", "export", "CUES, PLAYLISTS, TAGS, KEYBINDS AND SETTINGS INTO ONE FILE"],
	["IMPORT SETUP", "import", "READ THAT FILE BACK -- CUES AND PLAYLISTS LAND AT ONCE"],
	["MIDI SETUP", "midi", "DEVICES, A LIVE MONITOR, AND LEARN FOR EVERY MAPPABLE ACTION"],
	["AUDIO OUTPUT", "output", "WHICH DEVICE THE MASTER BUS PLAYS OUT OF"],
]
var _tool_windows := {}   # kind -> Window

func _setup_tools_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "TOOLS"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	var note := Label.new()
	note.text = "EACH OPENS IN ITS OWN WINDOW\nAND WORKS ON THE PLAYING TRACK"
	note.theme_type_variation = &"Green"
	tab.add_child(note)
	for spec in TOOLS:
		var b := Button.new()
		b.text = "[ %s ]" % spec[0]
		var kind: String = spec[1]
		b.pressed.connect(func() -> void: _open_tool(kind))
		_hover_note(b, func() -> String: return str(spec[2]))
		tab.add_child(b)

## One window per tool, raised rather than duplicated. Returns the column to fill, or null when
## the tool was already open.
func _tool_window(kind: String, title: String, size: Vector2i) -> VBoxContainer:
	var open: Window = _tool_windows.get(kind)
	if is_instance_valid(open):
		open.grab_focus()
		return null
	var win := Window.new()
	win.name = "Tool%s" % kind.capitalize()
	win.title = "SOUNDSCAPE // %s" % title
	win.size = size
	win.unresizable = false
	win.transient = false
	win.exclusive = false
	win.theme = theme
	add_child(win)
	_enable_window_fullscreen_toggle(win)
	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 8)
	chassis.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pad.add_child(col)
	win.close_requested.connect(func() -> void:
		_tool_windows.erase(kind)
		win.queue_free())
	_tool_windows[kind] = win
	_centre_on_primary(win)
	win.show()
	return col

## A captioned field, the shape every tool's inputs take.
func _tool_field(col: Control, caption: String, value: String, chars := 16) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	var cap := Label.new()
	cap.text = caption
	row.add_child(cap)
	_pin_label(cap)
	var field := LineEdit.new()
	field.text = value
	field.max_length = chars
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	return field

func _open_tool(kind: String) -> void:
	match kind:
		"meta": _open_metadata_tool()
		"info": _open_file_info()
		"export": _pick_setup_file(true)
		"import": _pick_setup_file(false)
		"midi": _open_midi_window()
		"output": _open_output_window()

# --- EXPORT / IMPORT SETUP ------------------------------------------------------------------
## Everything worth carrying to another machine already lives in ONE ConfigFile -- cues under
## [cues], playlists and their cue sets under [playlists], RENAME tags under [library], the key
## map under [keybinds], and every setting beside them. So the export is that file, written
## where the user asks for it, rather than a second serialiser with its own idea of the shape.
## A .cfg out is also a .cfg a user can open and read, which a JSON blob of the same data is
## not, and it round-trips every Variant type the config already holds (Vector2 among them)
## without the quoting games JSON would need.
const SETUP_FILTER := "*.cfg ; SOUNDSCAPE SETUP"
var _setup_dialog: FileDialog

## One dialog, rebuilt per use: SAVE for the export, OPEN for the import.
func _pick_setup_file(saving: bool) -> void:
	if not is_instance_valid(_setup_dialog):
		_setup_dialog = FileDialog.new()
		_setup_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_setup_dialog.use_native_dialog = true
		_setup_dialog.theme = theme
		add_child(_setup_dialog)
	for c in _setup_dialog.file_selected.get_connections():
		_setup_dialog.file_selected.disconnect(c["callable"])
	_setup_dialog.clear_filters()
	_setup_dialog.add_filter(SETUP_FILTER)
	_setup_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if saving else FileDialog.FILE_MODE_OPEN_FILE
	_setup_dialog.title = "EXPORT SETUP" if saving else "IMPORT SETUP"
	_setup_dialog.current_path = "%s/soundscape_setup.cfg" % OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_setup_dialog.file_selected.connect(_export_setup if saving else _import_setup)
	_setup_dialog.popup_centered(Vector2i(900, 600))

func _export_setup(path: String) -> void:
	if not is_node_ready():
		return
	var cfg := _build_cfg()   # live state, in memory: see _build_cfg on why not via the file
	# a stamp, so a file found in six months says what wrote it and when
	cfg.set_value("setup", "version", ProjectSettings.get_setting("application/config/version", ""))
	cfg.set_value("setup", "exported", Time.get_datetime_string_from_system(false, true))
	if cfg.save(path) != OK:
		_note = "  //  [!] COULD NOT WRITE %s" % path.get_file()
	else:
		_note = "  //  EXPORTED %d CUE SETS, %d PLAYLISTS TO %s" % [
			(_library.cues as Dictionary).size(), (_library.playlists as Dictionary).size(),
			path.get_file()]
	_clear_note_later()

## What comes back in, and what has to wait. The DATA -- cues, playlist membership and their
## cue sets, RENAME tags -- is applied live and is on screen immediately, because that is what
## somebody moving between machines is actually after. The SETTINGS are merged into the config
## and take effect on the next launch: _load() runs once, against a UI that is still being
## built, and re-running it over a live player would mean re-applying forty things by hand for
## the ones that have an _apply_ and silently missing the ones that do not.
func _import_setup(path: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		_note = "  //  [!] NOT A SETUP FILE: %s" % path.get_file()
		_clear_note_later()
		return
	# the same four reads _load() does, in the same order and through the same migration: a
	# setup file is a config file, so a file written by an older build comes in path-keyed and
	# has to be re-keyed to track ids exactly as one found on disk at boot would be
	_library.cues = _library.migrate_keys(_cfg_dict(cfg, "cues", "tracks"))
	_library.labels = _library.migrate_keys(_cfg_dict(cfg, "library", "track_labels"))
	_library.playlists = _library.migrate_keys(_cfg_dict(cfg, "playlists", "list"))
	for name in _library.playlists:
		var ids: Array = []
		for entry in (_library.playlists[name] as Array):
			ids.append(_library.id_for(str(entry)) if str(entry).contains("/") else entry)
		_library.playlists[name] = ids
	_library.pl_cues = _cfg_dict(cfg, "playlists", "cues")
	for name in _library.pl_cues:
		_library.pl_cues[name] = _library.migrate_keys(_library.pl_cues[name])
	# a playlist scope that did not come with the file would leave both crates showing an
	# empty list with no way back
	for c in 2:
		if not _library.playlists.has(_library.crate_pl[c]):
			_library.crate_pl[c] = ""
	# MIDI bindings come in LIVE with the data rather than waiting for a relaunch like the rest
	# of the settings: a setup file carried to another machine is usually carried with the
	# controller, and a mapper that shows the imported binds only after a restart reads as an
	# import that did not work.
	var imported_midi := _cfg_dict(cfg, "midibinds", "map")
	if not imported_midi.is_empty():
		_midi.from_dict(imported_midi)
		for action in MidiMap.ACTIONS:
			_refresh_midi_row(str(action))   # no-op unless the mapper happens to be open
	# the undo stack points AT the old store dictionaries, which have just been replaced
	_cue_undo_clear()
	_refresh_playlists()
	_refill()
	_cue_overlay.queue_redraw()
	# ONE write, not a merge followed by a save: _save() rebuilds the file from live state, so
	# it would take the imported settings straight back out again a moment later. The live
	# state (with the library data imported above) is the base, and the file's own sections go
	# over the top of it. The scan roots come too -- a setup file from another machine can
	# point at paths that do not exist here, and RELOCATE beside REMOVE FOLDER is how that is
	# fixed; dropping them instead would import a library with nothing in it to show.
	var merged := _build_cfg()
	for section in cfg.get_sections():
		if section == "setup":
			continue
		for key in cfg.get_section_keys(section):
			merged.set_value(section, key, cfg.get_value(section, key))
	_write_cfg_async(merged)
	_note = "  //  IMPORTED %d CUE SETS, %d PLAYLISTS  //  SETTINGS APPLY ON NEXT LAUNCH" % [
		(_library.cues as Dictionary).size(), (_library.playlists as Dictionary).size()]
	_clear_note_later()

# --- MIDI ------------------------------------------------------------------------------------
## Control surfaces. Godot delivers MIDI as InputEventMIDI once OS.open_midi_inputs() has been
## called, and delivers NOTHING before that -- which is the first thing to check when a
## controller looks dead.
##
## The table of actions and every piece of arithmetic lives in midi_map.gd. What is here is the
## three things that need the player: routing an event, running an action, and the window.
##
## INPUT ONLY. Godot 4.7.1 has no MIDI output of any kind (verified against the binary: there is
## no open_midi_outputs and no send_midi), so a controller's lights, VU meters and motorised
## anything cannot be driven from here. Bindings are one-way, permanently, unless MIDI out goes
## into libsoundscape_dsp.
var _midi := MidiMap.new()
var _midi_learn := ""                       # the action currently listening, or ""
var _midi_shift := false                    # the controller's own SHIFT, while it is held
var _midi_shift_at := 0                     # when it went down, so a lost note-off cannot latch it
var _midi_monitor: Label                    # the live message line, while the window is open
var _midi_device: OptionButton
var _midi_rows := {}                        # action -> [assignment Label, LEARN Button, mode Button]
## One click of a relative encoder, as a fraction of a fader's travel. 127 clicks end to end,
## which is one MIDI step per click and about a full turn of a detented knob.
const MIDI_NUDGE := 1.0 / 127.0
## And one click of a jog wheel, in seconds of playhead.
const MIDI_JOG_SEC := 0.10

func _route_midi(e: InputEventMIDI) -> void:
	if is_instance_valid(_midi_monitor):
		_midi_monitor.text = MidiMap.describe(e)
	if not _midi_learn.is_empty():
		_finish_midi_learn(e)
		return
	var action := _midi.action_for(MidiMap.event_key(e))
	if not action.is_empty():
		_run_midi(action, e)

## Arms a row. Mirrors _start_rebind exactly, including the timer that re-checks before it
## cancels -- a capture that finished half a second ago must not be killed by its own stale timer.
func _start_midi_learn(action: String) -> void:
	if not _midi_learn.is_empty():
		var was := _midi_learn
		_midi_learn = ""
		_refresh_midi_row(was)         # cancel whichever row was already listening
	_midi_learn = action
	var row: Array = _midi_rows.get(action, [])
	if row.size() == 3:
		(row[1] as Button).text = "[ TOUCH ]"
	get_tree().create_timer(REBIND_TIMEOUT_SEC).timeout.connect(func() -> void:
		if _midi_learn != action:
			return
		_midi_learn = ""
		_refresh_midi_row(action)
		_note = "  //  MIDI LEARN TIMED OUT"
		_clear_note_later())

## The first message that arrives while a row is listening takes the binding.
##
## A note-OFF is ignored rather than bound: pressing a pad sends both, and binding on the release
## would make every pad learn itself twice with the second one winning. Message types this does
## not map are ignored too, so an aftertouch-happy controller cannot steal the capture from the
## pad somebody is actually pressing.
func _finish_midi_learn(e: InputEventMIDI) -> void:
	if MidiMap.event_key(e).is_empty() or e.message == MIDI_MESSAGE_NOTE_OFF:
		return
	var action := _midi_learn
	_midi_learn = ""
	var clash := _midi.bind(action, e, _midi.mode_of(action))
	if clash.is_empty():
		_note = "  //  %s  ->  %s" % [_midi.label_of(action), str(MidiMap.ACTIONS[action][0])]
	else:
		# Refused, not stolen: the same rule the keyboard rebind follows. The message says WHY
		# and WHAT TO DO, and names the control as well as the action it already drives -- the
		# usual cause is two things on the surface sending identical messages, and a controller
		# whose deck A and deck B jogs are on the same channel and CC cannot have them told
		# apart by anything in here. Seeing the control printed is what turns that from "the
		# mapper is broken" into "the controller needs a different CC on that wheel".
		_note = "  //  THAT CONTROL (%s) IS ALREADY BOUND TO %s -- CLEAR THAT ROW FIRST" % [
			_midi.label_of(clash), str(MidiMap.ACTIONS[clash][0])]
	_clear_note_later()
	_refresh_midi_row(action)
	_save()

## What a bound control does. Split three ways by the action's KIND rather than by the message,
## so a pad and a fader bound to the same action behave the way that action needs.
func _run_midi(action: String, e: InputEventMIDI) -> void:
	var kind: int = MidiMap.ACTIONS[action][2]
	var mode := _midi.mode_of(action)
	var v := MidiMap.event_value(e)
	# A modifier is the one thing here that cares about the release as well as the press, so it
	# is read before the press test rather than inside it.
	if action in MidiMap.HELD:
		_midi_shift = MidiMap.is_press(e)
		_midi_shift_at = Time.get_ticks_msec()
		return
	if kind == MidiMap.BUTTON:
		if MidiMap.is_press(e):
			_midi_button(action)
		return
	if kind == MidiMap.STEPPER:
		# a stepper on an absolute control still works -- a pad press is one click forward --
		# but it is an encoder's job, which is why the mode button is on every row
		var clicks := MidiMap.rel_delta(v, mode) if mode != MidiMap.MODE_ABS \
			else (1 if MidiMap.is_press(e) else 0)
		if clicks != 0:
			_midi_step(action, clicks)
		return
	if mode == MidiMap.MODE_ABS:
		_midi_fader(action, MidiMap.to_unit(v))
		return
	# A relative fader NEVER writes an absolute position: it moves from wherever the control
	# already is. Writing the raw value here is what makes an endless encoder slam a fader to one
	# end on the first click.
	var d := MidiMap.rel_delta(v, mode)
	if d != 0:
		_midi_fader(action, clampf(_midi_fader_at(action) + float(d) * MIDI_NUDGE, 0.0, 1.0))

## Whether a pad press means CLEAR rather than set-or-jump. Either the controller's own SHIFT,
## if one is bound to the `shift` action, or the keyboard's -- so the pads work the same whether
## or not the surface has a spare button to give up.
## A LOST NOTE-OFF MUST NOT LATCH THE MODIFIER. A controller unplugged mid-hold, or a message
## dropped, would otherwise leave every pad press deleting a cue with nothing on screen to say
## why. Nobody holds shift for half a minute, so a hold older than that is a note-off that never
## arrived and the modifier lets go of itself. Checked here rather than per frame: this is the
## only thing that asks, and it asks a handful of times a session.
const MIDI_SHIFT_MAX_MS := 30000

func _midi_shift_held() -> bool:
	if _midi_shift and Time.get_ticks_msec() - _midi_shift_at > MIDI_SHIFT_MAX_MS:
		_midi_shift = false
	return _midi_shift or Input.is_key_pressed(KEY_SHIFT)

func _midi_button(action: String) -> void:
	# the deck-addressed half of the table, which is most of it: "a_eq_low" -> deck 0, "eq_low"
	var deck := _midi_deck(action)
	var bare := _midi_bare(action)
	match bare:
		"play_pause": _toggle_deck(deck)
		"stop": _stop(deck)
		"next": _deck_step_track(deck, 1)
		"prev": _deck_step_track(deck, -1)
		"seek_back": _seek_deck(deck, _deck_pos(deck) - _skip_secs)
		"seek_fwd": _seek_deck(deck, _deck_pos(deck) + _skip_secs)
		"cue_set": _add_cue_on(deck, _deck_pos(deck), 0)
		"cue_1", "cue_2", "cue_3", "cue_4":
			_pad_cue(deck, int(bare.right(1)), _midi_shift_held())
		"cue_del_1", "cue_del_2", "cue_del_3", "cue_del_4":
			_pad_cue(deck, int(bare.right(1)), true)   # the pad grid without a spare SHIFT
		"sync": _set_beat_sync(not _beat_sync)
		"select": _select_deck(deck)
		"auto_fade": _auto_fade()
		"both": _toggle_both()
		"load_a": _load_selected(0)
		"load_b": _load_selected(1)
		"viz_full": _toggle_simple_mode()
		"os_full": _toggle_window_fullscreen()
		"mark": %Mark.button_pressed = not %Mark.button_pressed

## Which deck an action id means: "a_" is deck 0, "b_" is deck 1, and a bare id is whichever deck
## the transport bar is showing. One rule in one place, rather than fifty explicit cases.
func _midi_deck(action: String) -> int:
	if action.begins_with("a_"):
		return 0
	if action.begins_with("b_"):
		return 1
	return _bar_deck()

func _midi_bare(action: String) -> String:
	return action.substr(2) if action.begins_with("a_") or action.begins_with("b_") else action

func _midi_step(action: String, clicks: int) -> void:
	var deck := _midi_deck(action)
	match _midi_bare(action):
		# Works on a stopped deck as well as a playing one -- see _seek_deck, which lifts the
		# pause for the seek and puts it straight back, because Godot throws away a seek sent to
		# a paused player. Cueing up a track you are not playing yet is most of what a jog is for.
		"jog": _seek_deck(deck, _deck_pos(deck) + float(clicks) * MIDI_JOG_SEC)
		"browse": _browse_step(clicks)
		"viz_mode": _cycle_viz_mode(clicks)
		"viz_color": _cycle_viz_color(clicks)

func _midi_fader(action: String, unit: float) -> void:
	var deck := _midi_deck(action)
	match _midi_bare(action):
		"seek": _seek_deck(deck, unit * _deck_len(deck))
		"crossfader":
			_kill_auto_fade()   # a fade you have taken hold of is one you are doing yourself
			if _engine.both:
				_engine.set_both(false)
			_set_crossfader(unit)
		# An analogue pot -- the S2's MAIN knob among them -- sends plain absolute CC, so this
		# needs nothing special: any CC number on any channel, 0-127 across the full travel.
		"master_vol": _set_volume(unit * 100.0)
		"boost": _set_boost(int(roundf(unit * 100.0)))
		"eq_low": _set_eq_band(deck, 0, unit)
		"eq_mid": _set_eq_band(deck, 1, unit)
		"eq_high": _set_eq_band(deck, 2, unit)

## Where a fader is NOW, 0-1, so a relative encoder has something to move from.
func _midi_fader_at(action: String) -> float:
	var deck := _midi_deck(action)
	match _midi_bare(action):
		"seek": return (_deck_pos(deck) / _deck_len(deck)) if _deck_len(deck) > 0.0 else 0.0
		"crossfader": return _decks.crossfader
		"master_vol": return _volume / 100.0
		"boost": return float(_boost) / 100.0
		"eq_low": return _eq_unit(deck, 0)
		"eq_mid": return _eq_unit(deck, 1)
		"eq_high": return _eq_unit(deck, 2)
	return 0.0

## EQ for one deck. The FOCUSED deck is written through its slider, whose value_changed is
## already wired to the engine, so the panel and the audio cannot disagree. Any other deck has no
## slider on screen -- the panel only ever shows the focused rack -- so it is written straight to
## that deck's Equalizer. 0-1 spans GAIN_MIN..GAIN_MAX, which puts flat in the middle of the
## travel, where a centre-detented EQ knob rests.
func _set_eq_band(deck: int, i: int, unit: float) -> void:
	if i < 0 or i > 2:
		return
	var db := lerpf(Equalizer.GAIN_MIN, Equalizer.GAIN_MAX, clampf(unit, 0.0, 1.0))
	if deck == _engine.deck and i < _ez_faders.size():
		_ez_faders[i].value = db
		return
	if deck >= 0 and deck < _eq_decks.size():
		(_eq_decks[deck] as Equalizer).set_ez(i, db)

func _eq_unit(deck: int, i: int) -> float:
	if deck < 0 or deck >= _eq_decks.size():
		return 0.5
	var eq: Equalizer = _eq_decks[deck]
	if i < 0 or i >= eq.ez_db.size():
		return 0.5
	return inverse_lerp(Equalizer.GAIN_MIN, Equalizer.GAIN_MAX, eq.ez_db[i])

# --- AUDIO OUTPUT ------------------------------------------------------------------------------
## Which device the master bus plays out of. A window rather than a TBS row that cycles on click:
## every other setting in TBS can be cycled past and back with no consequence, and an output
## device cannot -- landing on the wrong one mid-set means silence in the room while the music
## carries on somewhere else.
##
## "Default" is Godot's own name for "whatever Windows is using", and it is kept at the top of
## the list rather than resolved to a real device, so a setup carried to another machine still
## makes sense there.
var _output_device := "Default"

func _open_output_window() -> void:
	var col := _tool_window("output", "AUDIO OUTPUT", Vector2i(620, 260))
	if col == null:
		return
	var cap := Label.new()
	cap.text = "THE MASTER BUS PLAYS OUT OF:"
	col.add_child(cap)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(picker)
	var status := Label.new()
	status.theme_type_variation = &"Green"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(status)
	var fill := func() -> void:
		picker.clear()
		var devices := AudioServer.get_output_device_list()
		for d in devices:
			picker.add_item(str(d))
		var at := Array(devices).find(AudioServer.get_output_device())
		picker.selected = maxi(at, 0)
		status.text = "NOW PLAYING OUT OF: %s" % AudioServer.get_output_device()
	fill.call()
	picker.item_selected.connect(func(i: int) -> void:
		_set_output_device(picker.get_item_text(i))
		status.text = "NOW PLAYING OUT OF: %s" % AudioServer.get_output_device())
	var refresh := Button.new()
	refresh.text = "[ REFRESH ]"
	refresh.pressed.connect(fill)
	col.add_child(refresh)
	var note := Label.new()
	note.theme_type_variation = &"Green"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = "A DEVICE UNPLUGGED WHILE SELECTED FALLS BACK TO DEFAULT ON THE NEXT LAUNCH, " \
		+ "SO A MISSING INTERFACE CANNOT LEAVE THE PLAYER WITH NOWHERE TO PLAY."
	col.add_child(note)

## Applies and remembers a device. The name is checked against the live list before it is used:
## a config carried from another machine, or an interface that has been unplugged, would
## otherwise hand AudioServer a device that is not there.
func _set_output_device(name: String) -> void:
	if name.is_empty() or not Array(AudioServer.get_output_device_list()).has(name):
		_output_device = "Default"
		AudioServer.set_output_device("Default")
		return
	_output_device = name
	AudioServer.set_output_device(name)
	_note = "  //  AUDIO OUT: %s" % name
	_clear_note_later()
	_save_soon()

# --- the MIDI SETUP window -------------------------------------------------------------------
## Built on _tool_window, which already owns the chassis, the theme, F11, centring, the one-per-
## kind registry and the close. What is added here is a device row, the monitor, and a scrolling
## grid of one row per action.
## Wide enough for a whole row at the program's own font -- 16 px a character, so the action
## name, the assignment and three buttons come to about 900. Sized to the CONTENT rather than to
## a round number, because a mapper whose CLEAR button is off the right edge is a mapper you
## cannot unbind anything with.
const MIDI_WIN_SIZE := Vector2i(1010, 660)
const MIDI_WIN_MIN := Vector2i(520, 320)

func _open_midi_window() -> void:
	var col := _tool_window("midi", "MIDI SETUP & MAPPER", MIDI_WIN_SIZE)
	if col == null:
		return   # already open, and _tool_window raised it
	var win := _tool_windows["midi"] as Window
	win.min_size = MIDI_WIN_MIN

	var dev_row := HBoxContainer.new()
	dev_row.add_theme_constant_override("separation", 6)
	col.add_child(dev_row)
	var dev_cap := Label.new()
	dev_cap.text = "DEVICE"
	dev_row.add_child(dev_cap)
	_pin_label(dev_cap)   # this window is not under _tabs, so nothing pins its captions for it
	_midi_device = OptionButton.new()
	_midi_device.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dev_row.add_child(_midi_device)
	var refresh := Button.new()
	refresh.text = "[ REFRESH ]"
	refresh.pressed.connect(_refresh_midi_devices)
	_pin_label(refresh)
	dev_row.add_child(refresh)

	# A permanent line, not an error state. An empty device list or a silent monitor is almost
	# always the controller sitting in its own HID mode rather than anything wrong with a
	# mapping, and there is no way to guess that from inside the app.
	# The wording matters more than it looks. "IT WORKS IN MIXXX" is the single most likely thing
	# somebody will have tried before opening this window, and it is not reassurance -- it is the
	# diagnosis. Mixxx drives these controllers over raw HID; Godot has no HID at all, only MIDI.
	# A controller happily working there can be completely invisible here, and the fix is on the
	# controller, not in this program.
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.theme_type_variation = &"Green"
	hint.text = "NO DEVICE DETECTED? WORKING IN MIXXX DOES NOT MEAN IT WILL APPEAR HERE: " \
		+ "MIXXX DRIVES THESE OVER HID, AND THIS READS MIDI ONLY. OPEN THE NI CONTROLLER " \
		+ "EDITOR AND CHECK 'ENABLE MIDI INTERFACE' IN PREFERENCES, THEN PRESS REFRESH. " \
		+ "UNTIL WINDOWS LISTS IT AS A MIDI INPUT, NOTHING HERE CAN SEE IT."
	col.add_child(hint)

	_midi_monitor = Label.new()
	_midi_monitor.clip_text = true
	_midi_monitor.text = "WAITING FOR A MESSAGE -- TOUCH ANYTHING ON THE CONTROLLER"
	col.add_child(_midi_monitor)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# AUTO, not DISABLED: the rows have a real minimum width, so a window dragged narrower than
	# one has to be scrollable sideways or the buttons are simply gone. Every other scroller in
	# this program disables it because its rows can shrink; these cannot.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	col.add_child(scroll)
	var grid := VBoxContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("separation", 2)
	scroll.add_child(grid)

	_midi_rows = {}
	var group := ""
	for action in MidiMap.ACTIONS:
		var spec: Array = MidiMap.ACTIONS[action]
		if str(spec[1]) != group:
			group = str(spec[1])
			var head := Label.new()
			head.text = "-- %s --" % group
			head.theme_type_variation = &"Green"
			grid.add_child(head)
		_midi_row(grid, str(action), str(spec[0]))
	# the window closing takes its controls with it; the refs must not outlive them
	win.close_requested.connect(func() -> void:
		_midi_monitor = null
		_midi_device = null
		_midi_rows = {}
		_midi_learn = ""
		_midi_shift = false)   # nothing is being held once the mapper is shut
	_wheel_through(grid)
	_wheel_scrolls(scroll)
	_refresh_midi_devices()

## ACTION | ASSIGNMENT | [ LEARN ] | [ ABS ] | [ CLEAR ]
func _midi_row(grid: Control, action: String, label: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	grid.add_child(row)
	var name_label := Label.new()
	name_label.text = label
	name_label.custom_minimum_size.x = 290
	row.add_child(name_label)
	var assign := Label.new()
	assign.custom_minimum_size.x = 200
	assign.theme_type_variation = &"Green"
	row.add_child(assign)
	var learn := Button.new()
	learn.pressed.connect(func() -> void: _start_midi_learn(action))
	_hover_note(learn, func() -> String:
		return "PRESS, THEN TOUCH THE CONTROL ON THE CONTROLLER TO BIND IT")
	row.add_child(learn)
	# Both of these change their own text -- LEARN becomes TOUCH IT while armed, and the mode
	# button cycles through three names of different lengths. Pinned to the WIDEST text each can
	# ever hold, so a row does not reflow under the pointer the moment it is clicked.
	_pin_to_widest(learn, ["[ LEARN ]", "[ TOUCH ]"])
	var mode := Button.new()
	mode.pressed.connect(func() -> void:
		_midi.set_mode(action, _midi.mode_of(action) + 1)
		_refresh_midi_row(action)
		_save())
	_hover_note(mode, func() -> String:
		return "ABS: FADERS AND PADS  //  REL: JOG WHEELS AND ENDLESS ENCODERS, WHICH SEND " \
			+ "HOW FAR THEY MOVED RATHER THAN WHERE THEY ARE")
	row.add_child(mode)
	# bare, not bracketed like the buttons either side: three mode names in brackets cost the row
	# 70 px, and this is the one control here whose text IS its state rather than its action
	var mode_texts: Array[String] = []
	for n in MidiMap.MODE_NAMES:
		mode_texts.append(str(n))
	_pin_to_widest(mode, mode_texts)
	var clear := Button.new()
	clear.text = "[ CLEAR ]"
	clear.pressed.connect(func() -> void:
		_midi.clear(action)
		_refresh_midi_row(action)
		_save())
	_pin_label(clear)
	row.add_child(clear)
	_midi_rows[action] = [assign, learn, mode]
	_refresh_midi_row(action)

func _refresh_midi_row(action: String) -> void:
	var row: Array = _midi_rows.get(action, [])
	if row.size() != 3:
		return
	(row[0] as Label).text = _midi.label_of(action)
	(row[1] as Button).text = "[ LEARN ]"
	var mode_btn := row[2] as Button
	mode_btn.text = str(MidiMap.MODE_NAMES[_midi.mode_of(action)])
	mode_btn.disabled = _midi.key_of(action).is_empty()   # nothing to be relative about

## Godot only reports devices it has OPENED, and it enumerates ONCE, inside open_midi_inputs().
## A controller plugged in after launch is therefore invisible until the driver is taken down and
## brought back up -- which is what REFRESH is for.
##
## CLOSE FIRST, always. Godot's Windows driver appends to its list of open sources rather than
## rebuilding it, so calling open twice without a close leaves the same device connected twice
## and every message arriving twice with it -- a fader that jumps two steps a notch and a pad
## that toggles play and then toggles it back. The pair is not optional.
func _refresh_midi_devices() -> void:
	if not is_instance_valid(_midi_device):
		return
	OS.close_midi_inputs()
	OS.open_midi_inputs()
	_midi_shift = false   # the driver just went down; whatever was held is not held now
	var found := OS.get_connected_midi_inputs()
	_midi_device.clear()
	_midi_device.disabled = found.is_empty()
	if found.is_empty():
		_midi_device.add_item("NO MIDI DEVICES FOUND")
	else:
		for name in found:
			_midi_device.add_item(str(name))
		_midi_device.selected = 0   # something is always chosen, so the row never reads as unset
	# printed as well as shown: the name Godot reports is the one piece of evidence worth having
	# when a controller is connected and still silent, and the status line scrolls away
	var note := MidiMap.device_note(found)
	print("MIDI: ", note)
	_note = "  //  %s" % note
	_clear_note_later()

## FILE INFO: what the file actually is, read from the file. The same probe TRACK INFO uses,
## laid out where it can be read and left open while other tracks play.
func _open_file_info() -> void:
	var col := _tool_window("info", "FILE INFO", Vector2i(560, 420))
	if col == null:
		return
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_OFF
	col.add_child(body)
	var refresh := Button.new()
	refresh.text = "[ READ THE TRACK ON THE TRANSPORT ]"
	var fill := func() -> void:
		var path := _bar_path()
		if path.is_empty():
			body.text = "NOTHING ON THE TRANSPORT."
			return
		var m := _engine.metadata(path)
		var stamp := AudioEngine.file_stamp(path)
		var key: Dictionary = m.get("key", {})
		var bpm := float(m.get("bpm", 0.0))
		body.text = "\n".join([
			"FILE......%s" % path.get_file(),
			"WHERE.....%s" % path.get_base_dir(),
			"SIZE......%s" % _bytes(int(stamp[1]) if stamp.size() == 2 else 0),
			"",
			"TITLE.....%s" % m.get("title", "-"),
			"ARTIST....%s" % (m.get("artist", "") if str(m.get("artist", "")) != "" else "-"),
			"ALBUM.....%s" % (m.get("album", "") if str(m.get("album", "")) != "" else "-"),
			"KEY.......%s" % (str(key.get("text", "")) if str(key.get("text", "")) != "" else "-"),
			"BPM.......%s" % ("%.1f" % bpm if bpm > 0.0 else "-"),
			"",
			"CODEC.....%s" % m.get("codec", "-"),
			"RATE......%d HZ" % int(m.get("sample_rate", 0)),
			"DEPTH.....%d BIT" % int(m.get("bits", 0)),
			"CHANNELS..%d" % int(m.get("channels", 0)),
			"LENGTH....%s" % _time_text(float(m.get("duration", 0.0))),
			"",
			"ENGINE....%s" % autopsy_source(_bar().stream, m, path),
		])
	refresh.pressed.connect(fill)
	col.add_child(refresh)
	fill.call()

## METADATA: the three tags the rest of the program reads, written into a COPY. ffmpeg cannot
## retag in place, and a tool that rewrites somebody's master to change a spelling is not a tool
## anyone should have to trust -- so the copy is the feature, not a limitation.
func _open_metadata_tool() -> void:
	var col := _tool_window("meta", "METADATA", Vector2i(520, 320))
	if col == null:
		return
	var path := _bar_path()
	var m := _engine.metadata(path) if not path.is_empty() else {}
	var head := Label.new()
	head.clip_text = true
	head.text = path.get_file() if not path.is_empty() else "NOTHING ON THE TRANSPORT"
	col.add_child(head)
	var title_field := _tool_field(col, "TITLE ", str(m.get("title", "")), 120)
	var artist_field := _tool_field(col, "ARTIST", str(m.get("artist", "")), 120)
	var album_field := _tool_field(col, "ALBUM ", str(m.get("album", "")), 120)
	var status := Label.new()
	status.theme_type_variation = &"Green"
	status.clip_text = true
	col.add_child(status)
	var save := Button.new()
	save.text = "[ WRITE A TAGGED COPY ]"
	save.pressed.connect(func() -> void:
		if path.is_empty():
			_status_note(status, false, "NOTHING ON THE TRANSPORT")
			return
		var out := "%s (TAGGED).%s" % [path.get_basename(), path.get_extension()]
		_status_note(status, true, "WRITING %s" % out.get_file())
		_engine.run_task(func() -> void:
			var ok := AudioEngine.run_process("ffmpeg", ["-v", "error", "-y", "-nostdin",
				"-i", path, "-c", "copy",
				"-metadata", "title=%s" % title_field.text,
				"-metadata", "artist=%s" % artist_field.text,
				"-metadata", "album=%s" % album_field.text, out],
				_engine.is_shut_down) == 0
			(func() -> void:
				_status_note(status, ok and FileAccess.file_exists(out),
					"WROTE %s" % out.get_file() if ok else "FFMPEG WOULD NOT TAG THAT FORMAT")).call_deferred()))
	col.add_child(save)

# --- NOW PLAYING, in a window of its own --------------------------------------------------
## The whole player is a lot of screen for "what is this and how far in are we". This is that
## question alone, in a BORDERLESS window you can drop in a corner over whatever you are actually
## working in -- which is also why it is always on top and why it is dragged by its own face:
## a borderless window has no title bar for the OS to move it by.
##
## Three shapes for the same question, because how much of it you want depends on what the
## window is sitting next to. DISPLAY is the VFD readout -- what is playing and who by, nothing
## else. CASUAL is the whole answer: a bar, the times, and enough transport to work it without
## going back to the player. COMPACT is a title and a hairline of progress.
## MARQUEE is the fourth: a strip with nothing in it but the artist and title, running right to
## left for as long as it is open. It uses the SAME marquee_frame() the hover scroll on a track
## row uses -- one character a tick in the program's own typeface, not a pixel slide, so the two
## scrolls in this program look like the same program.
const NOW_MODES := ["DISPLAY", "CASUAL", "COMPACT", "MARQUEE"]
## Opening size per mode. A FLOOR, not a rule: the fit below grows the window to whatever the
## contents actually measure in the font the user picked, and the corner drags it bigger.
## MARQUEE opens wider than the rest for one reason: the mode button and the close button are
## fixed width, so on a short strip they take nearly half of it and the scroll runs in what is
## left. They stay -- a borderless window has no title bar, so without its own X this one
## could not be closed -- but the text gets the room instead of them.
const NOW_MODE_SIZES := [Vector2i(420, 64), Vector2i(500, 116), Vector2i(380, 52), Vector2i(620, 44)]
const NOW_MARQUEE := 3
## The padding strip round the contents. No control reaches into it, so a press there is
## unambiguously the window's own: the right and bottom strips resize, a press anywhere else drags.
const NOW_EDGE := 8
var _now_win: Window
var _now_title: Label
var _now_artist: Label        # DISPLAY mode only; the other two fold the artist into the title
var _now_time: Label          # CASUAL only
var _now_bar: ProgressBar     # not in DISPLAY
var _now_playing := false     # TBS NOW PLAYING WINDOW, saved
var _now_mode := 1            # CASUAL, saved
var _now_btn: Button
var _now_grab := Vector2i.ZERO   # pointer offset inside the window while it is being dragged
var _now_dragging := false
var _now_resizing := false
var _now_pos := Vector2i(-1, -1)   # where it was last, so switching mode does not move it

func _toggle_now_playing(on: bool) -> void:
	if on == is_instance_valid(_now_win):
		return
	if not on:
		if is_instance_valid(_now_win):
			_now_pos = _now_win.position
			_now_win.queue_free()
		_now_win = null
		_now_artist = null
		_now_time = null
		_now_bar = null
		return
	var win := Window.new()
	win.name = "NowPlayingWindow"
	win.title = "SOUNDSCAPE // NOW PLAYING"
	win.size = NOW_MODE_SIZES[_now_mode]
	win.borderless = true
	win.always_on_top = true
	win.transient = false
	win.exclusive = false
	win.theme = theme
	add_child(win)
	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	# PASS, not the default STOP: the whole face of this window is a drag handle and its edges
	# are a resize handle, so the chassis and its padding must not be the reason a press near
	# an edge is somebody else's event.
	chassis.mouse_filter = Control.MOUSE_FILTER_PASS
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_PASS
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, NOW_EDGE)
	chassis.add_child(pad)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)
	pad.add_child(col)
	var top := HBoxContainer.new()
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 6)
	col.add_child(top)
	_now_title = Label.new()
	_now_title.clip_text = true
	_now_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_now_title)
	var mode := Button.new()
	mode.text = NOW_MODES[_now_mode]
	mode.pressed.connect(func() -> void: _set_now_mode(_now_mode + 1))
	top.add_child(mode)
	var shut := Button.new()
	shut.text = "X"   # no title bar means no close button unless one is drawn
	shut.pressed.connect(func() -> void:
		_now_playing = false
		if is_instance_valid(_now_btn):
			_now_btn.button_pressed = false
		_refresh_now_btn()
		_toggle_now_playing(false)
		_save())
	top.add_child(shut)
	if _now_mode == 0:   # DISPLAY: the second line is the artist, and that is the whole window
		_now_artist = Label.new()
		_now_artist.clip_text = true
		_now_artist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_now_artist.theme_type_variation = &"Green"
		col.add_child(_now_artist)
	elif _now_mode == NOW_MARQUEE:
		pass   # the title line IS the window; no bar, no clock, nothing under it
	else:
		_now_bar = ProgressBar.new()
		_now_bar.show_percentage = false
		_now_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_now_bar.custom_minimum_size.y = 4 if _now_mode == 2 else 10
		col.add_child(_now_bar)
	if _now_mode == 1:   # CASUAL: times, and enough transport to work the deck from here
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 6)
		col.add_child(row)
		_now_time = Label.new()
		_now_time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_now_time)
		for spec in [["|<", _prev], [">||", _toggle], [">|", func() -> void: _next()],
				["[]", func() -> void: _stop(_bar_deck())]]:
			var b := Button.new()
			b.text = spec[0]
			b.pressed.connect(spec[1])
			row.add_child(b)
	# Dragged by its own face, in SCREEN coordinates: the pointer's offset inside the window is
	# taken on the press and held to for the whole drag, so the window does not creep. A press in
	# the RIGHT or BOTTOM padding strip resizes instead -- a borderless window has no frame to
	# grab, and a fixed size clipped the time and the buttons off the right edge the moment the
	# font got wider than the 460 px this was built at.
	# Only the PRESS and the release are read here. The motion is polled in _now_drag_step()
	# instead, because a window stops receiving motion events the moment the pointer leaves it
	# -- which is the first thing that happens when you drag a corner outward. Reading the
	# screen position every frame while the button is down is what makes both smooth.
	win.window_input.connect(func(e: InputEvent) -> void:
		var click := e as InputEventMouseButton
		if not click or click.button_index != MOUSE_BUTTON_LEFT:
			return
		var local := DisplayServer.mouse_get_position() - win.position
		_now_resizing = click.pressed and (local.x >= win.size.x - NOW_EDGE \
			or local.y >= win.size.y - NOW_EDGE)
		_now_dragging = click.pressed and not _now_resizing
		_now_grab = DisplayServer.mouse_get_position() - (win.size if _now_resizing else win.position))
	# The grip. A borderless window gives no sign that its corner does anything, and an 8 px
	# strip nobody can see is a feature nobody finds. Added to the WINDOW rather than into the
	# column, anchored to the bottom-right, so it floats over whichever of the four layouts is
	# showing without taking part in any of them. U+25E2 is in Px437; it was checked, unlike
	# the two glyphs the queue buttons were nearly given.
	var grip := Label.new()
	grip.name = "Grip"
	grip.text = "◢"
	grip.mouse_filter = Control.MOUSE_FILTER_IGNORE   # window_input does the work, not this
	grip.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	grip.offset_left = -20.0
	grip.offset_top = -22.0
	grip.offset_right = -2.0
	grip.offset_bottom = -2.0
	win.add_child(grip)
	_now_win = win
	if _now_pos.x >= 0:
		win.position = _now_pos   # a mode switch reopens the window; it must not jump to the middle
	else:
		_centre_on_primary(win)
	win.show()
	# The floor comes from what the contents MEASURE, not from a constant: this program lets the
	# user pick the font, and a wider one used to push the transport buttons out of the window.
	# Deferred because a minimum size is only settled after the containers have laid out once.
	(func() -> void:
		if not is_instance_valid(win):
			return
		var need := Vector2i(chassis.get_combined_minimum_size()) + Vector2i(2, 2)
		win.min_size = need
		win.size = Vector2i(maxi(win.size.x, need.x), maxi(win.size.y, need.y))).call_deferred()
	_now_update()

## Cycles DISPLAY -> CASUAL -> COMPACT -> MARQUEE. The window is rebuilt rather than reshuffled:
## four
## layouts that share two labels is less code than one layout that has to unbuild itself, and
## the position is carried across so it reopens exactly where it was.
func _set_now_mode(mode: int) -> void:
	_now_mode = posmod(mode, NOW_MODES.size())
	if is_instance_valid(_now_win):
		_toggle_now_playing(false)
		_toggle_now_playing(true)
	_note = "  //  NOW PLAYING: %s" % NOW_MODES[_now_mode]
	_clear_note_later()
	_save_soon()

## What the mini bar says, refreshed from the bar deck each frame it is open. Nothing here is
## state of its own: it reads the same _bar_path(), _pos() and _len() the transport does.
func _now_update() -> void:
	if not is_instance_valid(_now_win):
		return
	# Each of these exists only in the modes that show it, so every one is asked about rather
	# than assumed -- DISPLAY has no bar and no clock, COMPACT has no clock.
	var path := _bar_path()
	var length := _len()
	var who := ""
	var what := "[ NOTHING PLAYING ]"
	if not path.is_empty():
		var m := _engine.peek_meta(path)
		who = str(m.get("artist", ""))
		what = str(m.get("title", path.get_file().get_basename()))
	if is_instance_valid(_now_artist):
		_now_title.text = what.to_upper()
		_now_artist.text = who.to_upper() if not who.is_empty() else "-"
	elif _now_mode == NOW_MARQUEE:
		# one character a tick off the wall clock rather than an accumulator: this runs from
		# _process, and a strip left open for an hour must not drift because some frames were
		# long. A track with nothing playing still scrolls -- it says so, going past.
		var line := ("%s - %s" % [who, what] if not who.is_empty() else what).to_upper()
		_now_title.text = marquee_frame(line, int(Time.get_ticks_msec() * 0.001 * MARQUEE_HZ))
	else:
		_now_title.text = ("%s - %s" % [who, what] if not who.is_empty() else what).to_upper()
	if is_instance_valid(_now_time):
		_now_time.text = "--:-- / --:--" if path.is_empty() \
			else "%s / %s" % [_time_text(_pos()), _time_text(length)]
	if is_instance_valid(_now_bar):
		_now_bar.value = (_pos() / length * 100.0) if not path.is_empty() and length > 0.0 else 0.0

## Moves or resizes the mini bar while its own face is held. Run from _process, off the SCREEN
## pointer rather than off window motion events: the window stops getting those as soon as the
## pointer crosses its edge, so a corner drag used to travel a few pixels and stop dead. The
## button state is read from Input for the same reason -- the release can land outside too.
func _now_drag_step() -> void:
	if not (_now_dragging or _now_resizing) or not is_instance_valid(_now_win):
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_now_dragging = false
		_now_resizing = false
		return
	var at := DisplayServer.mouse_get_position() - _now_grab
	if _now_resizing:
		# min_size is what the contents measure, so this cannot be dragged small enough to
		# clip a button off the end whichever of the four modes is showing
		_now_win.size = Vector2i(maxi(at.x, _now_win.min_size.x), maxi(at.y, _now_win.min_size.y))
	else:
		_now_win.position = at

func _refresh_dual_bars_btn() -> void:
	if is_instance_valid(_dual_bars_btn):
		_dual_bars_btn.text = "[*] A + B" if _dual_bars else "[ ] ONE BAR"

func _refresh_meter_btn() -> void:
	if is_instance_valid(_meter_btn):
		_meter_btn.text = "[*] ON" if _meter_on else "[ ] OFF"

func _refresh_now_btn() -> void:
	if is_instance_valid(_now_btn):
		_now_btn.text = "[*] OPEN" if _now_playing else "[ ] CLOSED"

# --- the player bar's height ------------------------------------------------------------
## The transport sat in the main column at whatever height its controls needed, which is fine
## until you want to actually SEE the waveform you are cueing against. Body and the bar now share
## a VSplitContainer, so the divider between them is draggable: pull it up and the scrub bar takes
## every pixel you give it, markers, waveform and all, because both are drawn from the overlay's
## own height rather than a constant.
##
## Built here rather than in player.tscn because the nodes are already there and already wired:
## reparenting three of them keeps every %UniqueName (each has the scene root as its owner, which
## is what reparent() restores), where re-cutting the scene would touch every path below them.
const PLAYBAR_MIN_H := 52     # the bar at its natural height: scrub row plus the transport
const PLAYBAR_MAX_H := 420    # past this it is eating the library, not showing a waveform
var _playbar_split: VSplitContainer
var _playbar_offset := 0      # the divider's saved position, 0 = the bar at its minimum

func _setup_playbar_split() -> void:
	# Body's parent, not %Main: the main column is not a unique name in this scene
	var main: Control = %Body.get_parent()
	_playbar_split = VSplitContainer.new()
	_playbar_split.name = "PlayerSplit"
	_playbar_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_playbar_split)
	main.move_child(_playbar_split, %Body.get_index())
	%Body.reparent(_playbar_split, false)
	var bar := VBoxContainer.new()
	bar.name = "PlayerBar"
	bar.add_theme_constant_override("separation", 4)
	bar.custom_minimum_size.y = PLAYBAR_MIN_H
	_playbar_split.add_child(bar)
	%ScrubRow.reparent(bar, false)
	%ControlDeck.reparent(bar, false)
	_restore_unique_names(_playbar_split)
	# what grows when the divider moves: the scrub bar itself, and with it the cue overlay
	# anchored to it -- the transport row keeps its own height
	%ScrubRow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	%Scrub.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_playbar_split.split_offset = _playbar_offset
	_playbar_split.dragged.connect(func(offset: int) -> void:
		_playbar_offset = offset
		_save_soon())

## The bar's height, clamped: a drag that would leave the library a sliver, or the bar shorter
## than its own controls, is held at the edge rather than refused.
func _clamp_playbar() -> void:
	if not is_instance_valid(_playbar_split) or _playbar_split.get_child_count() < 2:
		return
	var bar: Control = _playbar_split.get_child(1)
	if bar.size.y > PLAYBAR_MAX_H:
		_playbar_split.split_offset += int(bar.size.y - PLAYBAR_MAX_H)
		_playbar_offset = _playbar_split.split_offset

# --- hover marquee ----------------------------------------------------------------------
## A title too long for the column scrolls while the pointer rests on it, and snaps back to the
## clipped view the moment it leaves. One character per tick, the same idiom -- and the same
## typeface -- as the status ticker, rather than a smooth pixel scroll that would read as a
## different program's animation.
##
## The row's text is what gets rewritten, so this has to be the only thing writing it: the
## write-in effect cancels it, and so does every refill, because both rebuild the rows underneath.
const MARQUEE_HZ := 9.0           # characters a second
const MARQUEE_GAP := "   //   "   # what separates the end of the title from its start again
var _marquee_crate := -1
var _marquee_row := -1
var _marquee_full := ""
var _marquee_t := 0.0
var _marquee_at := -1   # the character index last written, so a frame that moves nothing writes nothing
## The row a left-drag started on, for the selection run; -1 when no button is down.
var _drag_anchor := -1
## What was selected when the right button went down, before ItemList collapsed it.
var _rmb_bundle: Array[String] = []

func _marquee_hover(crate: int, row: int) -> void:
	if crate == _marquee_crate and row == _marquee_row:
		return
	_marquee_stop()
	if row < 0 or (_write_tween and _write_tween.is_valid()):
		return
	var list: ItemList = [_tracks, _tracks_b][crate]
	if row >= list.item_count or _row_fits(list, list.get_item_text(row)):
		return   # the row already shows all of it; scrolling would be motion for nothing
	_marquee_crate = crate
	_marquee_row = row
	_marquee_full = list.get_item_text(row)
	_marquee_t = 0.0
	_marquee_at = -1

## Whether a row's text fits the column as it stands, scrollbar and cell padding taken off.
const MARQUEE_PADDING := 12.0

func _row_fits(list: ItemList, text: String) -> bool:
	var font := list.get_theme_font("font")
	if not font:
		return true
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		list.get_theme_font_size("font_size")).x
	var bar := list.get_v_scroll_bar()
	var room := list.size.x - (bar.size.x if bar and bar.visible else 0.0) - MARQUEE_PADDING
	return width <= room

func _marquee_stop() -> void:
	if _marquee_row < 0:
		return
	var list: ItemList = [_tracks, _tracks_b][_marquee_crate]
	if _marquee_row < list.item_count:
		list.set_item_text(_marquee_row, _marquee_full)
	_marquee_crate = -1
	_marquee_row = -1
	_marquee_full = ""

func _marquee_step(delta: float) -> void:
	if _marquee_row < 0:
		return
	var list: ItemList = [_tracks, _tracks_b][_marquee_crate]
	if _marquee_row >= list.item_count:
		_marquee_stop()   # the list was rebuilt under the pointer
		return
	_marquee_t += delta * MARQUEE_HZ
	var step := int(_marquee_t)
	if step == _marquee_at:
		return
	# only when the CHARACTER changes, which is MARQUEE_HZ times a second rather than once a
	# frame. set_item_text makes an ItemList re-lay out every row it holds: measured, one text
	# change a frame costs 5.5 ms extra on a 20,000-row list and nothing at all on 5,000.
	_marquee_at = step
	list.set_item_text(_marquee_row, marquee_frame(_marquee_full, step))

## The title at tick `step`, looping through itself with MARQUEE_GAP between the end and the
## start. Pure, so the wrap -- the one place an off-by-one shows up as a stutter once a loop --
## is checkable without a list or a pointer.
static func marquee_frame(text: String, step: int) -> String:
	if text.is_empty():
		return text
	var loop := text + MARQUEE_GAP
	var at := posmod(step, loop.length())
	return loop.substr(at) + loop.substr(0, at)

static func marquee_test() -> bool:
	var full := "ABCDEF"
	var loop := full + MARQUEE_GAP
	return marquee_frame(full, 0) == loop \
		and marquee_frame(full, 1) == loop.substr(1) + loop[0] \
		and marquee_frame(full, loop.length()) == loop \
		and marquee_frame(full, -1) == marquee_frame(full, loop.length() - 1) \
		and marquee_frame("", 3) == "" \
		and marquee_frame(full, 3).length() == loop.length()

## Everything the pointer does over a track list that ItemList itself does not report: the drag
## that selects a run of rows, and the hover that scrolls a title too long for the column.
##
## SELECT_MULTI gives ctrl-click and shift-click for free and nothing for a drag, and pulling
## twenty tracks into the queue should not mean shift-clicking the far end of them.
func _on_list_pointer(e: InputEvent, crate: int) -> void:
	var list: ItemList = [_tracks, _tracks_b][crate]
	# The key forwarding that used to live here is gone: _transport_key() takes the transport's
	# keys at the root now, before any focused control sees them, so it covers these two lists
	# and every button, tab and tree besides.
	var click := e as InputEventMouseButton
	if click and click.pressed and click.button_index == MOUSE_BUTTON_RIGHT:
		# BEFORE ItemList sees it: this signal runs ahead of the control's own handler, which is
		# the only moment the multi-selection still exists to be read
		_rmb_bundle = _selected_paths(crate)
		return
	if click and click.button_index == MOUSE_BUTTON_LEFT:
		# the anchor is where the button went DOWN; ItemList has already selected that row
		_drag_anchor = list.get_item_at_position(click.position, true) if click.pressed else -1
		return
	var motion := e as InputEventMouseMotion
	if not motion:
		return
	var row := list.get_item_at_position(motion.position, true)
	if _drag_anchor >= 0 and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_select_run(list, _drag_anchor, row)
		return
	_marquee_hover(crate, row)

## The rows between the anchor and the pointer, and nothing else -- a drag REPLACES the selection
## rather than adding to it, which is what every file manager does and what makes a mis-drag one
## more drag to fix rather than a ctrl-click hunt.
static func _select_run(list: ItemList, from: int, to: int) -> void:
	if from < 0 or to < 0:
		return
	list.deselect_all()
	for row in range(mini(from, to), maxi(from, to) + 1):
		if row < list.item_count and list.is_item_selectable(row):
			list.select(row, false)

## Walks the focused crate's selection by `d` rows, for a browse encoder. Keeps the moved-to row
## on screen, because a selection that has scrolled out of view is the same as no selection.
func _browse_step(d: int) -> void:
	var crate := _engine.deck
	var list: ItemList = [_tracks, _tracks_b][crate]
	if list.item_count == 0:
		return
	var sel := list.get_selected_items()
	var row: int = clampi((sel[0] if sel.size() > 0 else 0) + d, 0, list.item_count - 1)
	list.deselect_all()
	list.select(row)
	list.ensure_current_is_visible()
	_marquee_hover(crate, row)   # the row under the cursor scrolls its title; so does this one

## Loads whatever the browse encoder has landed on onto `deck`. Uses _open_deck, which takes a
## deck index -- so unlike the PLAY buttons, loading deck B steals no focus.
func _load_selected(deck: int) -> void:
	var picked := _selected_paths(_engine.deck)
	if picked.is_empty():
		_note = "  //  NOTHING SELECTED TO LOAD"
		_clear_note_later()
		return
	_open_deck(deck, picked[0])

## The paths of every selected row in `crate`, in ROW order -- which is the order the user sees,
## and so the order a queued run has to arrive in. Header rows have no path and drop out.
func _selected_paths(crate: int) -> Array[String]:
	var list: ItemList = [_tracks, _tracks_b][crate]
	var row_path: PackedInt32Array = _row_paths[crate]
	var out: Array[String] = []
	for row in list.get_selected_items():
		if row >= 0 and row < row_path.size() and row_path[row] >= 0:
			out.append(_library.paths[row_path[row]])
	return out

func _on_list_scroll(e: InputEvent, list: ItemList) -> void:
	if not (e is InputEventMouseButton and e.pressed):
		return
	var dir := 0
	if e.button_index == MOUSE_BUTTON_WHEEL_UP: dir = -1
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN: dir = 1
	else: return
	if list.item_count == 0:
		return
	var step := list.get_item_rect(0).size.y
	if step <= 0.0:
		return
	var bar := list.get_v_scroll_bar()
	bar.value = snappedf(bar.value + dir * step * 3.0, step)
	list.accept_event()


## Px437 is a codepage-437 bitmap font: no CJK glyphs at all, so the Japanese track
## names would render as tofu. Chaining a SystemFont fallback keeps the pixel look for
## everything it covers and quietly hands the rest to the OS.
func _setup_pixel_font() -> void:
	var px := theme.default_font
	if not px:
		return
	var cjk := SystemFont.new()
	cjk.font_names = PackedStringArray(["Yu Gothic UI", "Meiryo", "MS Gothic", "Segoe UI"])
	cjk.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	cjk.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	px.fallbacks = [cjk]


## Classic 12x19 arrow, built in code and nearest-scaled up. '#' is the black outline,
## '.' the white fill, space transparent. Drawing it rather than shipping a PNG keeps
## it one file and lets CURSOR_SCALE decide how chunky the pixels read.
const CURSOR_SCALE := 3
const CURSOR_ART := [
	"#",
	"##",
	"#.#",
	"#..#",
	"#...#",
	"#....#",
	"#.....#",
	"#......#",
	"#.......#",
	"#........#",
	"#.....#####",
	"#..#..#",
	"#.# #..#",
	"##  #..#",
	"#    #..#",
	"     #..#",
	"      #..#",
	"      #..#",
	"       ##",
]

## Deliberately not persisted, for the same reason FULLSCREEN is not: booting into a
## player with no visible pointer is a UI you have to guess your way out of. [H] is a
## per-session thing you turn on to watch the visualizer clean.
var _cursor_hidden := false

## MOUSE_MODE_HIDDEN rather than CAPTURED: the pointer still moves, still hovers and
## still clicks, it just stops being drawn. CAPTURED would lock it to the window and
## break every fader in the rack.
func _toggle_cursor() -> void:
	_cursor_hidden = not _cursor_hidden
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if _cursor_hidden else Input.MOUSE_MODE_VISIBLE

func _setup_cursor() -> void:
	var w := 0
	for row in CURSOR_ART:
		w = maxi(w, row.length())
	var img := Image.create(w * CURSOR_SCALE, CURSOR_ART.size() * CURSOR_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in CURSOR_ART.size():
		var row: String = CURSOR_ART[y]
		for x in row.length():
			if row[x] == " ":
				continue
			var col := Color.BLACK if row[x] == "#" else Color.WHITE
			for dy in CURSOR_SCALE:
				for dx in CURSOR_SCALE:
					img.set_pixel(x * CURSOR_SCALE + dx, y * CURSOR_SCALE + dy, col)
	var custom := _custom_cursor_image()
	# The drawn arrow keeps its hotspot at the tip, which is pixel (0,0) of that bitmap.
	# A user image is scaled and given the hotspot from the CURSOR window instead.
	var shape := img
	var hotspot := Vector2.ZERO
	if custom:
		# resized HERE rather than at the slider, so the stored hotspot fraction resolves
		# against the size the OS is actually handed
		var want := Vector2i(
			clampi(int(roundf(custom.get_width() * _cursor_scale)), 1, ASSET_THUMB_PX * 2),
			clampi(int(roundf(custom.get_height() * _cursor_scale)), 1, ASSET_THUMB_PX * 2))
		if want != Vector2i(custom.get_width(), custom.get_height()):
			custom.resize(want.x, want.y, Image.INTERPOLATE_NEAREST)
		shape = custom
		# clamped inside the bitmap: a hotspot outside it is rejected outright, and the
		# program would silently keep whatever pointer it had
		hotspot = Vector2(
			clampf(shape.get_width() * _cursor_hotspot.x, 0.0, float(shape.get_width() - 1)),
			clampf(shape.get_height() * _cursor_hotspot.y, 0.0, float(shape.get_height() - 1))).floor()
	elif not is_equal_approx(_cursor_scale, 1.0):
		# CURSOR SIZE used to only resize a custom PNG -- picking BUILT-IN ARROW and
		# dragging the slider changed the readout and visibly did nothing. The hotspot
		# stays (0,0): the tip is pixel (0,0) at any uniform scale of this art.
		var want := Vector2i(
			clampi(int(roundf(img.get_width() * _cursor_scale)), 1, ASSET_THUMB_PX * 2),
			clampi(int(roundf(img.get_height() * _cursor_scale)), 1, ASSET_THUMB_PX * 2))
		img.resize(want.x, want.y, Image.INTERPOLATE_NEAREST)
	DisplayServer.cursor_set_custom_image(shape, DisplayServer.CURSOR_ARROW, hotspot)


# --- EQUALIZER tab --------------------------------------------------------
const EQ_MODES := ["OFF", "EZ EQ", "ADVANCED"]
const EZ_LABELS := ["LOW", "MID", "HIGH"]

func _setup_eq() -> void:
	# One rack per deck, each on that deck's bus. The chain is identical; only the state
	# differs, which is exactly what the DECK toggle swaps the UI over to.
	for i in _eq_decks.size():
		_eq_decks[i].setup(_engine.deck_bus(i))
		_eq_decks[i].from_dict(_eq_cfg_decks[i])
		# AFTER the Equalizer on the same bus, never before: Equalizer.setup builds from slot 0
		# and ends the bus with its limiter, and the rack inserts its modules just ahead of that
		# limiter -- so the deck limiter catches whatever the rack adds.
		var rack := FxRack.new()
		rack.name = "Rack%s" % ["A", "B"][i]
		add_child(rack)
		rack.setup(_engine.deck_bus(i))
		rack.from_dict(_rack_cfg_decks[i])
		_rack_decks.append(rack)
		# BEAT SYNC's tracker for this deck, behind its rack. Created at boot on purpose:
		# inserting its analyser rebuilds the deck bus's effect instances, harmless before any
		# audio flows and a glitch mid-set. It starts switched off (set_beat_sync below).
		var tracker := AudioDirector.new()
		tracker.name = "DeckTracker%s" % ["A", "B"][i]
		tracker.bus = _engine.deck_bus(i)
		add_child(tracker)
		_deck_directors.append(tracker)
	_eq = _eq_decks[_engine.deck]
	# the racks are inserted ahead of the analyser, which invalidates the handle the
	# director cached in its own _ready (children are ready before their parent)
	_director.rebind()
	var cap := Equalizer.grabber_texture()
	for i in EZ_LABELS.size():
		_ez_faders.append(_make_fader(%EzPanel, EZ_LABELS[i], cap, _eq.ez_db[i]))
	for i in Equalizer.LANES:
		# label every fourth lane only; 16 stacked captions is unreadable at this width
		var tag := _lane_hz(i) if i % 4 == 0 else ""
		_adv_faders.append(_make_fader(%AdvPanel, tag, cap, _eq.lane_db[i]))
	for i in _ez_faders.size():
		_ez_faders[i].value_changed.connect(func(v: float) -> void: _eq.set_ez(i, v))
		_hover_note(_ez_faders[i], func() -> String:
			return "%s: %+.1f DB" % [EZ_LABELS[i], _eq.ez_db[i]])
	for i in _adv_faders.size():
		var f := _adv_faders[i]
		# every lane names its own centre frequency here, including the three in four
		# that have no printed caption -- that is the readout this tab never had
		_hover_note(f, func() -> String:
			return "%s HZ: %+.1f DB" % [_lane_hz(i), _eq.lane_db[i]])
		f.drag_started.connect(func() -> void: _fader_base = _eq.lane_db.duplicate())
		f.value_changed.connect(_on_lane_changed.bind(i))
	%EqMode.pressed.connect(func() -> void:
		_eq.set_mode(((_eq.mode + 1) % 3) as Equalizer.Mode)
		_refresh_eq()
		_save())
	%EqAdapt.toggled.connect(func(on: bool) -> void:
		_eq.adapt = on
		_save())
	# T-BASS and BBE are FX rack modules (fx_rack.gd), each in its own wet/dry pair; this tab
	# has no rows for them, and an older [eq] state's tbass/bbe keys are simply ignored.
	_setup_presets()
	for e in _eq_decks:
		e.changed.connect(_save_soon)
	# With both fader panels hidden in OFF mode, and no T-BASS/BBE rows here, the
	# tab collapsed to a lone button in a 29 px strip -- which reads as the equalizer
	# having broken rather than being switched off. This says which it is.
	_eq_off_note = Label.new()
	_eq_off_note.name = "EqOffNote"
	# Two short fixed lines, NOT one long autowrapped one. Autowrap made the label
	# compute its height at its own minimum width (140 px) and demand 1636 px of it,
	# which the tab then inherited. Each line is kept under ~22 characters so it also
	# cannot widen the tab past the 575 px sidebar floor, the way the RAM readout did
	# to STATS.
	_eq_off_note.text = "[ EQUALIZER BYPASSED ]
EFFECTS ON THE FX TAB"
	_eq_off_note.theme_type_variation = &"Green"
	_eq_off_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var eq_tab := %EqMode.get_parent().get_parent()
	eq_tab.add_child(_eq_off_note)
	eq_tab.move_child(_eq_off_note, 1)
	%EqAdapt.button_pressed = _eq.adapt
	_refresh_eq()
	_set_beat_sync(_beat_sync)   # the trackers exist from here, so the saved state can apply

## Lane centre frequencies, 32 Hz to 16 kHz spread logarithmically across the 16 lanes.
func _lane_hz(i: int) -> String:
	var hz := 32.0 * pow(500.0, float(i) / float(Equalizer.LANES - 1))
	return "%dK" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz)

func _make_fader(parent: Control, tag: String, cap: ImageTexture, value: float) -> VSlider:
	var lane := VBoxContainer.new()
	lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lane.add_theme_constant_override("separation", 2)
	var f := VSlider.new()
	f.min_value = Equalizer.GAIN_MIN
	f.max_value = Equalizer.GAIN_MAX
	f.step = 0.5
	f.value = value
	f.size_flags_vertical = Control.SIZE_EXPAND_FILL
	f.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# generated cap: the stock grabber is a soft round dot that matches nothing else here,
	# and a theme icon needs a real texture either way
	f.add_theme_icon_override("grabber", cap)
	f.add_theme_icon_override("grabber_highlight", cap)
	lane.add_child(f)
	var l := Label.new()
	l.text = tag
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lane.add_child(l)
	parent.add_child(lane)
	return f

## ADAPT rewrites every lane, so the other 15 sliders have to be pushed back without
## re-entering this handler -- hence the sync guard rather than disconnecting signals.
func _on_lane_changed(v: float, i: int) -> void:
	if _fader_sync:
		return
	if _fader_base.size() != Equalizer.LANES:
		_fader_base = _eq.lane_db.duplicate()
	_eq.apply_lane(i, v, _fader_base)
	if not _eq.adapt:
		return
	_fader_sync = true
	for j in Equalizer.LANES:
		if j != i:
			_adv_faders[j].value = _eq.lane_db[j]
	_fader_sync = false

func _refresh_eq() -> void:
	%EqMode.text = "EQ: %s" % EQ_MODES[_eq.mode]
	if is_instance_valid(_eq_off_note):
		_eq_off_note.visible = _eq.mode == Equalizer.Mode.OFF
	%EzPanel.visible = _eq.mode == Equalizer.Mode.EZ
	%AdvPanel.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%EqAdapt.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%PresetRow.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%NameRow.visible = _eq.mode == Equalizer.Mode.ADVANCED

func _apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_volume, 0.01) / 100.0))

## Continuous controls (EQ faders, the volume bar) change many times per second, and
## writing library.cfg at that rate would hammer the disk. Every such control funnels
## through here instead, so at most one write lands per 1.5 s no matter how many move.
func _save_soon() -> void:
	if not is_inside_tree():
		return   # a detached instance (a test driving one handler) has no tree to time against
	if has_meta("save_pending"):
		return
	set_meta("save_pending", true)
	await get_tree().create_timer(1.5).timeout
	remove_meta("save_pending")
	_save()


# --- uptime and factory reset ---------------------------------------------
static func _hms(secs: float) -> String:
	var s := int(secs)
	var d := s / 86400
	var h := (s % 86400) / 3600
	return ("%dD %02d:%02d:%02d" % [d, h, (s % 3600) / 60, s % 60]) if d > 0 \
		else ("%02d:%02d:%02d" % [h, (s % 3600) / 60, s % 60])

## REBOOT is destructive, so the first click only arms it. A second click within four
## seconds commits.
##
## A reset is a restart with no config, not a walk over every setting. The old version
## reset each field by hand, had drifted to missing about twenty of them (keybinds, MONO,
## a hidden play bar, both FX racks, deck B's EQ...) and then SAVED the half-reset state.
## Moving the file aside cannot miss one, and it can be undone: rename the
## .reboot-<unix time> copy back. Fonts, cursors and license.dat stay in user://.
##
## OS.set_restart_on_exit is ignored when the project is run from the editor, so there
## REBOOT simply quits; an exported build comes straight back up on defaults.
var _rebooting := false

func _on_reboot() -> void:
	if _reboot_armed <= 0.0:
		_reboot_armed = 4.0
		%Reboot.text = "CONFIRM?"
		return
	_reboot_armed = 0.0
	# same order as a window close: finish the take, join the workers, THEN touch the file
	if _recorder and _recorder.recording:
		_recorder.stop(_rec_type, _rec_rate, _rec_quality)
	_engine.shutdown()
	_rebooting = true   # _save() refuses from here on
	var live := ProjectSettings.globalize_path(_cfg)
	if FileAccess.file_exists(live):
		DirAccess.rename_absolute(live, "%s.reboot-%d" % [live, int(Time.get_unix_time_from_system())])
	# the .bak goes too, or load_cfg_safe would find it on the way back up and restore it
	for leftover: String in [live + ".bak", live + ".tmp"]:
		if FileAccess.file_exists(leftover):
			DirAccess.remove_absolute(leftover)
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


# --- TBS -------------------------------------------------------------------
func _setup_tbs() -> void:
	# TBS means TO BE SORTED, and is the settings screen. Phase 3 renamed it SETTINGS; it went
	# back to TBS at Gavin's request (2026-09-19).
	#
	# Anchored off %Layout because the old list used to be how this found the tab.
	var tab: Control = %Layout.get_parent().get_parent()
	# The settings screen has outgrown the tab -- keybinds alone add ten rows, and the
	# scene's own rows plus the runtime ones now run well past the bottom of a sidebar
	# sitting on its 575 px floor, with no way to reach what is under the fold. Every
	# row moves into a scroller, and _tbs_home points at that instead of the tab, so
	# _add_settings_rows and the detached-window shuffle both carry on unchanged.
	var scroll := ScrollContainer.new()
	scroll.name = "TbsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.name = "TbsCol"
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	scroll.add_child(col)
	# snapshot first: reparenting mutates the child list being walked
	var rows := tab.get_children()
	tab.add_child(scroll)
	for row in rows:
		row.reparent(col, false)
	# reparent() re-registers the node it is CALLED ON, never its descendants -- and
	# every %UniqueName here (%Layout, %FadeMs, %Boost ...) is a child of a row, not the
	# row itself. Without this they all stop resolving the moment the rows move.
	_restore_unique_names(col)
	_tbs_home = col
	_tbs_tab = tab
	_add_settings_rows()
	_group_settings()
	_wheel_through(_tbs_home)
	_wheel_scrolls(scroll)

## Wheel handling written out rather than left to the ScrollContainer's own.
##
## The container does handle the wheel, but only for events that actually reach it, and what
## reaches it depends on the mouse_filter of everything stacked above -- which is a property on
## forty-odd controls that anything adding a row later can get wrong again. This connects the
## notch to scroll_vertical directly, on both the scroller and the column inside it, and
## accepts the event so the container's own handler does not scroll a second time on top.
##
## A gui_input SIGNAL runs before the control's own _gui_input, which is what makes accepting
## here enough to replace the built-in behaviour rather than add to it.
const TBS_WHEEL_STEP := 40

func _wheel_scrolls(scroll: ScrollContainer) -> void:
	var step := func(e: InputEvent) -> void:
		var click := e as InputEventMouseButton
		if not click or not click.pressed:
			return
		if click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll.scroll_vertical += TBS_WHEEL_STEP
		elif click.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll.scroll_vertical -= TBS_WHEEL_STEP
		else:
			return
		scroll.accept_event()
	scroll.gui_input.connect(step)
	for child in scroll.get_children():
		if child is Control:
			(child as Control).gui_input.connect(step)

## Wheel events reach a ScrollContainer only if nothing under the pointer swallows them first,
## and a Button's default mouse_filter is STOP. TBS is mostly buttons, so the wheel worked over
## the gaps between rows and nowhere else -- which reads as "the panel does not scroll", because
## the gaps are not where anyone puts the pointer. PASS lets each control handle what it wants
## and hands the rest up to its parent, so the panel scrolls wherever the pointer is sitting.
##
## RANGES ARE LEFT ALONE ON PURPOSE. The bars in here -- VOLUME BOOST, FADE TIME, the visual
## sliders -- take the wheel themselves through _bar_wheel, and passing it on as well would
## change the value AND scroll the panel out from under it on the same notch. Same for the
## dropdowns and any text field.
func _wheel_through(from: Node) -> void:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var c := n as Control
		if c and not (c is Range) and not (c is LineEdit) and not (c is OptionButton) \
				and c.mouse_filter == Control.MOUSE_FILTER_STOP:
			c.mouse_filter = Control.MOUSE_FILTER_PASS
		for child in n.get_children():
			stack.append(child)

## WHICH GROUP EACH SETTING BELONGS TO, by the row's node name. Anything not named here lands
## in ADVANCED, so a row added later shows up somewhere rather than vanishing -- and a keybind
## row (Bind_*) is matched by prefix, because there is one per action and the list grows.
##
## The order of the keys is the order the groups appear.
const SETTING_GROUPS := {
	"AUDIO": ["FadeRow", "FadeTimeRow", "PlayDelayRow", "BoostRow", "BeatRow", "MonoRow",
		"ListeningModeRow"],
	"LIBRARY": ["ShowMsRow"],
	"DISPLAY": ["FeedSizeRow", "FpsRow", "LayoutRow", "ClockRow", "FontRow", "FontsRow",
		"CursorRow", "CrtRow", "PlayBarRow", "PlayBarShapeRow", "VisualWinRow", "DualDeckRow",
		"FadeSpeedRow", "BgThrottleRow", "NowPlayingRow", "DualBarsRow", "MeterRow"],
	"VIDEO": ["IntroRow", "VideoTestRow", "VideoColorRow"],
	"INPUT": ["SkipSecsRow", "MidiSetupRow"],
	"ADVANCED": ["MessageLogRow", "CheatRow", "AutopsyPanel"],
}

var _setting_sections := {}   # group name -> the VBoxContainer holding its rows
var _settings_search: LineEdit

## Which group a row belongs in. Pure, so the table can be checked without building a screen.
static func setting_group(row_name: String) -> String:
	for group in SETTING_GROUPS:
		if row_name in (SETTING_GROUPS[group] as Array):
			return group
	# every keybind lands under INPUT beside SKIP SECONDS, the only other thing on that screen
	# about what the keyboard does; anything else added later shows up in ADVANCED rather than
	# vanishing, which is what an unlisted row would otherwise do
	return "INPUT" if row_name.begins_with("Bind_") else "ADVANCED"

static func settings_test() -> bool:
	var named := {}
	for group in SETTING_GROUPS:
		for row_name in SETTING_GROUPS[group]:
			if named.has(row_name):
				return false   # one row in two groups would be reparented twice
			named[row_name] = group
	var probe := HBoxContainer.new()
	var cap := Label.new()
	cap.text = "LISTENING MODE"
	probe.add_child(cap)
	var btn := Button.new()
	btn.text = "[ CASUAL (SMOOTH) ]"
	probe.add_child(btn)
	probe.name = "ListeningModeRow"
	var hay := setting_haystack(probe)
	probe.free()
	return setting_group("PlayBarShapeRow") == "DISPLAY" 		and setting_group("PlayBarRow") == "DISPLAY" 		and setting_group("FadeRow") == "AUDIO" 		and setting_group("Bind_play") == "INPUT" 		and setting_group("SkipSecsRow") == "INPUT" 		and setting_group("VideoColorRow") == "VIDEO" 		and setting_group("SomethingAddedLater") == "ADVANCED" 		and hay.contains("listening mode") and hay.contains("casual") and hay.contains("listeningmoderow")

## Forty-two rows in one flat column, in the order they happened to be built: FADE, FADE TIME,
## PLAY DELAY, FEED SIZE, MAX FPS, BEAT, BOOST, LAYOUT, CLOCK, FONT... with ten keybinds in the
## middle of it. Finding anything meant scrolling the whole list and reading every caption.
##
## The rows themselves are untouched -- they keep their names, their %UniqueNames and their
## signal connections, and the detached settings window still carries the lot across, because
## what moves is the same nodes into section containers rather than anything rebuilt.
func _group_settings() -> void:
	# snapshot before reparenting: the child list is about to change underneath the walk
	var rows := _tbs_home.get_children()
	for group in SETTING_GROUPS:
		var section := VBoxContainer.new()
		section.name = "Group_%s" % group
		section.add_theme_constant_override("separation", 4)
		var header := Label.new()
		header.name = "GroupHeader"
		header.text = "-- %s --" % group
		section.add_child(header)
		_tbs_home.add_child(section)
		# Owned, because the detached window moves SECTIONS: reparent() gives back the owner only
		# to nodes sharing the moved node's owner, and an ownerless section left every row inside
		# it -- and every %UniqueName -- ownerless after the first TBS open. See _move_rows.
		section.owner = self
		_setting_sections[group] = section
	for row: Node in rows:
		row.reparent(_setting_sections[setting_group(str(row.name))] as Node, false)
	# reparent() re-registers the node it is CALLED ON, never its descendants, and every
	# %UniqueName on this screen is a child of a row rather than the row itself
	_restore_unique_names(_tbs_home)
	_add_settings_search()

## Type-to-find over the whole screen. Matches a row's caption, the text on its control and its
## group name, so "FADE" finds FADE, FADE TIME and TAB FADE SPEED, and "AUDIO" brings back the
## whole audio group. A group with nothing left showing hides its header too, rather than
## leaving a run of titles over empty space.
func _add_settings_search() -> void:
	var row := HBoxContainer.new()
	row.name = "SettingsSearchRow"
	var caption := Label.new()
	caption.text = "FIND"
	row.add_child(caption)
	_settings_search = LineEdit.new()
	_settings_search.name = "SettingsSearch"
	_settings_search.placeholder_text = "TYPE TO FILTER TBS"
	_settings_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_search.clear_button_enabled = true
	row.add_child(_settings_search)
	_tbs_home.add_child(row)
	_tbs_home.move_child(row, 0)
	_settings_search.text_changed.connect(_filter_settings)

## The text a row can be found by: its caption, whatever its control currently reads, and the
## name of the node itself, so a row whose caption is an icon or a symbol is still reachable.
static func setting_haystack(row: Node) -> String:
	var parts := PackedStringArray([str(row.name)])
	var stack: Array[Node] = [row]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Label:
			parts.append((n as Label).text)
		elif n is Button:
			parts.append((n as Button).text)
		elif n is LineEdit:
			parts.append((n as LineEdit).text)
	return " ".join(parts).to_lower()

func _filter_settings(needle: String) -> void:
	var want := needle.strip_edges().to_lower()
	for group in _setting_sections:
		var section: VBoxContainer = _setting_sections[group]
		var any := false
		var in_group: bool = want.is_empty() or str(group).to_lower().contains(want)
		for row: Node in section.get_children():
			if str(row.name) == "GroupHeader":
				continue
			var show: bool = in_group or setting_haystack(row).contains(want)
			(row as CanvasItem).visible = show
			any = any or show
		section.visible = any

## Builds one settings row in the shape the scene's own rows use: a caption sized to
## match its siblings so the controls line up in a column, then a control filling the
## rest. `home` defaults to _tbs_home -- every TBS caller can go on omitting it -- but
## any container works, which is what lets the VISUAL tab grow rows the same way.
##
## Rows built for _tbs_home join it before anything is torn off, so they travel to the
## detached settings window with every other row and need no special handling there.
func _add_setting_row(caption_text: String, row_name: String, after: Control,
		home: Control = null) -> Button:
	if not home:
		home = _tbs_home
	var row := HBoxContainer.new()
	row.name = row_name
	var caption := Label.new()
	caption.text = caption_text
	row.add_child(caption)
	var btn := Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	home.add_child(row)
	home.move_child(row, after.get_index() + 1)
	# The caption column: the width of this caption's OWN text, floored by the sibling caption's
	# so the controls still line up. Taking the sibling's laid-out size instead was the old rule,
	# and it is what drew the VISUAL tab's captions two characters wide -- at build time that size
	# is whatever the last layout pass happened to leave there, which on a tab nobody had opened
	# yet was nothing. Pinned after the row is in the tree, where the label can read its font.
	_pin_label(caption)
	var sibling := after.get_child(0) as Control
	if sibling:
		caption.custom_minimum_size.x = maxf(caption.custom_minimum_size.x, sibling.custom_minimum_size.x)
	return btn

## The two settings that are built in code rather than in player.tscn, added after
## LAYOUT so they sit with the other display settings.
func _add_settings_rows() -> void:
	var layout_row: Control = %Layout.get_parent()
	var log_btn := _add_setting_row("MESSAGE LOG", "MessageLogRow", layout_row)
	log_btn.text = "[ OPEN ]"
	log_btn.pressed.connect(_open_log_window)
	_hover_note(log_btn, func() -> String:
		return "EVERY FAULT THIS SESSION  //  %d ERROR%s SO FAR" % [_log_errors, "" if _log_errors == 1 else "S"])

	_clock_btn = _add_setting_row("CLOCK", "ClockRow", layout_row)
	_clock_btn.pressed.connect(func() -> void:
		_clock_12h = not _clock_12h
		_refresh_clock_btn()
		_save())
	_refresh_clock_btn()

	_font_btn = _add_setting_row("FONT", "FontRow", _clock_btn.get_parent())
	_font_btn.pressed.connect(_cycle_font)
	_refresh_font_btn()

	# The two managers. FONT above still cycles what is already installed in one click,
	# which is the fast path; these open the windows that can add, preview and size.
	var fonts_btn := _add_setting_row("MANAGE", "FontsRow", _font_btn.get_parent())
	fonts_btn.text = "[ FONTS ]"
	fonts_btn.pressed.connect(_open_fonts_window)
	_hover_note(fonts_btn, func() -> String:
		return "ADD, PREVIEW AND SIZE FONTS  //  FILES LIVE IN %s" % FONT_DIR)

	# GRADIENT moved to the VISUAL tab (_setup_visual) -- it edits what that tab
	# previews live, so it belongs with the colour row, not in the settings screen.
	var cursor_btn := _add_setting_row("MANAGE", "CursorRow", fonts_btn.get_parent())
	cursor_btn.text = "[ CURSOR ]"
	cursor_btn.pressed.connect(_open_cursor_window)
	_hover_note(cursor_btn, func() -> String:
		return "ADD AND SCALE POINTERS  //  FILES LIVE IN %s" % CURSOR_DIR)

	_show_ms_btn = _add_setting_row("SHOW MS", "ShowMsRow", cursor_btn.get_parent())
	_show_ms_btn.toggle_mode = true
	_show_ms_btn.button_pressed = _show_ms
	_show_ms_btn.pressed.connect(func() -> void:
		_show_ms = _show_ms_btn.button_pressed
		_refresh_show_ms()
		# every position readout is rebuilt from _time_text in _process, so the transport,
		# the hover line and the STATS column follow on the next frame with nothing to
		# push. The markers' TS strings live in a menu built at popup time. This is the
		# only thing carrying stale text, and only because it is painted, not formatted.
		_cue_overlay.queue_redraw()
		_save())
	_refresh_show_ms()

	_intro_btn = _add_setting_row("INTRO VIDEO", "IntroRow", _show_ms_btn.get_parent())
	_intro_btn.toggle_mode = true
	_intro_btn.button_pressed = _intro_on
	_intro_btn.pressed.connect(func() -> void:
		_intro_on = _intro_btn.button_pressed
		_refresh_intro_btn()
		_save())
	_refresh_intro_btn()

	var after: Control = _intro_btn.get_parent()

	_mono_btn = _add_setting_row("MONO / STEREO", "MonoRow", after)
	_mono_btn.toggle_mode = true
	_mono_btn.button_pressed = _mono
	_mono_btn.pressed.connect(func() -> void:
		_mono = _mono_btn.button_pressed
		_apply_mono()
		_refresh_mono_btn()
		_save())
	_refresh_mono_btn()
	after = _mono_btn.get_parent()

	_listening_btn = _add_setting_row("LISTENING MODE", "ListeningModeRow", after)
	_listening_btn.pressed.connect(func() -> void:
		_listening_mode = (_listening_mode + 1) % AudioEngine.LISTENING_MODE_NAMES.size()
		_engine.set_listening_mode(_listening_mode)
		_refresh_listening_btn()
		_autopsy_at = 0.0
		_save())
	_refresh_listening_btn()
	_hover_note(_listening_btn, func() -> String:
		return "AUDIOPHILE: BIT-EXACT, NOTHING ADDED  //  CASUAL: +2.2 DB UNDER 120 HZ, -0.8 DB AT 3 KHZ, -1.5 DB OVER 16 KHZ, PHASE-LINEAR, 6 MS LATE")
	after = _listening_btn.get_parent()

	# DSP AUTOPSY: a column of its own rather than a caption + control row, refreshed at 4 Hz
	# from _process while it can be seen
	var autopsy := VBoxContainer.new()
	autopsy.name = "AutopsyPanel"
	var head := Label.new()
	head.text = "--- DSP AUTOPSY / SIGNAL FLOW"
	autopsy.add_child(head)
	_autopsy = Label.new()
	_autopsy.name = "Autopsy"
	autopsy.add_child(_autopsy)
	_tbs_home.add_child(autopsy)
	_tbs_home.move_child(autopsy, after.get_index() + 1)
	after = autopsy

	_now_btn = _add_setting_row("NOW PLAYING WINDOW", "NowPlayingRow", after)
	_now_btn.toggle_mode = true
	_now_btn.button_pressed = _now_playing
	_now_btn.pressed.connect(func() -> void:
		_now_playing = _now_btn.button_pressed
		_toggle_now_playing(_now_playing)
		_refresh_now_btn()
		_save())
	_refresh_now_btn()
	_hover_note(_now_btn, func() -> String:
		return "TITLE, TIME AND TRANSPORT IN A SMALL BORDERLESS WINDOW  //  DRAG IT BY ITS FACE")
	after = _now_btn.get_parent()

	_bg_throttle_btn = _add_setting_row("LOWER USAGE IN BACKGROUND", "BgThrottleRow", after)
	_bg_throttle_btn.toggle_mode = true
	_bg_throttle_btn.button_pressed = _bg_throttle
	_bg_throttle_btn.pressed.connect(func() -> void:
		_bg_throttle = _bg_throttle_btn.button_pressed
		_apply_bg_throttle(true)   # whatever it was capped at, the user is looking at it now
		_refresh_bg_throttle_btn()
		_save())
	_refresh_bg_throttle_btn()
	_hover_note(_bg_throttle_btn, func() -> String:
		return "WHILE ANOTHER PROGRAM HAS FOCUS, RUN AT %d FPS  //  OFF: FULL RATE, SO A SECOND-SCREEN FEED KEEPS MOVING" % UNFOCUSED_FPS)
	after = _bg_throttle_btn.get_parent()

	_crt_btn = _add_setting_row("CRT FILTER", "CrtRow", after)
	_crt_btn.toggle_mode = true
	_crt_btn.button_pressed = _crt_on
	_crt_btn.pressed.connect(func() -> void:
		_crt_on = _crt_btn.button_pressed
		_apply_crt()
		_refresh_crt_btn()
		_save())
	_refresh_crt_btn()
	after = _crt_btn.get_parent()

	_playbar_btn = _add_setting_row("PLAY BAR (BOTTOM)", "PlayBarRow", after)
	_playbar_btn.toggle_mode = true
	_playbar_btn.button_pressed = _playbar_on
	_playbar_btn.pressed.connect(func() -> void:
		_playbar_on = _playbar_btn.button_pressed
		_refresh_playbar_btn()
		_apply_feed(_feed)   # re-derives %ScrubRow / %ControlDeck visibility
		_save())
	_refresh_playbar_btn()
	after = _playbar_btn.get_parent()

	# NOT "PlayBarRow": that name is the show/hide toggle directly above. Two siblings with one
	# name means Godot silently renames the second, and a renamed row stops matching
	# SETTING_GROUPS and lands in ADVANCED instead of DISPLAY.
	_playbar_wave_btn = _add_setting_row("PLAYBAR SHAPE", "PlayBarShapeRow", after)
	_playbar_wave_btn.pressed.connect(func() -> void:
		_show_playbar_wave = not _show_playbar_wave
		_refresh_playbar_wave_btn()
		if is_instance_valid(_cue_overlay):
			_cue_overlay.queue_redraw()
		_save_soon())
	_refresh_playbar_wave_btn()
	after = _playbar_wave_btn.get_parent()

	_visual_win_btn = _add_setting_row("VISUAL EQ WINDOW", "VisualWinRow", after)
	_visual_win_btn.toggle_mode = true
	_visual_win_btn.button_pressed = _visual_windowed
	_visual_win_btn.pressed.connect(func() -> void:
		_visual_windowed = _visual_win_btn.button_pressed
		_toggle_visual_window(_visual_windowed)
		_refresh_visual_win_btn()
		_save())
	_refresh_visual_win_btn()
	after = _visual_win_btn.get_parent()

	_dual_deck_btn = _add_setting_row("DUAL DECK MODE", "DualDeckRow", after)
	_dual_deck_btn.pressed.connect(func() -> void: _set_dual_deck(not _dual_deck))
	_hover_note(_dual_deck_btn, func() -> String:
		return "DECK A'S TRACKS IN THEIR OWN COLUMN LEFT OF THE FEED  //  DECK B'S TRACKS, FX, EQ, DIRS ON THE RIGHT")
	after = _dual_deck_btn.get_parent()

	_video_test_btn = _add_setting_row("Video TEST", "VideoTestRow", after)
	_video_test_btn.toggle_mode = true
	_video_test_btn.button_pressed = _video_test
	_video_test_btn.pressed.connect(func() -> void: _set_video_test(_video_test_btn.button_pressed))
	_refresh_video_test_btn()
	_hover_note(_video_test_btn, func() -> String:
		return "OFF: MP4 FILES ARE INVISIBLE  //  ON: THEY JOIN THE LIBRARY, FULL AUDIO + LOW-FI PICTURE")
	after = _video_test_btn.get_parent()

	_video_color_btn = _add_setting_row("VIDEO COLOR", "VideoColorRow", after)
	_video_color_btn.pressed.connect(func() -> void:
		_video_color = VideoTest.ColorMode.ORIGINAL if _video_color == VideoTest.ColorMode.PALETTE \
			else VideoTest.ColorMode.PALETTE
		_picture.color_mode = _video_color
		_refresh_video_color_btn()
		_save())
	_refresh_video_color_btn()
	_hover_note(_video_color_btn, func() -> String:
		return "ORIGINAL: THE VIDEO'S OWN COLOURS  //  PALETTE: 4-STOP DITHER IN THE SKIN OR PICKED GRADIENT, PULSING ON THE KICK")
	after = _video_color_btn.get_parent()

	_skip_field = _add_setting_field_row("SKIP SECONDS (1-30)", "SkipSecsRow", after,
		str(int(_skip_secs)))
	_skip_field.text_submitted.connect(func(_s: String) -> void: _commit_skip_secs())
	_skip_field.focus_exited.connect(_commit_skip_secs)
	after = _skip_field.get_parent()

	_dual_bars_btn = _add_setting_row("DUAL PLAY BARS", "DualBarsRow", after)
	_dual_bars_btn.toggle_mode = true
	_dual_bars_btn.button_pressed = _dual_bars
	_dual_bars_btn.pressed.connect(func() -> void:
		_dual_bars = _dual_bars_btn.button_pressed
		_refresh_dual_bars_btn()
		_apply_dual_bars()
		_save())
	_refresh_dual_bars_btn()
	_hover_note(_dual_bars_btn, func() -> String:
		return "TWO SCRUB BARS, DECK A OVER DECK B, BOTH DRAWN WHATEVER HAS FOCUS  //  " \
			+ "CLICK EITHER TO SEEK THAT DECK; MARKERS ARE EDITED ON THE TOP BAR")
	after = _dual_bars_btn.get_parent()

	_meter_btn = _add_setting_row("MASTER LEVEL METER", "MeterRow", after)
	_meter_btn.toggle_mode = true
	_meter_btn.button_pressed = _meter_on
	_meter_btn.pressed.connect(func() -> void:
		_meter_on = _meter_btn.button_pressed
		if is_instance_valid(_meter):
			_meter.visible = _meter_on
		_refresh_meter_btn()
		_save())
	_refresh_meter_btn()
	_hover_note(_meter_btn, func() -> String:
		return "PEAK OUTPUT BESIDE THE VOLUME FADER  //  %s" % _meter_text())
	after = _meter_btn.get_parent()

	var midi_btn := _add_setting_row("MIDI SETUP", "MidiSetupRow", after)
	midi_btn.text = "[ OPEN MAPPER ]"
	midi_btn.pressed.connect(_open_midi_window)
	_hover_note(midi_btn, func() -> String:
		var n := _midi.binds.size()
		return "MIDI DEVICES, A LIVE MONITOR AND LEARN  //  %s" % [
			"NOTHING BOUND YET" if n == 0 else "%d ACTION%s BOUND" % [n, "" if n == 1 else "S"]])
	after = midi_btn.get_parent()

	_fade_speed_field = _add_setting_field_row("TAB FADE SPEED (0.25-4X)", "FadeSpeedRow",
		after, "%.2f" % _fade_speed)
	_fade_speed_field.text_submitted.connect(func(_s: String) -> void: _commit_fade_speed())
	_fade_speed_field.focus_exited.connect(_commit_fade_speed)
	after = _fade_speed_field.get_parent()

	after = _setup_keybinds(after)
	_sync_input_map()   # the bindings are final by here; take their keys off the ui_* actions

	_cheat_field = _add_setting_field_row("CHEAT CODE", "CheatRow", after, "", 16,
		HORIZONTAL_ALIGNMENT_LEFT)
	_cheat_field.placeholder_text = "TYPE A CODE, PRESS ENTER"
	_cheat_field.text_submitted.connect(func(s: String) -> void:
		var code := s.strip_edges().to_upper()
		_cheat_field.text = ""
		if LOCAL_CODES.has(code):
			_unlock(str(LOCAL_CODES[code]))
		elif not code.is_empty():
			_note = "  //  UNKNOWN CODE: %s" % code
			_clear_note_later())

## Same [*]/[ ] idiom the FX rack LEDs use -- a Button rather than a CheckBox, because
## the theme styles Button and Skins repaints it, while a CheckBox would arrive with
## stock Godot icons that no skin can touch.
func _refresh_intro_btn() -> void:
	if is_instance_valid(_intro_btn):
		_intro_btn.text = "[*] ON  (VIDEO + BIOS)" if _intro_on else "[ ] OFF  (SKIP BOTH)"

func _refresh_mono_btn() -> void:
	if is_instance_valid(_mono_btn):
		_mono_btn.text = "[*] MONO" if _mono else "[ ] STEREO"

func _refresh_bg_throttle_btn() -> void:
	if is_instance_valid(_bg_throttle_btn):
		# short, because the caption beside it is the longest on the screen: what the two states
		# actually do is on the hover note
		_bg_throttle_btn.text = "[*] ON" if _bg_throttle else "[ ] OFF"

func _refresh_crt_btn() -> void:
	if is_instance_valid(_crt_btn):
		_crt_btn.text = "[*] ON" if _crt_on else "[ ] OFF"

func _refresh_video_test_btn() -> void:
	if is_instance_valid(_video_test_btn):
		_video_test_btn.text = "[*] ON" if _video_test else "[ ] OFF"

func _refresh_listening_btn() -> void:
	if is_instance_valid(_listening_btn):
		_listening_btn.text = "[ %s ]" % AudioEngine.LISTENING_MODE_NAMES[_listening_mode]

func _refresh_video_color_btn() -> void:
	if is_instance_valid(_video_color_btn):
		_video_color_btn.text = "[ ORIGINAL COLOR ]" if _video_color == VideoTest.ColorMode.ORIGINAL \
			else "[ PALETTE / DITHER ]"

## Video TEST gates .mp4 at every door at once: the scan (so the TRACKS list, the index and the
## queue), the engine's decode (so nothing already queued can still play one), and the
## picture. Off also stops an MP4 that is playing and drops the renders --
## they are test output, not library data.
func _set_video_test(on: bool) -> void:
	_video_test = on
	_engine.video_test = on
	_refresh_video_test_btn()
	if not on:
		_picture.expect("", null)
		if _current.get_extension().to_lower() == "mp4":
			_stop()
		AudioEngine.purge_video_cache()
	_rescan()
	_engine.save_index(_library.all_paths)   # the index forgets them now, not at the next close
	_save()

func _refresh_playbar_btn() -> void:
	if is_instance_valid(_playbar_btn):
		_playbar_btn.text = "[*] SHOWN" if _playbar_on else "[ ] HIDDEN"

func _refresh_playbar_wave_btn() -> void:
	if is_instance_valid(_playbar_wave_btn):
		_playbar_wave_btn.text = "[ WAVEFORM ]" if _show_playbar_wave else "[ SOLID ]"

func _commit_skip_secs() -> void:
	_skip_secs = clampf(float(_skip_field.text), 1.0, 30.0)
	_skip_field.text = str(int(_skip_secs))
	_save_soon()

func _commit_fade_speed() -> void:
	_fade_speed = clampf(float(_fade_speed_field.text), 0.25, 4.0)
	_fade_speed_field.text = "%.2f" % _fade_speed
	_save_soon()

## Same row shape as _add_setting_row, but a LineEdit for a typed number instead of a
## button -- SKIP SECONDS and TAB FADE SPEED both want a value, not a toggle or a click.
func _add_setting_field_row(caption_text: String, row_name: String, after: Control,
		initial: String, max_len: int = 6, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_RIGHT
		) -> LineEdit:
	var row := HBoxContainer.new()
	row.name = row_name
	var caption := Label.new()
	caption.text = caption_text
	var sibling := after.get_child(0) as Control
	if sibling:
		caption.custom_minimum_size.x = sibling.size.x
	row.add_child(caption)
	var field := LineEdit.new()
	field.custom_minimum_size.x = 110
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.alignment = align
	field.max_length = max_len
	field.text = initial
	row.add_child(field)
	_tbs_home.add_child(row)
	_tbs_home.move_child(row, after.get_index() + 1)
	return field

# --- KEYBINDS tab UI ---------------------------------------------------------
## One row per KEYBIND_SPEC action: its label, and a button showing the bound key that
## starts a capture when clicked. Built the same generic way the FX rack is, off one
## table, so a new action is one line in KEYBIND_SPEC and nothing here.
func _setup_keybinds(after: Control) -> Control:
	for action in KEYBIND_SPEC:
		var label: String = KEYBIND_SPEC[action][0]
		var btn := _add_setting_row(label, "Bind_%s" % action, after)
		_rebind_btns[action] = btn
		btn.pressed.connect(_start_rebind.bind(action))
		_refresh_rebind_btn(action)
		after = btn.get_parent()
	return after

func _start_rebind(action: String) -> void:
	if not _awaiting_rebind.is_empty():
		_refresh_rebind_btn(_awaiting_rebind)   # cancel whichever capture was already open
	_awaiting_rebind = action
	_rebind_btns[action].text = "PRESS A KEY (ESC CANCELS)"
	# A capture that is never answered swallows the NEXT key the user presses, whenever
	# that happens to be -- walking away mid-rebind and coming back to a dead keyboard
	# is not something anyone would connect to a button they clicked ten minutes ago.
	# The action is re-checked on fire: a capture that already finished must not have a
	# later one cancelled out from under it by this timer.
	get_tree().create_timer(REBIND_TIMEOUT_SEC).timeout.connect(func() -> void:
		if _awaiting_rebind == action:
			_awaiting_rebind = ""
			_refresh_rebind_btn(action)
			_note = "  //  REBIND TIMED OUT"
			_clear_note_later())

## ESC cancels without touching the binding. Otherwise: refuse a key already bound to a
## DIFFERENT action rather than stealing it -- the same "report, don't silently take"
## rule _set_cue_key uses for marker keys.
func _finish_rebind(keycode: int) -> void:
	var action := _awaiting_rebind
	_awaiting_rebind = ""
	# No capture was open, or one for an action that no longer exists. Without this the
	# line below writes _keybinds[""] = keycode, and that junk entry then shadows a real
	# binding in _action_for_key -- whichever comes first in the dictionary wins, so a
	# perfectly good key silently stops doing anything and nothing on screen says why.
	if not KEYBIND_SPEC.has(action):
		return
	if keycode == KEY_ESCAPE:
		_refresh_rebind_btn(action)
		return
	var clash := _action_for_key(keycode)
	if not clash.is_empty() and clash != action:
		_note = "  //  %s ALREADY BOUND TO %s" % [_key_label(keycode), KEYBIND_SPEC[clash][0]]
		_clear_note_later()
		_refresh_rebind_btn(action)
		return
	_keybinds[action] = keycode
	_sync_input_map()
	_refresh_rebind_btn(action)
	_save()

## Takes every bound key away from the built-in ui_* actions that would otherwise eat it.
##
## These keys are matched by _action_for_key in _unhandled_input, which only ever sees an
## event the focused Control did not consume first -- and SPACE is ui_accept, the arrows
## are ui_left/right/up/down. So with a list or a slider focused, PAUSE and SEEK were
## delivered to the widget and never reached the transport at all. _drop_focus covers
## Buttons; this covers everything else, and it is the only place the InputMap is touched,
## so re-running it after a rebind is what keeps the two in step.
##
## Rebuilt from scratch each time rather than patched: an old binding's event has to come
## OUT of the ui_* action when the key moves, and erase-then-reapply is one rule instead
## of two.
const UI_ACTIONS_GUARDED := ["ui_accept", "ui_select", "ui_left", "ui_right", "ui_up",
	"ui_down", "ui_cancel", "ui_focus_next", "ui_focus_prev"]

var _ui_events_default := {}   # ui action -> its events as they were at boot

func _sync_input_map() -> void:
	# Snapshot first, once. These are engine built-ins, so they live in InputMap's own
	# defaults and NOT in project.godot -- reading them back from ProjectSettings returns
	# nothing and would empty every action it touched. The snapshot is also what makes a
	# second pass idempotent: without it, each sync would strip events the previous one
	# had already removed and the action would never recover a key that got rebound away.
	if _ui_events_default.is_empty():
		for ui in UI_ACTIONS_GUARDED:
			if InputMap.has_action(ui):
				_ui_events_default[ui] = InputMap.action_get_events(ui)
	var taken := {}
	for action in _keybinds:
		taken[int(_keybinds[action])] = true
	for ui in _ui_events_default:
		InputMap.action_erase_events(ui)
		for ev in _ui_events_default[ui]:
			var code: int = 0
			if ev is InputEventKey:
				code = ev.keycode if ev.keycode != 0 else ev.physical_keycode
			if code != 0 and taken.has(code):
				continue
			InputMap.action_add_event(ui, ev)

static func _key_label(keycode: int) -> String:
	return OS.get_keycode_string(keycode).to_upper()

func _refresh_rebind_btn(action: String) -> void:
	var btn: Button = _rebind_btns.get(action)
	if btn:
		btn.text = "[ %s ]" % _key_label(_keybinds[action])

## The label doubles as a legend for the format it switches to, because "SHOW MS: ON"
## says nothing about what the transport is about to look like.
func _refresh_show_ms() -> void:
	if is_instance_valid(_show_ms_btn):
		_show_ms_btn.text = "[*] ON  (MM:SS:MS)" if _show_ms else "[ ] OFF  (MM:SS)"

func _refresh_clock_btn() -> void:
	if is_instance_valid(_clock_btn):
		_clock_btn.text = "12 HOUR (AM/PM)" if _clock_12h else "24 HOUR (MILITARY)"

# --- TBS detached window ---------------------------------------------------
## The settings screen pops out into its own OS window, so it can sit on a second
## monitor while the player keeps the main screen.
##
## This is a REAL OS window on all three platforms, and that is not automatic: Godot
## embeds Window nodes inside the main viewport unless the root viewport says
## otherwise. `display/window/subwindows/embed_subwindows=false` in project.godot is
## what makes it native. There is no per-window override -- it is a root-viewport
## property, so the setting is global and the FileDialog on the FOLDERS tab becomes a
## native window too. That is the trade, and it reads better on every platform.
## Sized for the whole settings screen: ten rows of controls, and room left over so a
## torn-off copy is not a letterbox.
const TBS_WIN_SIZE := Vector2i(640, 620)
## The eight fixed rows need roughly 300 px; below this the list is squeezed to nothing.
## Resizing is otherwise unrestricted -- the window is meant to be dragged to another
## display and left there.
const TBS_WIN_MIN := Vector2i(430, 470)

var _tbs_home: Control          # the scroller's column: home for the rows while attached
var _tbs_tab: Control           # the tab itself, which is what the TabContainer indexes
var _tbs_col: VBoxContainer     # the window-side column they live in while detached
var _tbs_win: Window
var _tbs_btn: Button

## Moves everything on the TBS screen between the tab and the detached window. Measured,
## crossing into another Window:
##
##   reparent() called ON a node        -> its %UniqueName survives, both directions
##   node carried inside a moved parent -> its %UniqueName is lost, permanently
##
## Since _group_settings, what moves is the search row and the Group_* sections, and every
## row rides inside one. The rows keep their owner -- and so their %UniqueNames -- only
## because the sections are owned by the scene root too: reparent() restores the owner of
## every descendant that shares the MOVED node's owner, and nothing else. With ownerless
## sections one open of TBS lost all nine of %Fade %FadeMs %DelayMs %FeedSize %MaxFps
## %BeatTrack %Boost %BoostLabel %Layout for the session (9/9 -> 0/9, and closing did not
## bring them back); the next FADE click or MAX FPS commit was a null access, which halts a
## DEBUG run in the editor's debugger.
##
## keep_global_transform is false: a Control's screen position means nothing once it is
## inside a different window.
static func _move_rows(from: Node, to: Node) -> void:
	for row in from.get_children():   # a snapshot, safe to reparent while iterating
		row.reparent(to, false)

func _setup_tbs_window() -> void:
	# The TBS tab comes off the tab bar. Everything that was on it lives in the detached
	# window now, and a tab holding nothing but a "detached" notice is a dead click.
	#
	# Hidden rather than deleted, deliberately: the node is where the rows go home to
	# when the window is closed. Parking them on a hidden tab costs nothing and keeps
	# every %UniqueName alive, whereas reparenting the tab itself somewhere else would
	# carry all thirteen of them across and silently break the lot -- see _move_row.
	# _tbs_tab, not _tbs_home: since the rows moved into a ScrollContainer, _tbs_home is
	# the column INSIDE that scroller and the TabContainer knows nothing about it --
	# asking for its tab index returned -1 and set_tab_hidden(-1) took a null child.
	_tabs.set_tab_hidden(_tabs.get_tab_idx_from_control(_tbs_tab), true)

	_tbs_btn = Button.new()
	_tbs_btn.name = "TbsScreen"
	_tbs_btn.pressed.connect(_open_tbs_window)
	# directly above REBOOT, which is destructive and stays the last control on the tab
	var stats_tab := %Reboot.get_parent()
	stats_tab.add_child(_tbs_btn)
	stats_tab.move_child(_tbs_btn, %Reboot.get_index())
	_refresh_tbs_button()

## Already open means raise it, never spawn a second. grab_focus() on a Window asks the
## window manager to bring it forward, which is the only portable way to say "it is over
## there" -- on macOS especially, a second instance would be the wrong answer.
func _open_tbs_window() -> void:
	if is_instance_valid(_tbs_win):
		_tbs_win.grab_focus()
		return

	var win := Window.new()
	win.name = "TbsWindow"
	win.title = "SOUNDSCAPE // TBS"
	win.size = TBS_WIN_SIZE
	win.min_size = TBS_WIN_MIN
	win.unresizable = false
	# Neither transient nor exclusive. A transient window is pinned above its parent and
	# on macOS follows it between spaces; exclusive would block input to the player
	# while it is open. Both defeat the purpose of a window you park and leave.
	win.transient = false
	win.exclusive = false
	# The theme carries the IBM BIOS font and every stylebox in one property. Skins
	# mutates those stylebox resources in place rather than rebuilding the theme, so the
	# detached window follows a skin change with no extra wiring.
	win.theme = theme
	win.close_requested.connect(_close_tbs_window)
	add_child(win)
	_enable_window_fullscreen_toggle(win)   # every detached window answers F11 the same way

	# A Window paints no background of its own -- without this the panel floats on the
	# viewport clear colour. Reusing the ROOT's stylebox INSTANCE rather than a copy is
	# what keeps the chassis colour in step when the skin changes.
	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	chassis.add_child(pad)
	# The detached window had NO scroller: the tab got one when the settings outgrew it, and
	# this window -- which holds the same rows and can be dragged smaller than the tab ever is
	# -- was left with a plain column, so anything past the bottom was simply unreachable.
	var scroll := ScrollContainer.new()
	scroll.name = "TbsWinScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	pad.add_child(scroll)
	# leave a marker behind so the tab does not just lose a third of itself
	_tbs_col = VBoxContainer.new()
	_tbs_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tbs_col.add_theme_constant_override("separation", 4)
	scroll.add_child(_tbs_col)
	_move_rows(_tbs_home, _tbs_col)
	_wheel_through(_tbs_col)
	_wheel_scrolls(scroll)

	_tbs_win = win
	win.show()
	# Centred on the USABLE rect, not the raw screen rect: move_to_center() centres on
	# the full display and lands 36 px low here, half the taskbar's height. The usable
	# rect excludes the Windows taskbar, the macOS menu bar and Linux panels alike, and
	# current_screen keeps it on the display the window actually opened on rather than
	# flinging it back to the primary monitor.
	var scr := DisplayServer.screen_get_usable_rect(win.current_screen)
	win.position = _on_screen(scr, win.size)
	_refresh_tbs_button()

## The window's own close button, and nothing else. Closing a sub-Window never reaches
## the main window's NOTIFICATION_WM_CLOSE_REQUEST, so this cannot quit the application
## -- but the panel has to come home BEFORE the window is freed, or queue_free() takes
## the whole settings screen down with it.
func _close_tbs_window() -> void:
	if not is_instance_valid(_tbs_win):
		return
	_move_rows(_tbs_col, _tbs_home)
	_tbs_col = null
	var win := _tbs_win
	_tbs_win = null   # cleared first, so a re-entrant close_requested is a no-op
	win.queue_free()
	_refresh_tbs_button()

func _refresh_tbs_button() -> void:
	if is_instance_valid(_tbs_btn):
		_tbs_btn.text = "[ TBS * ]" if is_instance_valid(_tbs_win) else "[ TBS ]"


# --- tear-off tabs ---------------------------------------------------------
## Any tab can be dragged out of the dock and becomes its own OS window; closing that
## window puts it back where it was. Same native-window machinery as the settings screen,
## and the same requirement on project.godot's embed_subwindows=false.
## Preferred size on a landscape display, and on a portrait one. Both are only a
## starting point: the real minimum comes from the panel itself, and the whole thing is
## clamped to the screen it opens on.
const TEAR_WIN_SIZE := Vector2i(620, 720)
const TEAR_WIN_SIZE_V := Vector2i(560, 1000)
## Padding inside a torn-off window, normal and compact. A narrow window spends its width
## on content, not on chrome -- 12 px of horizontal inset is 3% of a 380 px window.
const TEAR_PAD := 6
const TEAR_PAD_TIGHT := 1
## Below this width a torn-off window switches to the compact padding.
const TEAR_TIGHT_BELOW := 520

var _drag_tab := -1     # tab index the current drag started on, -1 when not dragging
var _drag_dock: TabContainer   # which dock that tab was in: _tabs or %DeckADock
var _torn := {}         # panel Control -> {title, index, window, pad, home}
## Canonical tab order: Control -> position. A stored absolute index goes stale the
## moment a SECOND tab is torn off, because the first one leaving shifted everything
## after it -- restoring both then put EQ and FX back the wrong way round. Sorting the
## whole bar against this map is order-independent, however many are out at once.
## Every tab's canonical slot in Tabs. Keyed by the Control rather than by its NodePath
## on purpose: a torn-off tab's path changes the moment it is reparented into its window,
## which is exactly when the map still has to resolve, and a node reference survives that
## move where a path does not.
var _tab_home_indices := {}

func _setup_tear_off() -> void:
	# Godot's own reorder drag is what produces the drag event at all; without it a tab
	# is not draggable and nothing below ever fires. Reordering inside the bar comes free.
	_tabs.drag_to_rearrange_enabled = true
	%DeckADock.drag_to_rearrange_enabled = true
	# a deliberate reorder becomes the new canonical order, so restoring a torn-off tab
	# never undoes an arrangement the user chose
	_tabs.active_tab_rearranged.connect(func(_to: int) -> void: _capture_tab_order())
	# NOTE: the initial capture is NOT done here. This runs before _setup_rack_tab builds
	# the FX tab, so capturing now would leave FX out of the map and sort it to the end of
	# the bar every time it was torn off and put back. _ready captures after the FX tab.

func _capture_tab_order() -> void:
	# A tab that is out -- torn off, or over in %DeckADock -- is NOT in the container, and
	# clearing the map wholesale would drop it and sort it to the far end when it came back.
	# So the absent keep their slots untouched, and the tabs still in the bar are dealt the
	# SAME set of slots they already held, in their new order. The old version nudged one
	# absent tab half a slot ahead of its successor; with DUAL DECK MODE holding two tabs out
	# for a whole session, that half slot drifted further forward on every reorder.
	var top := -1.0
	for panel in _tab_home_indices:
		top = maxf(top, float(_tab_home_indices[panel]))
	var slots: Array[float] = []
	for i in _tabs.get_tab_count():
		var panel := _tabs.get_tab_control(i)
		if _tab_home_indices.has(panel):
			slots.append(float(_tab_home_indices[panel]))
		else:
			top += 1.0   # a tab the map has never seen joins after everything it knows
			slots.append(top)
	slots.sort()
	for i in _tabs.get_tab_count():
		_tab_home_indices[_tabs.get_tab_control(i)] = slots[i]

## Puts every attached tab back into canonical order. Torn-off panels are simply absent
## from the container, so they need no special case -- they slot back in when they return.
func _restore_tab_order(dock: TabContainer = null) -> void:
	if not dock:
		dock = _tabs
	var kids := dock.get_children()
	kids.sort_custom(func(a: Node, b: Node) -> bool:
		return float(_tab_home_indices.get(a, 999)) < float(_tab_home_indices.get(b, 999)))
	for i in kids.size():
		dock.move_child(kids[i], i)

## Moves one tab into the other dock. The title is carried by hand (a TabContainer names a new
## tab after its node), and the tab lands in canonical order there, the order both docks share.
func _move_tab(panel: Control, to: TabContainer) -> void:
	var from := panel.get_parent() as TabContainer
	var title := from.get_tab_title(from.get_tab_idx_from_control(panel))
	panel.reparent(to, false)
	_restore_unique_names(panel)
	_restore_tab_order(to)
	var at := to.get_tab_idx_from_control(panel)
	to.set_tab_title(at, title)
	to.current_tab = at

## F11 fullscreens THIS window specifically, not the main one -- a torn-off tab is a
## real OS window of its own, and pressing F11 while it has focus should do what F11
## always does, rather than nothing (or worse, silently hitting the main window behind
## it). window_input fires for raw input local to this Window regardless of which
## control inside it has focus, so no per-window script is needed to catch the key.
##
## A fresh Window never boots into exclusive fullscreen the way the main one does, so
## none of _toggle_window_fullscreen's MAXIMIZED-first workaround applies here -- a
## plain WINDOWED/FULLSCREEN flip is the whole fix.
func _enable_window_fullscreen_toggle(win: Window) -> void:
	win.window_input.connect(func(e: InputEvent) -> void:
		if not (e is InputEventKey and e.pressed and not e.is_echo()):
			return
		if _action_for_key(e.keycode) != "fullscreen":
			return
		win.mode = Window.MODE_WINDOWED if win.mode == Window.MODE_FULLSCREEN \
			else Window.MODE_FULLSCREEN
		win.set_input_as_handled())

## Pulls one tab out of the dock into its own window.
##
## The panel is reparented directly, never wrapped in a carrier: measured, reparent()
## keeps a moved node's whole subtree of %UniqueNames alive as long as that node has an
## owner, and every tab in player.tscn does. The FX tab is built at runtime and has no
## owner, which is why _restore_unique_names runs afterwards regardless -- it costs a
## walk of one panel and removes the whole class of "this tab works, that one crashes".
func _tear_off_tab(from: TabContainer, idx: int) -> void:
	if idx < 0 or idx >= from.get_tab_count():
		return
	var panel := from.get_tab_control(idx)
	if not panel or _torn.has(panel):
		return

	var title := from.get_tab_title(idx)
	var win := Window.new()
	win.name = "Tear%s" % panel.name
	win.title = "SOUNDSCAPE // %s" % title
	win.unresizable = false
	win.transient = false     # independent: it can live on another monitor
	win.exclusive = false     # and must not block the player while it is open
	win.theme = theme         # font + every stylebox, and Skins repaints it for free
	add_child(win)
	_enable_window_fullscreen_toggle(win)

	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	var pad := MarginContainer.new()
	chassis.add_child(pad)
	# Window header: the title again, and the way back. Closing the window already
	# re-docks the tab, but a window's X reads as "throw this away" -- a button that says
	# DOCK is the one affordance that says the panel is going home rather than being lost.
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	pad.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	var caption := Label.new()
	caption.text = "[ %s ]" % title
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.theme_type_variation = &"Green"
	head.add_child(caption)
	var dock := Button.new()
	dock.text = "DOCK"
	dock.pressed.connect(_reattach_tab.bind(panel))
	head.add_child(dock)

	# Measured with the panel still out: a container's combined minimum does not update
	# until the frame after a child arrives, so asking the chassis afterwards returns
	# only its own border and margins (12 px) and the floor comes out useless.
	_tear_pad(pad, TEAR_WIN_SIZE.x)
	var chrome: Vector2 = chassis.get_combined_minimum_size()

	# reparenting out of a TabContainer removes the tab and its title outright
	_torn[panel] = {"title": title, "index": idx, "window": win, "pad": pad, "home": from}
	panel.reparent(col, false)
	# A TabContainer stretches its tab over the whole page whatever the size flags say; a VBox
	# hands a child that does not expand only its MINIMUM height. Without this every tab came
	# out squeezed to its minimum -- TRACKS 136 of 955 px, TBS 0 -- with its list, tree or
	# scroller collapsed to nothing. TabContainer reads FILL, not EXPAND, so docking needs no undo.
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_restore_unique_names(panel)
	win.close_requested.connect(_reattach_tab.bind(panel))

	# Size AFTER the panel is inside, because the numbers come from the panel. Measured,
	# the tabs need 532 / 480 / 412 / 336 px of width -- a fixed 380 px floor let EQ be
	# shrunk 152 px past what it can draw in, and the content simply clipped off the
	# right edge with nothing to indicate it.
	var scr := DisplayServer.screen_get_usable_rect(win.current_screen)
	var portrait_screen: bool = scr.size.x < scr.size.y
	# the header row is part of what the window has to fit, measured rather than assumed
	_fit_tear_window(win, pad, panel.get_combined_minimum_size() + chrome
		+ Vector2(0.0, head.get_combined_minimum_size().y + 4.0), portrait_screen)
	win.show()
	# re-fit whenever the user resizes it, so the padding follows the actual width
	win.size_changed.connect(func() -> void:
		if is_instance_valid(win):
			_tear_pad(pad, win.size.x))
	scr = DisplayServer.screen_get_usable_rect(win.current_screen)
	win.position = _on_screen(scr, win.size)

## Centred on the screen, then clamped so the whole window -- title bar included -- is
## inside the usable rect. Centring alone goes NEGATIVE the moment the window is larger
## than the screen, which puts the title bar above the top edge where it cannot be
## grabbed and the window cannot be moved or closed.
static func _on_screen(scr: Rect2i, size: Vector2i) -> Vector2i:
	var pos := scr.position + (scr.size - size) / 2
	return Vector2i(
		clampi(pos.x, scr.position.x, maxi(scr.position.x, scr.end.x - size.x)),
		clampi(pos.y, scr.position.y, maxi(scr.position.y, scr.end.y - size.y)))

## Gives a torn-off window a size and a floor that come from what it actually holds.
##
## `need` is the panel's own combined minimum plus the chassis chrome, both measured at
## the call site rather than guessed -- the tabs really do want 532 / 480 / 412 / 336 px
## of width, and the fixed 380 px floor this replaces let EQ be dragged 152 px narrower
## than it can draw in, clipping its right-hand column away with no indication.
##
## On a portrait display the preferred shape is taller and narrower, and everything is
## finally clamped to the usable rect so a window can never open larger than the screen
## it lands on. That clamp is the whole vertical-monitor story: a 620x720 default is
## fine on 1920x1080 and fine on 1080x1920, but not on a small vertical panel.
func _fit_tear_window(win: Window, pad: MarginContainer, need: Vector2, portrait_screen: bool) -> void:
	var want: Vector2i = TEAR_WIN_SIZE_V if portrait_screen else TEAR_WIN_SIZE
	var scr := DisplayServer.screen_get_usable_rect(win.current_screen)
	# The content floor is CAPPED to the screen. It used to be taken from the panel's
	# combined minimum with nothing above it, so a wide tab could demand a window bigger
	# than the display -- which cannot be resized back down and cannot be dragged fully
	# into view, i.e. exactly the "detached window will not stay visible or placeable"
	# report. A window slightly narrower than its content clips; one larger than the
	# screen is unusable, so the screen wins.
	win.min_size = Vector2i(
		mini(ceili(need.x), maxi(scr.size.x - 80, 320)),
		mini(ceili(maxf(need.y, 240.0)), maxi(scr.size.y - 120, 240)))
	win.size = Vector2i(
		clampi(want.x, win.min_size.x, maxi(scr.size.x - 40, win.min_size.x)),
		clampi(want.y, win.min_size.y, maxi(scr.size.y - 60, win.min_size.y)))
	_tear_pad(pad, win.size.x)

## Compact padding on a narrow window: 6 px each side is invisible at 620 px wide and
## costs 3% of the usable width at 380.
static func _tear_pad(pad: MarginContainer, width: int) -> void:
	var m: int = TEAR_PAD_TIGHT if width < TEAR_TIGHT_BELOW else TEAR_PAD
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, m)


## Closing a torn-off window puts its tab back. Closing a sub-Window never reaches the
## main window's NOTIFICATION_WM_CLOSE_REQUEST, so this cannot quit the application --
## but the panel has to be reparented home BEFORE the window is freed, or queue_free
## takes the whole tab down with it.
func _reattach_tab(panel: Control) -> void:
	var rec: Dictionary = _torn.get(panel, {})
	if rec.is_empty():
		return
	_torn.erase(panel)
	# back to the dock it came out of -- unless that is deck A's, folded away since
	var dock: TabContainer = rec.get("home", _tabs)
	if dock != _tabs and not _dual_deck:
		dock = _tabs
	panel.reparent(dock, false)
	# straight to its canonical slot first, then the full re-sort so the tabs that never
	# left keep their order too -- move_child alone puts this one right and nothing else
	var home := int(_tab_home_indices.get(panel, rec.get("index", dock.get_child_count() - 1)))
	dock.move_child(panel, clampi(home, 0, dock.get_child_count() - 1))
	_restore_tab_order(dock)
	_restore_unique_names(panel)
	# the tab title defaults to the node name; restore whatever it actually was
	var back := dock.get_tab_idx_from_control(panel)
	if back >= 0:
		dock.set_tab_title(back, rec["title"])
		dock.current_tab = back
	var win: Window = rec["window"]
	if is_instance_valid(win):
		win.queue_free()

## Re-registers %UniqueName on a moved subtree.
##
## Insurance, not ceremony. Measured: a reparented node keeps its descendants'
## registrations when it has an owner and loses them when it does not, and a lost
## registration fails silently -- %EqMode simply stops resolving and the next
## _refresh_eq() call dies on a null. Toggling the flag re-registers, so doing it
## unconditionally makes tear-off safe for scene tabs and runtime-built ones alike.
static func _restore_unique_names(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.unique_name_in_owner:
			n.unique_name_in_owner = false
			n.unique_name_in_owner = true
		for c in n.get_children():
			stack.append(c)


# --- crossfade -------------------------------------------------------------
## The transition itself is DeckController's; these are the limits the TBS fields clamp
## to, and the levels the transport writes directly when it is not fading.
const ACTIVE_DB := DeckController.ACTIVE_DB
const SILENT_DB := DeckController.SILENT_DB
const FADE_MS_MIN := 100
const FADE_MS_MAX := 10000
const DELAY_MS_MIN := DeckController.DELAY_MS_MIN
const DELAY_MS_MAX := 2000
const MIN_FADE_IN_MS := DeckController.MIN_FADE_IN_MS

func _setup_fade() -> void:
	%Fade.pressed.connect(func() -> void:
		_decks.fade_on = not _decks.fade_on
		%Fade.text = "FADE: %s" % ("ON" if _decks.fade_on else "OFF")
		_save())
	%FadeMs.text_submitted.connect(func(_s: String) -> void: _commit_fade_ms())
	%FadeMs.focus_exited.connect(_commit_fade_ms)
	%DelayMs.text_submitted.connect(func(_s: String) -> void: _commit_delay_ms())
	%DelayMs.focus_exited.connect(_commit_delay_ms)
	%Fade.text = "FADE: %s" % ("ON" if _decks.fade_on else "OFF")
	%FadeMs.text = str(_decks.fade_ms)
	%DelayMs.text = str(_decks.delay_ms)

## Clamped on commit rather than per keystroke, so typing "2" on the way to "2500"
## does not get rewritten to the 100 ms floor under the cursor.
func _commit_fade_ms() -> void:
	_decks.fade_ms = clampi(int(%FadeMs.text), FADE_MS_MIN, FADE_MS_MAX)
	%FadeMs.text = str(_decks.fade_ms)
	%DelayMs.text = str(_decks.delay_ms)
	_save()

## Equal-length ramps on one deck's two players. The deck's live reference swaps at the
## audible moment, so the transport, scrub and spectrum follow the incoming track.
##
## Selecting a third track mid-fade is safe with only two players: the still-fading
## player becomes the new incoming one, its volume is reset explicitly, and the killed
## tween's cleanup callback is simply never needed.
##
## `deck` is explicit and everything below belongs to it -- its pair, its live player, its
## tween -- so a fade on the parked deck and a fade on the live deck never touch each other.
func _crossfade(stream: AudioStream, deck: int) -> void:
	_decks.crossfade(stream, deck, func(d: int, incoming: AudioStreamPlayer) -> void:
		# the deck's own live reference already moved; the transport, scrub and analyser
		# hand over only when this deck is the one being looked at
		_sync_attach(d, incoming)
		if _engine.deck == d:
			_decks.audio = incoming
			_director.attach(_decks.audio))

func _fade_running(deck: int) -> bool:
	return _decks.fading(deck)

func _kill_fade(deck: int) -> void:
	_decks.kill_fade(deck)

## The player a deck is sounding through: `_decks.audio` for the live deck, the recorded live
## player -- or the primary, if it never played -- for the parked one.
func _live_player(deck: int) -> AudioStreamPlayer:
	return _decks.live(deck)

# --- addressing ONE deck ----------------------------------------------------------------------
## Everything above this line works on the deck the transport bar is showing -- that is what
## _bar_deck() is for, and it is the right model for a keyboard and a mouse, where there is one
## pointer and one focus. A two-deck control surface is not that: the S2's right-hand play button
## means DECK B whatever the screen is looking at, and taking focus on every press would drag the
## EQ panel, the crate and the transport bar back and forth under the user's hands all night.
##
## So these are the same operations addressed by index instead. They deliberately do NOT touch
## focus, the video player (one picture, which belongs to the bar deck) or the crossfader.
func _deck_path(deck: int) -> String:
	return _current if deck == _engine.deck else _decks.deck_cur[deck]

func _deck_len(deck: int) -> float:
	var pl := _live_player(deck)
	return pl.stream.get_length() if pl and pl.stream else 0.0

func _deck_pos(deck: int) -> float:
	var pl := _live_player(deck)
	return pl.get_playback_position() if pl else 0.0

## SEEKING A PAUSED DECK, which Godot will not do on its own.
##
## AudioStreamPlayer.seek() on a paused player is DISCARDED -- not deferred, not applied on
## resume: measured, a seek to 60 s while paused left the position at 30 s and resuming carried
## on from 30 s as though nothing had been asked. That is why scrubbing a stopped deck never
## worked here, and it is the whole of what stood between a jog wheel and a cue point.
##
## Lifting the pause for the seek and putting it straight back, inside one frame, does land it:
## the same test then reports 45.005 for a seek to 45, the deck is still paused afterwards, and a
## run of small steps accumulates exactly. The audio thread never gets a frame to sound, so there
## is nothing to hear.
func _seek_deck(deck: int, t: float) -> void:
	var pl := _live_player(deck)
	if not pl or not pl.stream:
		return
	var target := clampf(t, 0.0, _deck_len(deck))
	if pl.stream_paused:
		pl.stream_paused = false
		pl.seek(target)
		pl.stream_paused = true
	elif not pl.playing:
		# A PARKED DECK -- loaded and never started, which is exactly the deck you want to jog
		# while you find its first beat. seek() is ignored on a stopped player the same way it
		# is on a paused one, and play() is the only call that takes a position; pausing in the
		# same frame means it holds there without sounding. The deck reads PAUSED afterwards,
		# which is what being cued up IS.
		pl.play(target)
		pl.stream_paused = true
	else:
		pl.seek(target)
	if deck == _bar_deck():
		_scrub_to(target)   # the bar is showing this deck, so the overlay has to follow

## Pushes the scrub bar and its overlay to a position without waiting for _process to notice.
## A jog wheel moves in steps far smaller than the bar's own repaint, and a playhead that catches
## up a frame later reads as a wheel that is not connected to anything.
func _scrub_to(t: float) -> void:
	var span := _len()
	if span > 0.0:
		_scrub.value = clampf(t / span * 100.0, 0.0, 100.0)
	_cue_overlay.queue_redraw()

## PAUSED IS TESTED FIRST, for the reason _state() gives: AudioStreamPlayer.playing goes false
## while stream_paused is set, so asking "is it playing" about a paused deck answers no and the
## deck reads as STOPPED.
func _deck_state(deck: int) -> String:
	var pl := _live_player(deck)
	if not pl or not pl.stream:
		return "EMPTY"
	if pl.stream_paused:
		return "PAUSED"
	return "PLAYING" if pl.playing else "STOPPED"

## Play/pause ONE deck. The bar deck's version goes through _toggle() so the video player and the
## fades come with it; any other deck is the player alone.
func _toggle_deck(deck: int) -> void:
	if deck == _bar_deck():
		_toggle()
		return
	var pl := _live_player(deck)
	if not pl or not pl.stream:
		return
	# Same trap as _deck_state, and worse here: `playing` is false while paused, so asking it
	# first sent a paused deck down the "not playing" arm and pl.play() RESTARTED the track from
	# the beginning instead of resuming it.
	if pl.stream_paused:
		pl.stream_paused = false
	elif pl.playing:
		pl.stream_paused = true
	else:
		pl.play()
	_refresh_deck_ui()

## NEXT / PREVIOUS for one deck, walked across that crate's own visible list rather than the
## engine queue -- the queue belongs to the driven deck, and this must work on the other one.
func _deck_step_track(deck: int, delta: int) -> void:
	var shown: Array = _library.shown[deck]
	if shown.is_empty():
		return
	var at := shown.find(_deck_path(deck))
	var to := posmod(at + delta, shown.size()) if at >= 0 else 0
	_open_deck(deck, str(shown[to]))

func _commit_delay_ms() -> void:
	_decks.delay_ms = clampi(int(%DelayMs.text), DELAY_MS_MIN, DELAY_MS_MAX)
	%DelayMs.text = str(_decks.delay_ms)
	_save()

## Every stylebox state a Button can draw. Overriding only normal/hover/pressed is what
## made gradient previews read as solid white bars: `focus` and `hover_pressed` were left
## on the theme, and BOTH of those are a near-white opaque box under this theme
## (SB_btn is the WIN98 button face at 0.886 grey; Godot's built-in hover_pressed is
## white). They draw OVER the swatch, so the ramp was there the whole time with a white
## rectangle painted on top of it. Overriding the full set is the fix, and it is the only
## one that holds for a toggle swatch, which is the state combination that shows both.
const BUTTON_BOX_STATES := ["normal", "hover", "pressed", "focus", "hover_pressed",
	"disabled"]

static func _apply_swatch(btn: Button, sb: StyleBox) -> void:
	for state in BUTTON_BOX_STATES:
		btn.add_theme_stylebox_override(state, sb)

## Gradient chip for the rainbow option. A StyleBoxFlat holds a single colour, so the
## swatch has to be a stretched texture to show what the mode actually does.
func _rainbow_swatch() -> StyleBoxTexture:
	var img := Image.create(32, 1, false, Image.FORMAT_RGBA8)
	for x in 32:
		img.set_pixel(x, 0, Color.from_hsv(float(x) / 32.0, 0.85, 1.0))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	return sb


# --- VISUAL FEED SIZE ------------------------------------------------------
enum Feed { LARGE, MEDIUM, SMALL, GONE, FULLSCREEN, CUSTOM }
## CUSTOM is appended rather than slotted in beside the other sizes on purpose: the mode
## is persisted as an integer, and inserting it earlier would silently reinterpret every
## saved feed_size in every existing config.
const FEED_NAMES := ["LARGE", "MEDIUM", "SMALL", "GONE", "FULLSCREEN", "CUSTOM"]
## Left-column stretch against the sidebar's 1.0. GONE and FULLSCREEN are visibility
## states rather than ratios, so their entries are never read.
const FEED_RATIO := [3.0, 1.5, 0.5, 0.0, 0.0, 0.0]   # CUSTOM's entry is never read

func _setup_feed() -> void:
	# Every mode is draggable now (see _apply_feed), not only CUSTOM -- CUSTOM is what a
	# drag leaves behind, not a thing to gate on beforehand.
	%Workspace.dragged.connect(func(_offset: int) -> void:
		if _feed == Feed.GONE or _feed == Feed.FULLSCREEN:
			return
		# stored from the resulting geometry rather than from the offset the signal
		# carries, because that offset is only meaningful against this screen's size
		var span: float = %Workspace.size.y if _portrait else %Workspace.size.x
		var first: float = %LeftColumn.size.y if _portrait else %LeftColumn.size.x
		if span > 1.0:
			_feed = Feed.CUSTOM   # the geometry a drag leaves behind, not a menu choice
			_split_frac = clampf(first / span, 0.05, 0.95)
			_save_soon())
	# CUSTOM is deliberately not offered here: it is what free-dragging any other mode
	# leaves behind, not something to pick from the menu.
	for i in FEED_NAMES.size():
		if i == Feed.CUSTOM:
			continue
		%FeedSize.add_item(FEED_NAMES[i], i)
	%FeedSize.item_selected.connect(func(i: int) -> void:
		if i == Feed.FULLSCREEN and _feed != Feed.FULLSCREEN:
			_feed_prev = _feed          # remembered so ESC has somewhere to return to
		_apply_feed(i)
		_save())
	_apply_feed(_feed)

func _apply_feed(mode: int) -> void:
	_feed = mode
	var full: bool = mode == Feed.FULLSCREEN
	var gone: bool = mode == Feed.GONE
	# the transport now sits in Main, not in the feed's column, so GONE can drop the
	# whole column and hand the workspace to the sidebar without taking the deck with it
	%LeftColumn.visible = not gone
	%ScreenPanel.visible = true
	%RightSidebar.visible = not full
	%TopHeaderBar.visible = not full
	%TickerBar.visible = not full
	%StatusBar.visible = not full
	%ScrubRow.visible = not full and _playbar_on
	%ControlDeck.visible = not full and _playbar_on
	_apply_dual_bars()
	# SplitContainer ignores size_flags_stretch_ratio -- it positions the divider from
	# split_offset instead -- so the preset sizes are translated into an offset, and
	# CUSTOM simply restores the one a drag last left it at.
	#
	# Every mode is draggable now: only GONE and FULLSCREEN have no meaningful divider
	# to grab (one side is gone, the other is chrome-off). dragger_visibility only
	# controls whether the grip is DRAWN -- measured, DRAGGER_HIDDEN with
	# dragging_enabled true still accepts the mouse, so both are gated together.
	var drag_ok: bool = not gone and not full
	%Workspace.dragging_enabled = drag_ok
	%Workspace.dragger_visibility = SplitContainer.DRAGGER_VISIBLE if drag_ok \
		else SplitContainer.DRAGGER_HIDDEN
	if mode == Feed.CUSTOM:
		_split_to_fraction(_split_frac)
	elif not gone and not full:
		var table: Array = FEED_RATIO_V if _portrait else FEED_RATIO
		# a stretch ratio of r puts the divider at r/(r+1) of the span
		var r: float = table[mode]
		if r > 0.0:
			_split_to_fraction(r / (r + 1.0))
	# the 6px chassis inset would leave a border in fullscreen
	for side in ["left", "top", "right", "bottom"]:
		%Margin.add_theme_constant_override("margin_" + side, 0 if full else 6)
	# CUSTOM has no row in the menu any more; leave whatever preset is still showing
	if mode != Feed.CUSTOM and %FeedSize.selected != mode:
		%FeedSize.selected = mode
	# nothing can see the feed while it is GONE: stop rendering its SubViewport and stop
	# stepping the visualizer, rather than paying for frames that are never shown
	(%VizBox.get_child(0) as SubViewport).render_target_update_mode = \
		SubViewport.UPDATE_ALWAYS if not gone else SubViewport.UPDATE_DISABLED
	# %VizBoxB is left to its container: it is hidden unless DUAL VISUAL is on, and forcing
	# UPDATE_ALWAYS here would render it behind that. _viz may be either half, so name both.
	%Viz.set_process(not gone)
	%VizB.set_process(not gone)
	%DeckAPanel.visible = _dual_deck and not full

## Puts the divider where a stretch ratio used to put it.
##
## split_offset is a delta from the container's own default split, and that default is
## whatever the children's minimum sizes imply -- it is not zero and not the midpoint.
## Rather than guess it, the current reading is inverted: the first child's size is
## `default + offset` within the clamps, so `default = size - offset` and the offset
## that lands the divider at `want` is `want - default`. Deferred because it needs a
## laid-out size to measure, and re-run on every resize so a preset mode keeps its
## proportion when the window changes.
func _split_to_fraction(frac: float) -> void:
	if frac <= 0.0 or frac >= 1.0:
		return
	_split_gen += 1
	var gen := _split_gen
	# Measured: the divider position is exactly `default + split_offset`, slope 1.0, with
	# `default` fixed by the children's minimum sizes (1427 px at a 1908 px workspace).
	# The catch is that `default` cannot simply be read, because offset 0 is ALREADY
	# clamped -- the sidebar is pinned at its 575 px floor there and reads 1325, a
	# 102 px lie. So this solves for it instead: with slope 1 the fixed-point iteration
	# lands exactly in one correction when the target is reachable, and stops itself the
	# moment the offset stops changing, which is what a clamped mode like LARGE does.
	for _pass in 4:
		# two frames per pass: the container re-sorts a frame after the offset is set,
		# and reading before it has is what made the first attempt land short
		await get_tree().process_frame
		await get_tree().process_frame
		if gen != _split_gen or not is_instance_valid(%Workspace):
			return   # a newer feed size superseded this one; drop it rather than fight
		var span: float = %Workspace.size.y if _portrait else %Workspace.size.x
		if span <= 1.0:
			return
		var first: float = %LeftColumn.size.y if _portrait else %LeftColumn.size.x
		var want: float = span * frac
		var default_pos: float = first - float(%Workspace.split_offset)
		var next_off := int(roundf(want - default_pos))
		if next_off == %Workspace.split_offset:
			return   # converged, or pinned against a minimum size and cannot go further
		%Workspace.split_offset = next_off


# --- CRT / MONO toggles ------------------------------------------------------
## %VizBox never loses its material object -- OFF nulls the material property, not the
## resource -- so toggling back on needs nothing rebuilt, just the same reference again.
func _apply_crt() -> void:
	if is_instance_valid(%VizBox):
		%VizBox.material = _crt_mat if _crt_on else null

## Deck DSP (T-BASS, BBE, the rack) stays untouched: MONO is a monitoring fold on the
## final Master output, not a mix decision, so switching it off hands back exactly the
## stereo image the rack built.
func _apply_mono() -> void:
	_engine.set_mono(_mono)


# --- VISUAL EQ WINDOW toggle --------------------------------------------------
## Tears %LeftColumn (the whole visual feed panel, screen + CRT pass) out into its own
## OS window, or puts it back. Same reparent-and-restore-unique-names idea the tab
## tear-off system uses -- %LeftColumn just is not a tab, so it gets its own small
## version rather than bending TabContainer machinery around a non-tab Control.
const VISUAL_WIN_SIZE := Vector2i(560, 420)

func _toggle_visual_window(on: bool) -> void:
	if on == is_instance_valid(_visual_win):
		return
	if on:
		_visual_home_index = %LeftColumn.get_index()
		var win := Window.new()
		win.name = "VisualEqWindow"
		win.title = "SOUNDSCAPE // VISUAL EQ"
		win.unresizable = false
		win.transient = false     # independent: it can live on another monitor
		win.exclusive = false     # and must not block the player while it is open
		# ON TOP, unlike every other window here, and the visualizer is why: it is the one panel
		# people put on a second screen and keep WATCHING while they work in something else. A
		# feed that disappears behind the browser it is playing under is not a feed.
		win.always_on_top = true
		win.theme = theme         # font + every stylebox, and Skins repaints it for free
		win.size = VISUAL_WIN_SIZE
		add_child(win)
		_enable_window_fullscreen_toggle(win)   # F11 here fullscreens the FEED, not the player
		_visual_win = win
		var chassis := PanelContainer.new()
		chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
		var root_sb: StyleBox = get("theme_override_styles/panel")
		if root_sb:
			chassis.add_theme_stylebox_override("panel", root_sb)
		win.add_child(chassis)
		%LeftColumn.reparent(chassis, false)
		_restore_unique_names(%LeftColumn)
		# the window's own close button re-docks, the same way a torn-off tab's does --
		# an X reading as "throw this away" would be wrong for a panel with no other way back
		win.close_requested.connect(func() -> void:
			_visual_windowed = false
			if is_instance_valid(_visual_win_btn):
				_visual_win_btn.button_pressed = false
				_refresh_visual_win_btn()
			_toggle_visual_window(false)
			_save())
		_centre_on_primary(win)
		win.show()
	else:
		if is_instance_valid(_visual_win):
			%LeftColumn.reparent(%Workspace, false)
			%Workspace.move_child(%LeftColumn,
				clampi(_visual_home_index, 0, %Workspace.get_child_count() - 1))
			_restore_unique_names(%LeftColumn)
			_visual_win.queue_free()
		_visual_win = null

func _refresh_visual_win_btn() -> void:
	if is_instance_valid(_visual_win_btn):
		_visual_win_btn.text = "[*] WINDOWED" if _visual_windowed else "[ ] DOCKED"

# --- DUAL DECK MODE -------------------------------------------------------------
## [DECK A WING | FEED | DECK B WING]. %DeckADock is a second TabContainer left of %Workspace,
## behind its own divider (%Body); TRACKS A and FX A move into it and the sidebar opens
## on TRACKS B. Both docks share one canonical tab order, tear off the same way, and take tabs
## dragged over from the other. Off, whatever is in deck A's dock goes back to the sidebar.
## EQ stays single and follows the deck being driven, as it always has.
func _set_dual_deck(on: bool) -> void:
	_dual_deck = on
	var dock: TabContainer = %DeckADock
	var tracks: Control = _tracks.get_parent()
	if on:
		for panel: Control in [tracks, _rack_boxes[0].get_parent().get_parent()]:   # box -> scroll -> FX A
			if _torn.has(panel):
				_reattach_tab(panel)   # out in its own window: home first, then into the wing
			if panel.get_parent() == _tabs:
				_move_tab(panel, dock)
		_tabs.current_tab = _tabs.get_tab_idx_from_control(_tracks_b.get_parent())   # mirrors TRACKS A on the left
		dock.current_tab = maxi(dock.get_tab_idx_from_control(tracks), 0)
	else:
		for panel: Control in dock.get_children():
			_move_tab(panel, _tabs)
		if tracks.get_parent() == _tabs:
			_tabs.current_tab = _tabs.get_tab_idx_from_control(tracks)
	_apply_feed(_feed)   # %DeckAPanel's visibility lives with the rest of the chrome
	if is_instance_valid(_dual_deck_btn):
		_dual_deck_btn.text = "[*] ON" if on else "[ ] OFF"
	if is_instance_valid(_split_btn):
		_split_btn.text = "[SPLIT]" if on else "SPLIT"
	_save()


# --- tab transition: top-to-bottom line scan ----------------------------------
## Seconds per revealed row at TAB FADE SPEED == 1.0. The field is a multiplier, not
## seconds, so "2x" reads the same regardless of the base value here.
const TAB_SCAN_BASE_SEC := 0.035

var _scan_tween: Tween
var _scan_rows: Array[CanvasItem] = []   # what the running scan is hiding, for cleanup

## Whichever tab becomes current -- picked from the tab bar, restored from a tear-off,
## or the one showing at boot -- is revealed one row at a time from the top.
##
## The old transition tweened the whole panel's modulate.a from 0 to 1, which is a
## modern crossfade and read as nothing else in this program does. Each row here SNAPS
## on, with no alpha ramp at all: the panel prints itself down the screen the way a
## terminal does. Rows rather than glyphs because a row is the unit a container already
## lays out -- a per-character reveal would mean re-typing every Label's text.
## A tab page that is off screen sleeps: PROCESS_MODE_DISABLED while it is not visible in the
## tree, INHERIT the moment it is. A TabContainer already hides the pages it is not showing, so
## they were never drawn; this stops them processing too. It keys on the page's own visibility
## rather than on tab_changed, so every way a page moves -- a tab click, a drag into the other
## dock, a torn-off window and back, DUAL DECK or the FULL feed folding deck A's dock away --
## lands in the same place. Nothing is rebuilt: a sleeping page keeps its text, scroll and
## selection, and waking it is one property.
static func sleep_hidden_pages(dock: TabContainer) -> void:
	for page in dock.get_children():
		if page is Control:
			var wake := func() -> void:
				page.process_mode = Node.PROCESS_MODE_INHERIT if page.is_visible_in_tree() \
					else Node.PROCESS_MODE_DISABLED
			page.visibility_changed.connect(wake)
			page.tree_entered.connect(wake)   # a reparent can change visibility while out of the tree
			wake.call()

func _setup_tab_fade() -> void:
	for dock: TabContainer in [_tabs, %DeckADock]:
		dock.tab_changed.connect(func(idx: int) -> void:
			_scan_in(dock.get_tab_control(idx)))

func _scan_in(panel: Control) -> void:
	# An interrupted scan must put its rows back FIRST: switching tabs mid-scan would
	# otherwise leave the previous panel's un-revealed rows parked at alpha 0 forever,
	# and that panel is still reachable from the tab bar.
	if _scan_tween and _scan_tween.is_valid():
		_scan_tween.kill()
	for row in _scan_rows:
		if is_instance_valid(row):
			row.modulate.a = 1.0
	_scan_rows.clear()
	if not is_instance_valid(panel):
		return
	# A tab whose whole body is one ScrollContainer has exactly one child, and scanning
	# a single row is just a snap. Descend until there is something to actually scan.
	var host: Node = panel
	while host.get_child_count() == 1 and host.get_child(0) is Control:
		host = host.get_child(0)
	for c in host.get_children():
		if c is CanvasItem:
			_scan_rows.append(c)
			(c as CanvasItem).modulate.a = 0.0
	if _scan_rows.is_empty():
		return
	var step := TAB_SCAN_BASE_SEC / clampf(_fade_speed, 0.05, 100.0)
	_scan_tween = create_tween()
	for row in _scan_rows:
		# delay-then-callback per row: a sequential Tween already chains these, so the
		# nth row lands at n * step with one tween rather than n timers
		_scan_tween.tween_callback(func() -> void:
			if is_instance_valid(row):
				row.modulate.a = 1.0).set_delay(step)


# --- chunky tab arrows --------------------------------------------------------
## A blocky right-pointing wedge, upscaled like the CURSOR_ART bitmap above -- real
## pixels at a low base resolution, not a smooth vector glyph. Flipped column-order
## for the left-pointing one, so one art table serves both.
const TAB_ARROW_ART := [
	"#....",
	"##...",
	"###..",
	"####.",
	"###..",
	"##...",
	"#....",
]
const TAB_ARROW_SCALE := 3

static func _chunky_arrow_texture(flip: bool) -> ImageTexture:
	var w := TAB_ARROW_ART[0].length()
	var h := TAB_ARROW_ART.size()
	var img := Image.create(w * TAB_ARROW_SCALE, h * TAB_ARROW_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var row: String = TAB_ARROW_ART[y]
		for x in w:
			if row[x] != "#":
				continue
			var px := (w - 1 - x) if flip else x
			for dy in TAB_ARROW_SCALE:
				for dx in TAB_ARROW_SCALE:
					img.set_pixel(px * TAB_ARROW_SCALE + dx, y * TAB_ARROW_SCALE + dy, Color.WHITE)
	return ImageTexture.create_from_image(img)

## Replaces the TabBar's stock scroll-arrow icons with the 80s/90s chunky glyphs above.
## Godot only draws these when the tab row overflows its width, which is exactly when
## a modern vector arrow would have looked out of place next to everything else here.
## Nine tabs do not fit a sidebar sitting on its 575 px floor, and the overflow answer
## Godot gives is two ~15 px scroll arrows -- which is how RECORD SET ended up
## effectively unreachable. Two things fix it together: shorter titles for the
## two worst offenders, and a width cap so no single tab can hog the bar.
##
## Titles are set here rather than by renaming the nodes, because the node name is what
## _tab_home_indices and the tear-off registry key on, and a rename would reshuffle the
## saved tab order. _reattach_tab restores the title from its own record, so a torn-off
## tab comes back with the short name intact.
const TAB_SHORT_TITLES := {
	"RECORD SET": "REC", "FOLDERS": "DIRS", "VISUAL": "VIS", "TRACKS A": "TRK A", "TRACKS B": "TRK B",
}
const TAB_MAX_WIDTH := 108

func _shorten_tab_titles() -> void:
	for dock: TabContainer in [_tabs, %DeckADock]:
		if dock.get_tab_bar():
			dock.get_tab_bar().max_tab_width = TAB_MAX_WIDTH
	for i in _tabs.get_tab_count():
		var t := _tabs.get_tab_title(i)
		if TAB_SHORT_TITLES.has(t):
			_tabs.set_tab_title(i, TAB_SHORT_TITLES[t])

func _setup_tab_arrows() -> void:
	var right := _chunky_arrow_texture(false)
	var left := _chunky_arrow_texture(true)
	for dock: TabContainer in [_tabs, %DeckADock]:
		var bar := dock.get_tab_bar()
		if not bar:
			continue
		bar.add_theme_icon_override("increment", right)
		bar.add_theme_icon_override("increment_highlight", right)
		bar.add_theme_icon_override("decrement", left)
		bar.add_theme_icon_override("decrement_highlight", left)


## ESC only means anything in FULLSCREEN, so the event is left alone otherwise -- the
## boot screen and any future dialog keep their own handling. A focused LineEdit/etc
## consumes the keypress before it ever reaches here, so typing into the search box is
## unaffected.
##
## ESC does whichever kind of "full screen" is currently on. The two are separate and
## stack: Feed.FULLSCREEN hides the program's own chrome, the window mode fills the
## monitor. ESC unwinds the chrome first, because that is the one the user most recently
## chose in almost every case.
func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if not k or not k.pressed:
		return
	# Held keys arrive again every OS repeat interval. Dropped here rather than in the
	# cue-jump branch alone, because every shortcut below is a one-shot or a toggle: a
	# held SPACE flickered play/pause at the repeat rate, a held jump key re-seeked the
	# track dozens of times a second and backed up a queue of seeks behind the mix.
	if k.is_echo():
		return
	# Typing wins, stated rather than relied upon. A VISIBLE focused LineEdit eats the key
	# before this ever runs, which is what has kept SEARCH typing out of the shortcuts and out
	# of the code buffer -- but a field that holds focus while hidden eats nothing, and then
	# every letter of a search would drive a shortcut. One line beats reasoning about which
	# fields can be in that state.
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	# CTRL+Z / CTRL+SHIFT+Z / CTRL+Y, ahead of the remappable table because they are not in it:
	# a modifier combination cannot be expressed in KEYBIND_SPEC, which stores one keycode per
	# action, and putting them there would mean somebody could rebind UNDO onto a bare letter
	# and lose it to the cheat buffer.
	if k.ctrl_pressed and (k.keycode == KEY_Z or k.keycode == KEY_Y):
		_cue_undo_step(k.keycode == KEY_Y or k.shift_pressed)
		get_viewport().set_input_as_handled()
		return
	# Fed BEFORE the shortcuts below and deliberately NOT consuming the event, so a letter
	# can drive its shortcut and advance a code in the same press -- see the note on
	# LOCAL_CODES.
	var ch := OS.get_keycode_string(k.keycode)
	if ch.length() == 1 and ch >= "A" and ch <= "Z":
		_push_code_key(ch)
	# Everything below is a remappable action (TBS -> KEYBINDS); _action_for_key is the
	# one place a keycode turns into a name, so a rebind takes effect with nothing else
	# to update.
	match _action_for_key(k.keycode):
		"pause":
			_toggle()
			get_viewport().set_input_as_handled()
			return
		"seek_back":
			_seek_by(-_skip_secs)
			get_viewport().set_input_as_handled()
			return
		"seek_fwd":
			_seek_by(_skip_secs)
			get_viewport().set_input_as_handled()
			return
		"vol_up":
			_nudge_volume(5.0)
			get_viewport().set_input_as_handled()
			return
		"vol_down":
			_nudge_volume(-5.0)
			get_viewport().set_input_as_handled()
			return
		"deck_a":
			_select_deck(0)
			get_viewport().set_input_as_handled()
			return
		"deck_b":
			_select_deck(1)
			get_viewport().set_input_as_handled()
			return
		"deck_both":
			_toggle_both()
			get_viewport().set_input_as_handled()
			return
		"kb_nav":
			_set_kb_nav(not _kb_nav)
			get_viewport().set_input_as_handled()
			return
		"mark_mode":
			%Mark.button_pressed = not %Mark.button_pressed
			get_viewport().set_input_as_handled()
			return
		"cursor":
			_toggle_cursor()
			get_viewport().set_input_as_handled()
			return
		"fullscreen":
			_toggle_window_fullscreen()
			get_viewport().set_input_as_handled()
			return
		"media_play":
			_toggle()
			get_viewport().set_input_as_handled()
			return
		"media_next":
			_next()
			get_viewport().set_input_as_handled()
			return
		"media_prev":
			_prev()
			get_viewport().set_input_as_handled()
			return
		"media_stop":
			_stop(_bar_deck())
			get_viewport().set_input_as_handled()
			return
		"simple_mode":
			_toggle_simple_mode()
			get_viewport().set_input_as_handled()
			return
	# Cue jump keys come AFTER the transport keys, so a marker can never shadow one, and
	# they are only live while a track is loaded. A focused LineEdit eats the keypress
	# before _unhandled_input ever sees it, so typing a search term cannot jump anything.
	if not _bar_path().is_empty() and _jump_to_key(OS.get_keycode_string(k.keycode)):
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_ESCAPE:
		# the innermost thing first: leaving keyboard navigation should not also drop the
		# window out of fullscreen
		if _kb_nav:
			_set_kb_nav(false)
			get_viewport().set_input_as_handled()
		elif _feed == Feed.FULLSCREEN:
			_toggle_simple_mode()
			get_viewport().set_input_as_handled()
		elif _window_is_fullscreen():
			_toggle_window_fullscreen()
			get_viewport().set_input_as_handled()

## Reverse lookup over the ~10-entry keybind table -- cheap enough to do on every
## keypress and the only way a rebind can take effect with no second place to update.
func _action_for_key(keycode: int) -> String:
	for action in _keybinds:
		if _keybinds[action] == keycode:
			return action
	return ""

func _seek_by(secs: float) -> void:
	if _len() <= 0.0:
		return
	_seek(clampf(_pos() + secs, 0.0, _len()))

## Same tail as _on_vol_input: value, slider, bus, save.
func _nudge_volume(pct: float) -> void:
	_volume = clampf(_volume + pct, 0.0, 100.0)
	_vol.value = _volume
	_apply_volume()
	_save_soon()


## VISUALIZER FULLSCREEN (F1): all chrome off, the feed at 100%.
##
## No new state and no second hide/show path -- Feed.FULLSCREEN already drops the
## sidebar, header, ticker, scrub row, transport and status bar, zeroes the 6 px chassis
## inset and hands the workspace to the visualizer. Coming back out re-runs the previous
## feed size, which re-solves the divider from the stored FRACTION, so the split lands
## where it was at whatever size the window is now. F1 and ESC are the same toggle; F1
## also gets you in, which is the only thing that was missing.
func _toggle_simple_mode() -> void:
	if _feed == Feed.FULLSCREEN:
		# a config saved while already in FULLSCREEN has no earlier size to return to
		_apply_feed(Feed.LARGE if _feed_prev == Feed.FULLSCREEN else _feed_prev)
	else:
		_feed_prev = _feed
		_apply_feed(Feed.FULLSCREEN)
	_save()


# --- OS window fullscreen ---------------------------------------------------
## Both modes count. Requesting WINDOWED from the boot fullscreen state reports
## EXCLUSIVE_FULLSCREEN back on this build, so a check for the one flag alone would
## decide the window was already windowed and refuse to leave.
func _window_is_fullscreen() -> bool:
	var m := DisplayServer.window_get_mode()
	return m == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or m == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN

func _toggle_window_fullscreen() -> void:
	if _window_is_fullscreen():
		_leave_window_fullscreen()
	else:
		_enter_window_fullscreen()

func _enter_window_fullscreen() -> void:
	# remember where to come back to, before the mode change overwrites it
	_windowed_rect = Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size())
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_relayout_for_window()

## Leaving is the awkward direction, and the fallback is not defensive padding.
##
## Measured on this build: setting WINDOWED directly from the boot fullscreen state does
## nothing -- window_get_mode reports EXCLUSIVE_FULLSCREEN straight back and
## window_set_size is refused outright. Going through MAXIMIZED first is what actually
## releases it. If even that does not take, the window is left borderless MAXIMIZED,
## which fills the monitor minus the taskbar and looks identical to the fullscreen boot;
## that is a far better outcome than a window stuck fullscreen with no way out.
func _leave_window_fullscreen() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	await get_tree().process_frame
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await get_tree().process_frame
	if _window_is_fullscreen():
		# the release did not take; borderless maximised is the honest second best
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	elif _windowed_rect.size.x > 0:
		DisplayServer.window_set_size(_windowed_rect.size)
		DisplayServer.window_set_position(_windowed_rect.position)
		await get_tree().process_frame
		_refit_window_to_screen()   # in case the remembered rect no longer fits
	_relayout_for_window()

## One full layout re-evaluation. _update_orientation re-reads the viewport, re-picks
## portrait vs landscape, recomputes the sidebar's responsive floor and re-applies the
## feed size -- which in turn re-solves the split from its stored FRACTION rather than a
## stale pixel offset, so the divider lands proportionally right at the new size. The
## SubViewport follows on its own: stretch_shrink resizes it from the container, measured
## at 476x259 / 511x259 / 476x268 across these three monitors.
##
## Deferred by a frame because the window has not finished resizing when the mode change
## returns, and measuring the viewport before it settles is what produces a layout fitted
## to the old geometry.
func _relayout_for_window() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	# keep the screen poll in step, so a deliberate toggle is not mistaken for a monitor
	# move and repaired into borderless maximised a frame later
	_last_screen = DisplayServer.window_get_current_screen()
	_last_vp = Vector2.ZERO      # force _update_orientation to run even if vp is unchanged
	_update_orientation()


# --- MAX FRAMERATE ---------------------------------------------------------
const FPS_MIN := 10
const FPS_MAX := 240
## Engine.max_fps = 0 means no cap at all. It has to sit OUTSIDE the FPS_MIN..FPS_MAX
## clamp rather than inside it, which is why the old field could not reach it: clamping
## a typed 0 landed on 10 and the setting had no uncapped state. The presets are the
## common refresh rates, listed in the field's placeholder so they are discoverable
## without turning a free-text field into a dropdown.
const FPS_UNCAPPED := 0
const FPS_PRESETS := [30, 60, 75, 120, 144, 165, 240, FPS_UNCAPPED]
## The shipped cap. Was 30 and spelled out in four separate places -- the variable's
## initialiser, the config fallback, and twice in the factory reset -- which is three
## chances for them to drift apart. One constant now, so changing it changes all of them.
const FPS_DEFAULT := 60
## Frame cap while the application is in the background. Never RAISES a lower user cap, and
## never persisted: _max_fps keeps the setting and focus returning puts it back.
const UNFOCUSED_FPS := 30

func _setup_fps() -> void:
	%MaxFps.max_length = 10   # "UNCAPPED" does not fit the old 3-character field
	%MaxFps.placeholder_text = "60 / 144 / 165 / 240 / 0"
	%MaxFps.text_submitted.connect(func(_s: String) -> void: _commit_max_fps())
	%MaxFps.focus_exited.connect(_commit_max_fps)
	_refresh_max_fps()
	Engine.max_fps = _max_fps
	_hover_note(%MaxFps, func() -> String:
		return "MAX FRAMERATE: %s  //  PRESETS %s  //  0 OR UNCAPPED REMOVES THE CAP" % [
			_fps_text(_max_fps), ", ".join(FPS_PRESETS.slice(0, FPS_PRESETS.size() - 1))])

static func _fps_text(fps: int) -> String:
	return "UNCAPPED" if fps == FPS_UNCAPPED else str(fps)

func _refresh_max_fps() -> void:
	%MaxFps.text = _fps_text(_max_fps)

## Clamped on commit, same as the fade fields: rewriting per keystroke would fight the
## cursor while you type. Applied straight to Engine.max_fps, which caps the whole app.
##
## 0 is not clamped into FPS_MIN..FPS_MAX because it is not a rate -- it is the absence
## of a cap. Typing the word works too: "UNCAPPED" is what the field shows for it, and a
## field you cannot type back what it displays reads as broken.
func _commit_max_fps() -> void:
	var typed: String = %MaxFps.text.strip_edges().to_upper()
	_max_fps = FPS_UNCAPPED if typed.begins_with("U") or typed.begins_with("OFF") \
		or int(typed) == 0 else clampi(int(typed), FPS_MIN, FPS_MAX)
	_refresh_max_fps()
	Engine.max_fps = _max_fps
	_save()




# --- user EQ preset slots --------------------------------------------------
## Eight empty slots the user fills themselves. Nothing ships preloaded: a slot is a
## name plus a captured curve, and an unused one loads nothing when selected.
const EQ_SLOTS := 8

func _init_presets() -> void:
	# Shape-checked, not merely counted. A hand-edited or truncated `presets=` can hold a
	# String, or a Dictionary missing members, and all six places that read a slot assume
	# name/lanes/used are present -- _refresh_presets typed its local as Dictionary and threw
	# there, which aborted the rest of _ready. Normalised once here, the single place that
	# already owns preset shape, rather than guarded at each reader.
	for i in _presets.size():
		var d: Variant = _presets[i]
		var nm: Variant = d.get("name") if d is Dictionary else null
		var ln: Variant = d.get("lanes") if d is Dictionary else null
		var us: Variant = d.get("used") if d is Dictionary else null
		_presets[i] = {
			"name": nm if nm is String else "CUSTOM %d" % (i + 1),
			"lanes": ln if ln is Array else [],
			"used": us if us is bool else false,
		}
	while _presets.size() < EQ_SLOTS:
		_presets.append({"name": "CUSTOM %d" % (_presets.size() + 1), "lanes": [], "used": false})
	_presets.resize(EQ_SLOTS)

func _setup_presets() -> void:
	_init_presets()
	%EqPreset.item_selected.connect(_load_preset)
	%EqPresetSave.pressed.connect(_store_preset)
	%EqPresetName.text_submitted.connect(func(_s: String) -> void: _rename_preset())
	%EqPresetName.focus_exited.connect(_rename_preset)
	# uppercase as you type. Setting `text` in code does not re-emit text_changed, so
	# there is no recursion, but it does reset the caret -- hence saving the column.
	%EqPresetName.text_changed.connect(func(s: String) -> void:
		var up := s.to_upper()
		if up != s:
			var col: int = %EqPresetName.caret_column
			%EqPresetName.text = up
			%EqPresetName.caret_column = col)
	_refresh_presets()

## Rebuilt rather than patched in place: the list is eight items, and one code path
## means a rename, a save and a REBOOT all render identically.
func _refresh_presets() -> void:
	var keep: int = maxi(%EqPreset.selected, 0)
	%EqPreset.clear()
	for i in _presets.size():
		var slot: Dictionary = _presets[i]
		# a trailing dot marks a slot that holds a curve, so empty ones read as empty
		%EqPreset.add_item(("%s ." % slot["name"]) if slot["used"] else slot["name"], i)
	%EqPreset.selected = clampi(keep, 0, _presets.size() - 1)
	%EqPresetName.text = _presets[%EqPreset.selected]["name"]

func _load_preset(i: int) -> void:
	if i < 0 or i >= _presets.size():
		return
	var slot: Dictionary = _presets[i]
	# the dropdown moves itself when the user picks an item, but not when this is
	# called in code -- and a stale selection makes SAVE and rename hit the wrong slot
	if %EqPreset.selected != i:
		%EqPreset.selected = i
	%EqPresetName.text = slot["name"]
	if not slot["used"]:
		return                       # empty slot: selecting it just parks you there
	_eq.set_lanes(slot["lanes"])
	# sync guard up, or each fader write bounces back through _on_lane_changed
	_fader_sync = true
	for j in Equalizer.LANES:
		_adv_faders[j].value = _eq.lane_db[j]
	_fader_sync = false
	_fader_base = _eq.lane_db.duplicate()
	_note = "  //  LOADED %s" % slot["name"].to_upper()
	_clear_note_later()

func _store_preset() -> void:
	var i: int = maxi(%EqPreset.selected, 0)
	_presets[i] = {"name": _presets[i]["name"], "lanes": Array(_eq.lane_db), "used": true}
	_refresh_presets()
	_save()
	_note = "  //  SAVED %s" % _presets[i]["name"].to_upper()
	_clear_note_later()

func _rename_preset() -> void:
	var i: int = maxi(%EqPreset.selected, 0)
	var want: String = %EqPresetName.text.strip_edges().to_upper()
	if want.is_empty():
		want = "CUSTOM %d" % (i + 1)   # never leave a slot with no label at all
	_presets[i]["name"] = want
	_refresh_presets()
	_save()


# --- logo intro ------------------------------------------------------------
## Plays before the BIOS screen, then hands over. Godot 4 has no H.264 decoder, so the
## source MP4 was transcoded to Ogg Theora (intro.ogv) -- VideoStreamPlayer will not
## take an .mp4 at all, silently or otherwise.
func _start_intro() -> void:
	# Off means BOTH are skipped -- no video and no POST -- straight into the player.
	# %Boot is visible = false in the scene and only shows itself when begin() is called,
	# so not calling it is the whole of "skip the BIOS".
	if not _intro_on:
		%Intro.visible = false
		return
	# A first launch skips the VIDEO but keeps the POST: someone who has never opened the
	# program reaches it in seconds, and the logo plays from the second launch on.
	if not %IntroVid.stream or _first_run:
		_begin_boot()
		return
	%Intro.visible = true
	%IntroVid.finished.connect(_begin_boot, CONNECT_ONE_SHOT)
	%IntroVid.play()

func _begin_boot() -> void:
	if not %Intro.visible:
		return                      # already handed over; a skip and the end can race
	%IntroVid.stop()
	%Intro.visible = false
	%Boot.begin(_user_name, _library.paths.size())

## Any key or click skips the logo. Handled here rather than in boot.gd because the
## boot screen has not been handed control yet.
##
## Keybind capture also lives in _input rather than _unhandled_input: it runs BEFORE
## Godot's own GUI dispatch, so the rebind button holding focus never turns a captured
## SPACE or ENTER into a click on itself first.
func _input(event: InputEvent) -> void:
	# A press anywhere returns to the mouse context. Without this, clicking a button in keyboard
	# mode would leave it focused and eating SPACE -- the exact failure the two contexts exist
	# to prevent, arrived at from the other direction.
	if _kb_nav and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_set_kb_nav(false)
	if not _awaiting_rebind.is_empty():
		if event is InputEventKey and event.pressed and not event.is_echo():
			_finish_rebind(event.keycode)
			get_viewport().set_input_as_handled()
		return
	# MIDI is handled here and nowhere else. It is not an InputEventKey, so _transport_key ignores
	# it and _unhandled_input returns at its first line -- nothing downstream would ever see it.
	var midi := event as InputEventMIDI
	if midi:
		_route_midi(midi)
		get_viewport().set_input_as_handled()
		return
	if %Intro.visible:
		var skip: bool = (event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed)
		if skip:
			_begin_boot()
			get_viewport().set_input_as_handled()
		return
	if _transport_key(event):
		get_viewport().set_input_as_handled()

## The transport's keys, taken at the ROOT before the focused control ever sees them.
##
## _unhandled_input runs only for events nothing consumed, and a focused control consumes
## them: click a button, a tab or a list and SPACE belonged to that control rather than to
## PLAY/PAUSE. Outside KEYBOARD NAVIGATION nothing in this program is focusable -- _drop_focus
## sees to that -- so this is belt and braces there; inside it, it is the whole fix.
##
## TWO EXCEPTIONS, and both earn their keep:
##   - a LineEdit with focus is somebody TYPING. Every letter, arrow and space belongs to them,
##     and this is the one case where the transport must keep its hands off entirely.
##   - UP and DOWN while KEYBOARD NAVIGATION is on walk the UI, which is what that mode is
##     for. Everything else still reaches the transport there, and ENTER still activates the
##     focused control, so the mode stays usable with SPACE taken.
##
## Routed through _unhandled_input rather than a second copy of the match: that function also
## feeds the cheat-code buffer, and a shortcut intercepted here would otherwise stop a letter
## key counting toward a code.
func _transport_key(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if not k or not k.pressed or k.is_echo():
		return false
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return false
	if _kb_nav and (k.keycode == KEY_UP or k.keycode == KEY_DOWN):
		return false
	if _action_for_key(k.keycode).is_empty():
		return false
	_unhandled_input(k)
	return true


# --- volume booster --------------------------------------------------------
func _setup_boost() -> void:
	%Boost.gui_input.connect(_on_boost_bar)
	_hover_note(%Boost, func() -> String: return "VOLUME BOOST: %d  //  +%.1f DB" % [
		_boost, _boost_gain()])
	_refresh_boost()
	_eq.set_boost(_boost_gain())

## The dial reads 0-100; the engine still wants dB. 0 maps to unity, so the bottom of
## the slider is genuinely no boost rather than a small permanent one.
func _boost_gain() -> float:
	return float(_boost) / 100.0 * Equalizer.BOOST_MAX

## Same click-drag ProgressBar the volume, sensitivity and DSP controls use, so the
## booster reads as part of the same panel rather than a lone text field.
func _on_boost_bar(e: InputEvent) -> void:
	var w := _bar_wheel(e, float(_boost) / 100.0, BAR_WHEEL_COARSE)
	if w >= 0.0:
		_set_boost(int(roundf(w * 100.0)))
		return
	if not _bar_drag(e, %Boost):
		return
	_set_boost(int(roundf(_ratio_at(e.position.x, %Boost.size.x) * 100.0)))

## Boost by NUMBER, 0-100, for the same reason _set_volume exists.
func _set_boost(v: int) -> void:
	_boost = clampi(v, 0, 100)
	_refresh_boost()
	_eq.set_boost(_boost_gain())
	_save_soon()

func _refresh_boost() -> void:
	%Boost.value = float(_boost)
	%BoostLabel.text = "VOLUME BOOST: %d" % _boost


# --- responsive orientation ------------------------------------------------
## Portrait proportions for the same five feed sizes. The sidebar is always 1.0, so
## LARGE reads as 45/55 -- visualizer on top, tab dock filling the rest beneath it.
const FEED_RATIO_V := [0.82, 0.54, 0.30, 0.0, 0.0, 0.0]
## Anything squarer than this counts as portrait. 1.1 rather than 1.0 so a near-square
## window commits to one layout instead of flickering between the two on tiny resizes.
const PORTRAIT_BELOW := 1.1
const LAYOUT_NAMES := ["AUTO-DETECT", "FORCE LANDSCAPE", "FORCE PORTRAIT"]

func _setup_layout() -> void:
	for i in LAYOUT_NAMES.size():
		%Layout.add_item(LAYOUT_NAMES[i], i)
	%Layout.selected = _layout
	%Layout.item_selected.connect(func(i: int) -> void:
		_layout = i
		_update_orientation()
		_save())
	get_viewport().size_changed.connect(_update_orientation)
	_update_orientation()

## Picks the axis and re-applies the feed size, which is what actually sets the split.
## Runs on every viewport resize, so dragging a window across the threshold restructures
## the UI live rather than only at startup.
func _update_orientation() -> void:
	# a width change is exactly when a caption starts or stops fitting
	_label_clipped_controls.call_deferred()
	var vp := get_viewport().get_visible_rect().size
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var want: bool = aspect < PORTRAIT_BELOW
	if _layout == 1:
		want = false
	elif _layout == 2:
		want = true
	_portrait = want
	# The 575 px floor keeps the tab dock usable beside the feed, but stacked it is a
	# horizontal floor on the WHOLE window -- anything narrower would overflow. In
	# landscape it is also capped at half the viewport: on a narrow-but-still-landscape
	# window (a 700 px wide one is aspect 1.13, so not portrait) an unconditional 575
	# leaves the visualizer 125 px and pushes the layout past the window edge.
	%RightSidebar.custom_minimum_size.x = 0.0 if _portrait \
		else minf(SIDEBAR_MIN_X, vp.x * 0.5)
	# A SplitContainer clamps the divider against its children's COMBINED minimum sizes,
	# so lowering the floor above is only half the job: the TabContainer and whatever
	# panel is showing inside it each report their own minimum, and the widest one wins.
	# Clipping them is what lets the drag actually reach SIDEBAR_MIN_X instead of
	# stopping at whatever the busiest tab happens to need.
	%RightSidebar.custom_minimum_size.y = 0.0
	_tabs.custom_minimum_size = Vector2.ZERO
	_tabs.clip_contents = true
	%Workspace.vertical = _portrait
	_apply_feed(_feed)   # re-runs _split_to_fraction, so presets stay proportional


## SHUF and RPT are persisted now, so their captions have to be derived from the engine
## rather than toggled in place -- the .tscn defaults would otherwise lie after a reload.
func _refresh_transport() -> void:
	%Shuffle.text = "SHUF:%s" % ["OFF", "TRUE", "JAM"][_engine.shuffle_mode]
	%Repeat.text = "RPT:%s" % ["OFF", "ALL", "ONE"][_engine.repeat]


## The tempo fit sweeps ~560 candidate periods every 0.5 s on the main thread, so it stays
## off unless asked for -- and AudioDirector._process returns before any of that work when
## it is off, which is what keeps the readout free. Saying "BPM: OFF" is honest; the old
## permanent "-- BPM" read as a tracker that was running and failing. The [#] ticker is
## only meaningful while the beat clock is live, so it is dropped entirely when it is not.
func _bpm_readout() -> String:
	if not _director.track_tempo:
		return "BPM: OFF"
	var tick := "[#]" if _flash > 0.0 else "[ ]"
	if _director.bpm <= 0.0:
		return "%s BPM: ----" % tick     # tracking, but not locked yet
	# EMA, display only: the fit lands every 0.5 s and can move a whole BPM between
	# fits, which reads as a counter that will not sit still. The tracker's own value
	# is left alone -- smoothing THAT would feed a lagged tempo back into the beat clock.
	return "%s %.1f BPM" % [tick, _bpm_shown]


# --- beat tracking ---------------------------------------------------------
## Width the tab dock needs to stay usable beside the visualizer. Only applied in
## landscape; see _update_orientation().
##
## Lowered from 640 back to 320. The 640 floor was set so all eight tabs fit the bar at
## once, but that is a nicety the overflow arrows already cover, and it cost the thing
## people actually do: on a 1280 px window `minf(SIDEBAR_MIN_X, vp.x * 0.5)` evaluates
## to exactly 640, so the divider hit its clamp at the halfway mark and the sidebar
## could not be dragged any narrower. 320 leaves the tab bar scrollable but lets the
## feed have most of the window, which is what a visualizer-first layout wants.
const SIDEBAR_MIN_X := 320.0

## The tempo fit is the one genuinely expensive thing in this program -- ~560 candidate
## periods swept against every onset in a 10 s history, every 0.5 s, on the main thread --
## and nothing but the status readout consumes it. So it ships off and this is the switch,
## rather than a cost every user pays for a number most will never look at.
func _setup_beat() -> void:
	%BeatTrack.pressed.connect(func() -> void:
		_director.track_tempo = not _director.track_tempo
		# drop the old lock either way: stale on resume, and a stale BPM would otherwise
		# sit in the status bar after switching off
		_director.reset()
		_refresh_beat()
		_save())
	_refresh_beat()

func _refresh_beat() -> void:
	%BeatTrack.text = "ON" if _director.track_tempo else "OFF"


# --- dynamic FX rack (FX tab) -----------------------------------------------
## The rack boots BLANK. Every module already exists on the bus (FxRack.setup
## pre-allocates all of them, disabled), so ADD EFFECT only flips a slot -- see
## fx_rack.gd for why nothing is ever inserted at runtime.
var _rack_decks: Array[FxRack] = []
var _rack_cfg_decks := [{}, {}]   # deck -> saved [rack]/[rack_b] block
var _rack_presets := {}           # preset name -> FxRack.to_dict()
## One FX tab per deck, each pinned to its own rack (FX A, FX B), rather than one tab that
## re-binds to whichever deck is live: DUAL DECK MODE shows both at once, one in each dock.
var _rack_boxes: Array[VBoxContainer] = [null, null]   # deck -> where its module boxes render
var _rack_bars := [{}, {}]        # deck -> "type/key" -> [ProgressBar, Label]

var _key := {}          # _current's key: {"text": String, "pc": int, "minor": bool},
						 # optionally "estimated": true when it came from SpectralKey

## The tag wins outright. A spectral estimate only ever fills in where the tag was
## silent (pc == -1), and is always marked with a trailing "~" -- a chroma vote is a
## vote, not a fact, and the readout says so every time it shows one.
func _resolved_key(path: String) -> Dictionary:
	var tag: Dictionary = _engine.metadata(path).get("key", {})
	if int(tag.get("pc", -1)) >= 0:
		return tag
	var spec := _engine.spectral_key_for(path)
	if spec.is_empty():
		return tag   # still unresolved -- nothing queued yet, or nothing conclusive found
	return {"text": "%s ~" % AudioEngine.key_label(int(spec["pc"]), bool(spec["minor"])),
		"pc": spec["pc"], "minor": spec["minor"], "estimated": true}

# --- focus policy -------------------------------------------------------------
## A clicked Button keeps keyboard focus, and a focused Button eats SPACE and the arrow
## keys as its own "press me" / "move to the next control" actions -- so after clicking
## anything, PAUSE stopped working and the arrows stopped seeking, with nothing on
## screen to say why. Every button-like control gives up focus entirely.
##
## LineEdit is deliberately EXCLUDED. It has to hold focus or it cannot be typed into,
## and its swallowing of keys is the wanted behaviour: it is what lets SEARCH accept a
## space in a track name without the transport hearing it. That is already how the
## shortcut handler is documented to work.
##
## Done as a node_added hook rather than a line in every builder: this program creates
## controls at runtime constantly (the FX rack, the gradient editor, torn-off windows,
## the asset managers), and a rule that has to be remembered at 40 call sites is a rule
## that gets missed at the 41st.
## Nothing in this program is wide. The deck A wing is a sidebar, the settings screen is a
## sidebar, and both hold rows whose captions were written for a maximised window: "LISTENING
## MODE", "ROTATE GRADIENTS", "DUAL DECK MODE". Narrow either one and Godot simply CLIPS the
## text mid-glyph -- there is no ellipsis by default and no tooltip, so a button can read
## "ROTATE GRADI" with no way to find out what the rest of it said.
##
## So: every Button, Label and OptionButton that cannot fit its own text gets TRIM_ELLIPSIS,
## which makes the truncation visible rather than ambiguous, and a tooltip carrying the full
## text. Controls that DO fit are left alone -- a tooltip repeating a label you can already
## read is noise, and it would cover the thing it describes.
##
## Deferred by a frame because none of this is knowable until the first layout pass has given
## every control its real width, and re-run on resize for the same reason.
func _label_clipped_controls(from: Node = null) -> void:
	var stack: Array[Node] = [from if from else self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var text := ""
		if n is OptionButton:
			var ob := n as OptionButton
			text = ob.get_item_text(ob.selected) if ob.selected >= 0 else ""
		elif n is Button:
			text = (n as Button).text
		elif n is Label:
			text = (n as Label).text
		if text.strip_edges().is_empty():
			continue
		var ctrl := n as Control
		if ctrl == null or ctrl.size.x <= 0.0:
			continue
		var font := ctrl.get_theme_font("font")
		var font_size := ctrl.get_theme_font_size("font_size")
		if font == null:
			continue
		# the room the glyphs actually have: the control less whatever its style box eats
		var pad := 0.0
		var sb := ctrl.get_theme_stylebox("normal")
		if sb:
			pad = sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)
		var needed := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		var clipped: bool = needed > ctrl.size.x - pad + 0.5
		if n is Button:
			(n as Button).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if clipped else TextServer.OVERRUN_NO_TRIMMING
		elif n is Label:
			(n as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if clipped else TextServer.OVERRUN_NO_TRIMMING
		# never overwrite a tooltip somebody wrote on purpose -- those say more than the label
		if ctrl.tooltip_text.is_empty() or ctrl.tooltip_text == str(ctrl.get_meta("clip_tip", "")):
			if clipped:
				ctrl.tooltip_text = text
				ctrl.set_meta("clip_tip", text)
			elif ctrl.has_meta("clip_tip"):
				ctrl.tooltip_text = ""
				ctrl.remove_meta("clip_tip")

## FOCUS IS A CONTEXT, and the reason is the keyboard map. SPACE is PAUSE/PLAY, the arrows are
## seek and volume, TAB is DECK A+B -- which is every key focus navigation needs. Turning focus
## on for everything, the obvious reading of "remove the blanket FOCUS_NONE", would hand all five
## to whichever button was last clicked and take the transport off the keyboard.
##
## So there are two contexts and the program is always plainly in one of them:
##
##   MOUSE (default)  no control takes focus, and every shortcut means what it says.
##   KEYBOARD (F2)    buttons, lists and tabs take focus; TAB and the arrows move between them
##                    and ENTER/SPACE press the one you are on, because Godot's GUI consumes
##                    those before _unhandled_input ever sees them. ESC or F2 goes back.
##
## Nothing is lost in either direction: the shortcuts the GUI does not want (1, 2, M, H, F1,
## F11, the media keys) still work while navigating, and a click anywhere drops straight back to
## the mouse context so a stray focus can never be why SPACE stopped playing.
var _kb_nav := false
## The control the focus ring is on, tinted so it is visible on a theme with no focus stylebox.
var _kb_focused: Control
const KB_FOCUS_TINT := Color(1.35, 1.35, 1.0)

func _set_kb_nav(on: bool) -> void:
	if _kb_nav == on:
		return
	_kb_nav = on
	_apply_focus_policy()
	if on:
		# start where the user is looking: the page of whichever tab is open
		var page: Control = _tabs.get_current_tab_control() if is_instance_valid(_tabs) else null
		var first := _first_focusable(page if page else self)
		if first:
			first.grab_focus()
		_note = "  //  KEYBOARD NAVIGATION  //  TAB AND ARROWS MOVE  //  ENTER PRESSES  //  ESC LEAVES"
	else:
		_tint_focus(null)
		var owner := get_viewport().gui_get_focus_owner()
		if owner and not owner is LineEdit:
			owner.release_focus()
		_note = "  //  MOUSE MODE"
		_clear_note_later()

func _first_focusable(from: Node) -> Control:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		var c := n as Control
		if c and c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree():
			return c
		for child in n.get_children():
			stack.append(child)
	return null

## Re-walks every control for the context that is now current. Cheap enough to run on a mode
## switch and never run otherwise.
func _apply_focus_policy() -> void:
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		_drop_focus(n)
		for c in n.get_children():
			stack.append(c)

func _on_focus_changed(control: Control) -> void:
	if _kb_nav:
		_tint_focus(control)

## A visible ring without depending on the theme having a focus stylebox: the skins define
## normal/hover/pressed and Skins repaints them, so a focus box would be one more thing every
## skin had to remember. A tint is theme-independent and cannot be forgotten.
func _tint_focus(control: Control) -> void:
	if is_instance_valid(_kb_focused):
		_kb_focused.modulate = Color.WHITE
	_kb_focused = control
	if is_instance_valid(_kb_focused):
		_kb_focused.modulate = KB_FOCUS_TINT

func _setup_focus_policy() -> void:
	get_tree().node_added.connect(_drop_focus)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	# _tabs has to exist before the initial walk below, or the clip_text half of
	# _drop_focus silently does nothing for every control the scene shipped with
	assert(is_instance_valid(_tabs))
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		_drop_focus(n)
		for c in n.get_children():
			stack.append(c)

func _drop_focus(n: Node) -> void:
	if n is LineEdit:
		return
	# in the keyboard context these are exactly the things worth landing on; in the mouse
	# context none of them may hold focus, because the keys that would move it are the transport
	if n is Button or n is TabBar or n is ItemList or n is OptionButton or n is Tree:
		(n as Control).focus_mode = Control.FOCUS_ALL if _kb_nav else Control.FOCUS_NONE
	# Inside the sidebar only: a caption is not allowed to be the reason the divider
	# stops moving. Outside it (the transport, the ticker, popups) the old sizing still
	# applies, because nothing there is being dragged narrower than its content.
	#
	# Hooked to node_added rather than done as one boot-time walk on purpose: the FX
	# rack, the gradient editor and every torn-off window build their rows later, and a
	# one-shot walk would let the floor creep back up the first time a module was added.
	if (n is Button or n is Label) and is_instance_valid(_tabs) and _tabs.is_ancestor_of(n):
		n.set("clip_text", true)
		if n is Label:
			_pin_label(n as Label)

## A clipped Label reports NO minimum width, so an HBoxContainer hands it nothing at all beside a
## control that expands. That is why every caption player.tscn ships -- FADE TIME, PLAY DELAY,
## VISUAL FEED SIZE, MAX FRAMERATE, BEAT TRACKING, VOLUME BOOST, LAYOUT -- drew as a 1 px sliver
## with its text gone the moment clip_text was applied to everything under the tabs.
##
## So a clipped label is pinned to the width of the text it is carrying RIGHT NOW, and right now
## is the whole rule: a caption is written before it is added and keeps that width for good, while
## a readout whose text arrives later (the RAM line, the track count, the status bar) pins nothing
## and stays clipped -- which is what still keeps a long string from putting a floor under the
## sidebar, the thing clip_text was for.
const LABEL_PINNED := "pinned_width"

## Takes a Control rather than a Label because BUTTONS need it too, and for the same reason:
## _drop_focus clips them, a clipped control reports no minimum width, and one sharing a row
## with anything that expands is then squeezed to a couple of characters. Measured on the QUEUE
## tab before this: four buttons 28 px wide holding text that needed 176 to 256, which reads as
## four blank buttons. Pinning is used sparingly -- a button whose label CHANGES would put a
## floor under the sidebar at its longest text, which is what the clipping is there to prevent.
func _pin_label(l: Control) -> void:
	var text := str(l.get("text"))
	if text.is_empty() or (l.custom_minimum_size.x > 0.0 and not l.has_meta(LABEL_PINNED)):
		return   # empty, or a width somebody set on purpose
	var font := l.get_theme_font("font")
	if not font:
		return
	var size := l.get_theme_font_size("font_size")
	var widest := 0.0
	for line in text.split("\n"):
		widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x)
	# buttons carry their own stylebox padding, which the text width knows nothing about
	var pad := 0.0
	if l is Button:
		var sb := l.get_theme_stylebox("normal")
		pad = sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT) if sb else 8.0
	l.custom_minimum_size.x = ceilf(widest + pad)
	l.set_meta(LABEL_PINNED, true)

## Pins a control wide enough for ANY of `texts`, not just the one it is showing. _pin_label
## measures what is there now, which is right for a caption and wrong for a button that renames
## itself: a LEARN button that becomes TOUCH IT would otherwise widen its row the instant it is
## pressed, shoving everything after it sideways under the pointer.
func _pin_to_widest(c: Control, texts: Array[String]) -> void:
	var font := c.get_theme_font("font")
	if not font:
		return
	var size := c.get_theme_font_size("font_size")
	var widest := 0.0
	for t in texts:
		widest = maxf(widest, font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x)
	var sb := c.get_theme_stylebox("normal")
	c.custom_minimum_size.x = ceilf(widest + (sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT) if sb else 8.0))

## Every pinned caption re-measured. The pin is a pixel width, so a new font or a new size would
## otherwise leave every settings column measured for the old one.
func _repin_labels() -> void:
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if (n is Label or n is Button) and n.has_meta(LABEL_PINNED):
			(n as Control).custom_minimum_size.x = 0.0
			_pin_label(n as Control)

# --- RECORD SET tab ----------------------------------------------------------
## The one colour in the program that does not come from the skin. A failed take has to read as
## wrong on every palette, including the ones whose accent IS red, so it is fixed here and always
## paired with the "[!] WRITE FAILED" text rather than carrying the meaning on its own.
const REC_ERROR_COLOR := Color(0.87, 0.26, 0.22)

var _recorder: Recorder
var _rec_dir := ""
var _rec_rate := 0        # index into Recorder.RATES
var _rec_type := 0        # index into Recorder.FILE_TYPES
var _rec_quality := 1     # index into Recorder.QUALITY_NAMES
var _rec_btn: Button
var _rec_status: Label
var _rec_dir_btn: Button

func _setup_record_tab() -> void:
	_recorder = Recorder.new()
	_recorder.name = "Recorder"
	add_child(_recorder)
	_recorder.setup()
	# Recorder.setup() puts an AudioEffectCapture on MASTER -- the analyser's own bus --
	# and by this file's own rule anything that edits that chain has to re-bind after,
	# or AudioDirector is left holding a handle to an instance the insert rebuilt and
	# the visualizer reads 0.0 forever with nothing on screen to say why. This was the
	# one Master-chain edit added after _setup_eq's rebind and it had no partner.
	_director.rebind()
	if _rec_dir.is_empty():
		_rec_dir = OS.get_system_dir(OS.SYSTEM_DIR_MUSIC)

	var tab := VBoxContainer.new()
	tab.name = "RECORD SET"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)

	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	tab.add_child(fd)
	fd.dir_selected.connect(func(d: String) -> void:
		_rec_dir = d
		_refresh_rec()
		_save())

	_rec_dir_btn = _rec_row(tab, "DIRECTORY")
	_rec_dir_btn.pressed.connect(func() -> void: fd.popup_centered(Vector2i(760, 520)))

	var rates: Array[String] = []
	for r in Recorder.RATES:
		rates.append("%d HZ" % r)
	_rec_option(tab, "SAMPLE RATE", rates, _rec_rate, func(i: int) -> void:
		_rec_rate = i
		_save())
	var types: Array[String] = []
	types.assign(Recorder.FILE_TYPES)
	_rec_option(tab, "FILE TYPE", types, _rec_type, func(i: int) -> void:
		_rec_type = i
		_refresh_rec()
		_save())
	var quals: Array[String] = []
	quals.assign(Recorder.QUALITY_NAMES)
	_rec_option(tab, "QUALITY", quals, _rec_quality, func(i: int) -> void:
		_rec_quality = i
		_refresh_rec()
		_save())

	_rec_btn = Button.new()
	_rec_btn.pressed.connect(_toggle_record)
	tab.add_child(_rec_btn)
	_rec_status = Label.new()
	_rec_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	tab.add_child(_rec_status)
	_hover_note(_rec_btn, func() -> String:
		return "RECORDS THE MASTER BUS TO DISK  //  LENGTH IS LIMITED BY FREE SPACE, NOT RAM")
	# a take that outlives the window would be a truncated file with no header sizes
	_recorder.finished.connect(func(path: String, ok: bool) -> void:
		_write_setlist(path)
		_note = "  //  %s %s%s" % ["SAVED" if ok else "KEPT RAW", path.get_file(),
			"  //  +%d TRACK SET LIST" % _set_log.size() if not _set_log.is_empty() else ""]
		_clear_note_later()
		_refresh_rec())
	# A take that stopped because the disk would not take it. Deliberately NOT cleared on the
	# usual four-second timer: every other note is something you can miss without losing
	# anything, and this one is a recording that stopped while you thought it was running.
	_recorder.failed.connect(func(path: String, reason: String) -> void:
		_log_fault("RECORDING STOPPED", "%s (raw take kept as %s)" % [reason, path])
		_note = "  //  [!] RECORDING STOPPED: %s  //  RAW TAKE KEPT AS %s" % [
			reason.to_upper(), path.get_file()]
		_refresh_rec())
	_refresh_rec()

func _rec_row(parent: Control, caption: String) -> Button:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	parent.add_child(r)
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size.x = 110
	r.add_child(l)
	var b := Button.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	r.add_child(b)
	return b

func _rec_option(parent: Control, caption: String, items: Array[String], selected: int,
		on_pick: Callable) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	parent.add_child(r)
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size.x = 110
	r.add_child(l)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.clip_text = true                  # see the note in _rack_module_box
	opt.custom_minimum_size.x = 90
	for i in items.size():
		opt.add_item(items[i], i)
	opt.selected = clampi(selected, 0, items.size() - 1)
	opt.item_selected.connect(on_pick)
	r.add_child(opt)

## Keeps the END of a path, which is the part that says where a take actually lands.
## clip_text alone kept the HEAD, so the button read "C:/Users/gavin/AppData/" and the
## folder name -- the only bit anyone needs -- was the part that got cut.
static func _elide_head(path: String, keep: int) -> String:
	if path.length() <= keep:
		return path
	# cut on a separator, never mid-word: a raw character count produced
	# ".../OUNDSCAPE_HOTFIX_TE", which is not a folder name anyone can recognise
	var parts := path.split("/", false)
	var out := ""
	for i in range(parts.size() - 1, -1, -1):
		var candidate := "/" + parts[i] + out
		if candidate.length() > keep:
			break
		out = candidate
	return ".." + out if not out.is_empty() else ".." + path.substr(path.length() - keep)

## What has played since the take started, as {at (seconds into the take), path, title, artist}.
## A recorded set is the audio plus the running order, and until now only the audio was kept --
## the one thing anyone wants afterwards, to put in a description or a tag, had to be
## reconstructed from memory.
var _set_log: Array[Dictionary] = []

func _toggle_record() -> void:
	if not _recorder:
		return
	if _recorder.recording:
		_recorder.stop(_rec_type, _rec_rate, _rec_quality)
	elif _recorder.start(_rec_dir).is_empty():
		_note = "  //  CANNOT WRITE TO %s" % _rec_dir
		_clear_note_later()
	else:
		_set_log.clear()
		_note_track_for_set(_current)   # whatever was already playing when RECORD was pressed
	_refresh_rec()

## Adds a track to the running order at wherever the take has reached. Called when a track
## starts and once at the top, so a set that began mid-track still names it.
func _note_track_for_set(path: String) -> void:
	if not _recorder or not _recorder.recording or path.is_empty():
		return
	var m := _engine.cached_meta(path)
	var at := float(_recorder.frames_written) / maxf(AudioServer.get_mix_rate(), 1.0)
	# the same track twice in a row is a re-cue, not a new entry in the running order
	if not _set_log.is_empty() and str(_set_log[-1]["path"]) == path:
		return
	_set_log.append({"at": at, "path": path,
		"title": str(m.get("title", path.get_file().get_basename())),
		"artist": str(m.get("artist", ""))})

## The running order as plain text and as a CUE SHEET, written beside the take. Text because it
## is what gets pasted into a description; .cue because every DJ tool and most players read it,
## which is what makes the recording navigable instead of one long file.
##
## Pure, so the formatting is checkable without recording anything.
static func setlist_text(entries: Array, take_name: String) -> String:
	var out := PackedStringArray(["SOUNDSCAPE SET  //  %s" % take_name, ""])
	for i in entries.size():
		var e: Dictionary = entries[i]
		var who := str(e.get("artist", ""))
		var what := str(e.get("title", ""))
		out.append("%s  %2d. %s" % [ts_text(float(e.get("at", 0.0))).left(8), i + 1,
			"%s - %s" % [who, what] if not who.is_empty() else what])
	return "\n".join(out) + "\n"

## MM:SS:FF at 75 frames a second, which is what the CUE format counts in -- not milliseconds.
static func cue_stamp(secs: float) -> String:
	var total := maxf(secs, 0.0)
	var m := int(total / 60.0)
	var sec := int(total) % 60
	var frames := int((total - floor(total)) * 75.0)
	return "%02d:%02d:%02d" % [m, sec, frames]

static func cue_sheet(entries: Array, audio_file: String) -> String:
	var out := PackedStringArray([
		'TITLE "SOUNDSCAPE SET"',
		'FILE "%s" WAVE' % audio_file])
	for i in entries.size():
		var e: Dictionary = entries[i]
		out.append("  TRACK %02d AUDIO" % (i + 1))
		out.append('    TITLE "%s"' % str(e.get("title", "")).replace('"', "'"))
		var who := str(e.get("artist", ""))
		if not who.is_empty():
			out.append('    PERFORMER "%s"' % who.replace('"', "'"))
		out.append("    INDEX 01 %s" % cue_stamp(float(e.get("at", 0.0))))
	return "\n".join(out) + "\n"

static func set_export_test() -> bool:
	var entries := [
		{"at": 0.0, "path": "a.flac", "title": "Opener", "artist": "Someone"},
		{"at": 185.5, "path": "b.flac", "title": "Second", "artist": ""},
	]
	var txt := setlist_text(entries, "TAKE.wav")
	var cue := cue_sheet(entries, "TAKE.wav")
	return txt.contains("Someone - Opener") and txt.contains(" 2. Second") \
		and not txt.contains(" - Second") \
		and cue.contains('FILE "TAKE.wav" WAVE') and cue.contains("TRACK 01 AUDIO") \
		and cue.contains("INDEX 01 00:00:00") and cue.contains("INDEX 01 03:05:37") \
		and cue.contains('PERFORMER "Someone"') \
		and cue_stamp(0.0) == "00:00:00" and cue_stamp(61.5) == "01:01:37" \
		and setlist_text([], "T").contains("SOUNDSCAPE SET")

## Writes the two companion files beside a finished take. Failure is reported and never fatal:
## the audio is the recording, and these are notes about it.
func _write_setlist(take_path: String) -> void:
	if _set_log.is_empty() or take_path.is_empty():
		return
	var base := take_path.get_basename()
	for pair in [[".txt", setlist_text(_set_log, take_path.get_file())],
			[".cue", cue_sheet(_set_log, take_path.get_file())]]:
		var f := FileAccess.open(base + str(pair[0]), FileAccess.WRITE)
		if not f:
			_log_fault("SET LIST NOT WRITTEN", "%s%s: %s" % [base, pair[0],
				error_string(FileAccess.get_open_error())])
			continue
		f.store_string(str(pair[1]))
		f.close()

## Rebuilt from the recorder's own counters rather than a second tally kept here, so
## the readout cannot disagree with what was actually written.
func _refresh_rec() -> void:
	if not is_instance_valid(_rec_btn):
		return
	var on: bool = _recorder.recording
	var broke: bool = not on and not _recorder.error.is_empty()
	# The readout carries the error in its own right -- text first, colour second, so it still
	# reads on a skin whose palette is nothing like this red and for anyone who cannot see it.
	if broke:
		_rec_status.add_theme_color_override("font_color", REC_ERROR_COLOR)
	else:
		_rec_status.remove_theme_color_override("font_color")
	_rec_btn.text = "[*] STOP AND SAVE" if on else ("[!] RECORD SET" if broke else "[ ] RECORD SET")
	_rec_dir_btn.text = _elide_head(_rec_dir, 34) if not _rec_dir.is_empty() else "[ CHOOSE... ]"
	var q: String = Recorder.QUALITY_NAMES[_rec_quality]
	var detail := "%s / %s" % [Recorder.FILE_TYPES[_rec_type], q]
	if broke:
		_rec_status.text = "[!] WRITE FAILED  //  %s  //  %.1f MB KEPT AS %s" % [
			_recorder.error.to_upper(), float(_recorder.frames_written) * 8.0 / 1048576.0,
			_recorder.last_take().get_file()]
	elif on:
		# discarded is the one number that matters while running: anything but 0 means
		# the capture buffer overran and audio is missing from the take
		_rec_status.text = "REC %s  //  %.1f MB  //  DROPPED %d  //  %s" % [
			_hms(_recorder.elapsed), float(_recorder.frames_written) * 8.0 / 1048576.0,
			_recorder.discarded, detail]
	else:
		_rec_status.text = "IDLE  //  %s  //  MASTER BUS, LENGTH LIMITED BY DISK" % detail

# --- FX tab: the dynamic rack ------------------------------------------------
## Fits "AUTO RATE HZ", the longest label any module declares. Every rack row uses it,
## so the captions, the switches and the dropdowns all line up in one column.
const RACK_LABEL_W := 132
# --- FX tab: the dynamic rack ------------------------------------------------
## Boots blank: four buttons, the Master Volume panel, and an empty module list.
func _setup_rack_tab(deck: int) -> void:
	var tab := VBoxContainer.new()
	tab.name = "FX %s" % ["A", "B"][deck]
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	_tabs.move_child(tab, _tabs.get_node("EQ").get_index() + 1 + deck)  # right after EQ, not after STATS

	# HFlow, not HBox: five buttons on one line is 1084 px of minimum width, and clipping
	# them instead leaves "ADD.../CLE.../CRE..." which is no use to anyone. Wrapping to a
	# second line keeps every caption readable at any sidebar width.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	tab.add_child(row)
	for spec in [["ADD EFFECT", "add"], ["CLEAR ALL", "clear"], ["CREATE PRESET", "new"],
			["DELETE PRESET", "del"], ["SELECT PRESET", "sel"]]:
		var b := Button.new()
		b.text = spec[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var what: String = spec[1]
		b.pressed.connect(func() -> void: _rack_action(deck, what))
		row.add_child(b)

	# Master Volume deliberately STAYS on the transport bar. Moving it here put the one
	# control you reach for constantly behind a tab switch, and made it disappear
	# entirely whenever any other tab was open -- a worse trade than the tidiness it
	# bought. The transport is visible on every tab, which is the whole point of it.

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	scroll.add_child(box)
	_rack_boxes[deck] = box
	_refresh_rack(deck)

## Rebuilt wholesale rather than patched: a module added or removed renumbers the boxes,
## and the rack is a handful of entries, not a track list.
func _refresh_rack(deck: int) -> void:
	# the rack as well as the box: the tab is built after _setup_eq creates the racks, but
	# one reorder of those two calls would turn this into a null deref at boot
	var box := _rack_boxes[deck]
	if not is_instance_valid(box) or deck >= _rack_decks.size():
		return
	var rack := _rack_decks[deck]
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	(_rack_bars[deck] as Dictionary).clear()
	var any := false
	for type in FxRack.MODULES:
		if rack.active.get(type, false):
			any = true
			_rack_module_box(deck, type)
	if not any:
		var empty := Label.new()
		empty.text = "RACK EMPTY  //  PRESS ADD EFFECT"
		box.add_child(empty)

## One module: the same 1 px outlined box the fixed rack uses, its parameters as drag
## bars, its switches as [*]/[ ] buttons and its choices as dropdowns -- all generated
## from FxRack.MODULES, so a new module is an entry in that table and nothing here.
func _rack_module_box(deck: int, type: String) -> void:
	var rack := _rack_decks[deck]
	var body := _fx_module(_rack_boxes[deck], "[ %s ]" % FxRack.module_name(type))
	var head: Control = body.get_child(0)
	# ON/BYP before REMOVE, and that order is the point: the one you want mid-set takes the
	# module out of the signal path and keeps every value it holds, where REMOVE throws them away
	var bypass_btn := Button.new()
	bypass_btn.toggle_mode = true
	bypass_btn.button_pressed = not bool(rack.bypass.get(type, false))
	_refresh_bypass_btn(bypass_btn)
	bypass_btn.pressed.connect(func() -> void:
		rack.set_bypass(type, not bypass_btn.button_pressed)
		_refresh_bypass_btn(bypass_btn)
		_save())
	head.add_child(bypass_btn)
	var vis := Button.new()
	vis.text = "VIS"
	vis.pressed.connect(func() -> void: _open_fx_window(deck, type))
	_hover_note(vis, func() -> String:
		return "%s ON ITS OWN, IN A WINDOW YOU CAN PUT ANYWHERE" % FxRack.module_name(type))
	head.add_child(vis)
	var kill := Button.new()
	kill.text = "REMOVE"
	kill.pressed.connect(func() -> void:
		rack.remove_module(type)
		_close_fx_window(deck, type)   # its window is about a module that is no longer here
		_refresh_rack(deck)
		_save())
	head.add_child(kill)
	_rack_controls(deck, body, type)

func _refresh_bypass_btn(btn: Button) -> void:
	btn.text = "[*] ON" if btn.button_pressed else "[ ] BYP"

## Every control a module has: its choices, its switches and its faders, built into `body`.
## The rack box and the detached VIS window are the same controls in two places, so they are
## built by the same function rather than drifting apart.
func _rack_controls(deck: int, body: Control, type: String) -> void:
	var rack := _rack_decks[deck]
	for key in FxRack._choices(type):
		var spec: Array = FxRack._choices(type)[key]
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 6)
		body.add_child(r)
		var l := Label.new()
		l.text = spec[0]
		l.custom_minimum_size.x = RACK_LABEL_W
		r.add_child(l)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# an OptionButton's minimum width is its WIDEST item, and a Control's minimum
		# propagates all the way up -- one long option name put a floor under the
		# sidebar that the OS window itself then refused to resize past
		opt.clip_text = true
		opt.custom_minimum_size.x = 90
		for i in (spec[1] as Array).size():
			opt.add_item(str((spec[1] as Array)[i]), i)
		opt.selected = rack.ch[type][key]
		opt.item_selected.connect(func(i: int) -> void:
			rack.set_choice(type, key, i)
			_save())
		r.add_child(opt)
	for key in FxRack._switches(type):
		var spec: Array = FxRack._switches(type)[key]
		var btn := _rack_switch(body, spec[0])
		btn.button_pressed = rack.sw[type][key]
		_refresh_rack_switch(btn, spec[0], btn.button_pressed)
		btn.pressed.connect(func() -> void:
			rack.set_switch(type, key, btn.button_pressed)
			_refresh_rack_switch(btn, spec[0], btn.button_pressed)
			_save())
	for key in FxRack._params(type):
		_rack_row(deck, body, type, key)

# --- one module, in its own window ------------------------------------------------------
## VIS pulls a single effect out into an OS window: the same controls as the rack box, with the
## width to actually use them, and nothing else on screen competing for the space. A module you
## are riding through a mix is a thing you want under the pointer, not three tabs deep.
##
## ponytail: the controls are the program's own faders and switches, not drawn knobs. A knob is
## new art and a new drag law for the one place it would appear; if the rotary look matters more
## than the consistency, that is the upgrade.
const FX_WIN_SIZE := Vector2i(420, 520)
var _fx_windows := {}   # "deck:type" -> Window

static func _fx_window_key(deck: int, type: String) -> String:
	return "%d:%s" % [deck, type]

func _open_fx_window(deck: int, type: String) -> void:
	var key := _fx_window_key(deck, type)
	var open: Window = _fx_windows.get(key)
	if is_instance_valid(open):
		open.grab_focus()   # already out there: bring it forward rather than opening a second
		return
	var win := Window.new()
	win.name = "Fx%s%d" % [type.capitalize(), deck]
	win.title = "SOUNDSCAPE // %s  (%s)" % [FxRack.module_name(type), AudioEngine.DECK_NAMES[deck]]
	win.size = FX_WIN_SIZE
	win.unresizable = false
	win.transient = false
	win.exclusive = false
	win.theme = theme
	add_child(win)
	_enable_window_fullscreen_toggle(win)
	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 8)
	chassis.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pad.add_child(col)
	var title := Label.new()
	title.text = "[ %s ]" % FxRack.module_name(type)
	title.theme_type_variation = &"Green"
	col.add_child(title)
	var rack := _rack_decks[deck]
	var bypass_btn := Button.new()
	bypass_btn.toggle_mode = true
	bypass_btn.button_pressed = not bool(rack.bypass.get(type, false))
	_refresh_bypass_btn(bypass_btn)
	bypass_btn.pressed.connect(func() -> void:
		rack.set_bypass(type, not bypass_btn.button_pressed)
		_refresh_bypass_btn(bypass_btn)
		_refresh_rack(deck)   # the rack box's own toggle says the same thing
		_save())
	col.add_child(bypass_btn)
	_rack_controls(deck, col, type)
	win.close_requested.connect(func() -> void: _close_fx_window(deck, type))
	_fx_windows[key] = win
	_centre_on_primary(win)
	win.show()

func _close_fx_window(deck: int, type: String) -> void:
	var key := _fx_window_key(deck, type)
	var win: Window = _fx_windows.get(key)
	_fx_windows.erase(key)
	if is_instance_valid(win):
		win.queue_free()

## No caption Label: the button already says the word, and having both rendered as
## "MODULAT      [ ] MODULATE OFF" -- the label clipped, the word duplicated, and the
## button stretched across the whole row so it read as floating text rather than a
## control. One compact, left-aligned button instead.
func _rack_switch(parent: Control, caption: String) -> Button:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	parent.add_child(r)
	var btn := Button.new()
	btn.toggle_mode = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size.x = RACK_LABEL_W
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	r.add_child(btn)
	return btn

func _refresh_rack_switch(btn: Button, caption: String, on: bool) -> void:
	btn.text = "[*] %s ON" % caption if on else "[ ] %s OFF" % caption

## Same ProgressBar + _bar_drag control every other fader in the program uses, rather
## than an HSlider the theme has no styles for.
func _rack_row(deck: int, parent: Control, type: String, key: String) -> void:
	var rack := _rack_decks[deck]
	var spec: Array = FxRack._params(type)[key]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = spec[0]
	# wide enough for the longest label in MODULES ("AUTO RATE HZ") so nothing clips;
	# the bar beside it is EXPAND_FILL and simply takes whatever is left
	l.custom_minimum_size.x = RACK_LABEL_W
	row.add_child(l)
	var bar := ProgressBar.new()
	bar.custom_minimum_size.y = 14
	bar.show_percentage = false
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)
	var val := Label.new()
	val.custom_minimum_size.x = 72
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.theme_type_variation = &"Green"
	row.add_child(val)
	_rack_bars[deck]["%s/%s" % [type, key]] = [bar, val]
	bar.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.double_click:
			rack.set_param(type, key, spec[3])   # double-click restores the spec default
			_refresh_rack_value(deck, type, key)
			_save_soon()
			return
		var w := _bar_wheel(e, inverse_lerp(spec[1], spec[2], rack.fx[type][key]))
		if w >= 0.0:
			rack.set_param(type, key, lerpf(spec[1], spec[2], w))
			_refresh_rack_value(deck, type, key)
			_save_soon()
			return
		if not _bar_drag(e, bar):
			return
		rack.set_param(type, key,
			lerpf(spec[1], spec[2], _ratio_at(e.position.x, bar.size.x)))
		_refresh_rack_value(deck, type, key)
		_save_soon())
	_refresh_rack_value(deck, type, key)

func _refresh_rack_value(deck: int, type: String, key: String) -> void:
	var pair: Array = (_rack_bars[deck] as Dictionary).get("%s/%s" % [type, key], [])
	if pair.is_empty():
		return
	var spec: Array = FxRack._params(type)[key]
	var v: float = _rack_decks[deck].fx[type][key]
	(pair[0] as ProgressBar).value = inverse_lerp(spec[1], spec[2], v) * 100.0
	(pair[1] as Label).text = _rack_value_text(key, v, spec[2] > 1.0)

## MIX and the other 0..1 depths read as per cent; anything with a real unit keeps it.
static func _rack_value_text(key: String, v: float, unit_ms := false) -> String:
	if key == "freq" or key == "tone":
		return _hz(v)
	if key == "rate":
		return "%.2f HZ" % v
	# by the parameter's own RANGE, not its current value: chorus depth is in ms and
	# pumper depth is a 0..1 amount, and reading "0.8" as a percentage on one and a
	# millisecond on the other is the same number meaning two different things
	if key == "depth" and unit_ms:
		return "%.2f MS" % v
	if key == "q":
		return "%.1f Q" % v
	if key == "pan":
		return "C" if absf(v) < 0.02 else ("L%d" % int(-v * 100.0) if v < 0.0 else "R%d" % int(v * 100.0))
	return "%d%%" % int(roundf(v * 100.0))

## The four buttons. Presets store the WHOLE rack -- which modules are in it and every
## value they hold -- so recalling one is a single from_dict, not a per-module replay.
func _rack_action(deck: int, what: String) -> void:
	var rack := _rack_decks[deck]
	match what:
		"add":
			var free: Array[String] = []
			for type in FxRack.MODULES:
				if not rack.active.get(type, false):
					free.append(type)
			if free.is_empty():
				_note = "  //  EVERY MODULE IS ALREADY IN THE RACK"
				_clear_note_later()
				return
			var labels: Array[String] = []
			for type in free:
				labels.append(FxRack.module_name(type))
			_rack_popup(labels, func(picked: String) -> void:
				rack.add_module(free[labels.find(picked)])
				_refresh_rack(deck)
				_save())
		"clear":
			# FxRack.clear() flips every slot's enable in one pass and leaves the effect
			# COUNT untouched, which is the whole point of the pre-allocated rack: this
			# empties the rack without the driver lock a remove_bus_effect would take.
			rack.clear()
			_refresh_rack(deck)
			_note = "  //  RACK CLEARED"
			_clear_note_later()
			_save()
		"new":
			_ask("CREATE PRESET", "RACK %d" % (_rack_presets.size() + 1),
				func(name: String) -> void:
					if name.is_empty():
						return
					_rack_presets[name] = rack.to_dict()
					_note = "  //  SAVED RACK PRESET %s" % name
					_clear_note_later()
					_save())
		"del":
			var names: Array[String] = []
			names.assign(_rack_presets.keys())
			if names.is_empty():
				_note = "  //  NO RACK PRESETS YET"
				_clear_note_later()
				return
			_rack_popup(names, func(picked: String) -> void:
				_rack_presets.erase(picked)
				_note = "  //  DELETED RACK PRESET %s" % picked
				_clear_note_later()
				_save())
		"sel":
			var names: Array[String] = []
			names.assign(_rack_presets.keys())
			if names.is_empty():
				_note = "  //  NO RACK PRESETS YET"
				_clear_note_later()
				return
			_rack_popup(names, func(picked: String) -> void:
				rack.from_dict(_rack_presets[picked])
				_refresh_rack(deck)
				_note = "  //  LOADED RACK PRESET %s" % picked
				_clear_note_later()
				_save())

## A throwaway menu rather than the shared %Menu: these lists are built from whatever
## is in the rack right now, and routing four more id ranges through _on_menu_id would
## be more bookkeeping than the menu is worth.
func _rack_popup(items: Array[String], on_pick: Callable) -> void:
	var menu := PopupMenu.new()
	menu.theme = theme
	add_child(menu)
	for i in items.size():
		menu.add_item(items[i], i)
	menu.id_pressed.connect(func(id: int) -> void: on_pick.call(items[id]))
	menu.popup_hide.connect(menu.queue_free)   # id_pressed has already fired by then
	menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))

## A rack module: 1 px bordered panel, a header row, then rows. The header row is child 0,
## which is where _rack_module_box hangs its REMOVE button.
func _fx_module(parent: Control, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	parent.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	var caption := Label.new()
	caption.text = title
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	return col

# --- key readout -----------------------------------------------------------
## Short form for the STATS column, which has no room for the arrow.
## The track's key as tagged or estimated. There is no transposition to fold in any more:
## KEY SHIFT went with the fixed rack, and FxRack has no pitch module, so what the file says
## is what is playing.
func _key_stat() -> String:
	var t: String = str(_key.get("text", ""))
	return "--" if t.is_empty() else t

static func _hz(hz: float) -> String:
	# the unit was missing below 1 kHz, so a rack row read "FREQ 800" directly above
	# "AUTO RATE 1.20 HZ" -- same column, two different conventions
	return "%.1fK HZ" % (hz / 1000.0) if hz >= 1000.0 else "%d HZ" % int(hz)


# --- playlists, cue markers and the context menu ---------------------------
## All three ride machinery that is already here. A playlist is a second filter over the
## same visible list SEARCH filters, so the queue, the track count and the TOTAL TIME
## readout all scope themselves -- `_refill` stays the single place that decides what is
## playable. Cue markers are painted onto the existing scrub ProgressBar through its
## `draw` signal rather than an overlay node, so they inherit its geometry for free and
## there is nothing to keep in sync when the window resizes.
##
## Stored in library.cfg as one Dictionary per key rather than one key per track, because
## ConfigFile would otherwise need every absolute path quoted as a section key:
##
##   [playlists] list   = { NAME: [path, ...] }
##   [playlists] cues   = { NAME: { path: [cue, ...] } }    playlist-scoped cues
##   [cues]      tracks = { path: [cue, ...] }              globally-scoped cues
##   [library]   track_labels = { path: NAME }              RENAME TAG overrides
##   cue = { "id": int, "time": float, "label": String, "color": String,
##           "key": String, "shape": String }
##   -- "key" is present only once one is assigned; "shape" defaults to "square"
##
## The track's path is the dictionary KEY rather than a "path" field inside each record:
## the lookup runs every time the bar repaints, which is every frame while a track plays,
## and a hash hit beats scanning a list of records for a matching field.
##
## Every write here goes through _save_soon() -- the 1.5 s debounce the EQ faders and the
## volume bar already use -- except the two that must not be able to disagree with the
## disk (a new playlist, a deleted file), which call _save() outright.
func _setup_menus() -> void:
	for crate in 2:
		([_tracks, _tracks_b][crate] as ItemList).item_clicked.connect(_on_item_clicked.bind(crate))
	%Menu.id_pressed.connect(_on_menu_id)
	%PlMenu.id_pressed.connect(_on_menu_id)
	var shapes := PopupMenu.new()
	shapes.name = "ShapeMenu"
	%Menu.add_child(shapes)
	shapes.owner = self
	shapes.unique_name_in_owner = true   # %ShapeMenu
	shapes.id_pressed.connect(_on_menu_id)
	%Ask.confirmed.connect(func() -> void:
		if _ask_cb.is_valid():
			_ask_cb.call(%AskLine.text.strip_edges()))
	# Enter in the field is the same as pressing OK, which is what a rename prompt has to
	# do -- without it the dialog is a text box you cannot finish from the keyboard
	%Ask.register_text_enter(%AskLine)
	_ask_cancel = %Ask.add_cancel_button("CANCEL")
	# RMB on the picker acts on the playlist it is showing. The picker IS the sidebar's
	# playlist control, and PopupMenu gives no per-item right-click signal to hang this
	# off inside the drop-down, so the button itself is where it goes.
	for crate in 2:
		var picker: OptionButton = [%Playlist, %PlaylistB][crate]
		picker.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
				_menu_crate = crate
				_popup_playlist_menu())
		picker.item_selected.connect(func(i: int) -> void:
			_library.crate_pl[crate] = "" if i == 0 else picker.get_item_text(i)
			_refill(crate)
			if crate == 0:
				_write_in()   # the write-in is TRK A's
			_cue_overlay.queue_redraw()   # playlist-scoped cues come and go with the scope
			_save_soon())
	# MARK MODE is deliberately not persisted. It changes what a click on the scrub bar
	# does, and booting into a player whose scrub bar silently refuses to seek is a bug
	# report, not a restored preference.
	%Mark.toggled.connect(func(on: bool) -> void:
		_mark_mode = on
		%Mark.text = "MARK:ON" if on else "MARK:OFF")
	_hover_note(%Mark, func() -> String:
		return "MARK MODE: CLICK THE BAR TO DROP A CUE THERE  //  SEEKING IS OFF" if _mark_mode \
			else "MARK MODE: OFF")
	_setup_cue_overlay()
	_setup_dual_bars()
	_refresh_playlists()

## Cue markers get their own canvas item. Nothing is painted into %Scrub any more.
##
## The overlay is a child of %Scrub with full-rect anchors rather than a sibling in the
## ScrubRow HBox: a sibling would claim layout space and push the bar around, while a
## child of a non-container Control is positioned by its anchors alone and follows the
## bar's rect through every resize and orientation flip for free. It has no draw of its
## own beyond the markers, so the ProgressBar's fill is untouched geometry.
##
## MOUSE_FILTER_PASS is what keeps the bar usable: the overlay sees each press first, and
## anything that is not a marker is left unaccepted and continues to %Scrub, which still
## seeks and still drops markers in MARK MODE exactly as before.
##
## The top edge is lifted by one tab height so the caps sit ABOVE the bar instead of
## inside the green fill -- that is the part that read as the fill being "split". Set
## offset_top back to 0 to put them inside the bar again.
func _setup_cue_overlay() -> void:
	_cue_overlay = Control.new()
	_cue_overlay.name = "CueOverlay"
	_cue_overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	_scrub.add_child(_cue_overlay)
	_cue_overlay.owner = self
	_cue_overlay.unique_name_in_owner = true   # %CueOverlay
	# anchors AND offsets: set_anchors_preset alone keeps the node's current rect, which
	# for a Control created a line earlier is 0x0 -- measured, that produced a 6 px tall
	# overlay sitting above an untouched bar, with every marker clipped out of existence
	_cue_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cue_overlay.offset_top = -CUE_TAB.y
	_cue_overlay.draw.connect(_draw_cues)
	_cue_overlay.gui_input.connect(_on_overlay_input)
	# the ProgressBar used to repaint every frame as its value changed, which hid the
	# fact that markers need a repaint of their own; an overlay only redraws when asked
	_cue_overlay.resized.connect(_cue_overlay.queue_redraw)

# --- DUAL PLAY BARS -------------------------------------------------------------------------
## One transport bar shows the deck the transport is on, which means the other deck's playhead,
## waveform and markers are invisible until you switch to it -- and switching is exactly what you
## do not want to do while beat-matching. With this on there are two bars, deck A above deck B,
## both drawn all the time whatever has focus.
##
## The second bar is a SIBLING of %ScrubRow inside the PlayerBar column, not a reparenting of
## anything the scene ships. That matters here: %ScrubRow, %Scrub and %CueOverlay are all
## %UniqueNames, and moving them around is how this program has broken itself before.
##
## Click-to-seek works on it; dragging a marker does not. Cue editing stays on the main bar
## where the menu, the audition and the drag already live, rather than being half-implemented in
## two places.
var _dual_bars := false          # TBS DUAL PLAY BARS, saved
var _dual_bars_btn: Button
var _scrub_b: ProgressBar
var _overlay_b: Control
var _dual_row: Control

func _setup_dual_bars() -> void:
	var bar := %ScrubRow.get_parent()   # the PlayerBar column built by _setup_playbar_split
	_dual_row = HBoxContainer.new()
	_dual_row.name = "ScrubRowB"
	_dual_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(_dual_row as HBoxContainer).add_theme_constant_override("separation", 6)
	bar.add_child(_dual_row)
	bar.move_child(_dual_row, %ScrubRow.get_index() + 1)
	var tag := Label.new()
	tag.text = "B"
	tag.theme_type_variation = &"Green"
	_dual_row.add_child(tag)
	_pin_label(tag)
	_scrub_b = ProgressBar.new()
	_scrub_b.name = "ScrubB"
	_scrub_b.show_percentage = false
	_scrub_b.max_value = 100.0
	_scrub_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub_b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# the scene's own bar carries stylebox overrides; a ProgressBar built at runtime gets the
	# theme default instead, and the two bars then look like they came from different programs
	for style: String in ["background", "fill"]:
		var sb: StyleBox = %Scrub.get_theme_stylebox(style)
		if sb:
			_scrub_b.add_theme_stylebox_override(style, sb)
	_dual_row.add_child(_scrub_b)
	_overlay_b = Control.new()
	_overlay_b.name = "CueOverlayB"
	_overlay_b.mouse_filter = Control.MOUSE_FILTER_PASS
	_scrub_b.add_child(_overlay_b)
	_overlay_b.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay_b.offset_top = -CUE_TAB.y
	_overlay_b.draw.connect(func() -> void: _draw_cues_on(_overlay_b, 1))
	_overlay_b.resized.connect(_overlay_b.queue_redraw)
	# click anywhere on B's bar to seek B -- through _seek_deck, so it works while B is paused
	_scrub_b.gui_input.connect(func(e: InputEvent) -> void:
		var click := e as InputEventMouseButton
		if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			_seek_deck(1, _ratio_at(click.position.x, _scrub_b.size.x) * _deck_len(1))
			_scrub_b.accept_event())
	_hover_note(_scrub_b, func() -> String:
		var path := _deck_path(1)
		return "DECK B: %s  //  %s" % [path.get_file() if not path.is_empty() else "EMPTY",
			_deck_state(1)])
	_apply_dual_bars()

## The A tag only appears when there are two bars to tell apart. With one bar it would be a
## label on the only thing there is.
func _apply_dual_bars() -> void:
	if not is_instance_valid(_dual_row):
		return
	_dual_row.visible = _dual_bars and _playbar_on and _feed != Feed.FULLSCREEN
	var tag_a := %ScrubRow.get_node_or_null("ScrubTagA") as Label
	if _dual_bars and not tag_a:
		tag_a = Label.new()
		tag_a.name = "ScrubTagA"
		tag_a.text = "A"
		tag_a.theme_type_variation = &"Green"
		%ScrubRow.add_child(tag_a)
		%ScrubRow.move_child(tag_a, 0)
		_pin_label(tag_a)
	elif tag_a:
		tag_a.visible = _dual_bars
	_cue_overlay.queue_redraw()   # the main bar changes which deck it is showing

## Deck B's bar, stepped from _process beside the main one.
func _step_dual_bars() -> void:
	if not _dual_bars or not is_instance_valid(_scrub_b) or not _scrub_b.is_visible_in_tree():
		return
	var span := _deck_len(1)
	_scrub_b.value = clampf(_deck_pos(1) / span * 100.0, 0.0, 100.0) if span > 0.0 else 0.0
	_overlay_b.queue_redraw()

## Rebuilt rather than patched: playlists are a handful of entries, and this runs on a
## config load or a playlist being created, not per frame.
func _refresh_playlists() -> void:
	for crate in 2:
		var picker: OptionButton = [%Playlist, %PlaylistB][crate]
		picker.clear()
		picker.add_item("ALL TRACKS")
		for name in _library.playlists:
			picker.add_item(name)
		# index 0 is ALL TRACKS, so a playlist sits one past its position in the dictionary
		var at := _library.playlists.keys().find(_library.crate_pl[crate])
		picker.selected = at + 1 if at >= 0 else 0

# --- context menu ----------------------------------------------------------
## Two open-ended ranges at the top, everything fixed below them: a playlist is
## PL_FIRST + its index, a palette colour is COLOR_FIRST + its index.
const PL_FIRST := 100
const COLOR_FIRST := 200
const SHAPE_FIRST := 300
## Tab handle shapes, in menu order. The stored value is the lowercase name, so a config
## written before shapes existed reads back as "square" through the default.
const SHAPES := ["square", "circle", "triangle"]
const MENU_NEW_PL := 1
const MENU_RENAME := 2
const MENU_UNFILE := 3
const MENU_INFO := 4
const MENU_DELETE := 5
const MENU_CUE_GLOBAL := 6
const MENU_CUE_LOCAL := 7
const MENU_CUE_DELETE := 8
const MENU_CUE_HEX := 9
const MENU_CUE_KEY := 10
const MENU_PL_DELETE := 11
const MENU_CUE_TS := 12
const MENU_DECK_A := 14
const MENU_MAKE_PLAYLIST := 17   # was 14 -- MENU_DECK_A's id, so the folder item ran PLAY ON DECK A
const MENU_PL_UP := 15
const MENU_PL_DOWN := 16
const MENU_PLAY_NEXT := 18
const MENU_QUEUE := 19
const MENU_QUEUE_CLEAR := 20
const MENU_CUES := 21

## RMB anywhere on a row. `item_clicked` hands back the row index, so there is no
## hit-testing to do and no gui_input handler to write; `allow_rmb_select` in the scene is
## what makes the row highlight under the cursor, so the menu visibly belongs to a track.
func _on_item_clicked(row: int, _at: Vector2, button: int, crate: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var row_path: PackedInt32Array = _row_paths[crate]
	if row < 0 or row >= row_path.size() or row_path[row] < 0:
		return   # a FOLDER-mode header row is not a track
	_menu_crate = crate   # REMOVE FROM / MOVE UP act on THIS list's playlist
	# RMB on a row that is part of the selection means the whole selection; on any other row it
	# means that row alone.
	#
	# The bundle comes from the SNAPSHOT _on_list_pointer took on the press, not from the list:
	# ItemList collapses its selection to the row under the pointer before item_clicked fires, so
	# reading it here always answered "one track". And the target is built explicitly rather than
	# with a ternary, because `[path] as Array[String]` is NOT a typed array at runtime -- the
	# call was failing the argument's type check and the menu never opened at all.
	var path: String = _library.paths[row_path[row]]
	var target: Array[String] = []
	if _rmb_bundle.size() > 1 and path in _rmb_bundle:
		target = _rmb_bundle
		_reselect(crate, target)   # put the highlight back on the rows the menu is about
	else:
		target.append(path)
	_rmb_bundle = []
	_popup_track_menu(path, target)

## Selects every row holding one of `paths`, for putting a bundle back after ItemList has
## collapsed it. Rows that are filtered out of this crate's view simply have none.
func _reselect(crate: int, paths: Array[String]) -> void:
	var list: ItemList = [_tracks, _tracks_b][crate]
	var path_row: PackedInt32Array = _path_rows[crate]
	for path in paths:
		var i: int = _library.path_pos.get(path, -1)
		if i >= 0 and i < path_row.size() and path_row[i] >= 0 and path_row[i] < list.item_count:
			list.select(path_row[i], false)

func _popup_track_menu(path: String, picked: Array[String] = []) -> void:
	if picked.is_empty():
		picked = [path] as Array[String]
	_menu_ctx = {"kind": "track", "path": path, "picked": picked}
	# how many tracks every item below is about, said once rather than on each line
	var many := "" if picked.size() < 2 else "  (%d)" % picked.size()
	%PlMenu.clear()
	for i in _library.playlists.size():
		%PlMenu.add_item(_library.playlists.keys()[i], PL_FIRST + i)
	%PlMenu.add_separator()
	%PlMenu.add_item("+ NEW PLAYLIST", MENU_NEW_PL)
	%Menu.clear()
	# the two queue actions lead: they are what a set is built out of, and everything below
	# them is housekeeping
	%Menu.add_item("PLAY NEXT%s" % many, MENU_PLAY_NEXT)
	%Menu.add_item("ADD TO QUEUE%s" % many, MENU_QUEUE)
	if not _up_next.is_empty():
		%Menu.add_item("CLEAR QUEUE  (%d)" % _up_next.size(), MENU_QUEUE_CLEAR)
	%Menu.add_separator()
	%Menu.add_submenu_node_item("ADD TO PLAYLIST", %PlMenu)
	%Menu.add_item("RENAME TAG", MENU_RENAME)
	# offered only where it can do something, and it is the only way back out of a
	# mis-click on ADD TO PLAYLIST
	var playlist: String = _library.crate_pl[_menu_crate]
	# offered when ANY of the bundle is filed here, not just the row under the pointer: the
	# item removes all of them, so it has to appear whenever there is something to remove
	if not playlist.is_empty() and _filed_count(playlist, picked) > 0:
		%Menu.add_item("REMOVE FROM %s%s" % [playlist, many], MENU_UNFILE)
		# manual rearrangement: only meaningful while VIEWING the playlist the track is
		# actually filed in, which not is_empty() + the membership check above both cover.
		# Single-track only -- moving nine rows "up one" has no meaning anyone agrees on.
		if picked.size() == 1:
			%Menu.add_item("MOVE UP IN PLAYLIST", MENU_PL_UP)
			%Menu.add_item("MOVE DOWN IN PLAYLIST", MENU_PL_DOWN)
	%Menu.add_item("PLAY ON DECK A", MENU_DECK_A)
	%Menu.add_item("EDIT CUES", MENU_CUES)
	%Menu.add_item("TRACK INFO", MENU_INFO)
	%Menu.add_separator()
	%Menu.add_item("DELETE FROM DISK", MENU_DELETE)
	_popup_at_mouse()

## The marker editor. Same single PopupMenu node as the track menu, rebuilt -- and the
## same submenu node too, since a menu can only be in one place at a time anyway.
##
## SCOPE is two checkable items rather than one toggling line: with a radio mark you can
## see which scope the marker is in without clicking anything, where a toggle labelled
## with its own action always reads ambiguously ("does that say what it IS, or what it
## will DO?").
func _popup_cue_menu(cue: Dictionary) -> void:
	_menu_ctx = {"kind": "cue", "cue": cue}
	var local := _cue_is_local(cue)
	%PlMenu.clear()
	for i in _viz.PRESETS.size():
		# the visualizer's palette, which is the one set of colours this program already
		# owns -- a second palette would be a second thing to keep looking right per skin
		%PlMenu.add_icon_item(_swatch(_viz.PRESETS[i]),
			(_viz.PRESETS[i] as Color).to_html(false).to_upper(), COLOR_FIRST + i)
	%PlMenu.add_separator()
	%PlMenu.add_item("CUSTOM HEX...", MENU_CUE_HEX)
	%ShapeMenu.clear()
	for i in SHAPES.size():
		%ShapeMenu.add_radio_check_item((SHAPES[i] as String).to_upper(), SHAPE_FIRST + i)
		%ShapeMenu.set_item_checked(i, str(cue.get("shape", "square")) == SHAPES[i])
	%Menu.clear()
	# the timestamp leads: it is the one thing about a marker you read as often as you
	# change it, and it doubles as the edit field
	%Menu.add_item("TS %s" % _time_text(float(cue["time"])), MENU_CUE_TS)
	%Menu.add_separator()
	%Menu.add_icon_item(_swatch(Color(str(cue["color"]))), "SELECT COLOR", -1)
	%Menu.set_item_submenu_node(%Menu.item_count - 1, %PlMenu)
	%Menu.add_item("CHANGE SHAPE", -1)
	%Menu.set_item_submenu_node(%Menu.item_count - 1, %ShapeMenu)
	var key := str(cue.get("key", ""))
	%Menu.add_item("ASSIGN KEYBIND%s" % ("" if key.is_empty() else "  [%s]" % key),
		MENU_CUE_KEY)
	%Menu.add_separator()
	%Menu.add_radio_check_item("SCOPE: TRACK GLOBAL", MENU_CUE_GLOBAL)
	%Menu.set_item_checked(%Menu.item_count - 1, not local)
	%Menu.add_radio_check_item("SCOPE: PLAYLIST ONLY", MENU_CUE_LOCAL)
	%Menu.set_item_checked(%Menu.item_count - 1, local)
	%Menu.add_separator()
	%Menu.add_item("DELETE MARKER", MENU_CUE_DELETE)
	_popup_at_mouse()

## Which store this marker lives in. Read rather than remembered: the scope IS where the
## cue is, and a second copy of that fact in the cue record could disagree with it.
func _cue_is_local(cue: Dictionary) -> bool:
	if _library.crate_pl[_bar_deck()].is_empty():
		return false
	return cue in ((_library.pl_cues.get(_library.crate_pl[_bar_deck()], {}) as Dictionary).get(_library.id_for(_bar_path()), []) as Array)

## A 12 px colour chip for a menu item. Cached per colour, because a menu rebuild would
## otherwise allocate a texture per swatch every time a marker is clicked.
func _swatch(c: Color) -> ImageTexture:
	var key := c.to_html(false)
	if not _swatch_cache.has(key):
		var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
		img.fill(c)
		_swatch_cache[key] = ImageTexture.create_from_image(img)
	return _swatch_cache[key]

## RMB on the playlist picker. ALL TRACKS is not a playlist and has nothing to delete,
## so the menu simply does not open there.
func _popup_playlist_menu() -> void:
	var playlist: String = _library.crate_pl[_menu_crate]
	if playlist.is_empty():
		return
	_menu_ctx = {"kind": "playlist", "playlist": playlist}
	%Menu.clear()
	%Menu.add_item("DELETE PLAYLIST %s" % playlist, MENU_PL_DELETE)
	_popup_at_mouse()

## Dropping a playlist also drops every cue that was scoped to it -- those cues exist
## nowhere else, which is why this one asks first. Tracks are untouched: a playlist is a
## view of the library, never a container for it.
func _delete_playlist(name: String) -> void:
	_library.playlists.erase(name)
	_library.pl_cues.erase(name)
	for crate in 2:
		if _library.crate_pl[crate] == name:
			_library.crate_pl[crate] = ""   # back to ALL TRACKS rather than a scope that no longer exists
	_refresh_playlists()
	_refill()
	_cue_overlay.queue_redraw()
	_note = "  //  DELETED PLAYLIST %s" % name
	_clear_note_later()
	_save_soon()

## Screen coordinates, not viewport ones: this project runs with embed_subwindows off,
## so a popup is a real OS window and positions itself against the desktop.
func _popup_at_mouse() -> void:
	%Menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))

func _on_menu_id(id: int) -> void:
	var path: String = _menu_ctx.get("path", "")
	var cue: Dictionary = _menu_ctx.get("cue", {})
	# Every track action is about the BUNDLE the menu was opened on -- [path] alone unless the
	# RMB landed inside a multi-selection. `path` stays the one the pointer was over, for the
	# things that only make sense singly (RENAME TAG, TRACK INFO, PLAY ON DECK A).
	var picked: Array[String] = []
	picked.assign(_menu_ctx.get("picked", [path]))
	if id >= SHAPE_FIRST:
		cue["shape"] = SHAPES[id - SHAPE_FIRST]
		_cue_overlay.queue_redraw()
		_save_soon()
	elif id >= COLOR_FIRST:
		_set_cue_color(cue, (_viz.PRESETS[id - COLOR_FIRST] as Color).to_html(false))
	elif id >= PL_FIRST:
		_file_track(_library.playlists.keys()[id - PL_FIRST], picked)
	elif id == MENU_PLAY_NEXT or id == MENU_QUEUE:
		_queue_tracks(picked, id == MENU_PLAY_NEXT)
	elif id == MENU_QUEUE_CLEAR:
		_clear_queue()
	elif id == MENU_DECK_A:
		_play_on_deck_a(path)
	elif id == MENU_NEW_PL:
		_ask("NEW PLAYLIST", "PLAYLIST %d" % (_library.playlists.size() + 1),
			func(name: String) -> void:
				if name.is_empty() or _library.playlists.has(name):
					return
				_library.playlists[name] = []
				_refresh_playlists()
				_file_track(name, picked)
				_save())
	elif id == MENU_RENAME:
		_ask("RENAME TAG", _library.labels.get(_library.id_for(path), path.get_file()), func(name: String) -> void:
			if name.is_empty():
				_library.labels.erase(_library.id_for(path))   # cleared back to the filename on disk
			else:
				_library.labels[_library.id_for(path)] = name
			_reindex()   # the row text and the search haystack are both built there
			_save_soon())
	elif id == MENU_UNFILE:
		_remove_from_playlist(_library.crate_pl[_menu_crate], picked)
	elif id == MENU_CUES:
		_edit_cues(path)
	elif id == MENU_PL_UP or id == MENU_PL_DOWN:
		var order: Array[String] = []
		order.assign(_library.playlists.get(_library.crate_pl[_menu_crate], []))
		setlist_move(order, order.find(_library.id_for(path)), -1 if id == MENU_PL_UP else 1)
		_library.playlists[_library.crate_pl[_menu_crate]] = order
		_refill()
		_save_soon()
	elif id == MENU_MAKE_PLAYLIST:
		var folder: String = _menu_ctx.get("path", "")
		_ask("MAKE PLAYLIST", folder.get_file(), func(name: String) -> void:
			if name.is_empty() or _library.playlists.has(name):
				return
			# direct children only -- sub-folders are ignored, same rule the checkbox
			# filter uses one level down
			var tracks: Array[String] = []
			for p in _library.all_paths:
				if p.get_base_dir() == folder:
					tracks.append(_library.id_for(p))
			_library.playlists[name] = tracks
			# opened in the driven deck's crate (DIRS belongs to neither list), set before
			# _refresh_playlists so that picker selects the new one
			_library.crate_pl[_engine.deck] = name
			_refresh_playlists()
			_refill()
			_write_in()
			_note = "  //  MADE PLAYLIST %s (%d TRACKS)" % [name, tracks.size()]
			_clear_note_later()
			_save())
	elif id == MENU_INFO:
		_show_info(path)
	elif id == MENU_DELETE:
		# The one menu item that changes the disk, and it sat one mis-click away from RENAME
		# TAG in the same list. The recycle bin makes it recoverable, not harmless: the cues,
		# the RENAME tag and every playlist entry for the track go with it, and none of those
		# come back out of the bin.
		_confirm("DELETE FROM DISK

%s

MOVES THE FILE TO THE RECYCLE BIN AND FORGETS ITS CUES, TAG AND PLAYLIST ENTRIES." % path.get_file(),
			_delete_track.bind(path))
	elif id == MENU_CUE_GLOBAL:
		_move_cue(cue, false)
	elif id == MENU_CUE_LOCAL:
		_move_cue(cue, true)
	elif id == MENU_CUE_DELETE:
		_delete_cue(cue)
	elif id == MENU_CUE_HEX:
		_ask("MARKER COLOUR (HEX)", str(cue["color"]), func(hex: String) -> void:
			if not Color.html_is_valid(hex):
				_note = "  //  NOT A COLOUR: %s" % hex
				_clear_note_later()
				return
			_set_cue_color(cue, Color(hex).to_html(false)))
	elif id == MENU_CUE_TS:
		# full precision in the FIELD whatever SHOW MS says: the menu label is a readout
		# and may round, but an editor prefilled with "01:42" would quietly throw away
		# the 250 ms the marker actually holds the moment the user pressed OK
		_ask("MARKER TIMESTAMP (MM:SS:MS)", ts_text(float(cue["time"])),
			func(raw: String) -> void:
				var t := ts_parse(raw)
				if t < 0.0:
					_note = "  //  NOT A TIMESTAMP: %s" % raw
					_clear_note_later()
					return
				# clamped to the track, and playback is not touched: retiming a marker is
				# an edit to the marker, not a seek
				_cue_edit_begin(cue)
				cue["time"] = clampf(t, 0.0, _len())
				_cue_undo_commit()
				_note = "  //  %s -> %s" % [cue["label"], _time_text(float(cue["time"]))]
				_clear_note_later()
				_cue_overlay.queue_redraw()
				_save_soon(), 12)
	elif id == MENU_CUE_KEY:
		_ask("JUMP KEY FOR %s" % cue["label"], str(cue.get("key", "")),
			func(raw: String) -> void: _set_cue_key(cue, raw), 1)
	elif id == MENU_PL_DELETE:
		_confirm("DELETE PLAYLIST %s\nAND ITS %d CUE SETS?" % [_menu_ctx.get("playlist", ""),
			(_library.pl_cues.get(_menu_ctx.get("playlist", ""), {}) as Dictionary).size()],
			_delete_playlist.bind(_menu_ctx.get("playlist", "")))

## How many of `paths` are filed under `name`. What decides whether REMOVE FROM PLAYLIST is
## worth offering, and it counts the whole bundle rather than the row under the pointer.
func _filed_count(name: String, paths: Array[String]) -> int:
	var list: Array = _library.playlists.get(name, [])
	var n := 0
	for path in paths:
		if list.has(_library.id_for(path)):
			n += 1
	return n

## Takes every track in `paths` out of `name`. The bundle, for the same reason _file_track
## takes it: REMOVE FROM PLAYLIST is offered on a multi-selection like everything else in that
## menu, and pulling one track out of nine highlighted ones is not what the highlight says.
func _remove_from_playlist(name: String, paths: Array[String]) -> void:
	var list: Array = _library.playlists.get(name, [])
	var gone := 0
	for path in paths:
		var id := _library.id_for(path)
		if list.has(id):
			list.erase(id)
			gone += 1
	_library.playlists[name] = list
	_note = "  //  REMOVED FROM %s" % name if gone == 1 else "  //  REMOVED %d FROM %s" % [gone, name]
	_clear_note_later()
	_refill()   # the rows just left this crate's scope
	_save_soon()

## EDIT CUES. A track's markers are drawn on the SCRUB BAR and edited there -- dragged along
## it, right-clicked for colour, scope, key and timestamp -- so editing them means putting the
## track on the transport. That is all this does, plus say where to go next; a second cue
## editor in a window would be a second place for the same markers to disagree about.
func _edit_cues(path: String) -> void:
	_open_deck(_engine.deck, path)
	_note = "  //  CUES FOR %s ARE ON THE SCRUB BAR -- DRAG A MARKER, OR RIGHT-CLICK IT" % path.get_file()
	_clear_note_later()

## Files every track in `paths` under `name`, skipping the ones already there. Takes the bundle
## rather than one path because ADD TO PLAYLIST is offered on a multi-selection: it read only
## _menu_ctx["path"] and quietly filed one track out of nine.
func _file_track(name: String, paths: Array[String]) -> void:
	var list: Array = _library.playlists.get(name, [])
	var added := 0
	for path in paths:
		var id := _library.id_for(path)
		if not list.has(id):
			list.append(id)
			added += 1
	_library.playlists[name] = list
	if added == 0:
		_note = "  //  ALREADY IN %s" % name
	elif paths.size() == 1:
		_note = "  //  FILED UNDER %s" % name
	else:
		_note = "  //  FILED %d UNDER %s" % [added, name]
	_clear_note_later()
	_refill()   # the track may have just entered the active scope
	_save_soon()

## One dialog for every prompt in the program: NEW PLAYLIST and RENAME TAG both want a
## line of text, and TRACK INFO wants the same box with the field hidden. A second dialog
## node would be a second thing to theme and a second thing to position.
## `max_len` of 0 is LineEdit's "no limit"; the keybind prompt passes 1, so a jump key
## cannot be typed as a word and then silently truncated to its first letter.
func _ask(prompt: String, initial: String, cb: Callable, max_len := 0) -> void:
	_ask_cb = cb
	%Ask.title = prompt
	%Ask.dialog_text = ""
	%AskLine.visible = true
	_ask_cancel.visible = false
	%AskLine.max_length = max_len
	%AskLine.text = initial
	%Ask.popup_centered()
	%AskLine.grab_focus()
	%AskLine.select_all()

## The same dialog with the field hidden and a CANCEL button showing. Used where an
## action cannot be undone and the config is the only copy of what it destroys.
func _confirm(text: String, cb: Callable) -> void:
	_ask_cb = func(_s: String) -> void: cb.call()
	%Ask.title = "CONFIRM"
	%Ask.dialog_text = text
	%AskLine.visible = false
	_ask_cancel.visible = true
	%Ask.popup_centered()

func _show_info(path: String) -> void:
	# cached when the track has played or been swept, and probed on the spot otherwise --
	# a deliberate exception to the no-inline-probe rule, because this is one file, asked
	# for by name, and the answer is the whole point of the menu item
	var m := _engine.metadata(path)
	var secs := float(m.get("duration", 0.0))
	var key_txt := str(m["key"]["text"])
	_ask_cb = Callable()
	%AskLine.visible = false
	_ask_cancel.visible = false
	%Ask.title = "TRACK INFO"
	%Ask.dialog_text = "\n".join([
		path.get_file(), "",
		"TITLE...%s" % m["title"],
		"ARTIST..%s" % (m["artist"] if m["artist"] else "-"),
		"ALBUM...%s" % (m["album"] if m["album"] else "-"),
		"KEY.....%s" % (key_txt if key_txt else "-"),
		"LENGTH..%s" % (_dur_text(secs) if secs > 0.0 else "-"),
		"FORMAT..%s %d HZ %d BIT %s" % [m["codec"], m["sample_rate"], m["bits"],
			"STEREO" if m["channels"] >= 2 else "MONO"],
		"CUES....%d" % _cues_for(path).size(),
		"", path,
	])
	%Ask.popup_centered()

## DELETE FROM DISK goes to the recycle bin, not to oblivion.
##
## OS.move_to_trash is the whole feature: one stdlib call, the same thing the file
## manager on this machine does, and recoverable. A raw DirAccess.remove() would be the
## same number of lines and would let a mis-click in a context menu -- one item away from
## RENAME TAG -- permanently destroy someone's music.
func _delete_track(path: String) -> void:
	var err := OS.move_to_trash(ProjectSettings.globalize_path(path))
	if err != OK:
		_log_fault("DELETE FAILED", "%s (%s)" % [path, error_string(err)])
		_note = "  //  COULD NOT DELETE %s (%d)" % [path.get_file(), err]
		_clear_note_later()
		return
	# the file is gone, so every reference to it is dead weight that would be re-saved
	# forever otherwise
	var gone := _library.id_for(path)
	_library.cues.erase(gone)
	_library.labels.erase(gone)
	for name in _library.playlists:
		(_library.playlists[name] as Array).erase(gone)
	for name in _library.pl_cues:
		(_library.pl_cues[name] as Dictionary).erase(gone)
	_note = "  //  MOVED TO RECYCLE BIN: %s" % path.get_file()
	_clear_note_later()
	_save()      # the disk has already changed; the config must not be able to disagree
	_rescan()

# --- cue markers -----------------------------------------------------------
## Half-width of a marker's click target, in pixels. A 2 px line is not something a hand
## can hit, so the hit box is the line plus four pixels either side.
const CUE_GRAB := 5.0

## Everything drawn and clickable for this track: the track's own cues, plus the ones
## scoped to the playlist that is currently active. A cue lives in exactly one of the
## two, which is what makes the scope menu a move rather than a copy.
## `deck` says whose playlist scope to merge in. It defaults to -1, meaning "work it out from
## the path", so every existing caller keeps behaving as it did -- and a caller that knows which
## deck it is asking about can say so and get the right answer.
##
## Reading the BAR deck's scope for whatever path it was handed was wrong the moment a second
## bar could draw the other deck and a pad could place a marker on it: deck B's cues were
## filtered through deck A's playlist, so they came back short, duplicated, or with the
## too-close test consulting a list the marker was never going into.
func _cues_for(path: String, deck := -1) -> Array:
	var id := _library.id_for(path)
	var out: Array = (_library.cues.get(id, []) as Array).duplicate()
	var scope: String = _library.crate_pl[_scope_deck(path, deck)]
	if not scope.is_empty():
		out.append_array((_library.pl_cues.get(scope, {}) as Dictionary).get(id, []))
	return out

## Whose playlist scope a path belongs under: the deck named outright, else whichever deck is
## actually holding that track, else the bar deck. The middle case is what makes the old
## single-argument callers correct without touching them.
func _scope_deck(path: String, deck := -1) -> int:
	if deck >= 0 and deck < 2:
		return deck
	if path == _deck_path(_bar_deck()):
		return _bar_deck()     # the same track on both decks belongs to the one being shown
	for d in 2:
		if path == _deck_path(d):
			return d
	return _bar_deck()

static func cue_x(t: float, length: float, w: float) -> float:
	return clampf(t / maxf(length, 0.001), 0.0, 1.0) * w

static func next_cue_id(cues: Array) -> int:
	var top := 0
	for c in cues:
		top = maxi(top, int(c["id"]))
	return top + 1

## MM:SS:MS, the last field in milliseconds -- "01:42:250" is 1 min 42.25 s. Minutes are
## not wrapped into hours: a track is minutes long, and 73:20:000 is easier to read on a
## marker than 01:13:20:000.
static func ts_text(t: float) -> String:
	var ms := int(roundf(maxf(t, 0.0) * 1000.0))
	return "%02d:%02d:%03d" % [ms / 60000, (ms / 1000) % 60, ms % 1000]

## The inverse, returning -1.0 for anything that will not parse -- the caller shows the
## note rather than silently moving a marker somewhere the user did not ask for.
##
## Accepts MM:SS and MM:SS:MS. A third field of three digits or more is read as true
## milliseconds ("01:42:500"), two or fewer as hundredths, because both spellings turn up
## the moment anyone types a timestamp by hand.
static func ts_parse(raw: String) -> float:
	var parts := raw.strip_edges().split(":", false)
	if parts.size() < 2 or parts.size() > 3:
		return -1.0
	for p in parts:
		if not (p as String).is_valid_int():
			return -1.0
	var secs := float(int(parts[0]) * 60 + int(parts[1]))
	if parts.size() == 3:
		var frac: String = parts[2]
		secs += float(int(frac)) / (1000.0 if frac.length() >= 3 else 100.0)
	return secs

static func ts_test() -> bool:
	return ts_text(102.25) == "01:42:250" and ts_text(0.0) == "00:00:000" \
		and ts_text(3661.0) == "61:01:000" \
		and is_equal_approx(ts_parse("01:42:250"), 102.25) \
		and is_equal_approx(ts_parse("00:30"), 30.0) \
		and is_equal_approx(ts_parse("01:42:50"), 102.5)   \
		and is_equal_approx(ts_parse(ts_text(217.33)), 217.33) \
		and ts_parse("nope") < 0.0 and ts_parse("1:2:3:4") < 0.0 and ts_parse("") < 0.0

static func key_test() -> bool:
	var a := {"key": "Q", "time": 102.25}
	var b := {"time": 8.0}
	return norm_key("q") == "Q" and norm_key("7") == "7" and norm_key("") == "" \
		and norm_key(" ") == "SPACE" and norm_key("esc") == "ESC" and norm_key("-") == "?" \
		and norm_key("qq") == "?" \
		and key_reserved(norm_key("h")) and key_reserved(norm_key("m")) \
		and key_reserved("SPACE") and key_reserved("F11") and not key_reserved("Q") \
		and is_equal_approx(float(key_conflict([a, b], b, "Q").get("time", 0.0)), 102.25) \
		and key_conflict([a, b], b, "Z").is_empty() \
		and key_conflict([a], a, "Q").is_empty()   # a marker never collides with itself

static func cue_test() -> bool:
	var cues: Array = [{"id": 1, "time": 30.0}, {"id": 4, "time": 90.0}]
	return next_cue_id(cues) == 5 and next_cue_id([]) == 1 \
		and is_equal_approx(cue_x(30.0, 120.0, 400.0), 100.0) \
		and is_equal_approx(cue_x(999.0, 120.0, 400.0), 400.0) \
		and is_equal_approx(cue_x(0.0, 0.0, 400.0), 0.0) \
		and on_tab(Vector2(100.0, 2.0), 100.0) \
		and on_tab(Vector2(104.0, 5.0), 100.0) \
		and not on_tab(Vector2(100.0, 12.0), 100.0) \
		and not on_tab(Vector2(112.0, 2.0), 100.0) \
		and Color.html_is_valid("d84445") and not Color.html_is_valid("nope") \
		and cue_too_close(cues, 30.03, MIN_CUE_GAP_SEC) \
		and not cue_too_close(cues, 30.10, MIN_CUE_GAP_SEC) \
		and not cue_too_close([], 30.0, MIN_CUE_GAP_SEC) \
		and DeckController.rev_cue_test()
		# keys moved out to key_test() when the rules grew past "is it a letter"

## REV mirrors what is SOUNDING, never what is stored. A marker at 30 s of a 120 s track sits at
## 90 s of the reversed render, and a marker dropped at 90 s of that render is the same 30 s of
## the track -- the round trip that stops REV from rewriting the cue store.
## The tab is the marker's handle: the line is 2 px and nothing can reliably hit 2 px,
## so the clickable part is a wider cap at the top. Drawn INSIDE the bar rather than
## above it -- the scrub bar is 16 px tall in a tight HBox, and a cap that overhung the
## top would paint over the workspace above it.
const CUE_TAB := Vector2(9.0, 6.0)

## Painted on %CueOverlay, never on %Scrub. X is the position the marker's time maps to
## across the overlay's own width -- the same width the bar has, but measured on the node
## doing the drawing, so nothing here can be confused with the bar's internal fill rect.
##
## The overlay's top CUE_TAB.y pixels are the cap strip above the bar; the line starts
## where the bar does and runs to the bottom.
## How dark the waveform sits against the bar. It is context, not the subject: the playhead, the
## fill and the markers all have to stay easier to read than the shape behind them.
const WAVE_ALPHA := 0.30

## The main bar's overlay. In DUAL PLAY BARS it is pinned to deck A; otherwise it follows the
## transport, which is what it has always done.
func _draw_cues() -> void:
	_draw_cues_on(_cue_overlay, 0 if _dual_bars else _bar_deck())

func _draw_cues_on(overlay: Control, deck: int) -> void:
	var length := _deck_len(deck)
	var path := _deck_path(deck)
	if path.is_empty() or length <= 0.0:
		return
	var w := overlay.size.x
	var top := CUE_TAB.y
	_draw_waveform_on(overlay, deck, w, top)
	for c in _cues_for(path, deck):
		var col := Color(str(c["color"]))
		var x := cue_x(_cue_stream_deck(deck, float(c["time"])), length, w)
		overlay.draw_rect(Rect2(x - 1.0, top, 2.0, overlay.size.y - top), col)
		# the handle. Its footprint is the same CUE_TAB box whatever the shape, so the
		# hit test stays one rectangle and a triangle is no harder to grab than a square.
		match str(c.get("shape", "square")):
			"circle":
				_cue_overlay.draw_circle(Vector2(x, top * 0.5), top * 0.5, col)
			"triangle":
				_cue_overlay.draw_colored_polygon(PackedVector2Array([
					Vector2(x - CUE_TAB.x * 0.5, 0.0),
					Vector2(x + CUE_TAB.x * 0.5, 0.0),
					Vector2(x, CUE_TAB.y)]), col)
			_:
				_cue_overlay.draw_rect(Rect2(x - CUE_TAB.x * 0.5, 0.0, CUE_TAB.x, CUE_TAB.y), col)
	# no label or keybind is painted into the strip: rendered and measured, a character
	# that small is a smudge. The hover readout says all of it in the status bar, where
	# there is room for words.

## The track's shape, under the markers. The bar was a bare rail: it said how far through you
## were and nothing about what was there, so finding the point where the intro ends meant
## scrubbing for it. Asking the engine is what starts the build, and until it lands this draws
## nothing and the bar looks exactly as it did.
##
## Drawn UNDER the cue lines deliberately -- a marker has to stay findable against it, which is
## also why WAVE_ALPHA is as low as it is. Mirrored about the middle of the strip, min below and
## max above, so a track with a loud left channel does not read as lopsided.
func _draw_waveform_on(overlay: Control, deck: int, w: float, top: float) -> void:
	if not _show_playbar_wave:
		return   # before waveform_for(), so OFF does not start a build nobody will draw
	var wave := _engine.waveform_for(_deck_path(deck))
	if wave.is_empty() or w <= 0.0:
		return
	var buckets := wave.size() / AudioEngine.WAVE_STRIDE
	var h := overlay.size.y - top
	if h <= 0.0:
		return
	var mid := top + h * 0.5
	var col := Color(theme.get_color("font_color", "Green"), WAVE_ALPHA)
	var step := w / float(buckets)
	for b in buckets:
		# LEFT above the centre line, RIGHT below it, each drawn from its own peak -- the two
		# channels rather than their average, which is what a stereo overview is for. A mono
		# track has the same peaks on both sides and draws exactly as it did when this folded
		# one channel and mirrored it.
		var left: float = maxf(absf(wave[b * AudioEngine.WAVE_STRIDE]), wave[b * AudioEngine.WAVE_STRIDE + 1])
		var right: float = maxf(absf(wave[b * AudioEngine.WAVE_STRIDE + 2]), wave[b * AudioEngine.WAVE_STRIDE + 3])
		var y0 := mid - left * h * 0.5
		var y1 := mid + right * h * 0.5
		# at least a pixel, so silence is a centre line rather than a gap in the drawing
		overlay.draw_rect(Rect2(float(b) * step, y0, maxf(step, 1.0), maxf(y1 - y0, 1.0)), col)

## The cue under a click, or {} -- returned by reference, so the caller can hand the same
## Dictionary to the scope and delete paths and have them find it in whichever store it
## actually lives in.
func _cue_at(x: float) -> Dictionary:
	var length := _len()
	if _bar_path().is_empty() or length <= 0.0:
		return {}
	var best := {}
	var best_dx := CUE_GRAB
	for c in _cues_for(_bar_path()):
		var dx: float = absf(cue_x(_cue_stream(float(c["time"])), length, _cue_overlay.size.x) - x)
		if dx <= best_dx:
			best_dx = dx
			best = c
	return best

## Was the click on a marker's TAB, as opposed to its line? The tab is the handle that
## opens the edit menu, so it has to be separable from the rest of the marker -- a plain
## click on the line still belongs to the bar (seek, or drop a cue in MARK MODE).
static func on_tab(pos: Vector2, x: float) -> bool:
	return pos.y <= CUE_TAB.y and absf(pos.x - x) <= CUE_TAB.x * 0.5

func _tab_at(pos: Vector2) -> Dictionary:
	var cue := _cue_at(pos.x)
	if cue.is_empty():
		return {}
	return cue if on_tab(pos, cue_x(_cue_stream(float(cue["time"])), _len(), _cue_overlay.size.x)) else {}

## Marker input, in overlay coordinates. Anything that is not a marker is left
## unaccepted, and MOUSE_FILTER_PASS hands it straight down to %Scrub -- which is why
## seeking, dragging and MARK MODE still behave as if the overlay were not there.
func _on_overlay_input(e: InputEvent) -> void:
	if not (e is InputEventMouseButton) or not e.pressed:
		return
	var hit := _cue_at(e.position.x)
	if hit.is_empty():
		return
	if e.button_index == MOUSE_BUTTON_RIGHT:
		_popup_cue_menu(hit)
	elif e.button_index == MOUSE_BUTTON_LEFT and e.shift_pressed:
		_audition(hit)
	elif e.button_index == MOUSE_BUTTON_LEFT and not _tab_at(e.position).is_empty():
		# a press on the tab ARMS a drag; the menu opens on release, and only if the
		# pointer never moved. That is what makes one handle do both jobs -- click to
		# edit, drag to reposition -- without a modifier to remember.
		_drag_cue = hit
		_drag_from_x = e.position.x
		_drag_moved = false
	else:
		return   # on the line, not the tab: it belongs to the bar underneath
	_cue_overlay.accept_event()

## Runs from _process while a tab is held. The release is POLLED rather than awaited for
## the same reason the scrub drag polls it: a button released off the control never
## reaches its gui_input, and a marker latched to the mouse forever is worse than a
## scrub bar that is.
##
## Dragging writes straight to the cue's time and repaints the overlay. It never seeks --
## the track keeps playing under the marker being moved, which is the whole point of
## being able to place one behind the playhead.
func _drag_cue_step() -> void:
	if _drag_cue.is_empty():
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var x := _cue_overlay.get_local_mouse_position().x
		if absf(x - _drag_from_x) > DRAG_SLOP:
			# ONCE, on the frame the drag starts moving -- not per frame, or a single drag
			# across the bar would fill the whole undo stack with its own intermediate steps
			if not _drag_moved:
				_cue_edit_begin(_drag_cue)
			_drag_moved = true
		if _drag_moved and _len() > 0.0:
			# where the pointer is in what is SOUNDING, mapped back to the track's own time
			var t := _cue_stream(_ratio_at(x, _cue_overlay.size.x) * _len())
			# the same floor _add_cue enforces on a new marker -- a drag that would land
			# this one within it of another simply refuses the move; the marker holds at
			# its last valid position rather than stacking on top of its neighbour
			var dragged_id := int(_drag_cue.get("id", -1))
			var others := _cues_for(_bar_path()).filter(
				func(c: Dictionary) -> bool: return int(c.get("id", -2)) != dragged_id)
			if not cue_too_close(others, t, MIN_CUE_GAP_SEC):
				_drag_cue["time"] = t
				_note = "  //  %s -> %s" % [_drag_cue["label"], _time_text(t)]
				_cue_overlay.queue_redraw()
		return
	var cue := _drag_cue
	var moved := _drag_moved
	_drag_cue = {}
	_drag_moved = false
	if moved:
		_cue_undo_commit()   # the pair to _cue_edit_begin above; one entry for the whole drag
		_clear_note_later()
		_save_soon()
	else:
		_popup_cue_menu(cue)   # a click, not a drag

## How far the pointer may wander before a click counts as a drag. Two pixels: a hand
## clicking a 9 px tab moves one or two, and treating that as a drag would nudge markers
## every time the menu was opened.
const DRAG_SLOP := 2.0

## `at` is a position in the track, in seconds -- the caller decides where. MARK MODE
## passes the time under the CLICK rather than the playhead: marking is as often "that
## bit I just heard" as "this instant", and a marker that can only land on the playhead
## cannot be placed behind it at all. Nothing in here touches playback.
##
## It is filed into whichever scope is active, because that is the scope you are working
## in. The RMB menu moves it afterwards.
## Cue Markers cannot land within this many seconds of an existing one -- without a
## floor, a double-click or two quick MARK-MODE presses drop two markers effectively on
## top of each other: visually one line, and CUE_GRAB can only ever resolve a click to
## whichever of them happens to be nearest, so the other becomes permanently ungrabbable.
const MIN_CUE_GAP_SEC := 0.05

## Pure, so the threshold is checkable without a bar to click on.
static func cue_too_close(cues: Array, t: float, min_gap: float) -> bool:
	for c in cues:
		if absf(float(c["time"]) - t) < min_gap:
			return true
	return false

# --- cue undo -----------------------------------------------------------------------------
## CTRL+Z for markers. Snapshots, not operations: one track's cue list is a handful of small
## dictionaries, and storing the list either side of a change is both simpler and harder to get
## wrong than replaying an inverse of every kind of edit. Add and delete are what it covers --
## including the pads, which can now drop and clear a cue faster than anything else in the
## program and are by far the easiest way to lose one by accident.
##
## The stack holds a REFERENCE to the store dictionary, so anything that replaces those
## wholesale -- importing a setup file -- has to clear it, or undo would write into a dictionary
## nothing is reading any more.
## ONE STEP CAN TOUCH SEVERAL LISTS. Moving a marker between ALL TRACKS and a playlist takes it
## out of one store and puts it in another, and an undo that only knew about one of those would
## restore half the change -- leaving the marker in both places or neither. So an entry holds a
## LIST of snapshots and they are applied together.
const CUE_UNDO_MAX := 50
var _cue_undo: Array[Dictionary] = []
var _cue_redo: Array[Dictionary] = []
var _cue_pending: Array[Dictionary] = []

## Snapshots one list before it changes. Called once per store a single operation will touch;
## asking twice for the same list is a no-op, so a caller can be safe rather than clever.
func _cue_undo_push(store: Dictionary, id: String) -> void:
	for s in _cue_pending:
		if is_same(s["store"], store) and str(s["id"]) == id:
			return
	_cue_pending.append({"store": store, "id": id,
		"before": (store.get(id, []) as Array).duplicate(true)})

func _cue_undo_commit() -> void:
	if _cue_pending.is_empty():
		return
	var snaps: Array[Dictionary] = []
	for s in _cue_pending:
		var store: Dictionary = s["store"]
		var id := str(s["id"])
		snaps.append({"store": store, "id": id, "before": s["before"],
			"after": (store.get(id, []) as Array).duplicate(true)})
	_cue_pending = []
	_cue_undo.append({"snaps": snaps})
	if _cue_undo.size() > CUE_UNDO_MAX:
		_cue_undo.pop_front()
	_cue_redo.clear()   # a new edit is a new branch; whatever was undone is not coming back

func _cue_undo_step(redo: bool) -> void:
	var from: Array[Dictionary] = _cue_redo if redo else _cue_undo
	var to: Array[Dictionary] = _cue_undo if redo else _cue_redo
	if from.is_empty():
		_note = "  //  NOTHING TO %s" % ("REDO" if redo else "UNDO")
		_clear_note_later()
		return
	var step: Dictionary = from.pop_back()
	for s: Dictionary in step["snaps"]:
		var store: Dictionary = s["store"]
		var id := str(s["id"])
		var want: Array = (s["after"] if redo else s["before"]) as Array
		if want.is_empty():
			store.erase(id)
		else:
			store[id] = want.duplicate(true)
	to.append(step)
	# Restoring puts COPIES in the store, so anything still holding one of the old dictionaries
	# is now pointing at a marker that is in no list at all -- an armed drag would move it and
	# an open menu would recolour it, both writing into nothing. Both are dropped.
	_drag_cue = {}
	if str(_menu_ctx.get("kind", "")) == "cue":
		_menu_ctx = {}
	_cue_overlay.queue_redraw()
	if is_instance_valid(_overlay_b):
		_overlay_b.queue_redraw()
	_save_soon()
	_note = "  //  CUES %s (%d LEFT)" % ["REDONE" if redo else "UNDONE", from.size()]
	_clear_note_later()

func _cue_undo_clear() -> void:
	_cue_undo.clear()
	_cue_redo.clear()
	_cue_pending = []

# --- hot cues, for a pad grid -----------------------------------------------------------------
## A pad is not a list position. SOUNDSCAPE's markers are an arbitrary keyed list -- as many as
## you drop, ordered by time -- and mapping pad N to "the Nth marker along" was fine for jumping
## and useless for the thing a pad grid is actually for, which is: press an empty pad to drop a
## cue, press a lit one to go there, shift-press to clear it. "The Nth marker" moves under you
## the moment you add one earlier in the track.
##
## So a cue created from a pad carries a SLOT. Slots are per track, live in the same cue
## dictionary as everything else, and persist through the same config with no new storage.
## Markers made the old way (clicking the bar in MARK MODE) have no slot and are untouched by
## this -- they still jump by key, and a pad will never delete one.
func _cue_in_slot(deck: int, slot: int) -> Dictionary:
	for c in _cues_for(_deck_path(deck), deck):
		if int((c as Dictionary).get("slot", 0)) == slot:
			return c
	return {}

## One pad press. `shift` is the modifier -- from the controller's own SHIFT button if one is
## bound, or the keyboard's.
##
## MARK MODE has nothing to do with this. That toggle exists to stop a click on the scrub bar
## being read as a seek; a pad is not the scrub bar, so a pad drops its cue either way. Anything
## else would be a mode nobody can see from the controller.
func _pad_cue(deck: int, slot: int, shift: bool) -> void:
	var path := _deck_path(deck)
	if path.is_empty():
		_note = "  //  NOTHING ON %s TO CUE" % AudioEngine.DECK_NAMES[deck]
		_clear_note_later()
		return
	var cue := _cue_in_slot(deck, slot)
	if shift:
		if cue.is_empty():
			return
		_delete_cue(cue)
		_note = "  //  CUE %d CLEARED ON %s" % [slot, AudioEngine.DECK_NAMES[deck]]
		_clear_note_later()
		return
	if cue.is_empty():
		_add_cue_on(deck, _deck_pos(deck), slot)
		return
	_seek_deck(deck, _cue_stream_deck(deck, float(cue["time"])))
	_note = "  //  CUE %d  //  %s" % [slot, AudioEngine.DECK_NAMES[deck]]
	_clear_note_later()

## `at` arrives as a position in what is currently SOUNDING. While the deck is reversed that is
## the mirror of the track's own time, and the marker is stored in the track's terms.
func _add_cue(at: float) -> void:
	if _bar_path().is_empty() or _len() <= 0.0:
		_note = "  //  NOTHING PLAYING TO MARK"
		_clear_note_later()
		return
	at = _cue_stream(at)
	# Range check BEFORE the clamp. Clamping first mapped every click past the end onto
	# the same instant, so the first one landed and every one after it was refused as
	# "too close" to the marker the clamp had just created -- which reads as markers
	# silently not working rather than as a click that was out of bounds.
	if at < -MIN_CUE_GAP_SEC or at > _len() + MIN_CUE_GAP_SEC:
		_note = "  //  OUTSIDE THE TRACK"
		_clear_note_later()
		return
	var t := clampf(at, 0.0, _len())
	if cue_too_close(_cues_for(_bar_path()), t, MIN_CUE_GAP_SEC):
		_note = "  //  TOO CLOSE TO AN EXISTING MARKER"
		_clear_note_later()
		return
	_write_cue(_bar_deck(), clampf(at, 0.0, _len()), 0)

## The same marker, on ANY deck, optionally carrying a pad SLOT. Split out of _add_cue so a pad
## on deck B can drop one without the transport bar being anywhere near that track.
func _write_cue(deck: int, t: float, slot: int) -> void:
	var path := _deck_path(deck)
	if path.is_empty():
		return
	var store := _cue_store(not _library.crate_pl[deck].is_empty(), deck)
	var id := _library.id_for(path)
	_cue_undo_push(store, id)
	var list: Array = store.get(id, [])
	var cue := {
		"id": next_cue_id(_cues_for(path, deck)),
		"time": t,
		"shape": "square",
		"label": ("CUE %d" % slot) if slot > 0 else "CUE %d" % (_cues_for(path, deck).size() + 1),
		# the skin accent, captured at creation: markers read against every scheme, and a
		# cue keeps the colour it was born with even after the skin changes
		"color": theme.get_color("font_color", "Green").to_html(false),
	}
	if slot > 0:
		cue["slot"] = slot   # only a pad's cue carries one; markers made on the bar have none
	list.append(cue)
	store[id] = list
	_cue_undo_commit()
	_note = "  //  %s @ %s" % [cue["label"], _time_text(t)]
	_clear_note_later()
	_cue_overlay.queue_redraw()
	_save_soon()

## A pad's cue, dropped at that deck's own playhead. Refuses for the same reasons _add_cue does
## -- nothing loaded, or a marker already within MIN_CUE_GAP_SEC -- but says so per deck.
func _add_cue_on(deck: int, at: float, slot: int) -> void:
	var path := _deck_path(deck)
	var span := _deck_len(deck)
	if path.is_empty() or span <= 0.0:
		_note = "  //  NOTHING ON %s TO MARK" % AudioEngine.DECK_NAMES[deck]
		_clear_note_later()
		return
	var t := clampf(_cue_stream_deck(deck, at), 0.0, span)
	if cue_too_close(_cues_for(path, deck), t, MIN_CUE_GAP_SEC):
		_note = "  //  TOO CLOSE TO AN EXISTING MARKER"
		_clear_note_later()
		return
	_write_cue(deck, t, slot)

## Stored time <-> sounding time for one deck. _cue_stream() answers for the bar deck only, and a
## pad on the other deck needs the same mirror when that deck is running in reverse.
func _cue_stream_deck(deck: int, t: float) -> float:
	return cue_stream_time(t, _deck_len(deck), _is_reversed(deck))

## The dictionary a cue of the given scope lives in, created on demand. Playlist scope
## with no playlist selected has nowhere to go, and the caller says so rather than
## silently writing the cue somewhere the user cannot see it.
## `deck` names whose playlist the cue is going into. It used to read the BAR deck's, while the
## caller decided the SCOPE from the target deck's -- so a marker dropped on deck B while B had
## a playlist open and A did not was filed under `pl_cues[""]`, a bucket with no name that
## _cues_for never looks in. The cue was saved, and never seen again.
##
## The empty-name guard is the belt to that brace: a playlist store with no playlist is not a
## thing, and anything asking for one gets the track's own cues instead.
func _cue_store(playlist_scope: bool, deck: int) -> Dictionary:
	if not playlist_scope:
		return _library.cues
	var name: String = _library.crate_pl[deck]
	if name.is_empty():
		return _library.cues
	if not _library.pl_cues.has(name):
		_library.pl_cues[name] = {}
	return _library.pl_cues[name]

func _move_cue(cue: Dictionary, to_playlist: bool) -> void:
	if to_playlist and _library.crate_pl[_bar_deck()].is_empty():
		_note = "  //  NO PLAYLIST SELECTED"
		_clear_note_later()
		return
	# BOTH lists are snapshotted, the one it leaves and the one it joins -- that is the whole
	# reason an undo entry holds a list. The order matters: the source has to be photographed
	# while the cue is still in it.
	var home := _cue_home(cue)
	if not home.is_empty():
		_cue_undo_push(home["store"], str(home["id"]))
	_pull_cue(cue)
	var store := _cue_store(to_playlist, _bar_deck())   # the scope menu is the bar's own menu
	var bar_id := _library.id_for(_bar_path())
	_cue_undo_push(store, bar_id)
	var list: Array = store.get(bar_id, [])
	list.append(cue)
	store[bar_id] = list
	_cue_undo_commit()
	_note = "  //  %s -> %s" % [cue["label"], _library.crate_pl[_bar_deck()] if to_playlist else "ALL TRACKS"]
	_clear_note_later()
	_cue_overlay.queue_redraw()
	_save_soon()

## Snapshots the list a cue lives in, for an edit that changes the cue IN PLACE rather than
## moving it. The dictionary is shared with the store, so the copy has to be taken before the
## field is written, not after.
func _cue_edit_begin(cue: Dictionary) -> void:
	var home := _cue_home(cue)
	if not home.is_empty():
		_cue_undo_push(home["store"], str(home["id"]))

func _set_cue_color(cue: Dictionary, hex: String) -> void:
	_cue_edit_begin(cue)
	cue["color"] = hex
	_cue_undo_commit()
	_cue_overlay.queue_redraw()
	_save_soon()

## Keys are stored as the printable name Godot itself gives a keycode ("A", "7"), which
## is what makes the lookup in _unhandled_input a dictionary-free string compare.
##
## The reserved transport keys are refused rather than silently accepted: they are
## handled earlier in _unhandled_input, so a marker bound to one would simply never fire
## and the setting would look broken rather than rejected.
## Keys the program keeps for itself. H, SPACE, F1, F11 and ESC are live transport
## shortcuts today; M is held back for MARK MODE, which is a toggle that wants a key
## sooner or later. Reserving one costs nothing and un-reserving it later breaks nobody,
## where handing it out and taking it back breaks whoever bound it.
## "1" and "2" joined the list when deck selection moved onto them: _unhandled_input
## checks transport actions BEFORE cue jumps, so a marker bound to either digit would
## simply never fire and would look broken rather than refused.
## ponytail: still a static list, so rebinding an action onto some OTHER letter can
## shadow a marker on it. A live union with _keybinds is the fix if that ever bites.
const CUE_KEYS_RESERVED := ["SPACE", "H", "M", "F1", "F11", "ESC", "1", "2"]

## "" clears the binding, "?" is not a usable key at all, anything else is the key's
## normalised name. A typed space comes back as SPACE rather than as a clear: someone
## pressing the space bar in that field is asking for the key, not emptying the field.
##
## Multi-character names (ESC, F11) only arrive from a hand-edited config -- the prompt
## is capped at one character -- but they are recognised rather than mangled into "E".
static func norm_key(raw: String) -> String:
	var k := raw.strip_edges().to_upper()
	if k.is_empty():
		return "SPACE" if raw.contains(" ") else ""
	if k.length() > 1:
		return k if k in CUE_KEYS_RESERVED else "?"
	return k if (k >= "A" and k <= "Z") or (k >= "0" and k <= "9") else "?"

static func key_reserved(k: String) -> bool:
	return k in CUE_KEYS_RESERVED

## The marker already holding `k` on this track, or {}. Pure, so the collision rule can
## be checked without a library, a track or a bar to click on.
static func key_conflict(cues: Array, cue: Dictionary, k: String) -> Dictionary:
	for other in cues:
		if other != cue and str(other.get("key", "")) == k:
			return other
	return {}

## Three refusals and one assignment. Nothing here overwrites an existing binding: a key
## that is already spoken for is reported back with the timestamp of the marker holding
## it, so the answer to "why did my key stop working" is on screen at the moment it would
## otherwise have been taken away.
func _set_cue_key(cue: Dictionary, raw: String) -> void:
	var k := norm_key(raw)
	if k == "?":
		_note = "  //  %s IS NOT AN AVAILABLE JUMP KEY" % raw.strip_edges().to_upper()
		_clear_note_later()
		return
	if key_reserved(k):
		_note = "  //  KEYBIND RESERVED BY SYSTEM"
		_clear_note_later()
		return
	var clash := key_conflict(_cues_for(_bar_path()), cue, k) if not k.is_empty() else {}
	if not clash.is_empty():
		# full precision here whatever SHOW MS says: this names a specific marker, and
		# two markers a fifth of a second apart must not read as the same one
		_note = "  //  KEYBIND ASSIGNED TO [TS %s]" % ts_text(float(clash["time"]))
		_clear_note_later()
		return
	_cue_edit_begin(cue)
	if k.is_empty():
		cue.erase("key")
	else:
		cue["key"] = k
	_cue_undo_commit()
	_note = "  //  %s -> %s" % [cue["label"], k if k else "NO KEY"]
	_clear_note_later()
	_cue_overlay.queue_redraw()
	_save_soon()

## The jump itself. Seeks only -- it is meant to be used while a track is playing, and a
## key that also started playback would turn a mis-hit into a surprise.
func _jump_to_key(k: String) -> bool:
	for c in _cues_for(_bar_path()):
		if str(c.get("key", "")) == k:
			_seek(_cue_stream(float(c["time"])))
			_note = "  //  JUMP %s @ %s" % [c["label"], _time_text(float(c["time"]))]
			_clear_note_later()
			return true
	return false

func _delete_cue(cue: Dictionary) -> void:
	var home := _cue_home(cue)
	if home.is_empty():
		return
	_cue_undo_push(home["store"], str(home["id"]))
	_pull_cue(cue)
	_cue_undo_commit()
	_note = "  //  DELETED %s" % cue["label"]
	_clear_note_later()
	_cue_overlay.queue_redraw()
	_save_soon()

## Which store and which track id a cue actually lives under. Dictionaries are reference types,
## so `has` finds the instance rather than an equal copy.
func _cue_home(cue: Dictionary) -> Dictionary:
	for store: Dictionary in _cue_stores():
		for id in store.keys():
			if (store[id] as Array).has(cue):
				return {"store": store, "id": id}
	return {}

func _cue_stores() -> Array[Dictionary]:
	var all: Array[Dictionary] = [_library.cues]
	for name in _library.pl_cues:
		all.append(_library.pl_cues[name])
	return all

## Takes a cue out of whichever store holds it. Dictionaries are reference types in
## GDScript, so erase() finds the instance the menu was opened on without an id search.
##
## An emptied list is dropped rather than left behind: without that, every track that
## ever held a cue keeps a `path: []` entry in library.cfg forever, and the file grows
## with tracks that have nothing to say.
## Searched for rather than looked up under _bar_path(): the bar-deck assumption was fine while
## the only way to delete a marker was the menu on the bar itself, and wrong the moment a pad on
## deck B could clear one -- it erased from deck A's list, found nothing, and left the marker
## exactly where it was while reporting it deleted.
func _pull_cue(cue: Dictionary) -> void:
	for store: Dictionary in _cue_stores():
		for id in store.keys():
			var list: Array = store[id]
			if not list.has(cue):
				continue
			list.erase(cue)
			# An emptied list is dropped rather than left behind: without that, every track that
			# ever held a cue keeps a `id: []` entry in library.cfg forever.
			if list.is_empty():
				store.erase(id)
			return

## A 500 ms taste of a cue: seek, play, pause. The generation counter is what keeps a
## second audition from being cut short by the first one's timer -- shift-clicking along
## a row of markers is the normal way to use this, and without it every preview after the
## first would be truncated by whatever was already counting down.
func _audition(cue: Dictionary) -> void:
	if not _bar().stream and not _vid():
		return
	_audition_gen += 1
	var gen := _audition_gen
	_seek(_cue_stream(float(cue["time"])))   # where that marker sits in what is sounding
	_play()
	_note = "  //  AUDITION %s @ %s" % [cue["label"], _time_text(float(cue["time"]))]
	_clear_note_later()
	await get_tree().create_timer(0.5).timeout
	if gen == _audition_gen and _playing():
		_set_paused(true)

# --- decks ------------------------------------------------------------------
## Deck A and deck B are two mixer channels, each with its own bus, its own EQ/FX rack
## and its own pair of players. The pair matters: a deck needs two players to cross-fade
## between consecutive tracks, so each deck gets the engine's primary plus one of the two
## players already in player.tscn as its spare.
##
## What "switching decks" does is re-point `_decks.audio`, `_current` and `_eq` at
## the other deck's set. Every piece of transport code downstream was already written
## against those, so the scrub bar, the fade, the cue markers and the whole rack became
## deck-aware without being touched.
##
## The deck you leave keeps playing. That is the entire point of two decks, and it is why
## _stop() -- which walks that deck's own pair -- only ever stops the deck you are looking at.
func _setup_decks() -> void:
	%AudioA.bus = _engine.deck_bus(0)
	%AudioB.bus = _engine.deck_bus(1)
	_decks.pair[0] = [_engine.deck_player(0), %AudioA]
	_decks.pair[1] = [_engine.deck_player(1), %AudioB]
	for i in _decks.pair.size():
		for pl: AudioStreamPlayer in _decks.pair[i]:
			# the outgoing player of a crossfade must not trigger auto-advance, and
			# neither must the deck nobody is driving
			pl.finished.connect(func() -> void:
				if pl == _decks.audio and not _fade_running(_engine.deck):
					_next(true))   # the queue moving on, not a click
	_engine.set_crossfader(_decks.crossfader)
	_bind_deck(_engine.deck)
	_setup_deck_ui()

## The two controls, built here rather than in player.tscn so the whole deck feature is
## one file. They go at the head of the transport, where a mixer's channel select and
## crossfader belong.
func _setup_deck_ui() -> void:
	_deck_btn = Button.new()
	# A <-> B only. A+B is its own keybind (TAB), never a stop on this button's cycle:
	# _select_deck leaves A+B first, so a click from A+B lands on a single deck too
	_deck_btn.pressed.connect(func() -> void: _select_deck(1 - _engine.deck))
	%ControlDeck.add_child(_deck_btn)
	_rev_btn = Button.new()
	_rev_btn.pressed.connect(_toggle_reverse)
	%ControlDeck.add_child(_rev_btn)
	_hover_note(_rev_btn, func() -> String:
		return "REVERSE PLAYBACK  //  THE TRACK IS REVERSED TO A CACHED FILE, NOT PITCH-BENT")
	_refresh_rev_btn()
	%ControlDeck.move_child(_deck_btn, 0)
	_hover_note(_deck_btn, func() -> String:
		var why := "" if _silenced < 0 else "  //  %s! IS PLAYING BUT THE CROSSFADER HAS IT SILENT" % (
			"A" if _silenced == 0 else "B")
		return "PLAYING INTO %s  //  CLICK FOR %s  //  THE OTHER DECK KEEPS PLAYING%s" % [
			AudioEngine.DECK_NAMES[_engine.deck], AudioEngine.DECK_NAMES[1 - _engine.deck], why])

	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)
	var cap := Label.new()
	cap.text = "A/B"
	row.add_child(cap)
	_xfade = ProgressBar.new()
	_xfade.custom_minimum_size = Vector2(90, 14)
	_xfade.show_percentage = false
	_xfade.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# RMB runs the fader across on its own; connected before the drag handler because
	# _bar_drag only answers for the left button and would swallow the event first
	_xfade.gui_input.connect(func(e: InputEvent) -> void:
		var click := e as InputEventMouseButton
		if click and click.pressed and click.button_index == MOUSE_BUTTON_RIGHT:
			_auto_fade()
			_xfade.accept_event())
	_xfade.gui_input.connect(func(e: InputEvent) -> void:
		if not _bar_drag(e, _xfade):
			return
		_kill_auto_fade()   # a fade you have taken hold of is one you are doing yourself
		# the press that GRABS the fader is the moment to line the grids up -- once, while the
		# incoming deck is still quiet, never on each motion event of the drag
		if _beat_sync and e is InputEventMouseButton:
			_align_decks()
		# reaching for the crossfader IS the request to stop running both decks at once
		if _engine.both:
			_engine.set_both(false)
		_set_crossfader(_ratio_at(e.position.x, _xfade.size.x)))
	_xfade.gui_input.connect(func(e: InputEvent) -> void:
		var w := _bar_wheel(e, _decks.crossfader, BAR_WHEEL_COARSE)
		if w >= 0.0:
			if _engine.both:
				_engine.set_both(false)
			_set_crossfader(w))
	row.add_child(_xfade)
	%ControlDeck.add_child(panel)
	%ControlDeck.move_child(panel, 1)
	_sync_btn = Button.new()
	_sync_btn.toggle_mode = true
	_sync_btn.toggled.connect(func(on: bool) -> void:
		_set_beat_sync(on)
		_save())
	%ControlDeck.add_child(_sync_btn)
	%ControlDeck.move_child(_sync_btn, 2)
	_hover_note(_sync_btn, _sync_readout)
	_refresh_sync_btn()
	# DUAL DECK MODE from the transport: bracketed while on, the same way the deck button
	# brackets whatever is live. A layout switch only -- which decks are heard stays A+B's job.
	_split_btn = Button.new()
	_split_btn.pressed.connect(func() -> void: _set_dual_deck(not _dual_deck))
	%ControlDeck.add_child(_split_btn)
	%ControlDeck.move_child(_split_btn, 1)
	_hover_note(_split_btn, func() -> String:
		return "DUAL DECK MODE %s  //  DECK A TRACKS | FEED | DECK B" % ("ON" if _dual_deck else "OFF"))
	_hover_note(_xfade, func() -> String:
		return "RIGHT-CLICK: AUTO FADE OVER %.1f S  //  CROSSFADER: %s  //  %s %+.1f DB  //  %s %+.1f DB" % [
			float(_decks.fade_ms) / 1000.0,
			("A" if _decks.crossfader < 0.02 else ("B" if _decks.crossfader > 0.98 else "%d%%" % int(_decks.crossfader * 100.0))),
			AudioEngine.DECK_NAMES[0], AudioEngine.deck_gain_db(1.0 - _decks.crossfader),
			AudioEngine.DECK_NAMES[1], AudioEngine.deck_gain_db(_decks.crossfader)])
	_refresh_deck_ui()

## The crossfader, run across on its own over the TBS FADE TIME -- the same number the
## track-to-track fade uses, so a hand fade and an auto fade take exactly as long as each other
## and a set has one fade length rather than two. It heads for whichever end it is not at, and
## SYNC lines the grids up first, the way grabbing the fader does.
##
## ponytail: linear in fader position, which is equal-power in LEVEL because set_crossfader's law
## is. A shaped curve would need a reason a cos/sin sweep does not already give.
var _xfade_tween: Tween

func _auto_fade() -> void:
	_kill_auto_fade()
	if _engine.both:
		_engine.set_both(false)   # a fade BETWEEN decks is not both decks at once
	if _beat_sync:
		_align_decks()
	var to := 0.0 if _decks.crossfader > 0.5 else 1.0
	var secs := maxf(float(_decks.fade_ms) / 1000.0, 0.05)
	_xfade_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_xfade_tween.tween_method(_set_crossfader, _decks.crossfader, to, secs)
	_note = "  //  AUTO FADE TO %s OVER %.1f S" % [AudioEngine.DECK_NAMES[1 if to > 0.5 else 0], secs]
	_clear_note_later()

func _kill_auto_fade() -> void:
	if _xfade_tween and _xfade_tween.is_valid():
		_xfade_tween.kill()

func _set_crossfader(x: float) -> void:
	_decks.crossfader = clampf(x, 0.0, 1.0)
	_engine.set_crossfader(_decks.crossfader)
	_refresh_deck_ui()
	_save_soon()

## TWO states, not three. The old A -> B -> A+B -> A cycle meant the same button did
## "change deck" and "stop muting the other one" depending on where in the rotation you
## happened to be, so you could not tell what a press would do without remembering the
## last one. Now [1] and [2] pick a deck outright and this only ever toggles combined. It is
## reached from the DECK A+B keybind alone; the transport's deck button only flips A <-> B.
func _toggle_both() -> void:
	if _engine.both:
		_engine.set_both(false)
		# back to the deck that was live when A+B was entered, not a hardcoded A --
		# dumping someone onto deck A mid-set is a silent channel change
		_switch_deck(_deck_before_both)
	else:
		_deck_before_both = _engine.deck
		_engine.set_both(true)
		if _beat_sync:
			_align_decks()   # both decks are about to be heard together: line them up first
	_refresh_deck_ui()
	_save()

## Picks a deck outright. Leaves combined mode first if it is on, because "play deck A"
## and "play both" are different requests and one must not silently mean the other.
func _select_deck(which: int) -> void:
	if _engine.both:
		_engine.set_both(false)
	_switch_deck(which)
	_refresh_deck_ui()
	_save()

# --- reverse playback ---------------------------------------------------------
var _rev_btn: Button
## Which deck A+B was entered from, so leaving it puts you back where you were.
var _deck_before_both := 0
## The deck playing while the crossfader holds it silent, or -1; watched in _process.
var _silenced := -1

func _is_reversed(deck: int) -> bool:
	return _decks.is_reversed(deck)

func _set_reversed(deck: int, on: bool) -> void:
	_decks.set_reversed(deck, on)

## A cue's time is ALWAYS stored against the track as recorded, forwards. While a deck plays the
## reversed render, that same instant sits at `length - t` in what is actually sounding -- so
## every marker crosses this on its way to the screen or the playhead, and every marker the user
## drops or drags crosses it on the way back. Stored times therefore never mirror, which is what
## stops a cue marked during REV from being written at the wrong place for good.
func _cue_stream(t: float) -> float:
	return cue_stream_time(t, _len(), _is_reversed(_bar_deck()))

## The pure rule, so it is checkable without a deck or a track. Its own inverse: applying it to a
## stream time hands back the stored time, which is why one function serves both directions.
static func cue_stream_time(t: float, length: float, reversed: bool) -> float:
	return DeckController.cue_stream_time(t, length, reversed)

## AudioStreamPlayer has no negative pitch_scale, so this is a real reversed FILE,
## produced once by ffmpeg and cached. That takes a moment on a long track, which is
## why the swap happens on the reversed_ready signal rather than inline here.
func _toggle_reverse() -> void:
	if _current.is_empty():
		_note = "  //  NOTHING LOADED TO REVERSE"
		_clear_note_later()
		return
	if _is_reversed(_engine.deck):
		# the flag follows the AUDIO, not the click. _open() refuses an index of -1,
		# which is exactly what queue.find() returns for a track filtered out by a
		# search or a playlist -- clearing the flag first left the button reading
		# FORWARD while the reversed file carried on playing.
		var at := _engine.queue.find(_current)
		if at < 0:
			_note = "  //  TRACK NOT IN THE VISIBLE QUEUE  //  CLEAR THE FILTER TO GO FORWARD"
			_clear_note_later()
			return
		_set_reversed(_engine.deck, false)
		_refresh_rev_btn()
		_open(at)
		return
	_note = "  //  REVERSING %s ..." % _current.get_file()
	_engine.request_reversed(_current)

## Where a finished reverse render leaves the deck, as [play, paused, from]. Read when the take
## LANDS, so the transport the user left is the one it gets: stopped stays stopped with the
## reversed take loaded, paused stays paused at the mirrored position, playing carries on there.
static func rev_landing(state: String, at: float, full: float, rev_len: float) -> Array:
	return [state != "STOPPED", state == "PAUSED", clampf(full - at, 0.0, maxf(rev_len, 0.0))]

func _refresh_rev_btn() -> void:
	if is_instance_valid(_rev_btn):
		_rev_btn.text = "[*] REV" if _is_reversed(_engine.deck) else "REV"

func _refresh_deck_ui() -> void:
	if is_instance_valid(_deck_btn):
		# both names always on the button, the live one bracketed: a label that shows only
		# the current deck reads as a command to switch to it. "!" marks a deck that is
		# playing while the crossfader holds it silent.
		var names := ["A", "B"]
		if _silenced >= 0:
			names[_silenced] += "!"
		_deck_btn.text = "[A+B]" if _engine.both else (
			"[%s] %s" % names if _engine.deck == 0 else "%s [%s]" % names)
	if is_instance_valid(_xfade):
		_xfade.value = _decks.crossfader * 100.0

# --- BEAT SYNC ------------------------------------------------------------------------
## One beat tracker per deck, on that deck's own bus, so the two grids can be compared. The
## Master director cannot do it: it hears the SUM, and two decks' kicks in one onset stream
## is one confused tempo.
##
## ponytail: PHASE alignment only. Godot has no time-stretch, so the tempos must already agree
## within SYNC_TEMPO_TOL; a 1% mismatch drifts ~5 ms per beat after the nudge. Matching tempo
## itself needs a stretch kernel in libsoundscape_dsp.
const SYNC_TEMPO_TOL := 0.015
var _deck_directors: Array[AudioDirector] = []
var _beat_sync := false
var _sync_btn: Button

func _set_beat_sync(on: bool) -> void:
	_beat_sync = on
	for i in _deck_directors.size():
		_deck_directors[i].set_tracking(on, on or _dual_visual)   # DUAL VISUAL reads their bands
		_sync_attach(i)
	_refresh_sync_btn()

## Points a deck's tracker at whatever that deck is sounding through. Every change of live
## player or track calls this; attach() also drops the previous track's tempo lock.
func _sync_attach(deck: int, player: AudioStreamPlayer = null) -> void:
	if deck < _deck_directors.size():
		_deck_directors[deck].attach(player if player else _live_player(deck))

func _refresh_sync_btn() -> void:
	if is_instance_valid(_sync_btn):
		_sync_btn.button_pressed = _beat_sync
		_sync_btn.text = "[*] SYNC" if _beat_sync else "[ ] SYNC"

func _sync_readout() -> String:
	if not _beat_sync or _deck_directors.size() < 2:
		return "BEAT SYNC OFF  //  ON: GRABBING THE CROSSFADER OR PRESSING A+B LINES THE BEATS UP"
	var a := _deck_directors[0]
	var b := _deck_directors[1]
	return "BEAT SYNC  //  A %s  //  B %s  //  ALIGNS ON CROSSFADER GRAB OR A+B" % [
		"%.1f BPM (%.2f)" % [a.bpm, a.confidence] if a.bpm > 0.0 else "NO LOCK",
		"%.1f BPM (%.2f)" % [b.bpm, b.confidence] if b.bpm > 0.0 else "NO LOCK"]

## Lines the OTHER deck's beat grid up with the live deck's, once, by nudging its playhead.
func _align_decks() -> void:
	if _deck_directors.size() < 2:
		return
	var master := _engine.deck
	var slave := 1 - master
	var pl := _live_player(slave)
	if not pl.playing:
		_note = "  //  SYNC: %s IS NOT PLAYING" % AudioEngine.DECK_NAMES[slave]
		_clear_note_later()
		return
	var d := AudioDirector.sync_seek(_deck_directors[master], _deck_directors[slave], SYNC_TEMPO_TOL)
	if is_nan(d):
		var m := _deck_directors[master]
		var s := _deck_directors[slave]
		_note = ("  //  SYNC: WAITING FOR A TEMPO LOCK ON BOTH DECKS" if m.bpm <= 0.0 or s.bpm <= 0.0
			else "  //  SYNC: TEMPOS TOO FAR APART (%.1f / %.1f BPM, NO TIME-STRETCH)" % [m.bpm, s.bpm])
		_clear_note_later()
		return
	pl.seek(maxf(pl.get_playback_position() + d, 0.0))
	_note = "  //  SYNC: %s NUDGED %+d MS ONTO %s'S BEAT" % [AudioEngine.DECK_NAMES[slave],
		int(roundf(d * 1000.0)), AudioEngine.DECK_NAMES[master]]
	_clear_note_later()

## Parks the deck being left and binds everything to the one being entered.
func _switch_deck(which: int) -> void:
	if which == _engine.deck:
		return
	_decks.deck_cur[_engine.deck] = _current
	_decks.deck_live[_engine.deck] = _decks.audio
	# a fade that is mid-flight belongs to the deck being parked; let it finish on its own
	# players rather than dragging the tween across the switch
	_engine.set_deck(which)
	_bind_deck(which)
	_note = "  //  %s" % AudioEngine.DECK_NAMES[which]
	_clear_note_later()
	_save_soon()

func _bind_deck(which: int) -> void:
	_decks.audio = _decks.deck_live[which] if _decks.deck_live[which] else _decks.pair[which][0]
	_current = _decks.deck_cur[which]
	_eq = _eq_decks[which] if _eq_decks.size() > which else _eq
	if _eq:
		# DRIVE is a global colour control rather than a channel strip, so it follows you
		# onto whichever deck you are driving
		_eq.set_boost(_boost_gain())
	_director.attach(_bar())   # the bar's player, not _decks.audio: an empty deck would blank it
	_refresh_deck_ui()
	_refresh_rev_btn()   # REV belongs to the deck, so the button changes with it
	if not _current.is_empty():
		_key = _resolved_key(_current)
		_ticker.text = _engine.ticker_line(_current)
	if is_instance_valid(_cue_overlay):
		_cue_overlay.queue_redraw()
	if not _library.index.is_empty():
		# the queue becomes this deck's crate view; neither list needs rebuilding for that
		_engine.set_queue(_library.shown[which], _current)
		_mark_decks()

# --- runtime assets: fonts, cursors, and the write-in ------------------------
## Fonts and cursors are read from beside library.cfg rather than compiled in, so a
## skinned copy of the program does not need a rebuild:
##
##   user://fonts/*.ttf,*.otf   picked from the TBS settings screen
##   user://cursors/arrow.png   replaces the drawn 12x19 arrow, hotspot at its top-left
##
## user:// rather than res://: an exported build's res:// is inside the pck and cannot be
## added to, which would make this a feature that only works in the editor.
const FONT_DIR := "user://fonts"
const CURSOR_DIR := "user://cursors"
const FONT_EXTS := ["ttf", "otf", "woff", "woff2"]

var _fonts: Array[String] = []   # display names; "" is the built-in pixel font
var _font_name := ""
var _font_btn: Button

func _scan_fonts() -> void:
	_fonts = [""]
	# created rather than merely tolerated: an empty folder sitting next to library.cfg
	# is the only documentation anyone needs for where a font goes, and get_files_at on
	# a missing directory pushes an error every time the list is rescanned
	if not DirAccess.dir_exists_absolute(FONT_DIR):
		DirAccess.make_dir_recursive_absolute(FONT_DIR)
		DirAccess.make_dir_recursive_absolute(CURSOR_DIR)
	for f in DirAccess.get_files_at(FONT_DIR):
		if f.get_extension().to_lower() in FONT_EXTS:
			_fonts.append(f)

## Swaps the theme's default font. Everything in the program draws with the theme, so a
## font change needs no per-node work -- and the CJK fallback chain is rebuilt straight
## after, or Japanese tags would turn into boxes the moment anyone picked a Latin font.
## sfnt / OTTO / ttcf / true, plus WOFF and WOFF2 for anything hand-dropped in the folder.
const FONT_MAGIC := [0x00010000, 0x4F54544F, 0x74746366, 0x74727565, 0x774F4646, 0x774F4632]
const PNG_MAGIC := 0x89504E47

## Big-endian magic number from the head of a file, or -1 if it cannot be read. Four bytes
## and no error output, which is the whole point -- see load_font_file.
static func _magic32(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return -1
	if f.get_length() < 8:
		f.close()
		return -1
	f.big_endian = true
	var m := f.get_32()
	f.close()
	return m

## The ONE place a font file becomes a FontFile, because validating one is not obvious:
## load_dynamic_font() returns OK for ANY file. FreeType does not look at the data until
## something asks it to rasterise, so a text file renamed .ttf sails straight through the
## error code and only fails later -- as console spam, with every glyph silently missing
## and the whole UI stuck on a font that cannot draw. The sfnt magic is the real test.
## Returns null for anything that will not render.
static func load_font_file(path: String) -> FontFile:
	if not (_magic32(path) in FONT_MAGIC):
		return null
	var f := FontFile.new()
	return f if f.load_dynamic_font(path) == OK else null

static func png_is_valid(path: String) -> bool:
	return _magic32(path) == PNG_MAGIC

func _apply_font(file_name: String) -> void:
	_font_name = file_name
	if file_name.is_empty():
		theme.default_font = _builtin_font
	else:
		var f := load_font_file(FONT_DIR.path_join(file_name))
		if not f:
			push_warning("font %s would not load" % file_name)
			_font_name = ""
			theme.default_font = _builtin_font
		else:
			theme.default_font = f
	_setup_pixel_font()   # re-attach the fallbacks to whatever is now in place
	_refresh_font_btn()
	_repin_labels()       # every caption's pinned width was measured in the old face

func _refresh_font_btn() -> void:
	if is_instance_valid(_font_btn):
		_font_btn.text = "PX437 (BUILT-IN)" if _font_name.is_empty() else _font_name.to_upper()

func _cycle_font() -> void:
	_scan_fonts()
	var at := _fonts.find(_font_name)
	_apply_font(_fonts[(at + 1) % _fonts.size()] if at >= 0 else "")
	_save()

## A PNG in user://cursors wins over the drawn arrow. DisplayServer rather than
## Input.set_custom_mouse_cursor: it is the call that actually owns the shape, and it
## takes the image directly, so a user bitmap needs no ImageTexture round trip.
## "" keeps the documented arrow.png behaviour, so a cursor dropped into the folder by
## hand still works with nothing selected in the manager.
func _custom_cursor_image() -> Image:
	var file := _cursor_name if not _cursor_name.is_empty() else "arrow.png"
	var path := CURSOR_DIR.path_join(file)
	if not png_is_valid(path):
		return null   # missing or not a PNG; the drawn arrow stands in
	var img := Image.load_from_file(path)
	if not img:
		push_warning("cursors/%s would not load" % file)
		return null
	return img


# --- FONTS / CURSOR manager windows ------------------------------------------
## Two windows off the VISUAL tab, both the same shape: ADD FILE, a list, a control strip
## and a status line. ADD FILE COPIES the chosen file into user://fonts or user://cursors
## rather than remembering where the user browsed to -- _scan_fonts() already reads those
## directories, the asset survives its original being moved or deleted, and an exported
## build's res:// cannot be written to at all.
const CURSOR_EXTS := ["png"]
const FONT_SIZE_MIN := 8
const FONT_SIZE_MAX := 28
const FONT_SIZE_DEFAULT := 16   # matches player.tscn's theme default_font_size
## Preview cap, and half the ceiling a scaled cursor is clamped to. Windows refuses a
## cursor bitmap past 256 px, and a pointer anywhere near that is already absurd.
const ASSET_THUMB_PX := 128
const CURSOR_SCALE_MIN := 0.5
const CURSOR_SCALE_MAX := 4.0
const ASSET_WIN_SIZE := Vector2i(560, 520)
const ASSET_OK := Color(0.35, 0.95, 0.45)
const ASSET_ERR := Color(1.0, 0.33, 0.33)

var _font_size := FONT_SIZE_DEFAULT
var _cursor_name := ""                # file inside CURSOR_DIR; "" is the drawn arrow
var _cursor_scale := 1.0
## Stored as a FRACTION of the image rather than in pixels, so moving the size slider
## does not drag the click point out from under the tip.
var _cursor_hotspot := Vector2.ZERO
var _asset_wins := {}                 # title -> Window, so a second press refocuses

## The theme's default size, so every Label, Button and list row follows from one write --
## the same reason _apply_font swaps theme.default_font instead of walking nodes.
func _apply_font_size(px: int) -> void:
	_font_size = clampi(px, FONT_SIZE_MIN, FONT_SIZE_MAX)
	theme.default_font_size = _font_size
	_repin_labels()   # the pins are pixel widths, and every one of them just changed

## Long edge capped, aspect preserved. Pure, so the cap rule is checkable without a file.
static func thumb_size(w: int, h: int, cap: int) -> Vector2i:
	var long_edge := maxi(w, h)
	if long_edge <= cap or long_edge <= 0:
		return Vector2i(maxi(w, 1), maxi(h, 1))
	var k := float(cap) / float(long_edge)
	return Vector2i(maxi(int(w * k), 1), maxi(int(h * k), 1))

static func asset_test() -> bool:
	return thumb_size(32, 32, 128) == Vector2i(32, 32) \
		and thumb_size(512, 256, 128) == Vector2i(128, 64) \
		and thumb_size(256, 512, 128) == Vector2i(64, 128) \
		and thumb_size(4000, 1, 128) == Vector2i(128, 1) \
		and thumb_size(0, 0, 128) == Vector2i(1, 1)

## Dead centre of the PRIMARY display, not of whatever screen the player happens to sit
## on: a manager window that opens away on a second monitor reads as not having opened.
func _centre_on_primary(win: Window) -> void:
	var s := DisplayServer.get_primary_screen()
	var usable := DisplayServer.screen_get_usable_rect(s)
	win.current_screen = s
	# a headless or otherwise degenerate screen reports a zero rect, and centring against
	# it would place the window at negative coordinates, i.e. nowhere the user can reach
	if usable.size.x <= 0 or usable.size.y <= 0:
		return
	win.size = Vector2i(mini(win.size.x, maxi(usable.size.x - 40, 320)),
		mini(win.size.y, maxi(usable.size.y - 60, 240)))
	win.position = usable.position + (usable.size - win.size) / 2

## A second press brings the open window forward instead of stacking a duplicate.
func _refocus_asset(title: String) -> bool:
	var win: Window = _asset_wins.get(title)
	if is_instance_valid(win):
		win.grab_focus()
		return true
	_asset_wins.erase(title)   # it was closed; the stale key would block reopening
	return false

func _asset_status(label: Label, ok: bool, what: String) -> void:
	label.text = "SUCCESSFULLY ADDED %s" % what if ok else "ERROR: CHECK FILE"
	label.add_theme_color_override("font_color", ASSET_OK if ok else ASSET_ERR)

## Validated BEFORE the copy, so an unreadable file never lands in the directory and never
## has to be swept back out. Returns the installed file name, or "" on any failure at all
## -- every caller turns that one empty string into the red status line.
func _install_asset(src: String, dir: String, exts: Array, as_font: bool) -> String:
	if src.is_empty() or not (src.get_extension().to_lower() in exts):
		return ""
	if not FileAccess.file_exists(src):
		return ""
	# magic-checked rather than handed straight to the loader: a bad file is a normal
	# thing for a user to pick, and it should turn into a red status line, not four lines
	# of engine error in the console
	if as_font:
		if load_font_file(src) == null:
			return ""
	elif not png_is_valid(src) or Image.load_from_file(src) == null:
		return ""
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		return ""
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var out := FileAccess.open(dir.path_join(src.get_file()), FileAccess.WRITE)
	if not out:
		return ""
	out.store_buffer(bytes)
	out.close()
	return src.get_file()

## Shared chassis. Both managers are the same window, so the frame is built once here and
## each one fills in its own list and control strip.
## Returns {window, list, controls, status, dialog}.
func _asset_window(title: String, filters: PackedStringArray) -> Dictionary:
	var win := Window.new()
	win.name = "Mgr%s" % title
	win.title = "SOUNDSCAPE // %s" % title
	win.transient = false     # independent: it can live on another monitor
	win.exclusive = false     # and must not block the player while it is open
	win.theme = theme         # font + every stylebox, and Skins repaints it for free
	win.size = ASSET_WIN_SIZE
	win.min_size = Vector2i(420, 360)
	add_child(win)
	_asset_wins[title] = win
	win.close_requested.connect(func() -> void:
		_asset_wins.erase(title)
		win.queue_free())

	var chassis := PanelContainer.new()
	chassis.set_anchors_preset(Control.PRESET_FULL_RECT)
	var root_sb: StyleBox = get("theme_override_styles/panel")
	if root_sb:
		chassis.add_theme_stylebox_override("panel", root_sb)
	win.add_child(chassis)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	chassis.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pad.add_child(col)

	var head := Label.new()
	head.text = "[ %s ]" % title
	head.theme_type_variation = &"Green"
	col.add_child(head)

	# native picker, like the FOLDERS dialog -- and a child of this window, so closing the
	# manager takes its dialog down with it rather than leaving one orphaned.
	# No filters means the manager has nothing to load from disk (the gradient editor), so
	# it gets neither the row nor the dialog rather than a button that cannot do anything.
	var fd: FileDialog = null
	if not filters.is_empty():
		fd = FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.use_native_dialog = true
		fd.filters = filters
		win.add_child(fd)
		var add := Button.new()
		add.text = "ADD FILE"
		add.pressed.connect(func() -> void: fd.popup_centered(Vector2i(760, 520)))
		col.add_child(add)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	var controls := VBoxContainer.new()
	controls.add_theme_constant_override("separation", 4)
	col.add_child(controls)

	var status := Label.new()
	status.clip_text = true
	status.theme_type_variation = &"Green"
	col.add_child(status)

	_centre_on_primary(win)
	win.show()
	return {"window": win, "list": list, "controls": controls, "status": status, "dialog": fd}

## A labelled drag bar -- the same ProgressBar + _bar_drag control the crossfader and every
## FX fader use, rather than an HSlider the theme has no styles for and which would be the
## one widget in the program that did not match.
##
## `on_change` is handed the readout Label as an argument rather than capturing it: a
## GDScript lambda captures by VALUE at creation, so a label assigned from this function's
## return value would still be null inside the closure.
func _asset_slider(parent: Control, caption: String, value: float, on_change: Callable) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var cap := Label.new()
	cap.text = caption
	cap.custom_minimum_size.x = 108
	row.add_child(cap)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(140, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.value = clampf(value, 0.0, 1.0) * 100.0
	row.add_child(bar)
	var read := Label.new()
	read.custom_minimum_size.x = 64
	row.add_child(read)
	bar.gui_input.connect(func(e: InputEvent) -> void:
		var t := _bar_wheel(e, bar.value / 100.0)
		if t < 0.0:
			if not _bar_drag(e, bar):
				return
			t = _ratio_at(e.position.x, bar.size.x)
		bar.value = t * 100.0
		on_change.call(t, read))
	return read

# --- FONTS -------------------------------------------------------------------
func _open_fonts_window() -> void:
	if _refocus_asset("FONTS"):
		return
	var w := _asset_window("FONTS", PackedStringArray(["*.ttf,*.otf ; FONT FILES"]))
	var status: Label = w["status"]
	var list: Control = w["list"]
	_fill_font_list(list, status)
	(w["dialog"] as FileDialog).file_selected.connect(func(path: String) -> void:
		var added := _install_asset(path, FONT_DIR, FONT_EXTS, true)
		_asset_status(status, not added.is_empty(), "FONT")
		if not added.is_empty():
			_apply_font(added)
			_save()
		_fill_font_list(list, status))
	var read := _asset_slider(w["controls"], "FONT SIZE",
		float(_font_size - FONT_SIZE_MIN) / float(FONT_SIZE_MAX - FONT_SIZE_MIN),
		func(t: float, label: Label) -> void:
			_apply_font_size(FONT_SIZE_MIN + int(roundf(t * float(FONT_SIZE_MAX - FONT_SIZE_MIN))))
			label.text = "%d PX" % _font_size
			_save_soon())
	read.text = "%d PX" % _font_size

## One Button per font, each drawn IN that font. ItemList has no per-item font in Godot 4
## -- there is no set_item_font -- so the list is Buttons in a VBox, which are themed,
## clickable, and take a font override each.
func _fill_font_list(list: Control, status: Label) -> void:
	for c in list.get_children():
		c.queue_free()
	_scan_fonts()
	for font_name in _fonts:
		var row := HBoxContainer.new()
		list.add_child(row)
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = font_name == _font_name
		if font_name.is_empty():
			b.text = "PX437 (BUILT-IN)"
			# in ITS face, like every row below it. Without this the built-in row was drawn in
			# whatever font is currently selected, so the one row that says what you get by
			# going back was the only one not showing it.
			if _builtin_font:
				b.add_theme_font_override("font", _builtin_font)
		else:
			b.text = font_name
			var f := load_font_file(FONT_DIR.path_join(font_name))
			if f:
				b.add_theme_font_override("font", f)
			else:
				# left visible rather than hidden: a font that will not load is something
				# the user put there on purpose, and silently omitting it reads as the
				# ADD having failed
				b.text = "%s  (UNREADABLE)" % font_name
				b.disabled = true
		row.add_child(b)
		b.pressed.connect(func() -> void:
			_apply_font(font_name)
			# _apply_font resets _font_name to "" when the load fails, so this comparison
			# IS the success test -- no second attempt at reading the file
			_asset_status(status, _font_name == font_name, "FONT")
			_save()
			_fill_font_list(list, status))
		# the built-in pixel font has no file to delete and stays selectable forever
		if not font_name.is_empty():
			var del := Button.new()
			del.text = "X"
			del.pressed.connect(func() -> void:
				DirAccess.remove_absolute(FONT_DIR.path_join(font_name))
				if _font_name == font_name:
					_apply_font("")   # the deleted font cannot stay selected
					_save()
				_status_note(status, true, "DELETED %s" % font_name)
				_fill_font_list(list, status))
			row.add_child(del)

# --- CURSOR ------------------------------------------------------------------
func _open_cursor_window() -> void:
	if _refocus_asset("CURSOR"):
		return
	var w := _asset_window("CURSOR", PackedStringArray(["*.png ; CURSOR IMAGES"]))
	var status: Label = w["status"]
	var list: Control = w["list"]
	_fill_cursor_list(list, status)
	(w["dialog"] as FileDialog).file_selected.connect(func(path: String) -> void:
		var added := _install_asset(path, CURSOR_DIR, CURSOR_EXTS, false)
		_asset_status(status, not added.is_empty(), "CURSOR")
		if not added.is_empty():
			_cursor_name = added
			_setup_cursor()
			_save()
		_fill_cursor_list(list, status))
	var size_read := _asset_slider(w["controls"], "CURSOR SIZE",
		(_cursor_scale - CURSOR_SCALE_MIN) / (CURSOR_SCALE_MAX - CURSOR_SCALE_MIN),
		func(t: float, label: Label) -> void:
			_cursor_scale = lerpf(CURSOR_SCALE_MIN, CURSOR_SCALE_MAX, t)
			label.text = "%.2fx" % _cursor_scale
			_setup_cursor()
			_save_soon())
	size_read.text = "%.2fx" % _cursor_scale
	var hx := _asset_slider(w["controls"], "HOTSPOT X", _cursor_hotspot.x,
		func(t: float, label: Label) -> void:
			_cursor_hotspot.x = t
			label.text = "%d%%" % int(t * 100.0)
			_setup_cursor()
			_save_soon())
	hx.text = "%d%%" % int(_cursor_hotspot.x * 100.0)
	var hy := _asset_slider(w["controls"], "HOTSPOT Y", _cursor_hotspot.y,
		func(t: float, label: Label) -> void:
			_cursor_hotspot.y = t
			label.text = "%d%%" % int(t * 100.0)
			_setup_cursor()
			_save_soon())
	hy.text = "%d%%" % int(_cursor_hotspot.y * 100.0)

func _fill_cursor_list(list: Control, status: Label) -> void:
	for c in list.get_children():
		c.queue_free()
	var names: Array[String] = [""]
	if not DirAccess.dir_exists_absolute(CURSOR_DIR):
		DirAccess.make_dir_recursive_absolute(CURSOR_DIR)
	for f in DirAccess.get_files_at(CURSOR_DIR):
		if f.get_extension().to_lower() in CURSOR_EXTS:
			names.append(f)
	for cur_name in names:
		var row := HBoxContainer.new()
		list.add_child(row)
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = cur_name == _cursor_name
		if cur_name.is_empty():
			b.text = "BUILT-IN ARROW"
		else:
			b.text = cur_name
			var tex := _thumb(CURSOR_DIR.path_join(cur_name))
			if tex:
				b.icon = tex
			else:
				b.text = "%s  (UNREADABLE)" % cur_name
				b.disabled = true
		row.add_child(b)
		b.pressed.connect(func() -> void:
			_cursor_name = cur_name
			_setup_cursor()
			# the built-in arrow is always a valid choice, so only a named file can fail
			_asset_status(status, cur_name.is_empty()
				or _custom_cursor_image() != null, "CURSOR")
			_save()
			_fill_cursor_list(list, status))
		# the built-in arrow has no file to delete and stays selectable forever
		if not cur_name.is_empty():
			var del := Button.new()
			del.text = "X"
			del.pressed.connect(func() -> void:
				DirAccess.remove_absolute(CURSOR_DIR.path_join(cur_name))
				if _cursor_name == cur_name:
					_cursor_name = ""   # the deleted cursor cannot stay selected
					_setup_cursor()
					_save()
				_status_note(status, true, "DELETED %s" % cur_name)
				_fill_cursor_list(list, status))
			row.add_child(del)

## Preview capped at ASSET_THUMB_PX on the long edge. A cursor PNG is usually tiny, but
## nothing stops someone adding a 4K image, and a button icon at that size would push the
## window off the screen.
func _thumb(path: String) -> ImageTexture:
	if not png_is_valid(path):
		return null
	var img := Image.load_from_file(path)
	if not img or img.is_empty():
		return null
	var want := thumb_size(img.get_width(), img.get_height(), ASSET_THUMB_PX)
	if want != Vector2i(img.get_width(), img.get_height()):
		img.resize(want.x, want.y, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


# --- gradients ---------------------------------------------------------------
## User colour gradients for the visualizer, stored in library.cfg as hex lists:
##
##   [visual]
##   user_grad_1="000000,ff0055,00ffcc,ffffff"
##
## That string is also exactly what COPY and PASTE move through the clipboard, so a
## gradient can be shared by pasting one line into a chat window. Parsing and sampling
## live in visualizer.gd, which is the thing that has to draw them.
const GRAD_MAX := 12          # swatch row is one line; past this it wraps and reads as noise
const GRAD_STOPS_MAX := 8
var _gradients: Array[Gradient] = []

func _grad_key(i: int) -> String:
	return "user_grad_%d" % (i + 1)

## 64x1 strip stretched across the swatch, the same trick _rainbow_swatch uses -- a
## StyleBoxFlat holds one colour, so anything with more than one has to be a texture.
func _gradient_swatch(grad: Gradient) -> StyleBoxTexture:
	# 128 rather than 64: the preview box in the gradient editor is 160 px wide, so a
	# 64 px strip was being upsampled and a narrow stop could land between two texels
	var img := Image.create(128, 1, false, Image.FORMAT_RGBA8)
	for x in 128:
		img.set_pixel(x, 0, grad.sample(float(x) / 127.0))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	return sb

## Swatches for the VISUAL tab: SKIN, the fixed presets, the rainbow, then one per gradient.
## Rebuilt wholesale rather than patched, because adding or deleting a gradient renumbers
## every slot after it and color_index is a position in this row (SKIN sits at -1).
func _rebuild_color_row() -> void:
	for c in %ColorRow.get_children():
		# removed as well as freed: queue_free alone leaves the old swatches in the child
		# list until the end of the frame, and color_index IS a position in this row
		%ColorRow.remove_child(c)
		c.queue_free()
	_viz.gradients = _gradients
	var fixed: int = _viz.PRESETS.size()
	for i in range(Visualizer.CUSTOM_INDEX, fixed + 1 + _gradients.size()):
		var b := Button.new()
		# %ColorRow is an HFlowContainer now, not a single fixed row -- a swatch needs its
		# own width to wrap sanely, where the old HBoxContainer could rely on
		# SIZE_EXPAND_FILL dividing one row evenly among however many there were
		b.custom_minimum_size = Vector2(40, 18)
		var sb: StyleBox
		if i == Visualizer.CUSTOM_INDEX:
			# the colour the picker holds, as its own swatch: the row is where every other
			# choice lives, so the custom one belongs in it rather than only in the picker
			var flat := StyleBoxFlat.new()
			flat.bg_color = _viz.custom_color
			flat.border_color = Color(0, 0, 0)
			flat.set_border_width_all(1)
			sb = flat
			_hover_note(b, func() -> String:
				return "CUSTOM COLOUR  //  %s  //  PICK IT ON THE ROW BELOW" % _viz.custom_color.to_html(false).to_upper())
		elif i == Visualizer.SKIN_INDEX:
			sb = _gradient_swatch(Skins.accent_ramp(_skin))
			# labelled, because a mono skin's swatch is one flat colour -- on WIN98 the very
			# green of the first preset -- and in the screen colour, which reads on every accent
			b.text = "SKIN"
			# wide enough for the word: every other swatch is a 40 px colour chip, and this one
			# is the only one carrying text, which clip_text was cutting to "SK"
			# measured off the THEME, not the button: nothing is in the tree yet here, so
			# get_theme_font() has nothing to walk up to and hands back null
			var swatch_font: Font = theme.default_font
			if swatch_font:
				b.custom_minimum_size.x = maxf(b.custom_minimum_size.x, ceilf(swatch_font.get_string_size(
					b.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, theme.default_font_size).x) + 8.0)
			for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
					"font_hover_pressed_color"]:
				b.add_theme_color_override(key, Skins.scheme(_skin).screen)
			_hover_note(b, func() -> String: return "SKIN ACCENTS  //  FOLLOWS %s" % _skin)
		elif i < fixed:
			var flat := StyleBoxFlat.new()
			flat.bg_color = _viz.PRESETS[i]
			flat.border_color = Color(0, 0, 0)
			flat.set_border_width_all(1)
			sb = flat
		elif i == fixed:
			sb = _rainbow_swatch()
		else:
			sb = _gradient_swatch(_gradients[i - fixed - 1])
		_apply_swatch(b, sb)
		b.pressed.connect(func() -> void:
			_viz.color_index = i
			_save())
		%ColorRow.add_child(b)

func _open_gradient_window() -> void:
	if _refocus_asset("GRADIENT"):
		return
	# no filters: this manager has nothing to load from disk, so _asset_window skips the
	# ADD FILE row and its dialog entirely
	var w := _asset_window("GRADIENT", PackedStringArray())
	var status: Label = w["status"]
	var list: Control = w["list"]
	var controls: Control = w["controls"]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	controls.add_child(row)
	for spec in [["NEW", "new"], ["COPY", "copy"], ["PASTE", "paste"], ["DELETE", "del"]]:
		var b := Button.new()
		b.text = spec[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var what: String = spec[1]
		b.pressed.connect(func() -> void: _gradient_action(what, list, status))
		row.add_child(b)
	_hover_note(row, func() -> String:
		return "COPY / PASTE MOVE A GRADIENT AS ONE HEX LINE VIA THE CLIPBOARD")
	_fill_gradient_list(list, status)

## The four buttons, kept in one place so adding a fifth is one entry in the table above
## rather than another closure wired at construction time.
func _gradient_action(what: String, list: Control, status: Label) -> void:
	var sel: int = _viz.gradient_index()
	match what:
		"new":
			if _gradients.size() >= GRAD_MAX:
				_status_note(status, false, "LIMIT %d GRADIENTS" % GRAD_MAX)
				return
			_gradients.append(_viz.parse_hex_list("000000,ff0055,00ffcc,ffffff"))
			_viz.color_index = _viz.PRESETS.size() + _gradients.size()
			_status_note(status, true, "NEW GRADIENT")
		"copy":
			if sel < 0 or sel >= _gradients.size():
				_status_note(status, false, "SELECT A GRADIENT FIRST")
				return
			DisplayServer.clipboard_set(_viz.to_hex_list(_gradients[sel]))
			_status_note(status, true, "COPIED TO CLIPBOARD")
		"paste":
			var grad: Gradient = _viz.parse_hex_list(DisplayServer.clipboard_get())
			# a clipboard holding a URL or a sentence parses to nothing, and that is the
			# case worth reporting -- silently creating an empty gradient reads as a crash
			if not grad or grad.get_point_count() < 2:
				_status_note(status, false, "CLIPBOARD HAS NO HEX LIST")
				return
			if _gradients.size() >= GRAD_MAX:
				_status_note(status, false, "LIMIT %d GRADIENTS" % GRAD_MAX)
				return
			_gradients.append(grad)
			_viz.color_index = _viz.PRESETS.size() + _gradients.size()
			_status_note(status, true, "PASTED %d STOPS" % grad.get_point_count())
		"del":
			if sel < 0 or sel >= _gradients.size():
				_status_note(status, false, "SELECT A GRADIENT FIRST")
				return
			_gradients.remove_at(sel)
			# the deleted slot took every later index down with it, so fall back to the
			# rainbow rather than leaving color_index pointing past the end
			_viz.color_index = _viz.PRESETS.size()
			_status_note(status, true, "DELETED")
	_after_gradient_change(list, status)

func _status_note(label: Label, ok: bool, msg: String) -> void:
	label.text = msg
	label.add_theme_color_override("font_color", ASSET_OK if ok else ASSET_ERR)

func _after_gradient_change(list: Control, status: Label) -> void:
	_viz.gradients = _gradients
	_rebuild_color_row()
	_fill_gradient_list(list, status)
	_viz.queue_redraw()
	_save()

## One block per gradient: the demo swatch, its hex string, the draggable offset strip,
## then a ColorPickerButton + delete pair per stop. ColorPickerButton rather than a
## hand-rolled picker -- it is the engine's own control, it already themes, and a
## custom one would be a colour wheel to maintain for no gain.
func _fill_gradient_list(list: Control, status: Label) -> void:
	for c in list.get_children():
		c.queue_free()
	if _gradients.is_empty():
		var empty := Label.new()
		empty.text = "NO GRADIENTS YET  //  PRESS NEW, OR PASTE A HEX LIST"
		list.add_child(empty)
		return
	for gi in _gradients.size():
		var grad: Gradient = _gradients[gi]
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		list.add_child(box)

		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		box.add_child(head)
		var pick := Button.new()
		pick.toggle_mode = true
		pick.button_pressed = _viz.gradient_index() == gi
		# the demo box: enlarged from the original 90x18 so a gradient is actually
		# readable at a glance rather than a thin paint chip
		pick.custom_minimum_size = Vector2(160, 32)
		_apply_swatch(pick, _gradient_swatch(grad))
		pick.pressed.connect(func() -> void:
			_viz.color_index = _viz.PRESETS.size() + 1 + gi
			_status_note(status, true, "GRADIENT %d SELECTED" % (gi + 1))
			_after_gradient_change(list, status))
		head.add_child(pick)
		var hexes := Label.new()
		hexes.text = _viz.to_hex_list(grad)
		hexes.clip_text = true
		hexes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(hexes)

		# repaints the demo box and the hex line from the live Gradient -- called after
		# any edit that does not itself already rebuild the whole list (a drag, a colour
		# change), so those stay smooth instead of re-typing every row on every frame
		var refresh_head := func() -> void:
			hexes.text = _viz.to_hex_list(grad)
			_apply_swatch(pick, _gradient_swatch(grad))
			_viz.queue_redraw()

		box.add_child(_make_grad_strip(grad, refresh_head))

		var stop_row := HBoxContainer.new()
		stop_row.add_theme_constant_override("separation", 3)
		box.add_child(stop_row)
		for si in grad.get_point_count():
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(30, 18)
			cp.color = grad.get_color(si)
			cp.edit_alpha = false
			# color_changed fires continuously while the wheel is dragged, so the save is
			# debounced -- _after_gradient_change would otherwise write library.cfg at
			# mouse-move rate
			cp.color_changed.connect(func(c: Color) -> void:
				grad.set_color(si, c)
				refresh_head.call()
				_save_soon())
			stop_row.add_child(cp)
			# per-stop delete -- the single trailing "-" only ever removed the LAST stop;
			# this is the one that actually lets any specific stop go
			var del := Button.new()
			del.text = "X"
			del.disabled = grad.get_point_count() <= 2   # two is the fewest still a gradient
			del.pressed.connect(func() -> void:
				grad.remove_point(si)
				_after_gradient_change(list, status))
			stop_row.add_child(del)
		var plus := Button.new()
		plus.text = "+"
		plus.disabled = grad.get_point_count() >= GRAD_STOPS_MAX
		plus.pressed.connect(func() -> void:
			var n := grad.get_point_count()
			var last := grad.get_offset(n - 1)
			var prev := grad.get_offset(n - 2) if n >= 2 else 0.0
			var mid := clampf((prev + last) * 0.5, 0.0, 1.0)
			# landing exactly on an existing stop would collapse two markers into one
			# indistinguishable line, so a coincidence is nudged off by a hair
			if is_equal_approx(mid, last) or is_equal_approx(mid, prev):
				mid = clampf(last - 0.01, 0.0, 1.0)
			grad.add_point(mid, grad.get_color(n - 1))   # duplicate colour: a visible, editable start
			_after_gradient_change(list, status))
		stop_row.add_child(plus)

## Custom-drawn strip: the gradient itself as a background, one tick per stop offset.
## Click-drag a tick to move that stop's OFFSET -- clamped so it cannot cross its
## neighbours, since Gradient does not resort points moved out of order. This is the
## "moveable colour marker lines for precise proximity dragging" ask; the stop's colour
## is still the ColorPickerButton below it, unchanged.
const GRAD_STRIP_H := 24.0
const GRAD_TICK_GRAB_PX := 10.0

func _make_grad_strip(grad: Gradient, on_change: Callable) -> Control:
	var strip := Control.new()
	strip.custom_minimum_size = Vector2(0, GRAD_STRIP_H)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.mouse_filter = Control.MOUSE_FILTER_STOP
	# which point index the button actually went down on, or -1 -- checked on every
	# motion event so a drag that started elsewhere (a press with no capture, then a
	# stray move across this strip) can never grab a tick it was never pressed on
	var armed := {"i": -1}
	strip.draw.connect(func() -> void:
		var w := strip.size.x
		var h := strip.size.y
		if w < 2.0:
			return
		var img := Image.create(maxi(int(w), 1), 1, false, Image.FORMAT_RGBA8)
		for x in img.get_width():
			img.set_pixel(x, 0, grad.sample(float(x) / maxf(w - 1.0, 1.0)))
		strip.draw_texture_rect(ImageTexture.create_from_image(img), Rect2(0, 0, w, h), false)
		for i in grad.get_point_count():
			var x := grad.get_offset(i) * w
			strip.draw_line(Vector2(x, 0), Vector2(x, h), Color.WHITE, 3.0)
			strip.draw_line(Vector2(x, 0), Vector2(x, h), Color.BLACK, 1.0))
	strip.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				var best := -1
				var best_d := GRAD_TICK_GRAB_PX
				for i in grad.get_point_count():
					var d := absf(grad.get_offset(i) * strip.size.x - e.position.x)
					if d < best_d:
						best_d = d
						best = i
				armed.i = best
			else:
				armed.i = -1
			return
		if not (e is InputEventMouseMotion and int(armed.i) >= 0 \
				and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0):
			return
		var i: int = armed.i
		var n := grad.get_point_count()
		var lo := 0.0 if i == 0 else grad.get_offset(i - 1) + 0.005
		var hi := 1.0 if i == n - 1 else grad.get_offset(i + 1) - 0.005
		if lo > hi:
			return   # neighbours are already touching; nowhere left to move
		grad.set_offset(i, clampf(_ratio_at(e.position.x, strip.size.x), lo, hi))
		strip.queue_redraw()
		on_change.call())
	return strip

# --- terminal write-in -------------------------------------------------------
## Rows type themselves in, top to bottom, when the list is rebuilt wholesale.
##
## ONLY the rows actually on screen are touched. A library of several thousand tracks has
## a few dozen visible rows and the rest are pure cost: every set_item_text on an unseen
## row is a string allocation and a redraw request for something nobody can see. The
## visible span is read from the scroll bar, so what "visible" means is whatever the user
## has actually scrolled to.
##
## One Tween drives the whole block rather than one per row: N tweens is N interpolators
## and N callbacks a frame, where this is one of each regardless of how many rows are up.
##
## It runs on a wholesale reload -- a rescan, a re-sort, a playlist change, a tab switch --
## and deliberately NOT on every _refill(). Search filters the list on each keystroke, and
## an animation there would restart mid-word on every letter typed.
const WRITE_IN_SECS := 0.18
const WRITE_IN_STAGGER := 0.55   # fraction of the run spent starting rows, not filling
const WRITE_IN_MAX := 96

var _write_tween: Tween
var _write_rows := PackedInt32Array()
var _write_full := PackedStringArray()

func _write_in() -> void:
	_marquee_stop()   # two things cannot own one row's text
	if _write_tween and _write_tween.is_valid():
		_write_tween.kill()
		_write_restore()
	if not _tracks.is_visible_in_tree() or _tracks.item_count == 0:
		return
	_write_rows.clear()
	_write_full.clear()
	var scroll := _tracks.get_v_scroll_bar()
	var top: float = scroll.value if scroll else 0.0
	for i in _tracks.item_count:
		# get_item_rect is in CONTENT coordinates -- measured: item 0 still reports y=2
		# after scrolling to 200 -- so the scroll offset has to be subtracted here rather
		# than assumed away
		var r := _tracks.get_item_rect(i)
		if not row_visible(r.position.y, r.size.y, top, _tracks.size.y):
			continue                      # off screen: never touched
		_write_rows.append(i)
		_write_full.append(_tracks.get_item_text(i))
		if _write_rows.size() >= WRITE_IN_MAX:
			break
	if _write_rows.is_empty():
		return
	for k in _write_rows.size():
		_tracks.set_item_text(_write_rows[k], "")
	_write_tween = create_tween()
	_write_tween.tween_method(_write_step, 0.0, 1.0, WRITE_IN_SECS)
	_write_tween.tween_callback(_write_restore)

## Does a row at `y` (content space) fall inside the view? Pure, so the one rule the
## whole optimisation rests on is checkable without a list, a window or a scroll bar.
static func row_visible(y: float, h: float, scroll: float, view_h: float) -> bool:
	return y + h >= scroll and y <= scroll + view_h

static func write_in_test() -> bool:
	return row_visible(0.0, 20.0, 0.0, 800.0) 		and row_visible(795.0, 20.0, 0.0, 800.0) 		and row_visible(-5.0, 20.0, 0.0, 800.0) 		and not row_visible(900.0, 20.0, 0.0, 800.0) 		and not row_visible(100.0, 20.0, 400.0, 800.0) 		and row_visible(1000.0, 20.0, 400.0, 800.0)

## Drops a running write-in WITHOUT restoring it, for the case where the list itself is
## about to be rebuilt. _write_in() kills-and-restores instead, because there the rows it
## is holding still exist and still need their text back.
func _write_cancel() -> void:
	if _write_tween and _write_tween.is_valid():
		_write_tween.kill()
	_write_rows.clear()
	_write_full.clear()

func _write_step(t: float) -> void:
	var n := _write_rows.size()
	for k in n:
		# the tween indexes a list it does not own, so the bound is re-checked every step
		# rather than trusted from arming time -- same guard _write_restore already has
		if _write_rows[k] >= _tracks.item_count:
			continue
		# each row starts a little after the one above it, so the block fills downward
		var start := float(k) / float(n) * WRITE_IN_STAGGER
		var local := clampf((t - start) / maxf(1.0 - WRITE_IN_STAGGER, 0.01), 0.0, 1.0)
		var full: String = _write_full[k]
		_tracks.set_item_text(_write_rows[k], full.substr(0, int(ceilf(full.length() * local))))

## Always runs, tween finished or killed: a row left holding a truncated string would
## look like the library had lost half its filenames.
func _write_restore() -> void:
	for k in _write_rows.size():
		if _write_rows[k] < _tracks.item_count:
			_tracks.set_item_text(_write_rows[k], _write_full[k])
	_write_rows.clear()
	_write_full.clear()


# --- cheat codes and unlocks --------------------------------------------------
## The last CODE_LEN letter keys.
##
## This buffer lives in _unhandled_input, and that IS why typing in SEARCH cannot fire a
## code: a focused LineEdit consumes the key before _unhandled_input is ever reached, so
## the buffer never sees it. That is Godot's input routing rather than a guard written
## here -- which is exactly why code_test() and the headless typing test pin it, because
## the property is invisible in this file and moving the buffer to _input() would break
## it silently, mid-search-term.
const CODE_LEN := 10
## Matched on the TAIL of the buffer, so a mistyped prefix does not have to be cleared
## before a correct code will register.
const LOCAL_CODES := {"SNAKE": "snake", "REDEEM": "redeem"}
var _keys := ""
var _unlocked: Array[String] = []

## Pure, so the matcher is testable without a window or a keyboard.
static func code_tail(buffer: String, ch: String, cap: int) -> String:
	var s := buffer + ch
	return s if s.length() <= cap else s.substr(s.length() - cap)

static func code_test() -> bool:
	var b := ""
	for ch in "XYSNAKE":
		b = code_tail(b, ch, CODE_LEN)
	if not b.ends_with("SNAKE"):
		return false
	for i in 50:                      # never grows past the cap, however much is typed
		b = code_tail(b, "Q", CODE_LEN)
	return b == "QQQQQQQQQQ" and code_tail("", "A", CODE_LEN) == "A" \
		and code_tail("SNAK", "E", CODE_LEN).ends_with("SNAKE")

func _push_code_key(ch: String) -> void:
	_keys = code_tail(_keys, ch, CODE_LEN)
	for code in LOCAL_CODES:
		if _keys.ends_with(code):
			_keys = ""
			_unlock(str(LOCAL_CODES[code]))
			return

func _unlock(what: String) -> void:
	if what == "redeem":
		_ask("REDEEM CODE", "", func(code: String) -> void: _redeem_code(code), 32)
		return
	if not (what in _unlocked):
		_unlocked.append(what)
	_apply_unlocks()
	if what == "snake":
		_viz.mode = Visualizer.Mode.SNAKE
		_viz.snake_reset()
		_note = "  //  SNAKE UNLOCKED"
	_clear_note_later()
	_refresh_visual()
	_save()

func _apply_unlocks() -> void:
	%Viz.snake_unlocked = "snake" in _unlocked
	%VizB.snake_unlocked = %Viz.snake_unlocked

## SNAKE sits one past the end of the normal cycle until it is unlocked, so the VIZ MODE
## button cannot land on it by accident.
func _viz_mode_count() -> int:
	return VIZ_NAMES.size() if _viz.snake_unlocked else VIZ_NAMES.size() - 1

# --- server codes --------------------------------------------------------------
## DORMANT unless an endpoint is configured. There is no SOUNDSCAPE server: `endpoint`
## under [secrets] in library.cfg is empty by default and nothing is sent anywhere until
## it is filled in. That is deliberate rather than unfinished -- redemption posts the
## user's NAME, and a build that quietly phoned home the first time somebody typed a word
## would be the wrong default whatever the endpoint eventually turns out to be.
##
## WHAT THE TOKEN IS WORTH, plainly: license.dat gates modes that run on THIS machine, and
## the key below ships inside the binary. It stops a hand-written license.dat and stops
## the file being copied between users unmodified. It does not stop anybody willing to
## open the executable, and it should not be read as DRM.
const LICENSE_PATH := "user://license.dat"
const LICENSE_KEY := "SOUNDSCAPE-v1-token"
var _license_endpoint := ""
var _http: HTTPRequest

func _redeem_code(code: String) -> void:
	var c := code.strip_edges().to_upper()
	if c.is_empty():
		return
	if _license_endpoint.is_empty():
		_note = "  //  NO REDEMPTION SERVER CONFIGURED"
		_clear_note_later()
		return
	if not is_instance_valid(_http):
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_redeem_reply)
	var body := JSON.stringify({"user_id": _user_name, "code": c})
	var err := _http.request(_license_endpoint, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	_note = "  //  REDEEMING..." if err == OK else "  //  REDEEM FAILED: NO CONNECTION"
	_clear_note_later()

func _on_redeem_reply(_result: int, status: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if status != 200:
		_note = "  //  CODE REJECTED (HTTP %d)" % status
		_clear_note_later()
		return
	var reply: Variant = JSON.parse_string(body.get_string_from_utf8())
	var unlocks: Array = reply.get("unlocks", []) if reply is Dictionary else []
	for u in unlocks:
		if not (str(u) in _unlocked):
			_unlocked.append(str(u))
	_write_license()
	_apply_unlocks()
	_note = "  //  UNLOCKED: %s" % ",".join(PackedStringArray(_unlocked)).to_upper()
	_clear_note_later()
	_refresh_visual()
	_save()

## "<user>|<unlocks>|<signature>". SIGNED rather than encrypted, and the distinction is
## the point: the job is to detect a file that was edited or carried over from another
## machine, which a signature does in one line -- where a cipher would only hide the same
## text behind a key that ships in the same binary.
func _write_license() -> void:
	var payload := "%s|%s" % [_user_name, ",".join(PackedStringArray(_unlocked))]
	var f := FileAccess.open(LICENSE_PATH, FileAccess.WRITE)
	if not f:
		push_warning("could not write %s" % LICENSE_PATH)
		return
	f.store_line("%s|%s" % [payload, license_sig(payload)])
	f.close()

static func license_sig(payload: String) -> String:
	return Marshalls.raw_to_base64(Crypto.new().hmac_digest(HashingContext.HASH_SHA256,
		LICENSE_KEY.to_utf8_buffer(), payload.to_utf8_buffer()))

## The unlocks the file legitimately carries. A missing, edited, unsigned or foreign file
## reads as no unlocks rather than as an error -- there is nothing the user can do about a
## bad license.dat except redeem again, so it is not worth a dialog.
func _read_license() -> Array[String]:
	var out: Array[String] = []
	if not FileAccess.file_exists(LICENSE_PATH):
		return out
	var line := FileAccess.get_file_as_string(LICENSE_PATH).strip_edges()
	var cut := line.rfind("|")
	if cut <= 0:
		return out
	var payload := line.substr(0, cut)
	if license_sig(payload) != line.substr(cut + 1):
		push_warning("license.dat failed its signature check; ignoring it")
		return out
	var parts := payload.split("|")
	if parts.size() < 2 or parts[0] != _user_name:
		return out       # correctly signed, but issued to somebody else
	for u in parts[1].split(",", false):
		out.append(u)
	return out

static func license_test() -> bool:
	var p := "gavin|snake"
	var sig := license_sig(p)
	return not sig.is_empty() and sig == license_sig(p) \
		and sig != license_sig(p + "x") \
		and sig != license_sig("someone|snake")


# --- playlist reordering, and deck A from the track menu ------------------------------
## DECK B's setlist tab is gone: TRK B is deck B's list now. `setlist_b` is still loaded and
## saved untouched -- the same courtesy the old TBS list gets -- so a running order someone
## built survives in library.cfg rather than being erased by the next save.
var _setlist_b: Array[String] = []

## Pure, so the reorder rules are checkable without a list widget. Returns the new index
## of the moved row, or the original when the move is not legal. MOVE UP/DOWN IN PLAYLIST.
static func setlist_move(list: Array[String], from: int, delta: int) -> int:
	if from < 0 or from >= list.size():
		return from
	var to := from + delta
	if to < 0 or to >= list.size():
		return from          # already at an end: a no-op, not a wrap
	var p: String = list[from]
	list.remove_at(from)
	list.insert(to, p)
	return to

static func setlist_test() -> bool:
	var l: Array[String] = ["a", "b", "c"]
	if setlist_move(l, 0, 1) != 1 or l != ["b", "a", "c"]:
		return false
	if setlist_move(l, 0, -1) != 0 or l != ["b", "a", "c"]:   # top edge holds
		return false
	if setlist_move(l, 2, 1) != 2 or l != ["b", "a", "c"]:    # bottom edge holds
		return false
	if setlist_move(l, -1, 1) != -1 or setlist_move(l, 9, -1) != 9:
		return false
	return setlist_move(l, 2, -1) == 1 and l == ["b", "c", "a"]

## PLAY ON DECK A from the track menu: switches to deck A and plays there.
func _play_on_deck_a(path: String) -> void:
	if _engine.both:
		_engine.set_both(false)
	if _engine.deck != 0:
		_switch_deck(0)
	_refresh_deck_ui()
	_open_deck(0, path)   # after the switch: the queue is crate A's view by then
