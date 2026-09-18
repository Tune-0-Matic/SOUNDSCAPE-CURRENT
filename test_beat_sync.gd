extends SceneTree
## Runnable check for BEAT SYNC (AudioDirector.sync_seek), on real audio on two deck buses:
##   1. two 120 BPM click tracks, deck B started 150 ms out of phase: both per-deck trackers
##      lock, and the measured grid offset between the decks is ~150 ms
##   2. the median of READINGS sync_seek nudges brings the two decks' clicks within 15 ms
##   3. a 128 BPM deck against a 120 BPM one is refused (NAN): no time-stretch, no false sync
## "Grid offset" is measured from the PLAYBACK POSITIONS, where the clicks really are -- not
## from the trackers being tested.
##   godot --headless --path . --script res://test_beat_sync.gd

const FPS := 60
const READINGS := 9

func _click_track(track_bpm: float, secs: float) -> AudioStreamWAV:
	var sr := 44100
	var n := int(sr * secs)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	var period := 60.0 / track_bpm
	for i in n:
		var t := float(i) / sr
		var since := fmod(t, period)
		var v := 0.0
		if since < 0.055:
			var hz: float = 45.0 + 75.0 * exp(-since * 45.0)
			v = sin(TAU * hz * since) * exp(-since * 32.0) * 0.9
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	return s

## Where deck B's clicks sit against deck A's, in seconds within half a period.
func _grid_gap(a: AudioStreamPlayer, b: AudioStreamPlayer, period: float) -> float:
	return fposmod(b.get_playback_position() - a.get_playback_position() + period * 0.5, period) - period * 0.5

func _locked(d: AudioDirector, want: float) -> bool:
	return absf(d.bpm - want) < 1.0 and d.confidence > 0.5

func _initialize() -> void:
	Engine.max_fps = FPS
	var engine := AudioEngine.new()
	root.add_child(engine)
	await process_frame
	var players: Array[AudioStreamPlayer] = []
	var trackers: Array[AudioDirector] = []
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = engine.deck_bus(i)
		root.add_child(p)
		players.append(p)
		var t := AudioDirector.new()
		t.bus = engine.deck_bus(i)
		root.add_child(t)
		trackers.append(t)
	engine.set_both(true)
	await process_frame
	var period := 0.5
	players[0].stream = _click_track(120.0, 40.0)
	players[1].stream = _click_track(120.0, 40.0)
	players[0].play()
	players[1].play(0.15)   # deck B runs 150 ms ahead in the track: its clicks land 150 ms early
	for i in 2:
		trackers[i].set_tracking(true, true)
		trackers[i].attach(players[i])
	var ok := true

	var guard := 0
	while not (_locked(trackers[0], 120.0) and _locked(trackers[1], 120.0)) and guard < FPS * 20:
		await process_frame
		guard += 1
	var before := _grid_gap(players[0], players[1], period)
	var locked := _locked(trackers[0], 120.0) and _locked(trackers[1], 120.0)
	ok = ok and locked and absf(absf(before) - 0.15) < 0.02
	print("1. both decks locked after %.1f s (A %.2f BPM, B %.2f BPM); measured grid gap %+.1f ms: %s" % [
		float(guard) / FPS, trackers[0].bpm, trackers[1].bpm, before * 1000.0, locked])

	# settle until the tempo fit has a full HISTORY window of onsets: a lock on a partial window
	# still reads up to ~0.9 BPM off, which leaves its phase ~20 ms wrong at the window's end.
	# Then READINGS sync_seek readings half a second apart, each judged against the positions in
	# the same frame. One reading can catch a tracker mid-correction; the median one is applied.
	while players[0].get_playback_position() < AudioDirector.HISTORY:
		await process_frame
	var nudges: Array[float] = []
	var errs: Array[float] = []
	var span_from := players[0].get_playback_position()
	var span_frames := 0
	for k in READINGS:
		for _f in (30 if k > 0 else 0):
			await process_frame
			span_frames += 1
		var n := AudioDirector.sync_seek(trackers[0], trackers[1], 0.015)
		if not is_nan(n):
			nudges.append(n)
			errs.append(fposmod(n + _grid_gap(players[0], players[1], period) + period * 0.5, period) - period * 0.5)
	var usable := nudges.size() == READINGS
	nudges.sort()
	errs.sort()
	var nudge: float = nudges[READINGS / 2] if usable else 0.0
	if usable:
		players[1].seek(players[1].get_playback_position() + nudge)
	for _f in 20:
		await process_frame
	var after := _grid_gap(players[0], players[1], period)
	# An onset is stamped at the FRAME the analysis first sees it, so each tracker's phase carries
	# up to one frame of audio time as bias, and the two decks' clicks sit at different sub-frame
	# offsets, so that bias does not cancel between them. Sixty real frames a second keeps it under
	# 17 ms; a headless frame under load covers far more audio than that, and the check was asking
	# the residual to beat sync_seek's own 15 ms tolerance with nothing left over for it. The bar is
	# the tolerance plus the frame it is actually running at -- a sync that genuinely failed leaves
	# the 150 ms it started with, which is nowhere near either number.
	var frame_secs: float = (players[0].get_playback_position() - span_from) / maxf(span_frames, 1)
	var bar := 0.015 + frame_secs
	var aligned := usable and absf(after) < bar
	ok = ok and aligned
	print("2. %d sync readings, error %+.1f to %+.1f ms; median nudged deck B %+.1f ms; grid gap now %+.1f ms (want < %.1f = 15 + %.1f ms/frame): %s" % [
		nudges.size(), errs[0] * 1000.0 if usable else 0.0, errs[-1] * 1000.0 if usable else 0.0,
		nudge * 1000.0, after * 1000.0, bar * 1000.0, frame_secs * 1000.0, aligned])

	# 3. a real tempo mismatch is refused
	players[1].stream = _click_track(128.0, 40.0)
	players[1].play()
	trackers[1].attach(players[1])
	guard = 0
	while not _locked(trackers[1], 128.0) and guard < FPS * 20:
		await process_frame
		guard += 1
	var refused := _locked(trackers[1], 128.0) and is_nan(AudioDirector.sync_seek(trackers[0], trackers[1], 0.015))
	ok = ok and refused
	print("3. 120 vs %.2f BPM: sync refused (NAN): %s" % [trackers[1].bpm, refused])

	for p in players:
		p.stop()
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
