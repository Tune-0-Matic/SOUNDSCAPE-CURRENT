class_name Visualizer
extends Control
## Pixelated spectrum visualizers. Drawn at low resolution inside a SubViewport and
## upscaled with NEAREST, so these are real pixels, not big smooth rectangles.
##
## Normalization (tilt + a fixed dB window + attack/release) is shared by every mode.
## The window is absolute, not auto-gained: see _process for why.

## SNAKE is last and deliberately outside the normal cycle: player.gd's VIZ_NAMES only
## reaches it once the code has been typed, so an unlocked mode cannot be stumbled into.
enum Mode { SEGMENTS, MIRROR, WATERFALL, GRID, RADIAL, MATRIX, TUNNEL, CRUISE, FIRE, KALEIDO, SNAKE }

const PRESETS: Array[Color] = [
	Color(0.18, 0.8, 0.443),   # green
	Color(1.0, 0.72, 0.2),     # amber
	Color(0.3, 0.85, 1.0),     # cyan
	Color(0.93, 0.93, 0.93),   # white
	Color(1.0, 0.35, 0.65),    # magenta
	Color(1.0, 0.29, 0.24),    # red
]
const WF_HEIGHT := 96

var director: AudioDirector

var mode: Mode = Mode.SEGMENTS
var color_index := 0
## 0..1 -> dB floor -80..-40 (0.5 is the -60 the display is tuned around). A higher
## setting raises the floor, so quieter detail reaches full height.
var sensitivity := 0.5

## The dB an empty bar sits at for the current sensitivity. The Video TEST picture's kick pulse
## reads the same scale (VideoTest.kick), so the bars and the colour agree on what loud is.
func db_floor() -> float:
	return lerpf(-80.0, -40.0, clampf(sensitivity, 0.0, 1.0))
## Cancels the library's ~39 dB natural slope (band 0 peaks -7 dBFS, band 28 -46).
## At 0 the top two thirds of the display never leave the floor.
var tilt_db := 20.0
var height_scale := 0.62

## 0..1 ballistics. Attack always outruns release -- equal rates read as flicker
## rather than as an EQ, so the two ranges never cross.
var speed := 0.5

## Nothing auto-gains any more -- see the FIXED dB window in _process. The AGC that
## used to live here is what made the bars pin and thrash, because it moved the scale
## itself in response to the music it was measuring.

## The frame rate every per-frame constant below was tuned at. Nothing here should ever
## advance "once per _process" again: at 144 FPS that runs 2.4x faster than at 60, which
## made the SPEED slider mean something different at every FPS cap.
const REF_FPS := 60.0

## Frame-rate independent version of lerpf(a, b, k).
##
## `per_frame` is the fraction of the remaining distance closed in one REF_FPS frame.
## Raised to (delta * REF_FPS) it becomes the fraction for a frame of any length, so the
## curve settles in the same wall-clock time at 30, 60 or 144 FPS. At exactly REF_FPS
## the exponent is 1 and this reduces to the original lerpf, so the tuned feel is
## preserved rather than re-guessed.
static func _fps_lerp(from: float, to: float, per_frame: float, delta: float) -> float:
	return lerpf(from, to, 1.0 - pow(1.0 - clampf(per_frame, 0.0, 0.999), delta * REF_FPS))

## Whole REF_FPS-rate steps owed this frame, remainder carried. Used by the effects that
## advance in discrete steps -- the waterfall's rows, the grid's history, the fire's
## propagation -- all of which were written as one step per frame.
## Capped at 4 so a frame hitch replays a few steps instead of several hundred.
func _due_steps(delta: float) -> int:
	_step_accum += delta * REF_FPS
	var n: int = mini(int(_step_accum), 4)
	_step_accum -= float(n)
	return n

## Self-check: the same total smoothing must be reached in the same wall-clock time
## whatever the frame rate. Asserted from player.gd's _ready.
static func fps_lerp_test() -> bool:
	var settle := func(fps: float) -> float:
		var v := 0.0
		var d: float = 1.0 / fps
		for i in int(fps):        # exactly one second of frames
			v = _fps_lerp(v, 1.0, 0.25, d)
		return v
	var a: float = settle.call(60.0)
	var b: float = settle.call(144.0)
	var c: float = settle.call(30.0)
	var d: float = settle.call(240.0)
	# all four must land within a hair of each other, and of the old 60 FPS behaviour
	return absf(a - b) < 0.001 and absf(a - c) < 0.001 and absf(a - d) < 0.001 and a > 0.99

func _attack() -> float: return lerpf(0.22, 0.95, clampf(speed, 0.0, 1.0))
func _release() -> float: return lerpf(0.04, 0.40, clampf(speed, 0.0, 1.0))
func _peak_fall() -> float: return lerpf(0.15, 1.30, clampf(speed, 0.0, 1.0))

var _v := PackedFloat32Array()
var _peak := PackedFloat32Array()
var _db := PackedFloat32Array()
var _hue := 0.0
var _wf_img: Image
var _wf_tex: ImageTexture
var _wf_row := 0
var _tun_phase := 0.0
var _grid: Array[PackedFloat32Array] = []   # ring of past spectra, newest at _grid_head
var _grid_head := 0
var _step_accum := 0.0
var _fire: PackedFloat32Array           # heat grid, FIRE_W * FIRE_H
var _fire_img: Image
var _fire_tex: ImageTexture
var _road_phase := 0.0
var _car := Countach.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := AudioDirector.BAND_COUNT
	_v.resize(n)
	_peak.resize(n)
	_db.resize(n)
	for i in GRID_ROWS:
		var row := PackedFloat32Array()
		row.resize(n)
		_grid.append(row)
	_fire = PackedFloat32Array()
	_fire.resize(FIRE_W * FIRE_H)
	_fire_img = Image.create(FIRE_W, FIRE_H, false, Image.FORMAT_RGBA8)
	_fire_tex = ImageTexture.create_from_image(_fire_img)
	_wf_img = Image.create(n, WF_HEIGHT, false, Image.FORMAT_RGBA8)
	_wf_img.fill(Color(0, 0, 0, 0))
	_wf_tex = ImageTexture.create_from_image(_wf_img)
	add_child(_car)  # child so its _process drives the suspension jitter

