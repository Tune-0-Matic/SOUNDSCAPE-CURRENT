extends SceneTree
## Runnable check for the persistent library index (AudioEngine.load_index / save_index):
##   1. two probed tracks survive into a FRESH engine, readable with zero ffprobe runs; peek_meta
##      stays empty until validate_index confirms them, still with no probe
##   2. editing a file (new size and mtime) invalidates its entry; the next read re-probes it
##      and sees the new duration
##   3. saving with a smaller library drops the entries that are no longer in it
##   4. a garbage index file loads as empty instead of throwing
##   5. BPM tags: what the parser takes and refuses, a tagged file read on its first probe, and an
##      index entry written before BPM existed backfilled by one re-probe
## Works in user://index_test and removes it; the real library_index.dat is never touched.
##   godot --headless --path . --script res://test_library_index.gd

const DIR := "user://index_test"

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

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var base := ProjectSettings.globalize_path(DIR)
	var t1 := base.path_join("one.wav")
	var t2 := base.path_join("two.wav")
	var idx := base.path_join("library_index.dat")
	_wav(t1, 0.5)
	_wav(t2, 0.5)
	var both: Array[String] = [t1, t2]
	var ok := true

	var a := AudioEngine.new()
	a.metadata(t1)
	a.metadata(t2)
	var saved := a.save_index(both, idx) == OK and a.probes == 2
	a.free()

	# 1. a fresh engine reads both from the index with no probe
	var b := AudioEngine.new()
	var loaded := b.load_index(idx)
	var hit := b.cached_meta(t1)
	var again := b.metadata(t2)
	var instant: bool = saved and loaded == 2 and not hit.is_empty() and absf(float(hit["duration"]) - 0.5) < 0.02 \
		and absf(float(again["duration"]) - 0.5) < 0.02 and b.probes == 0
	ok = ok and instant
	print("1. index of %d reloaded; durations %.3f / %.3f read with %d ffprobe runs: %s" % [
		loaded, float(hit.get("duration", -1.0)), float(again.get("duration", -1.0)), b.probes, instant])

	# 1b. the whole-library loops read peek_meta, which never touches the disk; validate_index is
	# what fills it (on a worker in the app), with no probe for an unchanged indexed file
	var v := AudioEngine.new()
	v.load_index(idx)
	var cold_peek := v.peek_meta(t1).is_empty()
	var landed := v.validate_index(both)
	var peeked: bool = cold_peek and landed == 2 and not v.peek_meta(t1).is_empty() and v.probes == 0
	ok = ok and peeked
	print("1b. peek_meta empty until validate_index confirms the index (%d landed, %d probes): %s" % [
		landed, v.probes, peeked])
	v.free()

	# 2. an edited file is not trusted
	var c := AudioEngine.new()
	c.load_index(idx)
	_wav(t2, 0.9)
	var stale_dropped := c.cached_meta(t2).is_empty()
	var fresh := c.metadata(t2)
	var reprobed: bool = stale_dropped and c.probes == 1 and absf(float(fresh["duration"]) - 0.9) < 0.02
	ok = ok and reprobed
	print("2. edited track: stale entry dropped %s, re-probed (%d run) to %.3f s: %s" % [
		stale_dropped, c.probes, float(fresh.get("duration", -1.0)), reprobed])

	# 3. entries for tracks no longer in the library are not written back
	c.metadata(t1)
	var only: Array[String] = [t1]
	c.save_index(only, idx)
	c.free()
	var d := AudioEngine.new()
	var kept := d.load_index(idx)
	var pruned: bool = kept == 1 and not d.cached_meta(t1).is_empty()
	ok = ok and pruned
	print("3. saved with one track left in the library: %d entry reloaded: %s" % [kept, pruned])
	d.free()

	# 5. BPM: the tag parser, a tagged file read on its first probe, and the upgrade path -- an
	# entry written before BPM existed keeps serving its duration and tags, and one re-probe
	# (backfill_bpm, a worker in the app) fills the tempo in without the user asking.
	var parsers: bool = AudioEngine.bpm_tag_test() and AudioEngine.key_tag_test()
	var tagged := base.path_join("tagged.flac")
	OS.execute("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
		"-metadata", "BPM=128", "-metadata", "artist=Picard", tagged], [], true)
	var idx2 := base.path_join("bpm_index.dat")
	var tagger := AudioEngine.new()
	var fresh_bpm := float(tagger.metadata(tagged).get("bpm", 0.0))
	tagger.save_index([tagged], idx2)
	tagger.free()
	# rewrite that index the way the previous build wrote it: no bpm key at all
	var blob: Dictionary = FileAccess.open(idx2, FileAccess.READ).get_var()
	var entry: Array = (blob["entries"] as Dictionary)[tagged]
	(entry[2] as Dictionary).erase("bpm")
	var w := FileAccess.open(idx2, FileAccess.WRITE)
	w.store_var(blob)
	w.close()
	var h := AudioEngine.new()
	h.load_index(idx2)
	var flagged := h.needs_bpm(tagged)
	var still_readable: bool = str(h.cached_meta(tagged).get("artist", "")) == "Picard" and h.probes == 0
	var filled := h.backfill_bpm([tagged])
	var after := float(h.metadata(tagged).get("bpm", 0.0))
	var backfilled: bool = parsers and absf(fresh_bpm - 128.0) < 0.01 and flagged and still_readable \
		and filled == 1 and absf(after - 128.0) < 0.01 and not h.needs_bpm(tagged) and h.probes == 1
	h.free()
	ok = ok and backfilled
	print("5. BPM parsed %s on the first probe; a pre-BPM entry still read its tags (%s) and one re-probe filled %s: %s" % [
		fresh_bpm, still_readable, after, backfilled])

	# 4. garbage
	var g := FileAccess.open(idx, FileAccess.WRITE)
	g.store_string("definitely not a stored Variant")
	g.close()
	var e := AudioEngine.new()
	var junk := e.load_index(idx) == 0
	ok = ok and junk
	print("4. a garbage index loads as empty: %s" % junk)
	e.free()

	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(base.path_join(f))
	DirAccess.remove_absolute(base)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
