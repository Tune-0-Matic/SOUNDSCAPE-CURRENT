class_name DeckController
extends Node
## The two DECKS: which players each one owns, which of them is sounding, how a track hands
## over to the next, which direction a deck is playing, and what happens when a track will
## not decode. No Control appears in this file -- player.gd owns the buttons and the scrub
## bar and asks this what they should read.
##
## A deck is a PAIR of AudioStreamPlayers, not one. A crossfade needs the outgoing track to
## keep sounding while the incoming one rises, so every deck has two players and takes turns
## between them; `live(deck)` is whichever of the pair that deck is currently sounding
## through. `_audio` is the one the transport, the scrub bar and the analyser are looking at,
## which is the live player of the deck the user is driving.
##
## Everything here is written to be TRUE OF EITHER DECK. The bug this shape exists to prevent
## is state that reads like it belongs to a deck but is actually shared: one `_reversed` flag
## for two decks meant reversing deck A also mirrored deck B's cue markers, and one crossfade
## tween for two decks let STOP on one deck strand the other mid-transition with both its
## players stuck at partial volume.

## How many unplayable tracks in a row end the set rather than being skipped past. Three is
## enough to step over a broken file or two mid-playlist, and few enough that a whole folder
## gone offline -- an unplugged drive, a cloud library with nothing downloaded -- stops the
## program on the third rather than tearing through a thousand tracks announcing each one.
const MAX_AUTO_SKIPS := 3

const ACTIVE_DB := 0.0
const SILENT_DB := -80.0
const DELAY_MS_MIN := 0
## The incoming ramp is never allowed to collapse to nothing: if PLAY DELAY is set at or past
## FADE TIME the delay is pulled back so this much fade-in always survives, which is what keeps
## an over-long delay from turning the transition into a hard cut.
const MIN_FADE_IN_MS := 100

enum Fail { REPORT, SKIP, STOP }

var engine: AudioEngine        # owns the queue, the deck buses and which deck is driven
var director: AudioDirector    # the beat tracker the live player is attached to

## deck -> [engine primary, scene spare]
var pair := [[], []]
## deck -> which side of its pair was last live
var deck_live := [null, null]
## deck -> the path it holds
var deck_cur := ["", ""]
## Whichever player currently owns playback: the live player of the DRIVEN deck. Everything
## downstream -- transport, scrub, the spectrum feed -- reads this, so a crossfade only has
## to reassign it.
var audio: AudioStreamPlayer

var crossfader := 0.0
var fade_on := true
var fade_ms := 1000
var delay_ms := 250

## REV is PER DECK. The deck you are not driving keeps playing whatever it was playing, in
## whichever direction it was playing it.
var reversed_a := false
var reversed_b := false

## Set while the load in flight came from a track ENDING rather than from somebody asking
## for that track. Only that case may skip past a file that will not decode.
var auto_advancing := false
var fail_streak := 0
## path -> why, for this session. The STATS column prints the count; the log carries each one.
var failed_tracks := {}

## One crossfade tween PER DECK. A single shared one let STOP, a new track or REV on one deck
## kill the other deck's fade mid-flight -- both of that deck's players left sounding at
## partial volume with nothing left to stop the outgoing one -- and switching decks cleared a
## shared "fading" flag, re-arming auto-advance in the middle of a transition.
var _fades: Array[Tween] = [null, null]

func fading(deck: int) -> bool:
	return _fades[deck] != null and _fades[deck].is_valid()

func kill_fade(deck: int) -> void:
	if fading(deck):
		_fades[deck].kill()

## The player a deck is sounding through: `audio` for the live deck, the recorded live player
## -- or the primary, if it never played -- for the parked one.
func live(deck: int) -> AudioStreamPlayer:
	if engine != null and deck == engine.deck:
		return audio
	return deck_live[deck] if deck_live[deck] else pair[deck][0]

# --- direction ------------------------------------------------------------------------
func is_reversed(deck: int) -> bool:
	return reversed_b if deck == 1 else reversed_a

func set_reversed(deck: int, on: bool) -> void:
	if deck == 1:
		reversed_b = on
	else:
		reversed_a = on

## A cue's time is ALWAYS stored against the track as recorded, forwards. While a deck plays
## the reversed render, that same instant sits at `length - t` in what is actually sounding --
## so every marker crosses this on its way to the screen or the playhead, and every marker the
## user drops or drags crosses it on the way back. Stored times therefore never mirror, which
## is what stops a cue marked during REV from being written at the wrong place for good.
##
## Its own inverse: applying it to a stream time hands back the stored time, which is why one
## function serves both directions.
static func cue_stream_time(t: float, length: float, reversed: bool) -> float:
	if not reversed or length <= 0.0:
		return t
	return clampf(length - t, 0.0, length)