## User gradients. Owned by player.gd, which loads/saves them as hex lists in
## library.cfg -- this class only samples them. Each is a real Gradient resource:
## Gradient natively supports non-uniform stop offsets (add_point / set_offset /
## sample), which is what lets a stop be dragged to an arbitrary position instead of
## always landing evenly spaced.
##
## The gradient is applied HERE and not in crt.gdshader, and that is the whole design
## decision: the shader is a post pass over the SubViewportContainer, so by the time it
## runs the bars are already pixels and a sampler2D there could only tint the finished
## image uniformly. Per-bar colour is chosen at draw time, which is this file.
var gradients: Array[Gradient] = []

## How a gradient moves. STATIC is the original "colour list" behaviour: color_at(t)
## samples purely by bar position and nothing drifts. The other three all walk the
## gradient's phase off _hue, the same clock the rainbow preset already uses.
enum ColorAnim { STATIC, FADE, LEFT_RIGHT, WAVE }
var color_anim: ColorAnim = ColorAnim.FADE

## Automatically steps color_index through the saved gradient list while one is
## selected. Off by default -- a gradient someone dialled in should not change under
## them without being asked.
var rotate_gradients := false
const ROTATE_PERIOD_SEC := 20.0
var _rotate_t := 0.0

## color_index layout: 0..PRESETS.size()-1 fixed, PRESETS.size() rainbow, then one slot
## per user gradient. Returns -1 when the current selection is not a gradient.
func gradient_index() -> int:
	return color_index - PRESETS.size() - 1

## Fraction of one cycle spent crossfading the last stop back to the first.
##
## The old version only closed the seam when the gradient left a gap of its own (first
## stop past 0, or last stop before 1) and returned the last colour flat when it did
## not. Every legacy hex list and every gradient the editor writes spans a full 0..1, so
## that was the common case -- and there sample() at 0.999 is the last colour while at
## 0.0 it is the first, with nothing in between. That hard cut is the pop.
const GRAD_SEAM := 0.12

## Gradient.sample() does not loop -- an offset past 1.0 just holds the last colour --
## so an animation whose phase drifts continuously through 0..1 and wraps hits a hard
## cut from the last stop back to the first. This always reserves a seam: a gradient
## that leaves its own gap donates it, one that fills 0..1 has GRAD_SEAM taken out of
## the body instead. Either way the body maps across 0..body and the remainder
## crossfades last -> first, so sampling either side of the wrap lands on the same
## colour and the loop closes for ANY gradient rather than only for a gapped one.
static func sample_looped(grad: Gradient, t: float) -> Color:
	var n := grad.get_point_count()
	if n == 0:
		return Color.WHITE
	if n == 1:
		return grad.get_color(0)
	var first: float = grad.get_offset(0)
	var last: float = grad.get_offset(n - 1)
	var seam: float = maxf((1.0 - last) + first, GRAD_SEAM)
	var body: float = 1.0 - seam
	var tt := fposmod(t, 1.0)
	if body <= 0.00001:
		# every stop piled on one offset: there is no body to sweep, only the crossfade
		return grad.get_color(n - 1).lerp(grad.get_color(0), tt)
	if tt <= body:
		return grad.sample(remap(tt, 0.0, body, first, last))
	return grad.get_color(n - 1).lerp(grad.get_color(0), (tt - body) / seam)

## How much of the ramp each animated mode lays across the 32 bands. FADE used to spread
## NONE of it -- every bar took one colour, so a twelve-stop gradient rendered as a
## single block that slowly changed hue and the spectrum carried no colour information
## at all. It now sweeps a fraction of the ramp across the columns while still drifting,
## which is what makes the display read as deep rather than flat; LEFT_RIGHT keeps the
## full ramp, so the two stay clearly different modes.
const SPREAD_FADE := 0.45
## The rainbow preset had the same flat problem. A hue axis across the spectrum is what
## a spectrum colour is FOR, so it spreads too -- less than a full turn, or the two ends
## of the display meet and the sweep reads as a repeat rather than a range.
const SPREAD_RAINBOW := 0.6

## Colour for a bar at t in 0..1 across the spectrum. The fixed presets are deliberately
## one flat colour; everything else varies across the bands.
func color_at(t: float) -> Color:
	var gi := gradient_index()
	if gi < 0 or gi >= gradients.size():
		if color_index >= PRESETS.size():
			return Color.from_hsv(fposmod(_hue + t * SPREAD_RAINBOW, 1.0), 0.85, 1.0)
		return color()
	var grad := gradients[gi]
	match color_anim:
		ColorAnim.LEFT_RIGHT:
			return sample_looped(grad, t + _hue)
		ColorAnim.WAVE:
			return sample_looped(grad, t + _hue + sin((_hue + t) * TAU) * 0.15)
		ColorAnim.FADE:
			return sample_looped(grad, t * SPREAD_FADE + _hue)
		_:   # STATIC: pure spatial position, nothing moves over time
			return grad.sample(clampf(t, 0.0, 1.0))

