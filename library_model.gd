class_name LibraryModel
extends Node
## The library's DATA: where the music is, which of it is showing, in what order, and what the
## user has attached to it. No Control ever appears in this file. player.gd owns the ItemLists,
## the folder Tree and the search fields; it asks this for what to put in them.
##
## The split is not cosmetic. Scanning, sorting and filtering are the three things that touch
## every track in the library, so they are the three things that decide whether a 40,000-track
## library feels instant or feels broken -- and while they lived in the middle of 7,600 lines of
## UI wiring, every one of them ran on the main thread because that is where the code happened
## to be. Here they are separable: `scan()` runs on a worker, and the rest is a plain data
## model a test can drive with no scene, no audio device and no disk.
##
## WHAT IS A TRACK, exactly. Three different identities are in play and confusing them is how
## a library loses a user's work:
##   * the PATH is where the file sits today. It changes when a folder is moved or a drive is
##     re-lettered, and it is NOT what anything the user made is keyed by.
##   * the ID (see track_id) is the track itself, stable across a move.
##   * the ROW is what the list shows, which is the RENAME TAG if there is one and the
##     filename otherwise. It is also what SEARCH matches, so a track you renamed is findable
##     by the name you gave it.

## What the library takes. An .mp4 joins only while Video TEST is on -- see `video_test`.
## APE and TAK are lossless formats nothing here decodes natively; AudioEngine renders them once
## through ffmpeg and plays the render, so they are ordinary library tracks from here on.
const EXTS := ["mp3", "wav", "ogg", "flac", "dsf", "dff", "ape", "tak"]
## Appended, never inserted: the sort is persisted as an index into this list.
const SORTS := ["PATH", "NAME", "TYPE", "DATE", "FOLDER", "ARTIST", "ALBUM", "KEY", "BPM"]
## The sorts that need metadata, and so need a key gathered per track before the sort runs.
const META_SORTS := ["ARTIST", "ALBUM", "KEY", "BPM"]

## done/total tracks, and the directory being walked. Emitted from the main thread.
signal scan_progress(done: int, total: int, where: String)
## `cancelled` true when stop_scan() cut it short: the library is unchanged in that case.
signal scan_finished(found: int, cancelled: bool)

var engine: AudioEngine   # metadata for the ARTIST/ALBUM/KEY sorts; set by the owner

# --- roots ---------------------------------------------------------------------
var folders: Array[String] = []
var enabled_folders := {}   # directory -> true for every directory whose tracks are showing
var known_folders := {}     # every directory ever seen, so a new one can be enabled by default
var enabled_known := false

# --- what was found, and what is showing ---------------------------------------
var all_paths: Array[String] = []   # everything the walk found
var paths: Array[String] = []       # all_paths minus the folders that are switched off
## Index-aligned with `paths`: {dir, file, row, hay}. Folded once per library change rather
## than once per search keystroke.
var index: Array[Dictionary] = []
var path_pos := {}                  # path -> its position in index/paths

# --- per crate (0 = TRK A, 1 = TRK B) ------------------------------------------
var sorts := [0, 0]                 # crate -> index into SORTS
var filters := ["", ""]             # crate -> its search text
var orders := [[], []]              # crate -> paths in that crate's sort order
var shown := [[], []]               # crate -> the paths its list shows, in row order: its queue
var crate_pl := ["", ""]            # crate -> selected playlist, "" = the whole library

# --- what the user made --------------------------------------------------------
## All three are keyed by track ID, not by path: a library that moves keeps its cues.
var playlists := {}   # NAME -> Array of track IDs
var pl_cues := {}     # NAME -> { id -> Array of cue Dictionaries }
var cues := {}        # id -> Array of cue Dictionaries, global scope
var labels := {}      # id -> display name, from RENAME TAG

var video_test := false   # whether .mp4 counts as a track, mirrored from the setting

var _mtime := {}     # path -> modification time, gathered per DATE sort pass
var _sortkey := {}   # path -> meta_sort_key, gathered per metadata sort pass

# --- scanning, on a worker ------------------------------------------------------
var _thread: Thread
var _scan_lock := Mutex.new()
var _scan_stop := false
var _scan_done := 0
var _scan_where := ""
var _scan_out: Array[String] = []
var _scan_ids := {}   # path -> [fingerprint, byte size], for the tracks the walk found with no id
## The last completed scan's _scan_ids, for migrate_ids(). Public because the owner is the one
## that knows whether this library has been through the fingerprint migration yet.
var scan_ids := {}
var _scan_live := false

