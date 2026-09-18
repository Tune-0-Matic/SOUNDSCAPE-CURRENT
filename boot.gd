extends Control
## Terminal boot screen. Reveals a fake POST sequence character by character, then either
## asks for a name (first run) or greets the stored one, and gets out of the way.
##
## Text is drawn into a plain Label and the name is captured from raw key events rather
## than a LineEdit: a LineEdit drags in a caret, selection and focus styling that would
## all need theming to match, for a field used exactly once.

signal finished(user_name: String)

## A POST reports what the machine FOUND. Every line below used to be a constant -- WASAPI
## 96000HZ on a machine running ALSA at 48 kHz, 1920x1080 in a 1280x720 window, and a DSP chain
## naming effects that no longer exist -- which made the one screen claiming to describe the
## hardware the least trustworthy thing in the program. Each placeholder is now filled by
## begin() from the thing it names.
const LINES := [
	"SOUNDSCAPE (HEADLESS HORSEMAN) BY ZFACTORPSX %s",
	"",
	"MEM TEST %s ............ %s",
	"DETECTING AUDIO DEVICE ..... %s",
	"MOUNTING LIBRARY ........... %d TRACKS",
	"LOADING DSP CHAIN .......... %s",
	"SPECTRUM ANALYSER .......... %d BANDS",
	"VIDEO MODE ................. %s",
	"CALIBRATING PHOSPHOR ....... OK",
	"",
]
const CHARS_PER_SEC := 150.0
const MAX_NAME := 16

enum Phase { BOOT, ASK, WELCOME, DONE }

var user_name := ""
var track_count := 0

var _phase: Phase = Phase.BOOT
var _buf := ""
var _shown := 0.0
var _started := false
var _returning := false
var _typed := ""
var _blink := 0.0
@onready var _label: Label = $Text
@onready var _bg: ColorRect = $BG

## The audio device as the driver reports itself, with the rate the mixer is actually running.
static func audio_line() -> String:
	var driver := AudioServer.get_driver_name() if AudioServer.has_method("get_driver_name") else ""
	if driver.is_empty():
		driver = "UNKNOWN"
	var out := "%s %dHZ" % [driver.to_upper(), int(AudioServer.get_mix_rate())]
	var device := AudioServer.output_device
	# "Default" says nothing the user does not already know; a named card is worth the room
	if not device.is_empty() and device.to_lower() != "default":
		out += " / %s" % device.to_upper()
	return out

## Physical memory, rounded the way a POST would write it. OS.get_memory_info() reports -1 for
## what a platform will not say, and a made-up number is the thing this whole change is against.
static func mem_line() -> Array:
	var physical := int(OS.get_memory_info().get("physical", -1))
	if physical <= 0:
		return ["  UNKNOWN", "SKIPPED"]
	return ["%7dK" % (physical / 1024), "OK"]

## What is ACTUALLY in circuit, named in signal order. The native decoders and the sinc are
## there only when libsoundscape_dsp loaded, and the limiter is read off the master bus rather
## than assumed -- this line is the fastest way to tell a build that lost its extension.
static func dsp_line() -> String:
	var parts := PackedStringArray()
	if ClassDB.class_exists("SsFlacStream"):
		parts.append("FLAC/WAV/DSD")
		parts.append("SINC")
	else:
		parts.append("GODOT DECODERS")
	if ClassDB.class_exists("SsCasualCurve"):
		parts.append("CURVE")
	parts.append("EQ21")
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		for i in AudioServer.get_bus_effect_count(master):
			if AudioServer.get_bus_effect(master, i) is AudioEffectHardLimiter:
				parts.append("LIMITER")
				break
	return "/".join(parts)

static func video_line() -> String:
	var win := DisplayServer.window_get_size()
	var screen := DisplayServer.screen_get_size()
	var hz := int(roundf(DisplayServer.screen_get_refresh_rate()))
	var out := "%dx%d" % [win.x, win.y]
	if screen.x > 0 and screen != win:
		out += " ON %dx%d" % [screen.x, screen.y]
	if hz > 0:
		out += " @%dHZ" % hz
	return out

func begin(saved_name: String, tracks: int) -> void:
	user_name = saved_name
	track_count = tracks
	var mem := mem_line()
	_buf = "\n".join(LINES) % [
		ProjectSettings.get_setting("application/config/version", ""),
		mem[0], mem[1], audio_line(), tracks, dsp_line(), AudioDirector.BAND_COUNT, video_line()]
	_started = true
	_returning = not user_name.is_empty()
	if _returning:
		_buf += "\nCOMPLETE\n"      # returning user: the POST reports done, then greets
	visible = true

func _process(delta: float) -> void:
	# Nothing runs until begin() hands over. Without this the state machine ticks from
	# frame 0 against an empty buffer, decides the POST is already finished, and drops
	# straight to the name prompt -- which is exactly what the logo intro exposed by
	# delaying begin() by three seconds.
	if not _started:
		return
	# read the palette every frame: the skin is applied after this node is ready, and
	# the user can be mid-boot when it lands
	var accent := get_theme_color("font_color", "Green")
	_label.add_theme_color_override("font_color", accent)
	_bg.color = get_theme_color("font_color", "ItemList").darkened(0.97)
	_blink += delta

	match _phase:
		Phase.BOOT:
			_shown += delta * CHARS_PER_SEC
			if _shown >= float(_buf.length()):
				_phase = Phase.ASK if user_name.is_empty() else Phase.WELCOME
		Phase.ASK:
			pass                     # waiting on the keyboard
		Phase.WELCOME:
			pass                     # waits for SPACE; the greeting is not a timed splash
	_redraw()

func _redraw() -> void:
	var out := _buf.substr(0, int(_shown))
	match _phase:
		Phase.ASK:
			out += "\nENTER NAME (OR JUST ENTER TO SKIP): " + _typed + _caret()
		Phase.WELCOME:
			out += "\nWELCOME BACK " if _returning else "\nWELCOME "
			out += user_name + "\n\nPRESS SPACE TO ENTER " + _caret()
	_label.text = out

func _caret() -> String:
	return "_" if fmod(_blink, 0.9) < 0.45 else " "

## Raw key capture. Only active while the prompt is up, and every key is consumed so a
## stray SPACE cannot reach the transport underneath.
func _unhandled_key_input(event: InputEvent) -> void:
	if _phase != Phase.ASK and _phase != Phase.WELCOME:
		return
	var k := event as InputEventKey
	if not k or not k.pressed:
		return
	if _phase == Phase.WELCOME:
		if k.keycode == KEY_SPACE or k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_phase = Phase.DONE
			visible = false
			finished.emit(user_name)
		accept_event()
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		if _typed.strip_edges().is_empty():
			# a blank name is a skip, not a stall: straight into the player, nameless. The
			# prompt returns next launch, one ENTER away -- the same cost as WELCOME's SPACE.
			_phase = Phase.DONE
			visible = false
			finished.emit("")
			accept_event()
			return
		user_name = _typed.strip_edges().to_upper()
		_buf += "\nCOMPLETE\n"
		_shown = float(_buf.length())
		_phase = Phase.WELCOME
	elif k.keycode == KEY_BACKSPACE:
		_typed = _typed.left(_typed.length() - 1)
	elif k.unicode >= 32 and _typed.length() < MAX_NAME:
		_typed += String.chr(k.unicode)
	accept_event()