func color() -> Color:
	var gi := gradient_index()
	if gi >= 0 and gi < gradients.size():
		# a mode that wants ONE colour per frame still animates unless STATIC, walking
		# the same phase the per-bar modes use so every mode stays in sync
		return gradients[gi].sample(0.0) if color_anim == ColorAnim.STATIC \
			else sample_looped(gradients[gi], _hue)
	if color_index >= PRESETS.size():
		# full saturation, full value: the bars are drawn on black, so a desaturated
		# sweep would just read as grey at the ends of the cycle
		return Color.from_hsv(fposmod(_hue, 1.0), 0.85, 1.0)
	return PRESETS[clampi(color_index, 0, PRESETS.size() - 1)]

## "000000,ff0055,00ffcc,ffffff" (legacy: no positions, falls back to even spacing) or
## "000000@0.0000,ff0055@0.3000,...@1.0000" (explicit offsets, what the drag editor
## writes) in, a Gradient out. The same string is what library.cfg stores and what
## travels through the clipboard, so one parser serves both, and a gradient saved
## before offsets existed still loads looking exactly as it always did.
## Unparseable stops are DROPPED rather than defaulted: a typo becoming silent black
## would look like a deliberate stop. Returns null for a list with no valid colour.
static func parse_hex_list(s: String) -> Gradient:
	var colors := PackedColorArray()
	var offsets := PackedFloat32Array()
	for part in s.split(",", false):
		var piece := part.strip_edges()
		var at := piece.find("@")
		var hex := piece if at < 0 else piece.substr(0, at)
		hex = hex.trim_prefix("#")
		if not Color.html_is_valid(hex):
			continue
		var off := -1.0
		if at >= 0:
			var num := piece.substr(at + 1)
			if num.is_valid_float():
				off = clampf(num.to_float(), 0.0, 1.0)
		colors.append(Color.html(hex))
		offsets.append(off)
	if colors.is_empty():
		return null
	# any stop with no explicit (valid) offset falls back to even spacing across the
	# whole list -- this is the entire legacy path, since an old hex list never has "@"
	for i in offsets.size():
		if offsets[i] < 0.0:
			offsets[i] = float(i) / float(maxi(colors.size() - 1, 1))
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	return g

static func to_hex_list(grad: Gradient) -> String:
	var parts := PackedStringArray()
	for i in grad.get_point_count():
		parts.append("%s@%.4f" % [grad.get_color(i).to_html(false), grad.get_offset(i)])
	return ",".join(parts)

## Self-check, asserted from player.gd's _ready. The round trip is the part that
## matters: a gradient that survives to library.cfg but comes back different is
## invisible until someone notices their saved palette drifted.
static func gradient_test() -> bool:
	var g := parse_hex_list("000000,ff0055, 00ffcc ,#ffffff")
	if not g or g.get_point_count() != 4:
		return false
	# legacy list (no "@") parses to even spacing: 0, 1/3, 2/3, 1
	if not (is_equal_approx(g.get_offset(0), 0.0) and is_equal_approx(g.get_offset(1), 1.0 / 3.0)
			and is_equal_approx(g.get_offset(3), 1.0)):
		return false
	if parse_hex_list("zzz,,##,ff0000").get_point_count() != 1:   # junk dropped, no crash
		return false
	if parse_hex_list("") != null:
		return false
	var two := parse_hex_list("000000,ffffff")
	if not (two.sample(0.0).is_equal_approx(Color.BLACK) and two.sample(1.0).is_equal_approx(Color.WHITE)
			and absf(two.sample(0.5).r - 0.5) < 0.01):
		return false
	# explicit offsets round-trip exactly, including a stop dragged off even spacing
	var explicit := parse_hex_list("000000@0.0000,ff0055@0.2000,ffffff@1.0000")
	if to_hex_list(explicit) != "000000@0.0000,ff0055@0.2000,ffffff@1.0000":
		return false
	# The seam must be CONTINUOUS -- sampling either side of the 1.0/0.0 wrap has to land
	# on very nearly the same colour, or the animation snaps once per cycle. The two
	# full-range lists are the cases that used to pop: with no gap of their own, the old
	# code jumped from the last stop straight back to the first.
	for hexes in ["ff0000@0.25,00ff00@0.75", "ff0000@0.0,00ff00@1.0", "000000,ff0055,ffffff"]:
		var lg := parse_hex_list(hexes)
		var before := sample_looped(lg, -0.002)
		var after := sample_looped(lg, 0.002)
		if absf(before.r - after.r) > 0.05 or absf(before.g - after.g) > 0.05 \
				or absf(before.b - after.b) > 0.05:
			return false
	# ...and it must still SWEEP: a closed seam is worthless if the phase stopped moving
	var sweep := parse_hex_list("ff0000@0.0,00ff00@1.0")
	return not sample_looped(sweep, 0.0).is_equal_approx(sample_looped(sweep, 0.4))