func _exit_tree() -> void:
	stop_scan()

# --- track identity -------------------------------------------------------------
## A track's identity, independent of where it sits on disk and of what it is called: FINGERPRINT
## BYTES read from the middle of the file, hashed. What that buys, against the name-and-size id it
## replaced (track_id below, kept for the migration):
##
##   a folder move, a drive re-letter, a whole library relocation  -> same id, as before
##   a RENAMED file                                                -> same id; the old id moved
##   two different tracks sharing a name and a byte count          -> different ids; they collided
##
## The middle, not the head or the tail, because that is where the tags are not: ID3v2 and Vorbis
## comments sit at the front, ID3v1 and APEv2 at the back. A tagger that rewrites in place, keeping
## the file length, therefore leaves the id alone. One that changes the length does not: the slice
## is taken at length/2, so it moves with the file. That is no worse than the size-based id it
## replaces, and it is the honest limit of a cheap fingerprint -- the alternative is hashing the
## decoded audio, which is a full decode per track.
##
## Re-encoding a file changes its id, which is correct: that is a different render of the track,
## and its old cue times need not fit.
const FINGERPRINT_BYTES := 65536

## [id, byte size], in one open. "" and 0 when the file cannot be read, so a caller can tell a
## fingerprint apart from a file that was not there.
static func fingerprint_and_size(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return ["", 0]
	var size := f.get_length()
	f.seek(maxi(0, int(size / 2) - FINGERPRINT_BYTES / 2))
	var slice := f.get_buffer(FINGERPRINT_BYTES)
	f.close()
	if slice.is_empty():
		return ["", size]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(slice)
	return [ctx.finish().hex_encode().left(16), size]

static func fingerprint(path: String) -> String:
	return str(fingerprint_and_size(path)[0])

## The PRE-FINGERPRINT id: the filename and the byte size. Only migrate_ids() still mints these,
## to work out which stored key belongs to which track before re-keying it.
static func track_id(path: String, size: int) -> String:
	return ("%s:%d" % [path.get_file().to_lower(), size]).sha1_text().left(16)

## The id for a path, assigning one if this is the first time the track has been seen. Costs one
## 64 KB read per NEW track -- the scan worker does that for everything it finds, so this only
## reads for a track that arrived some other way -- and nothing at all for one already indexed.
## A file that will not open falls back to the old name-and-size id rather than an empty key.
func id_for(path: String) -> String:
	if engine == null:
		return id_of(path)
	var known: String = engine.track_ids.get(path, "")
	if not known.is_empty():
		return known
	var id := id_of(path)
	engine.track_ids[path] = id
	return id

## The id a path earns from the file itself: its fingerprint, or -- for a file that will not open,
## which is every track on an unplugged drive -- the old name-and-size id, so the key is still
## stable rather than empty.
static func id_of(path: String) -> String:
	var got := fingerprint_and_size(path)
	return str(got[0]) if not str(got[0]).is_empty() else track_id(path, int(got[1]))

## Where a track with this id sits today, or "" if the library does not hold it. Built from
## the scanned paths, so it answers for the library as it is now, not as it was saved.
func path_for(id: String) -> String:
	return _id_paths.get(id, "")

var _id_paths := {}   # id -> path, rebuilt with the index

## Re-points every root, playlist and label from one location to another: the whole library
## moved to a new drive, or a folder was renamed. Paths are compared case-insensitively
## because Windows does. Returns how many roots moved.
##
## Cues, labels and playlists need no part in this -- they are keyed by id, and an id does not
## know where the file is. That is the entire reason they are keyed by id.
func relocate(from_prefix: String, to_prefix: String) -> int:
	var from := _norm_root(from_prefix)
	var to := _norm_root(to_prefix)
	if from.is_empty() or to.is_empty() or from.to_lower() == to.to_lower():
		return 0
	var moved := 0
	var out: Array[String] = []
	for root in folders:
		if _is_under(root, from):
			out.append(to + root.substr(from.length()))
			moved += 1
		else:
			out.append(root)
	folders = out
	var swap := func(src: Dictionary) -> Dictionary:
		var dst := {}
		for dir in src:
			var d := str(dir)
			dst[to + d.substr(from.length()) if _is_under(d, from) else d] = src[dir]
		return dst
	enabled_folders = swap.call(enabled_folders)
	known_folders = swap.call(known_folders)
	dedupe_roots()
	return moved

static func relocate_test() -> bool:
	var m := LibraryModel.new()
	m.folders = ["D:/Music", "C:/Other"]
	m.enabled_folders = {"D:/Music/Rock": true, "C:/Other/x": true}
	var n := m.relocate("D:\\Music\\", "E:/Sounds")
	var ok: bool = n == 1 and m.folders == ["E:/Sounds", "C:/Other"] \
		and m.enabled_folders.has("E:/Sounds/Rock") and m.enabled_folders.has("C:/Other/x") \
		and m.relocate("E:/Sounds", "E:/Sounds") == 0
	m.free()
	return ok

# --- path rules -----------------------------------------------------------------
## A file the library takes: audio always, an .mp4 only while Video TEST is on.
static func is_track(f: String, video := false) -> bool:
	var ext := f.get_extension().to_lower()
	return ext in EXTS or (video and ext == "mp4")

## Normalises a library root: backslashes to forward slashes, "." and ".." resolved, no
## trailing separator -- except on a bare drive, where "D:" alone is not a usable path.
static func _norm_root(dir: String) -> String:
	var out := dir.replace("\\", "/").simplify_path()
	if out.length() > 1 and out.ends_with("/") and not out.ends_with(":/"):
		out = out.left(out.length() - 1)
	return out

## True when `child` IS `parent` or sits underneath it. Case-insensitive, because Windows
## paths are; the separator is required so "C:/Music2" is not read as a child of "C:/Music".
static func _is_under(child: String, parent: String) -> bool:
	var c := child.to_lower()
	var p := parent.to_lower().trim_suffix("/")
	return c == p or c.begins_with(p + "/")

## Collapses the root list: normalised, de-duplicated case-insensitively, and with any root
## that lives inside another dropped.
##
## Nested roots are not merely redundant. The folder tree walks each root separately, so
## "C:/Music" and "C:/Music/Rock" both render a Rock branch -- two checkboxes for one
## directory, whose filter state then depends on which copy was clicked last.
func dedupe_roots() -> void:
	var kept: Array[String] = []
	for raw in folders:
		var dir := _norm_root(raw)
		var redundant := false
		for i in range(kept.size() - 1, -1, -1):
			if _is_under(dir, kept[i]):
				redundant = true      # covered by a root already kept
				break
			if _is_under(kept[i], dir):
				kept.remove_at(i)     # this root swallows one we had
		if not redundant:
			kept.append(dir)
	folders = kept

## Returns whether `dir` actually joined the library, and why not when it did not.
func add_folder(dir: String) -> Dictionary:
	dir = _norm_root(dir)
	for root in folders:
		if _is_under(dir, root):
			return {"added": false, "covered_by": root}
	folders.append(dir)
	dedupe_roots()
	enabled_folders[dir] = true   # a new root is on by default, like every folder in a fresh library
	return {"added": true, "covered_by": ""}

static func roots_test() -> bool:
	return _is_under("C:/Music/Rock", "C:/Music") \
		and _is_under("c:/music/rock", "C:/MUSIC") \
		and _is_under("C:/Music", "C:/Music") \
		and not _is_under("C:/Music2", "C:/Music") \
		and not _is_under("C:/Music", "C:/Music/Rock") \
		and _norm_root("C:\\Music\\Rock\\") == "C:/Music/Rock" \
		and _norm_root("D:/") == "D:/"

# --- scanning --------------------------------------------------------------------
## Walks every root on a WORKER thread. The disk walk used to run on the main thread, where a
## cold network drive or a sleeping external disk froze the whole program -- picture, audio
## meters and all -- for as long as the filesystem took to answer, with no way to stop it.
##
## Returns false when a scan is already running. Progress arrives as scan_progress; the result
## as scan_finished, on the main thread, with `all_paths` already replaced.
func scan() -> bool:
	if _scan_live:
		return false
	_scan_live = true
	_scan_lock.lock()
	_scan_stop = false
	_scan_done = 0
	_scan_where = ""
	_scan_out = []
	_scan_ids = {}
	_scan_lock.unlock()
	var roots := folders.duplicate()
	var video := video_test
	# a snapshot, so the worker never reads the live map while this thread writes it
	var known: Variant = engine.track_ids.duplicate() if engine else null
	_thread = Thread.new()
	_thread.start(func() -> void: _scan_worker(roots, video, known))
	set_process(true)
	return true

## Asks the running scan to stop and waits for the worker to notice. Safe to call when no
## scan is running.
func stop_scan() -> void:
	if not _scan_live:
		return
	_scan_lock.lock()
	_scan_stop = true
	_scan_lock.unlock()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_scan_live = false
	set_process(false)

func scanning() -> bool:
	return _scan_live

func _scan_worker(roots: Array[String], video: bool, known: Variant) -> void:
	var out: Array[String] = []
	for root in roots:
		if not _walk(root, out, video):
			break
	# Every NEW track's fingerprint, read here: id_for() would otherwise open each file on the main
	# thread during the reindex. The byte size rides along because migrate_ids() needs it to work
	# out what the old name-and-size id for this track would have been.
	var ids := {}
	if known is Dictionary:
		for p in out:
			if known.has(p):
				continue
			_scan_lock.lock()
			var stop := _scan_stop
			_scan_lock.unlock()
			if stop:
				break
			ids[p] = fingerprint_and_size(p)
	_scan_lock.lock()
	_scan_out = out
	_scan_ids = ids
	_scan_lock.unlock()

## The walk itself. Returns false when it was asked to stop, so every caller above it unwinds
## instead of finishing the tree.
func _walk(dir: String, out: Array[String], video: bool) -> bool:
	_scan_lock.lock()
	var stop := _scan_stop
	_scan_where = dir
	_scan_done = out.size()
	_scan_lock.unlock()
	if stop:
		return false
	for f in DirAccess.get_files_at(dir):
		if is_track(f, video):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not _walk(dir.path_join(d), out, video):
			return false
	return true

## Polls the worker. Only runs while a scan is live; set_process(false) otherwise.
func _process(_dt: float) -> void:
	if not _scan_live:
		return
	_scan_lock.lock()
	var done := _scan_done
	var where := _scan_where
	var finished: bool = _thread != null and not _thread.is_alive()
	var stopped := _scan_stop
	_scan_lock.unlock()
	if not finished:
		scan_progress.emit(done, 0, where)
		return
	var cancelled := stopped
	_thread.wait_to_finish()
	_thread = null
	_scan_live = false
	set_process(false)
	_scan_lock.lock()
	var found := _scan_out
	var ids := _scan_ids
	_scan_lock.unlock()
	if not cancelled:
		if engine:
			for p in ids:
				var id := str((ids[p] as Array)[0])
				if not engine.track_ids.has(p) and not id.is_empty():
					engine.track_ids[p] = id
		scan_ids = ids
		all_paths = found
		apply_folder_filter()
	scan_finished.emit(all_paths.size(), cancelled)

# --- the index, the sort and the filter --------------------------------------------
## Drops from `paths` everything in a folder the user unchecked, then rebuilds the index.
func apply_folder_filter() -> void:
	paths.clear()
	for path in all_paths:
		if enabled_folders.has(path.get_base_dir()):
			paths.append(path)
	reindex()

## Everything that is invariant under a search keystroke: the sort, the row strings, and the
## id maps. Typing used to re-run all of it per character -- an O(n log n) sort plus an
## O(folders x tracks) prefix scan -- so it is split out here and called only when the
## library or the sort order actually changes.
func reindex() -> void:
	index.clear()
	path_pos.clear()
	_id_paths.clear()
	for path in paths:
		var dir := path.get_base_dir()
		# a RENAME TAG override stands in for the filename in BOTH row forms, flat and
		# folder-grouped, and so is also what SEARCH matches against
		var id := id_for(path)
		_id_paths[id] = path
		var file: String = labels.get(id, path.get_file())
		var row := "%s/%s" % [dir.get_file(), file]
		index.append({"dir": dir, "file": file, "row": row, "hay": row.to_lower(), "id": id})
		path_pos[path] = index.size() - 1
	for crate in 2:
		orders[crate] = orders[0] if crate == 1 and sorts[1] == sorts[0] else sorted(SORTS[sorts[crate]])

## `paths` in `mode`'s order, as a new array. Stats and metadata keys are gathered once per
## pass here, not once per comparison.
func sorted(mode: String) -> Array[String]:
	_mtime.clear()
	if mode == "DATE":
		for p in paths:
			_mtime[p] = FileAccess.get_modified_time(p)
	_sortkey.clear()
	if mode in META_SORTS and engine != null:
		for p in paths:
			var m := engine.peek_meta(p)   # memory only: this runs on the main thread, per track
			if mode == "KEY" and int((m.get("key", {}) as Dictionary).get("pc", -1)) < 0:
				var est := engine.spectral_key_for(p)   # an untagged track sorts by its estimate
				if not est.is_empty():
					m = m.duplicate()
					m["key"] = {"pc": est["pc"], "minor": est["minor"]}
			_sortkey[p] = meta_sort_key(mode, m, p)
	var out: Array[String] = paths.duplicate()
	out.sort_custom(_cmp(mode))
	return out

## The comparator for `mode`, picked once per sort: matching the mode inside every comparison
## made a 20k-track PATH sort 4x slower (301 ms against 70 ms).
func _cmp(mode: String) -> Callable:
	# every metadata sort compares the keys gathered above, by membership rather than by a second
	# list of names: BPM was added to META_SORTS and not here, and silently sorted by path
	if mode in META_SORTS:
		return func(a: String, b: String) -> bool:
			return str(_sortkey.get(a, a)).naturalnocasecmp_to(str(_sortkey.get(b, b))) < 0
	match mode:
		"NAME":
			return func(a: String, b: String) -> bool: return a.get_file().naturalcasecmp_to(b.get_file()) < 0
		"TYPE":
			return func(a: String, b: String) -> bool:
				var d := a.get_extension().nocasecmp_to(b.get_extension())
				return d < 0 if d != 0 else a.naturalcasecmp_to(b) < 0
		"DATE":
			return func(a: String, b: String) -> bool:
				var ta: int = _mtime.get(a, 0)
				var tb: int = _mtime.get(b, 0)
				return ta > tb if ta != tb else a.naturalcasecmp_to(b) < 0  # newest first
	# PATH and FOLDER: keeps directories contiguous
	return func(a: String, b: String) -> bool: return a.naturalcasecmp_to(b) < 0

## The string a metadata sort orders by. Unknown values sort LAST ("~" is past every letter
## and digit), and the path breaks ties, so the order is total and stable across refills.
## Keys order round the Camelot wheel -- 1A 1B 2A ... -- which is the order a DJ mixes in.
static func meta_sort_key(mode: String, meta: Dictionary, path: String) -> String:
	match mode:
		"ARTIST":
			var artist := str(meta.get("artist", "")).to_lower()
			return "%s\t%s\t%s" % [artist if artist else "~", str(meta.get("album", "")).to_lower(), path]
		"ALBUM":
			var album := str(meta.get("album", "")).to_lower()
			return "%s\t%s" % [album if album else "~", path]
		"KEY":
			var k: Dictionary = meta.get("key", {})
			var pc := int(k.get("pc", -1))
			if pc < 0:
				return "~\t" + path
			return "%s\t%s" % [AudioEngine.camelot(pc, bool(k.get("minor", false))).lpad(3, "0"), path]
		"BPM":
			# zero-padded so it sorts as a number in a string compare: 090.00 before 128.00. An
			# untagged track has no tempo to place, and sorts last like an untagged key.
			var beats := float(meta.get("bpm", 0.0))
			return "%06.2f\t%s" % [beats, path] if beats > 0.0 else "~\t" + path
	return path

static func sort_key_test() -> bool:
	var k := func(mode: String, m: Dictionary) -> String: return meta_sort_key(mode, m, "p")
	var before := func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0
	return before.call(k.call("KEY", {"key": {"pc": 2, "minor": true}}), k.call("KEY", {"key": {"pc": 9, "minor": true}})) \
		and before.call(k.call("KEY", {"key": {"pc": 9, "minor": true}}), k.call("KEY", {"key": {"pc": 0, "minor": false}})) \
		and before.call(k.call("KEY", {"key": {"pc": 0, "minor": false}}), k.call("KEY", {})) \
		and before.call(k.call("BPM", {"bpm": 90.0}), k.call("BPM", {"bpm": 128.0})) \
		and before.call(k.call("BPM", {"bpm": 128.0}), k.call("BPM", {"bpm": 128.5})) \
		and before.call(k.call("BPM", {"bpm": 128.5}), k.call("BPM", {})) \
		and before.call(k.call("ARTIST", {"artist": "abba"}), k.call("ARTIST", {"artist": "Zed"})) \
		and before.call(k.call("ARTIST", {"artist": "Zed"}), k.call("ARTIST", {})) \
		and before.call(k.call("ALBUM", {"album": "A"}), k.call("ALBUM", {}))

# --- what the user made, keyed by id -----------------------------------------------
## The cue list for a path, in whichever scope is asked for. Always a live reference into the
## store, so appending to it appends to the library.
func cues_for(path: String, playlist := "") -> Array:
	var id := id_for(path)
	if playlist.is_empty():
		return cues.get(id, [])
	var per: Dictionary = pl_cues.get(playlist, {})
	return per.get(id, [])

## Turns a store that an older build keyed by absolute path into one keyed by id. Runs once,
## on load: a path that is still in the library is looked up, and one that is not is kept as
## it stands rather than dropped -- an unplugged drive must not eat a user's cues.
func migrate_keys(store: Dictionary) -> Dictionary:
	var out := {}
	for k in store:
		var key := str(k)
		out[id_for(key) if key.contains("/") or key.contains("\\") else key] = store[k]
	return out

## ONE-TIME: re-keys everything the user made from the name-and-size ids to fingerprints. `ids` is
## a scan's {path: [fingerprint, size]}, which is exactly what is needed to mint the old key for a
## track and hand its cues, its label and its playlist places to the new one. Returns how many
## stored keys moved.
##
## A key nothing in the library claims is LEFT ALONE, the same courtesy migrate_keys shows: an
## unplugged drive must not eat the cues of the tracks that live on it. Running twice is a no-op,
## because after the first pass no old key is in any store.
const ID_SCHEME := 2   # 1 = name and size, 2 = fingerprint

func migrate_ids(ids: Dictionary) -> int:
	var map := {}
	for p in ids:
		var pair: Array = ids[p]
		var new_id := str(pair[0])
		var old_id := track_id(str(p), int(pair[1]))
		if not new_id.is_empty() and new_id != old_id:
			map[old_id] = new_id
	if map.is_empty():
		return 0
	var moved := _rekey(cues, map) + _rekey(labels, map)
	for name in pl_cues:
		moved += _rekey(pl_cues[name], map)
	for name in playlists:
		var out: Array = []
		for id in (playlists[name] as Array):
			out.append(map.get(id, id))
		playlists[name] = out
	return moved

## Moves every key of `store` that `map` renames. The destination is never overwritten: if both
## ids are already in there, the new one is the live track's and wins.
static func _rekey(store: Dictionary, map: Dictionary) -> int:
	var moved := 0
	for old in map:
		if store.has(old) and not store.has(map[old]):
			store[map[old]] = store[old]
			store.erase(old)
			moved += 1
	return moved

static func migrate_test() -> bool:
	var m := LibraryModel.new()
	var got := m.migrate_keys({"C:/Music/a.mp3": [1], "abcdef0123456789": [2]})
	var ok: bool = got.size() == 2 and got.has("abcdef0123456789") and got[m.track_id("C:/Music/a.mp3", 0)] == [1]
	m.free()
	return ok

static func model_test() -> bool:
	return roots_test() and sort_key_test() and relocate_test() and migrate_test() \
		and is_track("A.MP3") and is_track("b.flac") and is_track("c.DSF") and not is_track("cover.jpg") \
		and is_track("d.ape") and is_track("e.TAK") and not is_track("notes.taken") \
		and not is_track("clip.MP4") and is_track("clip.MP4", true) and not is_track("clip.mp4.jpg", true) \
		and track_id("C:/a/Song.MP3", 12) == track_id("D:/b/song.mp3", 12) \
		and track_id("C:/a/Song.mp3", 12) != track_id("C:/a/Song.mp3", 13)