static func rev_cue_test() -> bool:
	var mirrored := cue_stream_time(30.0, 120.0, true)
	return is_equal_approx(cue_stream_time(30.0, 120.0, false), 30.0) \
		and is_equal_approx(mirrored, 90.0) \
		and is_equal_approx(cue_stream_time(mirrored, 120.0, true), 30.0) \
		and is_equal_approx(cue_stream_time(0.0, 120.0, true), 120.0) \
		and is_equal_approx(cue_stream_time(120.0, 120.0, true), 0.0) \
		and is_equal_approx(cue_stream_time(150.0, 120.0, true), 0.0) \
		and is_equal_approx(cue_stream_time(-5.0, 120.0, true), 120.0) \
		and is_equal_approx(cue_stream_time(30.0, 0.0, true), 30.0)   # no length: nothing to mirror

# --- a track that will not play --------------------------------------------------------
## What a track that would not decode should DO, given who asked for it and how many failed
## before it. A track somebody PICKED is never skipped past -- the failure is reported and the
## deck stays where it is -- and neither is a failure on the deck nobody is driving. Pure, so
## the rule is checkable without a deck, a file or an audio device.
static func fail_action(auto: bool, same_deck: bool, streak: int) -> Fail:
	if not auto or not same_deck:
		return Fail.REPORT
	return Fail.STOP if streak + 1 >= MAX_AUTO_SKIPS else Fail.SKIP

static func fail_test() -> bool:
	return fail_action(false, true, 0) == Fail.REPORT \
		and fail_action(false, true, MAX_AUTO_SKIPS) == Fail.REPORT \
		and fail_action(true, false, 0) == Fail.REPORT \
		and fail_action(true, true, 0) == Fail.SKIP \
		and fail_action(true, true, MAX_AUTO_SKIPS - 2) == Fail.SKIP \
		and fail_action(true, true, MAX_AUTO_SKIPS - 1) == Fail.STOP

# --- handing one track over to the next ----------------------------------------------------
## Crossfades `stream` in on `deck`, over FADE TIME, starting the incoming track PLAY DELAY
## into it so both ramps finish together.
##
## `on_live` is called with the incoming player when the deck's live reference moves, so the
## owner can re-point the transport and the analyser at it -- but only when this deck is the
## one being looked at.
func crossfade(stream: AudioStream, deck: int, on_live: Callable) -> void:
	kill_fade(deck)
	var outgoing := live(deck)
	var side: Array = pair[deck]
	var incoming: AudioStreamPlayer = side[1] if outgoing == side[0] else side[0]

	# clamped so delay + fade-in always fits inside FADE TIME; both ramps therefore finish
	# together and the whole transition still lasts exactly FADE TIME
	var delay: int = clampi(delay_ms, DELAY_MS_MIN, maxi(fade_ms - MIN_FADE_IN_MS, 0))
	var fade_s := float(fade_ms) / 1000.0
	var delay_s := float(delay) / 1000.0
	var in_s: float = maxf(fade_s - delay_s, float(MIN_FADE_IN_MS) / 1000.0)

	# armed but silent and NOT playing: starting it now would advance the playhead during the
	# delay, so the track would be mid-intro by the time it is audible
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.stream_paused = false

	var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fades[deck] = tw
	tw.set_parallel(true)
	# T = 0: the outgoing track starts falling immediately, over the full fade time
	tw.tween_property(outgoing, "volume_db", SILENT_DB, fade_s)
	# T = PLAY DELAY: the incoming track starts, and only then begins its ramp
	tw.tween_callback(func() -> void:
		incoming.volume_db = SILENT_DB
		incoming.play()
		deck_live[deck] = incoming
		on_live.call(deck, incoming)).set_delay(delay_s)
	tw.tween_property(incoming, "volume_db", ACTIVE_DB, in_s).set_delay(delay_s)
	# chain() waits for every parallel step, so this is the true end of the transition
	tw.chain().tween_callback(func() -> void:
		outgoing.stop()
		outgoing.volume_db = ACTIVE_DB
		outgoing.stream = null)

static func deck_test() -> bool:
	return rev_cue_test() and fail_test()