func _process(delta: float) -> void:
	if not director:
		return
	# Nothing can see this: the SubViewportContainer switches its viewport to UPDATE_DISABLED
	# while it is hidden -- a Video TEST picture over the cell, or the feed at GONE -- and the
	# band smoothing, the stepped modes' texture uploads and the redraw would all be work for no
	# pixels (measured: 60 redraws in 60 frames behind a video picture, audit P1).
	var vp := get_viewport() as SubViewport
	if vp and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		return
	var n := AudioDirector.BAND_COUNT
	if color_index >= PRESETS.size():
		# ~16 s per full cycle at the middle SPEED setting: a slow drift, not a strobe.
		# WRAPPED every frame rather than left to grow: an unbounded phase loses float
		# precision as it climbs (after an hour it is past 200, and the gap between
		# representable values is coarse enough that the wrap lands unevenly), which is
		# what made a long-running gradient visibly jump at the seam.
		_hue = fposmod(_hue + delta * 0.062 * lerpf(0.5, 2.0, speed), 1.0)
	# Only ticks while a gradient is actually the active selection -- a preset or the
	# rainbow is not something the rotator should silently steer away from.
	if rotate_gradients and gradient_index() >= 0 and gradients.size() > 1:
		_rotate_t += delta
		if _rotate_t >= ROTATE_PERIOD_SEC:
			_rotate_t = 0.0
			color_index = PRESETS.size() + 1 + (gradient_index() + 1) % gradients.size()
	else:
		_rotate_t = 0.0
	if mode == Mode.SNAKE:
		# steps on the music rather than on its own clock, so it reads as a visualiser and
		# not as a screensaver that happens to be running
		var hz: float = lerpf(SNAKE_HZ_MIN, SNAKE_HZ_MAX, clampf(director.energy * 0.35, 0.0, 1.0))
		# capped before the loop: after a frame hitch an uncapped accumulator would replay
		# hundreds of steps at once and the snake would teleport into itself
		_snake_t = minf(_snake_t + delta * hz, 4.0)
		while _snake_t >= 1.0:
			_snake_t -= 1.0
			_snake_step()
	# FIXED dB window, 0 dBFS at the top. The auto-gain this replaces chased the loudest
	# band down to a -50 dB floor, which is why the display pinned to full height on
	# anything dense and thrashed between bands on anything sparse: the scale itself was
	# moving under the bars. An absolute window means a loud mix reads loud and a quiet
	# one reads quiet, which is what a meter is for.
	#
	# SENSITIVITY moves the FLOOR rather than a relative span -- 0.5 lands on the -60 dB
	# the display is tuned around, and the ends stay useful for very quiet or very hot
	# material without handing the scale back to an AGC.
	# Silent feed means an EXACTLY empty display. AudioDirector zeroes its own bands when
	# the player is stopped; without matching that here the bars would hold their last
	# smoothed value forever, because _fps_lerp only ever approaches zero asymptotically.
	#
	# ONLY the bands are zeroed. Everything else keeps running on an idle feed: the hue
	# drift, the gradient rotator, SNAKE, and -- no longer behind an early return -- the
	# stepped modes below. That return used to freeze FIRE on its last flame, WATERFALL on
	# its last rows and GRID on its last spectra for as long as playback stayed stopped;
	# fed zeros they empty themselves on the same wall-clock schedule at any FPS.
	if director.levels.is_empty() or not director.is_live():
		_v.fill(0.0)
		_peak.fill(0.0)
		_db.fill(0.0)
	else:
		var floor_db := db_floor()
		var atk := _attack()
		var rel := _release()
		var pf := _peak_fall()
		for i in n:
			# linear amplitude -> dB, then tilt. dB is the only mapping that spreads a real
			# mix over the full height instead of leaving it pinned to the floor.
			_db[i] = linear_to_db(maxf(director.levels[i], 1e-7)) + tilt_db * float(i) / float(n)
			var t := clampf(remap(_db[i], floor_db, 0.0, 0.0, 1.0), 0.0, 1.0)
			# was lerpf(...) with no delta, which is what made the bars snap at high FPS
			_v[i] = _fps_lerp(_v[i], t, atk if t > _v[i] else rel, delta)
			_peak[i] = maxf(_peak[i] - pf * delta, _v[i])
	# divisor derived from the bands actually summed, not a hardcoded 6: BAND_COUNT is a
	# constant today but a smaller one would have this understating bass, and a zero one
	# would divide by zero
	var bass := 0.0
	var bass_bands: int = mini(6, n)
	for i in bass_bands:
		bass += _v[i]
	bass /= float(maxi(bass_bands, 1))
	# one accumulator, read once per frame, shared by whichever stepped mode is live
	var steps := _due_steps(delta)
	if mode == Mode.WATERFALL:
		for _s in steps:
			_push_waterfall()
	elif mode == Mode.GRID:
		for _s in steps:
			_push_grid()
	elif mode == Mode.FIRE:
		_step_fire(steps)
	elif mode == Mode.TUNNEL:
		# flight speed rides the bass; SPEED scales the whole thing
		_tun_phase += delta * (0.35 + bass * 2.4) * lerpf(0.5, 2.2, speed)
	elif mode == Mode.CRUISE:
		_road_phase += delta * (2.0 + bass * 9.0) * lerpf(0.5, 2.0, speed)
	queue_redraw()

## One new row per REF_FPS step into a ring buffer -- driven by _due_steps, not by the
## frame, so the scroll runs at one speed whatever the FPS cap. Writing a row and drawing
## the texture in two offset halves is far cheaper than shifting the image or drawing
## 32*96 rects.
func _push_waterfall() -> void:
	var n := AudioDirector.BAND_COUNT
	for i in n:
		var c := color_at(float(i) / float(maxi(n - 1, 1)))
		# squared: linear alpha made every cell bright and the display read as a green wall
		var v := _v[i] * _v[i]
		_wf_img.set_pixel(i, _wf_row, Color(c.r * v, c.g * v, c.b * v, v * 0.9))
	_wf_row = (_wf_row + 1) % WF_HEIGHT
	_wf_tex.update(_wf_img)

func _draw() -> void:
	match mode:
		Mode.SEGMENTS: _draw_segments(false)
		Mode.MIRROR: _draw_segments(true)
		Mode.WATERFALL: _draw_waterfall()
		Mode.GRID: _draw_grid()
		Mode.RADIAL: _draw_radial()
		Mode.MATRIX: _draw_matrix()
		Mode.TUNNEL: _draw_tunnel()
		Mode.CRUISE: _draw_cruise()
		Mode.FIRE: _draw_fire()
		Mode.KALEIDO: _draw_kaleido()
		Mode.SNAKE: _draw_snake()

