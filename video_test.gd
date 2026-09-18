class_name VideoTest
extends TextureRect
## The "Video TEST" picture (TBS). An MP4's SOUND plays on a deck like any other track -- the
## EQ, FX, beat tracker and recorder all hear it -- so this node carries no audio at all. It
## draws the MP4's low-res Theora proxy (AudioEngine.request_video) over the visualizer,
## slaved to the player sounding that track, through video_test.gdshader: in the video's own
## colours, or in whatever palette follow() hands it, pulsing with the kick.
##
## A TextureRect showing a hidden VideoStreamPlayer's texture, not the player itself:
## VideoStreamPlayer can only stretch, and this keeps the picture's aspect inside whatever the
## screen cell is -- docked, torn off into the VISUAL EQ window, or mid-resize.

## How far the picture may drift from the sound before it is re-seeked onto it. Theora seeks
## land on the requested time (measured on 4.7), so this only has to absorb frame and mix jitter.
const DRIFT_MAX := 0.12

## The shader's two modes, numbered as its MODE_ORIGINAL / MODE_PALETTE.
enum ColorMode { ORIGINAL, PALETTE }

## ORIGINAL draws the video's own colours; PALETTE is the dithered skin/gradient look. Safe to set
## before the node is in the tree: _ready pushes whatever it was left at.
var color_mode := ColorMode.PALETTE:
	set(value):
		color_mode = value
		if material:
			(material as ShaderMaterial).set_shader_parameter("color_mode", value)

var track := ""              # the MP4 this picture belongs to
var _sound: AudioStream      # the decoded sound it follows -- see follow()
var _video := VideoStreamPlayer.new()
## The shader's palette. A GradientTexture1D re-renders itself when its Gradient changes, so a
## gradient edited on the VISUAL tab repaints the picture with nothing pushed from here.
var _ramp := GradientTexture1D.new()

func _ready() -> void:
	expand_mode = EXPAND_IGNORE_SIZE           # the cell sizes the picture, never the reverse
	stretch_mode = STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = TEXTURE_FILTER_NEAREST    # hard texel blocks, not a blur
	mouse_filter = MOUSE_FILTER_IGNORE
	_ramp.gradient = Gradient.new()            # black to white until follow() hands one over
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://video_test.gdshader")
	mat.set_shader_parameter("ramp", _ramp)
	mat.set_shader_parameter("color_mode", color_mode)
	material = mat
	_video.visible = false                     # it decodes; this node draws
	add_child(_video)
	visible = false

## A track just started. Whatever picture was up goes, and a proxy rendered for `path` will
## follow `sound`. ("", null) expects nothing.
func expect(path: String, sound: AudioStream) -> void:
	_video.stream = null
	texture = null
	track = path
	_sound = sound
	visible = false

## A finished render. Refused unless it is for the track expected last: renders land in any
## order, and a slow one must not paint over the track that replaced it.
func open(path: String, ogv: String) -> bool:
	if path.is_empty() or path != track or _sound == null:
		return false
	var s := VideoStreamTheora.new()
	s.file = ogv
	_video.stream = s
	if _video.get_stream_length() <= 0.0:   # unreadable: Theora hands back an empty texture, not null
		_video.stream = null
		return false
	texture = _video.get_video_texture()
	return true

## Kick energy 0..1 from a linear band magnitude (AudioDirector.levels), on the visualizer's
## own dB scale -- so the colour pulse and the bars agree on what loud is, floor included.
static func kick(level: float, floor_db: float) -> float:
	return clampf(remap(linear_to_db(maxf(level, 1e-7)), floor_db, 0.0, 0.0, 1.0), 0.0, 1.0)

## Every frame, with the deck's live player, the palette to draw in (dark to light; null keeps
## the one already set) and the kick from kick(). The picture shows only while that player is
## sounding THIS track's stream, so a crossfade to another track, a REV swap, a deck switch or
## STOP each hand it a different stream or silence, and the visualizer comes back.
func follow(clock: AudioStreamPlayer, palette: Gradient = null, pulse := 0.0) -> void:
	var sounding := texture != null and clock != null and clock.stream == _sound \
		and (clock.playing or clock.stream_paused)
	visible = sounding
	if sounding:
		if palette and _ramp.gradient != palette:
			_ramp.gradient = palette
		(material as ShaderMaterial).set_shader_parameter("pulse", pulse)
	if not sounding or clock.stream_paused:
		if not _video.paused:
			_video.paused = true
		return
	var at := clock.get_playback_position()
	if not _video.is_playing():
		if at >= _video.get_stream_length():
			return   # the sound outlasts the picture: its last frame stays up
		_video.play()
		_video.stream_position = at
	if _video.paused:
		_video.paused = false
	if absf(_video.stream_position - at) > DRIFT_MAX:
		_video.stream_position = at