## Classic lit-cell ladder. Every coordinate is snapped to an integer or the low-res
## buffer smears the cell edges and the whole point of the SubViewport is lost.
func _draw_segments(mirror: bool) -> void:
	var n := AudioDirector.BAND_COUNT
	var cell := 3
	var base := size.y * 0.5 if mirror else size.y
	var full := (size.y * 0.5 if mirror else size.y * height_scale)
	for i in n:
		# per BAR, so a gradient -- or the rainbow -- runs left to right across the
		# spectrum. Only the fixed presets still fall through to the uniform color().
		var c := color_at(float(i) / float(maxi(n - 1, 1)))
		var x := _col_x(i)
		var bw := _col_w(i)
		var lit := int(_v[i] * full / cell)
		for k in lit:
			var y := int(base - (k + 1) * cell)
			draw_rect(Rect2(x, y, bw, cell - 1), c.lerp(Color.WHITE, clampf(float(k) * cell / maxf(full, 1.0) - 0.55, 0.0, 1.0) * 0.8))
			if mirror:
				draw_rect(Rect2(x, int(base + k * cell), bw, cell - 1), c * 0.55)
		var py := int(base - _peak[i] * full)
		draw_rect(Rect2(x, clampi(py, 0, int(size.y) - 1), bw, 1), Color(c, 0.9))
		if mirror:
			draw_rect(Rect2(x, clampi(int(base + _peak[i] * full), 0, int(size.y) - 1), bw, 1), Color(c, 0.5))

func _draw_waterfall() -> void:
	var h := size.y
	var older := WF_HEIGHT - _wf_row
	# rows from _wf_row..end are the oldest, then 0.._wf_row wraps in beneath them
	draw_texture_rect_region(_wf_tex, Rect2(0, 0, size.x, h * older / WF_HEIGHT),
		Rect2(0, _wf_row, AudioDirector.BAND_COUNT, older))
	draw_texture_rect_region(_wf_tex, Rect2(0, h * older / WF_HEIGHT, size.x, h * _wf_row / WF_HEIGHT),
		Rect2(0, 0, AudioDirector.BAND_COUNT, _wf_row))



## Spectrum swept around a circle: 90s "scope" panel look.
func _draw_radial() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var span := minf(size.x, size.y)
	var r0 := span * 0.16
	var r1 := _outer(span, 0.46)
	for i in n:
		var a := TAU * float(i) / float(n) - PI * 0.5
		var d := cos(a)
		var e := sin(a)
		var len := r0 + _v[i] * (r1 - r0)
		var steps := int(len - r0)
		for k in steps:  # stepped so it stays chunky instead of an antialiased line
			var rr := r0 + k
			draw_rect(Rect2(int(cx + d * rr), int(cy + e * rr), 2, 2),
				Color(c, 0.35 + float(k) / maxf(float(steps), 1.0) * 0.65))
		var pr := r0 + _peak[i] * (r1 - r0)
		draw_rect(Rect2(int(cx + d * pr), int(cy + e * pr), 2, 2), Color(c, 0.95))
	draw_rect(Rect2(int(cx) - 1, int(cy) - 1, 2, 2), Color(c, 0.6))

## Dot-matrix panel: the whole grid is visible and unlit cells stay faintly on, the way
## a real VFD display looks. That dim grid is what separates it from SEGMENTS.
func _draw_matrix() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var rows := maxi(int(size.y * height_scale / 4.0), 1)
	for i in n:
		var x := _col_x(i)
		var bw := _col_w(i)
		var lit := int(_v[i] * rows)
		var pk := int(_peak[i] * rows)
		for k in rows:
			var y := int(size.y - (k + 1) * 4)
			if k < lit:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.85))
			elif k == pk:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.7))
			else:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.18))  # unlit grid must stay visible or this is just SEGMENTS


## Column edges snapped independently so the bars tile the panel exactly. Some columns
## end up 1 px wider than others -- that is correct for pixel art, and it is what stops
## a dead strip appearing on the right at aspect ratios that do not divide evenly.
func _col_x(i: int) -> int:
	return int(float(i) * size.x / float(AudioDirector.BAND_COUNT))

func _col_w(i: int) -> int:
	var x1 := int(float(i + 1) * size.x / float(AudioDirector.BAND_COUNT))
	return maxi(x1 - _col_x(i) - 1, 1)


## Perspective wireframe tunnel. Rings recede on a 1/z curve and slide toward the
## viewer; the cross-section is not a circle but the spectrum itself, so the tube
## bulges wherever a band is loud. Strictly 1 px, unantialiased, no fills.
func _draw_tunnel() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var rings := 15
	# classic demoscene wobble -- the tunnel mouth drifts off centre
	var cx := size.x * 0.5 + sin(_tun_phase * 0.7) * size.x * 0.07
	var cy := size.y * 0.5 + cos(_tun_phase * 0.53) * size.y * 0.07
	var focal := minf(size.x, size.y) * 0.10
	var reach := lerpf(0.55, 1.15, height_scale)
	# fract is subtracted so depth indices stay monotonic: rings must be ordered for the
	# longitudinal spokes to join neighbours instead of leaping across the screen
	var frac: float = 1.0 - (_tun_phase - floor(_tun_phase))
	var prev := PackedVector2Array()
	var have_prev := false
	for k in rings:
		var z: float = (float(k) + frac) / float(rings)
		var rr: float = focal / maxf(z * z, 0.004) * reach
		if rr > maxf(size.x, size.y) * 2.0:
			continue  # this ring is past the camera
		var pts := PackedVector2Array()
		pts.resize(n)
		for i in n:
			var a := TAU * float(i) / float(n)
			var bulge := 1.0 + _v[i] * 0.75
			pts[i] = Vector2(cx + cos(a) * rr * bulge, cy + sin(a) * rr * bulge)
		var fade: float = clampf(1.0 - z * 0.85, 0.15, 1.0)
		for i in n:
			draw_line(pts[i], pts[(i + 1) % n], Color(c, fade), 1.0, false)
			if have_prev and i % 4 == 0:
				draw_line(pts[i], prev[i], Color(c, fade * 0.45), 1.0, false)
		prev = pts
		have_prev = true


# --- CRUISE: wireframe coupe on a receding road, EQ bars along both verges ---------
# All geometry is generated here as 3-D points and projected by hand. There is no mesh,
# no Camera3D and no model file: a wireframe this small is cheaper to project directly
# than to stand up a 3D pipeline for, and it keeps the pixel snapping the other modes use.

const EYE_Y := 1.30          # camera height above the road plane
const ROAD_HALF := 5.0       # half width of the tarmac
const VERGE := 6.4           # x offset of the EQ bars
const Z_NEAR := 0.55
const Z_FAR := 46.0
const RIB_SPACING := 2.4     # gap between transverse road ribs

func _proj(p: Vector3) -> Vector2:
	var f := size.y * 1.15
	var horizon := size.y * 0.40
	return Vector2(size.x * 0.5 + p.x * f / p.z, horizon + (EYE_Y - p.y) * f / p.z)

## Clips the segment to the near plane before projecting; without this a line crossing
## behind the camera wraps to the far side of the screen instead of running off it.
func _seg(a: Vector3, b: Vector3, c: Color) -> void:
	var p := a
	var q := b
	if p.z < Z_NEAR and q.z < Z_NEAR:
		return
	if p.z < Z_NEAR:
		p = p.lerp(q, (Z_NEAR - p.z) / (q.z - p.z))
	elif q.z < Z_NEAR:
		q = q.lerp(p, (Z_NEAR - q.z) / (p.z - q.z))
	draw_line(_proj(p), _proj(q), c, 1.0, false)

## Flat-shaded quad. Bars are short and always well in front of the camera, so a
## whole-polygon clip is enough -- no need for per-edge near-plane clipping here.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	if a.z < Z_NEAR or b.z < Z_NEAR or c.z < Z_NEAR or d.z < Z_NEAR:
		return
	var p := PackedVector2Array([_proj(a), _proj(b), _proj(c), _proj(d)])
	# A silent band collapses its bar to zero height, and triangulating a degenerate
	# polygon fails -- Godot logs "Invalid polygon data" every frame for every such bar.
	var area: float = absf((p[1] - p[0]).cross(p[3] - p[0])) + absf((p[2] - p[1]).cross(p[3] - p[1]))
	if area < 0.5:
		return
	draw_colored_polygon(p, col)

func _depth_fade(z: float, c: Color) -> Color:
	return Color(c, clampf(1.0 - (z - Z_NEAR) / Z_FAR, 0.12, 1.0))

func _draw_cruise() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	_draw_sun(c)

	# --- road: two edges, a centre dash line, and scrolling transverse ribs
	for x in [-ROAD_HALF, ROAD_HALF]:
		_seg(Vector3(x, 0.0, Z_NEAR), Vector3(x, 0.0, Z_FAR), Color(c, 0.75))
	# subtracted, not added: as the phase advances each rib's z must DECREASE so the
	# road runs toward the camera. Adding it made the ribs recede, i.e. driving backwards.
	var offset := RIB_SPACING - fposmod(_road_phase, RIB_SPACING)
	var z := Z_NEAR + offset
	while z < Z_FAR:
		var f := _depth_fade(z, c)
		_seg(Vector3(-ROAD_HALF, 0.0, z), Vector3(ROAD_HALF, 0.0, z), Color(f, f.a * 0.5))
		_seg(Vector3(0.0, 0.0, z), Vector3(0.0, 0.0, z + RIB_SPACING * 0.45), f)  # centre dashes
		z += RIB_SPACING

	# --- EQ bars: one band per slot down each verge, nearest band = lowest frequency
	var span := (Z_FAR - 4.0) / float(n)
	for i in n:
		var bz := 2.0 + i * span
		var h := _v[i] * 2.6
		var pk := _peak[i] * 2.6
		var f := _depth_fade(bz, c)
		var d := span * 0.55
		for sx in [-VERGE, VERGE]:
			var x0: float = sx - 0.45 if sx > 0.0 else sx + 0.45
			# solid: fill the face pointing at the camera and the inner flank, then
			# draw the outline over the top so the edges stay crisp at low resolution
			_quad(Vector3(x0, 0.0, bz), Vector3(sx, 0.0, bz),
				Vector3(sx, h, bz), Vector3(x0, h, bz), Color(f, f.a * 0.75))
			_quad(Vector3(x0, 0.0, bz), Vector3(x0, 0.0, bz + d),
				Vector3(x0, h, bz + d), Vector3(x0, h, bz), Color(f, f.a * 0.45))
			_seg(Vector3(x0, 0.0, bz), Vector3(x0, h, bz), f)
			_seg(Vector3(sx, 0.0, bz), Vector3(sx, h, bz), f)
			_seg(Vector3(x0, h, bz), Vector3(sx, h, bz), f)
			_seg(Vector3(sx, h, bz), Vector3(sx, h, bz + d), Color(f, f.a * 0.45))
			_seg(Vector3(x0, pk, bz), Vector3(sx, pk, bz), Color(c, f.a))  # peak rail

	# --- the car: square to the road, wheels sitting on the road plane
	var cz := 6.2
	var body := Color(c, 1.0)
	var pts := _car.edges()
	var i := 0
	while i < pts.size():
		_seg(_car_pt(pts[i], cz), _car_pt(pts[i + 1], cz), body)
		i += 2

## Local car space -> world. No yaw: the car's axis stays parallel to the road edges.
## The suspension offset is applied here rather than baked into the geometry, so the
## edge list stays immutable and is built exactly once.
func _car_pt(p: Vector3, cz: float) -> Vector3:
	var o := _car.offset
	return Vector3(p.x + o.x, p.y + o.y, cz + p.z)


## Retrowave sun sitting on the horizon: outline plus horizontal chords whose spacing
## widens toward the bottom, so the top reads solid and the base breaks into bands.
## Drawn in screen space -- it is at infinity, so running it through the perspective
## divide would only fight the road for the same vanishing point.
func _draw_sun(c: Color) -> void:
	var r := minf(size.x, size.y) * 0.26
	var cx := size.x * 0.5
	var horizon := size.y * 0.40
	var cy := horizon - r * 0.30          # bisected by the horizon, most of it above
	var prev := Vector2.ZERO
	for k in 41:
		var a: float = TAU * float(k) / 40.0
		var p := Vector2(cx + cos(a) * r, cy + sin(a) * r)
		if k > 0 and p.y < horizon and prev.y < horizon:
			draw_line(prev, p, Color(c, 0.55), 1.0, false)
		prev = p
	var y := cy - r
	while y < horizon:
		var dy: float = y - cy
		var half: float = sqrt(maxf(r * r - dy * dy, 0.0))
		if half > 1.0:
			draw_line(Vector2(int(cx - half), int(y)), Vector2(int(cx + half), int(y)),
				Color(c, 0.28), 1.0, false)
		# above centre the bands sit tight; below they spread into the classic slices
		y += 2.0 if dy < 0.0 else 2.0 + (dy / r) * 8.0


# --- 1990s modes -----------------------------------------------------------

const GRID_ROWS := 20
const FIRE_W := 56
const FIRE_H := 40

## Demoscene fire. The bottom row is seeded from the spectrum, then each cell above
## averages its neighbours and cools -- the classic cellular fire, at a deliberately
## coarse grid so it upscales into chunky pixels rather than smooth flame.
func _step_fire(steps: int) -> void:
	var n := AudioDirector.BAND_COUNT
	for x in FIRE_W:
		var band: int = clampi(int(float(x) / float(FIRE_W) * float(n)), 0, n - 1)
		_fire[(FIRE_H - 1) * FIRE_W + x] = clampf(_v[band] * 1.1, 0.0, 1.0)
	# cooling is per STEP now, not per frame, so the flame rises at one speed at any FPS
	var cool: float = 1.0 - clampf(lerpf(0.5, 2.2, speed) / REF_FPS, 0.0, 0.10)
	for _s in steps:
		for y in range(FIRE_H - 1):
			for x in FIRE_W:
				var below := (y + 1) * FIRE_W + x
				var l: float = _fire[below - 1] if x > 0 else _fire[below]
				var r: float = _fire[below + 1] if x < FIRE_W - 1 else _fire[below]
				_fire[y * FIRE_W + x] = (_fire[below] * 2.0 + l + r) * 0.25 * cool
	var c := color()
	for y in FIRE_H:
		for x in FIRE_W:
			var h: float = _fire[y * FIRE_W + x]
			# black -> accent -> white, with the white stop held back to the top of the
			# range so the flame body keeps its colour instead of blowing out
			var col := Color.BLACK.lerp(c, minf(h * 1.8, 1.0))
			col = col.lerp(Color.WHITE, clampf((h - 0.78) * 4.0, 0.0, 1.0))
			col.a = clampf(h * 1.5, 0.0, 1.0)
			_fire_img.set_pixel(x, y, col)
	_fire_tex.update(_fire_img)

func _draw_fire() -> void:
	draw_texture_rect(_fire_tex, Rect2(0, 0, size.x, size.y), false)

## Four-way mirrored fan: the spectrum swept through a quarter turn and reflected into
## the other three quadrants.
func _draw_kaleido() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var span := minf(size.x, size.y)
	var r0 := span * 0.08
	var r1 := _outer(span, 0.5)
	for i in n:
		var a: float = (PI * 0.5) * float(i) / float(n)
		var len: float = r0 + _v[i] * (r1 - r0)
		var pk: float = r0 + _peak[i] * (r1 - r0)
		for q in 4:
			# reflect rather than rotate, so adjacent quadrants meet as mirror images
			var dx: float = cos(a) * (1.0 if q == 0 or q == 3 else -1.0)
			var dy: float = sin(a) * (1.0 if q < 2 else -1.0)
			var steps := int(len - r0)
			for k in steps:
				var rr := r0 + float(k)
				draw_rect(Rect2(int(cx + dx * rr), int(cy + dy * rr), 2, 2),
					Color(c, 0.25 + float(k) / maxf(float(steps), 1.0) * 0.7))
			draw_rect(Rect2(int(cx + dx * pk), int(cy + dy * pk), 2, 2), Color(c, 0.95))


## Perspective spectrum landscape: every frame pushes the current spectrum onto a ring
## and the whole history is drawn receding toward a horizon, newest at the front. The
## classic 90s media-player "3D bars" view, done as a wireframe so it stays crisp at
## this resolution instead of turning into mush.
func _push_grid() -> void:
	_grid_head = (_grid_head - 1 + GRID_ROWS) % GRID_ROWS
	var row := _grid[_grid_head]
	for i in AudioDirector.BAND_COUNT:
		row[i] = _v[i]
	_grid[_grid_head] = row

func _draw_grid() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var horizon := size.y * 0.30
	var front := size.y * 0.92
	var lift := size.y * 0.42 * (height_scale / 0.62)
	# drawn back to front so nearer rows overlap the ones behind them
	for r in range(GRID_ROWS - 1, -1, -1):
		var row := _grid[(_grid_head + r) % GRID_ROWS]
		var z := 1.0 + float(r) * 0.32
		var base := horizon + (front - horizon) / z
		var half := size.x * 0.46 / z
		var fade := clampf(1.0 - float(r) / float(GRID_ROWS), 0.10, 1.0)
		var prev := Vector2.ZERO
		for i in n:
			var t := float(i) / float(n - 1)
			var p := Vector2(cx + (t - 0.5) * 2.0 * half, base - row[i] * lift / z)
			if i > 0:
				draw_line(Vector2(int(prev.x), int(prev.y)), Vector2(int(p.x), int(p.y)),
					Color(c, fade * 0.85), 1.0, false)
			prev = p


## Outer radius for the ring modes, capped at the circle inscribed in the canvas.
## Unclamped, `height_scale` at maximum pushed RADIAL to 0.74 and KALEIDO to 0.81 of the
## short side -- past the 0.5 half-extent -- so in a short wide panel the ring was cut
## flat top and bottom and read as a squashed oval rather than a circle.
func _outer(span: float, frac: float) -> float:
	return span * minf(frac * (height_scale / 0.62), 0.48)




# --- SNAKE (secret) ----------------------------------------------------------
## Unlocked by typing SNAKE. An attract-mode snake on a coarse grid that steps on the
## music rather than on a fixed timer, so it is still a visualiser: there is no input
## plumbed to it and there is not meant to be. It draws through color_at(), so a user
## gradient runs head to tail.
const SNAKE_COLS := 24
const SNAKE_ROWS := 16
## Steps per second at rest, and at full energy. The snake is the beat readout here.
const SNAKE_HZ_MIN := 4.0
const SNAKE_HZ_MAX := 14.0

var snake_unlocked := false
var _snake: Array[Vector2i] = []
var _snake_dir := Vector2i(1, 0)
var _snake_food := Vector2i(8, 8)
var _snake_t := 0.0

func snake_reset() -> void:
	var mid := SNAKE_ROWS / 2
	_snake = [Vector2i(4, mid), Vector2i(3, mid), Vector2i(2, mid)]
	_snake_dir = Vector2i(1, 0)
	_snake_food = Vector2i(SNAKE_COLS - 5, mid)

## Greedy: prefer the axis with the greater distance to the food, fall back to any legal
## direction, and reset when boxed in. An attract loop, not a solver -- a perfect player
## would fill the grid and stop being interesting to look at.
func _snake_step() -> void:
	if _snake.size() < 2:
		snake_reset()
		return
	var head: Vector2i = _snake[0]
	var d: Vector2i = _snake_food - head
	var options: Array[Vector2i] = []
	if absi(d.x) >= absi(d.y):
		options = [Vector2i(signi(d.x), 0), Vector2i(0, signi(d.y))]
	else:
		options = [Vector2i(0, signi(d.y)), Vector2i(signi(d.x), 0)]
	options.append_array([Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)])
	for o in options:
		if o == Vector2i.ZERO:
			continue
		if not _snake_free(head + o):
			continue
		_snake_dir = o
		break
	var nxt: Vector2i = head + _snake_dir
	if not _snake_free(nxt):
		snake_reset()
		return
	_snake.push_front(nxt)
	if nxt == _snake_food:
		# grown: the tail stays on, and the food moves somewhere the body is not. Bounded
		# tries rather than a while loop -- on a nearly full grid that would never return.
		for tries in 32:
			var spot := Vector2i(randi() % SNAKE_COLS, randi() % SNAKE_ROWS)
			if not (spot in _snake):
				_snake_food = spot
				break
	else:
		_snake.pop_back()
	if _snake.size() > SNAKE_COLS * SNAKE_ROWS / 2:
		snake_reset()

func _snake_free(p: Vector2i) -> bool:
	if p.x < 0 or p.y < 0 or p.x >= SNAKE_COLS or p.y >= SNAKE_ROWS:
		return false
	return not (p in _snake)

## Pure, so the wrap and self-collision rules are checkable without a tree or a clock.
static func snake_legal(p: Vector2i, body: Array[Vector2i]) -> bool:
	if p.x < 0 or p.y < 0 or p.x >= SNAKE_COLS or p.y >= SNAKE_ROWS:
		return false
	return not (p in body)

static func snake_test() -> bool:
	var body: Array[Vector2i] = [Vector2i(2, 2), Vector2i(1, 2)]
	return snake_legal(Vector2i(3, 2), body) 		and not snake_legal(Vector2i(2, 2), body) 		and not snake_legal(Vector2i(-1, 0), body) 		and not snake_legal(Vector2i(0, -1), body) 		and not snake_legal(Vector2i(SNAKE_COLS, 0), body) 		and not snake_legal(Vector2i(0, SNAKE_ROWS), body) 		and snake_legal(Vector2i(SNAKE_COLS - 1, SNAKE_ROWS - 1), body)

func _draw_snake() -> void:
	if _snake.is_empty():
		snake_reset()
	var cw := size.x / float(SNAKE_COLS)
	var chh := size.y / float(SNAKE_ROWS)
	var w := maxi(int(cw) - 1, 1)
	var h := maxi(int(chh) - 1, 1)
	for i in _snake.size():
		var p: Vector2i = _snake[i]
		var c := color_at(float(i) / float(maxi(_snake.size() - 1, 1)))
		draw_rect(Rect2(int(p.x * cw), int(p.y * chh), w, h),
			c.lerp(Color.WHITE, 0.6) if i == 0 else c)
	draw_rect(Rect2(int(_snake_food.x * cw), int(_snake_food.y * chh), w, h),
		Color(1.0, 1.0, 1.0, 0.85))
