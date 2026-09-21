class_name Mustang
extends Countach
## Wireframe 2004 Ford Mustang GT -- New Edge, SN95 -- drawn for the one view CRUISE shows.
##
## It extends Countach because that class is the wireframe-car chassis rather than a
## Lamborghini: local space (+Z nose, +Y up, wheels on y = 0), the flat PackedVector3Array of
## point pairs `edges()` hands the visualizer, and the suspension jitter in _process. Only
## _build() is replaced, so MUSTANG draws through exactly the same _draw_cruise() CRUISE does.
##
## THE CAMERA NEVER MOVES. It sits behind the car, slightly above it, dead on the centre
## line, so this is a model of the BACK of a Mustang and nothing else. Panels are declared as
## faces; _face() takes the plane normal, flips it to point away from a point INSIDE the body
## so the winding can be whatever reads best in the code, and keeps the face only if that
## outward normal still points at EYE. EYE is a constant, so the culling runs ONCE in _build()
## and costs nothing per frame. Shared edges are emitted once through _line().
##
## Culling cannot hide a front-facing surface behind a nearer one, so the pieces that would
## still bleed through the trunk are simply not built: HULL_FROM_Z stops the loft ahead of the
## cabin, the tyres build only the part that shows under the bodywork, and there are no front
## wheels, door shuts or mirrors at all.
##
## SCALE: 0.80 units per metre, the same as the road and the other car. A 2004 GT coupe is
## 4653 long, 1859 wide, 1359 tall, on a 2573 wheelbase, a 1516 rear track and 245/45R17 rear
## tyres. Two deliberate departures from those numbers, both at Gavin's direction (2026-09-21)
## because the honest ones read tall and narrow at 350 px: the car is drawn 1950 wide and 1250
## tall rather than 1859 and 1359, and the bumper's lower edge is carried about 5 cm higher
## than the real one so a proper band of tyre shows under it instead of a sliver.

## The CRUISE camera in this car's local space: Visualizer.EYE_Y up, back by Visualizer.CAR_Z.
## The hiding above is only correct while these are the visualizer's own numbers, so
## test_viz_fps asserts they match rather than trusting this comment.
const EYE := Vector3(0.0, 1.30, -6.2)
## Any point comfortably inside the bodywork, used only to decide which of a face's two
## normals points outward.
const INSIDE := Vector3(0.0, 0.48, -0.30)

## Cross-sections, nose to tail: z, lower half-width, lower y, waist half-width, waist y,
## top half-width, top y -- the parent's _ring() 7-tuple. `top` is the BELTLINE here, not the
## roof: a Mustang's greenhouse is a separate glasshouse sitting on the body, built as its own
## faces below. The waist is the fender line, which is the widest the car gets.
const RINGS := [
	[ 1.86, 0.46, 0.30, 0.60, 0.44, 0.52, 0.56],  # nose
	[ 1.50, 0.58, 0.24, 0.70, 0.46, 0.64, 0.66],  # front bumper
	[ 1.03, 0.62, 0.20, 0.76, 0.50, 0.70, 0.74],  # front axle
	[ 0.55, 0.62, 0.20, 0.76, 0.51, 0.70, 0.77],  # screen base
	[ 0.10, 0.62, 0.20, 0.76, 0.51, 0.70, 0.77],  # mid cabin
	[-0.45, 0.64, 0.20, 0.78, 0.51, 0.72, 0.77],  # rear beltline
	[-1.03, 0.70, 0.21, 0.78, 0.50, 0.70, 0.75],  # rear axle, over the haunch
	[-1.50, 0.71, 0.23, 0.76, 0.49, 0.69, 0.74],  # decklid
	[-1.86, 0.69, 0.25, 0.74, 0.47, 0.67, 0.72],  # tail panel
]

const AXLE_REAR := -1.03
## 245/45R17 on a 1516 track: 0.26 of radius, and drawn 0.24 between its flanks and out to
## 0.74 so the tread band has some width to it from dead astern.
const REAR_R := 0.26
const REAR_IN := 0.50
const REAR_OUT := 0.74

const TAIL_Z := -1.86
const DECK_Z0 := -1.10    # decklid, where the rear glass meets it
const DECK_Z1 := -1.86    # decklid, at the tail panel

var _seen := {}   # edge key -> true, so an edge two panels share is emitted once

func _build() -> void:
	_edges = PackedVector3Array()
	_seen = {}
	_hull()
	_glasshouse()
	_decklid()
	_spoiler()
	_lights()
	_bumper()
	_tyres()
	_seen = {}   # build scaffolding, not state

# --- the hiding ------------------------------------------------------------
func _line(a: Vector3, b: Vector3) -> void:
	var ka := "%.3f %.3f %.3f" % [a.x, a.y, a.z]
	var kb := "%.3f %.3f %.3f" % [b.x, b.y, b.z]
	var key: String = ka + "|" + kb if ka < kb else kb + "|" + ka
	if _seen.has(key):
		return
	_seen[key] = true
	_edge(a, b)

## A surface panel. Drawn only when it faces the camera; returns whether it was, so detail
## that lives ON a panel is skipped with the panel it belongs to.
func _face(pts: Array) -> bool:
	if pts.size() < 3:
		return false
	var a: Vector3 = pts[0]
	var n: Vector3 = (pts[1] - a).cross(pts[2] - a)
	if n.length_squared() < 1e-10:
		return false   # degenerate: three points in a line have no plane to face with
	n = n.normalized()
	var mid := Vector3.ZERO
	for p: Vector3 in pts:
		mid += p
	mid /= float(pts.size())
	if n.dot(mid - INSIDE) < 0.0:
		n = -n
	if n.dot(EYE - mid) <= 0.0:
		return false
	for i in pts.size():
		_line(pts[i], pts[(i + 1) % pts.size()])
	return true

# --- the car ---------------------------------------------------------------
## Where the hull starts being built at all. Culling handles the flanks and the floor on its
## own, but the BONNET is a genuine front face -- the camera sits above it -- that happens to
## be hidden behind the roof, and no normal test can know that. Rather than special-case it,
## nothing ahead of the mid-cabin station is lofted: from dead astern the whole nose sits
## inside the rear fenders' silhouette and contributes lines and nothing else.
const HULL_FROM_Z := 0.12

## Lofted hull as PANELS rather than rings and rails, each culled on its own. What survives is
## the tail cap, the haunches over the rear wheels and the top of the decklid.
func _hull() -> void:
	var prev: Array = []
	for s in RINGS:
		if float(s[0]) > HULL_FROM_Z:
			continue
		var r := _ring(s)
		if not prev.is_empty():
			for i in r.size():
				var j := (i + 1) % r.size()
				_face([prev[i], prev[j], r[j], r[i]])
		prev = r
	_face(prev)   # the tail cap: the panel this whole view is built around

## The fastback. Lowered to 1.00 and widened to 0.52 of half-roof at Gavin's direction: at the
## honest 1.359 m the greenhouse reads as a tall rounded canopy from behind, where the thing
## everyone recognises about this car is that it is WIDE and the glass is shallow.
const ROOF_Y := 1.00
const ROOF_HALF := 0.52
const ROOF_Z0 := 0.46     # roof, front
const ROOF_Z1 := -0.34    # roof, rear -- where the backlight starts its fall
const GLASS_BASE_Y := 0.78
const GLASS_BASE_HALF := 0.66

func _glasshouse() -> void:
	_face([Vector3(-ROOF_HALF, ROOF_Y, ROOF_Z0), Vector3(ROOF_HALF, ROOF_Y, ROOF_Z0),
		Vector3(ROOF_HALF, ROOF_Y, ROOF_Z1), Vector3(-ROOF_HALF, ROOF_Y, ROOF_Z1)])
	# the backlight, the biggest thing in the rear view after the bodywork itself
	_face([Vector3(-ROOF_HALF, ROOF_Y, ROOF_Z1), Vector3(ROOF_HALF, ROOF_Y, ROOF_Z1),
		Vector3(GLASS_BASE_HALF, GLASS_BASE_Y, DECK_Z0), Vector3(-GLASS_BASE_HALF, GLASS_BASE_Y, DECK_Z0)])
	# C-pillars: the triangle each side of the backlight, down onto the beltline
	for sx in [-1.0, 1.0]:
		_face([Vector3(sx * ROOF_HALF, ROOF_Y, ROOF_Z1),
			Vector3(sx * GLASS_BASE_HALF, GLASS_BASE_Y, DECK_Z0),
			Vector3(sx * 0.72, 0.77, -0.62)])
		# windscreen and side glass: built for completeness, culled from here
		_face([Vector3(sx * 0.66, 0.77, 0.55), Vector3(sx * ROOF_HALF, ROOF_Y, ROOF_Z0),
			Vector3(sx * ROOF_HALF, ROOF_Y, ROOF_Z1), Vector3(sx * 0.72, 0.77, -0.62)])
	_face([Vector3(-0.66, 0.77, 0.55), Vector3(0.66, 0.77, 0.55),
		Vector3(ROOF_HALF, ROOF_Y, ROOF_Z0), Vector3(-ROOF_HALF, ROOF_Y, ROOF_Z0)])

## The trunk lid seen from above and behind, the third brake light sunk into it, and the plate
## in its recess. The plate is drawn as a frame inside a recess rather than as one big box:
## a single rectangle the width of the panel is what made the tail read as a face.
const PLATE_HALF := 0.25
const PLATE_TOP := 0.66
const PLATE_BOT := 0.44

func _decklid() -> void:
	_face([Vector3(-GLASS_BASE_HALF, GLASS_BASE_Y, DECK_Z0), Vector3(GLASS_BASE_HALF, GLASS_BASE_Y, DECK_Z0),
		Vector3(0.67, 0.72, DECK_Z1), Vector3(-0.67, 0.72, DECK_Z1)])
	_face([Vector3(-0.17, 0.773, -1.16), Vector3(0.17, 0.773, -1.16),
		Vector3(0.17, 0.767, -1.24), Vector3(-0.17, 0.767, -1.24)])
	var z := TAIL_Z - 0.005
	if _face([Vector3(-PLATE_HALF, PLATE_TOP, z), Vector3(PLATE_HALF, PLATE_TOP, z),
			Vector3(PLATE_HALF, PLATE_BOT, z), Vector3(-PLATE_HALF, PLATE_BOT, z)]):
		# the plate itself, inset in the recess -- a 305 x 152 plate at this scale
		_face([Vector3(-0.155, PLATE_TOP - 0.045, z - 0.008), Vector3(0.155, PLATE_TOP - 0.045, z - 0.008),
			Vector3(0.155, PLATE_BOT + 0.045, z - 0.008), Vector3(-0.155, PLATE_BOT + 0.045, z - 0.008)])

## The factory pedestal wing: a blade lifted off the trunk on two uprights, spanning most of
## the lid. Flat, unlike the Countach's -- on this car the spoiler is a line across the tail,
## and giving it a V would be inventing a different car.
const WING_HALF := 0.60
const WING_Y := 0.84
const WING_LEAD := -1.30
const WING_TRAIL := -1.56
const WING_THICK := 0.03

func _spoiler() -> void:
	var drop := Vector3(0.0, WING_THICK, 0.0)
	var lead_l := Vector3(-WING_HALF, WING_Y, WING_LEAD)
	var lead_r := Vector3(WING_HALF, WING_Y, WING_LEAD)
	var trail_l := Vector3(-WING_HALF, WING_Y, WING_TRAIL)
	var trail_r := Vector3(WING_HALF, WING_Y, WING_TRAIL)
	_face([lead_l, lead_r, trail_r, trail_l])                                  # top
	_face([trail_l, trail_r, trail_r - drop, trail_l - drop])                  # trailing edge
	_face([lead_l - drop, lead_r - drop, trail_r - drop, trail_l - drop])      # underside, culled
	# pedestals: flat blades with no inside, so they have no outward normal to test
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.46
		_line(Vector3(x, WING_Y - WING_THICK, WING_LEAD), Vector3(x, 0.745, WING_LEAD + 0.04))
		_line(Vector3(x, WING_Y - WING_THICK, WING_TRAIL), Vector3(x, 0.735, WING_TRAIL - 0.04))
		_line(Vector3(x, 0.745, WING_LEAD + 0.04), Vector3(x, 0.735, WING_TRAIL - 0.04))

## THE TRI-BAR TAILLIGHTS, which are the whole point of a Mustang's rear. One housing per
## side, three VERTICAL segments in each.
##
## Dead square: top and bottom edges level, sides plumb, zero slant. The real housing's top
## edge does fall a little toward the outside of the car, and drawing that honestly was a
## mistake -- at 350 px a 4 cm fall does not read as a subtle contour, it reads as lights put
## on crooked. Level is what says Mustang here.
const LIGHT_IN_X := 0.40
const LIGHT_OUT_X := 0.66
const LIGHT_TOP := 0.68
const LIGHT_BOT := 0.46
const BARS := 3

func _lights() -> void:
	for sx in [-1.0, 1.0]:
		var z := TAIL_Z - 0.01
		if not _face([Vector3(sx * LIGHT_IN_X, LIGHT_TOP, z), Vector3(sx * LIGHT_OUT_X, LIGHT_TOP, z),
				Vector3(sx * LIGHT_OUT_X, LIGHT_BOT, z), Vector3(sx * LIGHT_IN_X, LIGHT_BOT, z)]):
			continue
		var lens := z - 0.008
		for k in BARS:
			var x0: float = sx * lerpf(LIGHT_IN_X, LIGHT_OUT_X, float(k) / float(BARS) + 0.035)
			var x1: float = sx * lerpf(LIGHT_IN_X, LIGHT_OUT_X, float(k + 1) / float(BARS) - 0.035)
			_face([Vector3(x0, LIGHT_TOP - 0.018, lens), Vector3(x1, LIGHT_TOP - 0.018, lens),
				Vector3(x1, LIGHT_BOT + 0.018, lens), Vector3(x0, LIGHT_BOT + 0.018, lens)])

## The New Edge bumper: one hard crease running the width of the car under the lights, the
## valance step below it, and the exhausts.
##
## THE PIPES SIT IN CUTOUTS, not below the car. Hung under the valance as round mouths either
## side of the plate they turned the whole tail into a face -- two nostrils and a snout. On
## the real car each tip exits THROUGH a notch cut up into the valance, so the lowest thing
## back there is bodywork and the pipe is inside it. PIPE_Y - PIPE_R clears VALANCE_Y, and
## the test asserts it stays that way.
const CREASE_Y := 0.36
const VALANCE_Y := 0.27
## Pulled inboard of the real car's, which exits at about 0.55. The tyre's tread band runs
## from 0.50 out to 0.74 and nothing here occludes anything, so a pipe drawn where the real
## one sits is a circle lying on top of a wheel. At 0.40 it clears the tread and still reads
## as a pair of tips spaced wide either side of the plate.
const NOTCH_IN_X := 0.30
const NOTCH_OUT_X := 0.50
const NOTCH_TOP := 0.40
const PIPE_X := 0.40
const PIPE_Y := 0.335
const PIPE_R := 0.045

func _bumper() -> void:
	var z := TAIL_Z - 0.004
	# one clean crease the full width, with short returns at the corners: a muscle car's
	# valance is a wide flat band, and the row of moulding detents I had here was clutter
	_line(Vector3(-0.68, CREASE_Y, z), Vector3(0.68, CREASE_Y, z))
	for sx in [-1.0, 1.0]:
		_line(Vector3(sx * 0.68, CREASE_Y, z), Vector3(sx * 0.66, VALANCE_Y, z))
	_line(Vector3(-0.66, VALANCE_Y, z), Vector3(-NOTCH_OUT_X, VALANCE_Y, z))
	_line(Vector3(NOTCH_OUT_X, VALANCE_Y, z), Vector3(0.66, VALANCE_Y, z))
	_line(Vector3(-NOTCH_IN_X, VALANCE_Y, z), Vector3(NOTCH_IN_X, VALANCE_Y, z))
	for sx in [-1.0, 1.0]:
		# the cutout: up from the valance line, across, and back down
		_line(Vector3(sx * NOTCH_OUT_X, VALANCE_Y, z), Vector3(sx * NOTCH_OUT_X, NOTCH_TOP, z))
		_line(Vector3(sx * NOTCH_OUT_X, NOTCH_TOP, z), Vector3(sx * NOTCH_IN_X, NOTCH_TOP, z))
		_line(Vector3(sx * NOTCH_IN_X, NOTCH_TOP, z), Vector3(sx * NOTCH_IN_X, VALANCE_Y, z))
		var mouth: Array[Vector3] = []
		for k in 6:
			var a := TAU * float(k) / 6.0
			mouth.append(Vector3(sx * PIPE_X + cos(a) * PIPE_R, PIPE_Y + sin(a) * PIPE_R, z - 0.01))
		_face(mouth)
		for k in range(0, 6, 2):
			_line(mouth[k], mouth[k] + Vector3(0.0, 0.0, 0.07))

## Rear tyres, drawn as the TREAD BAND rather than as a disc. A wheel modelled as a ring in an
## x-plane is edge-on to a camera on the centre line, which is why the last version looked
## like the car was floating on two stubs: the thing you actually see from behind is the
## cylinder, so that is what is built -- two arcs 0.24 apart with rungs across them, running
## the whole bottom half from where the bodywork cuts it off, down to the road and back up.
func _tyres() -> void:
	for sx in [-1.0, 1.0]:
		var outer: Array[Vector3] = []
		var inner: Array[Vector3] = []
		for k in 9:
			var a := PI + PI * float(k) / 8.0
			var y := REAR_R + sin(a) * REAR_R
			var z := AXLE_REAR + cos(a) * REAR_R
			outer.append(Vector3(sx * REAR_OUT, y, z))
			inner.append(Vector3(sx * REAR_IN, y, z))
		for k in outer.size() - 1:
			_line(outer[k], outer[k + 1])
			_line(inner[k], inner[k + 1])
		for k in range(0, outer.size(), 2):
			_line(outer[k], inner[k])   # tread rungs: what says 245 section from dead astern

# --- check -----------------------------------------------------------------
## The silhouette, asserted. Pure geometry, so it runs in the suite without a viewport.
## Called from test_viz_fps.
static func model_test() -> bool:
	var car := Mustang.new()
	var e := car.edges()
	car.free()
	if e.is_empty() or e.size() % 2 != 0:
		return false
	var top := -99.0
	var low := 99.0
	var ahead := 0            # anything left in front of the cabin is bleed-through
	var rear_w := 0.0
	var tail_panel := 0
	var on_road := 0          # tyre points actually touching y = 0
	for i in e.size():
		var p := e[i]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return false
		top = maxf(top, p.y)
		low = minf(low, p.y)
		if p.z > 0.60:
			ahead += 1
		if p.z < -0.9:
			rear_w = maxf(rear_w, absf(p.x))
		if absf(p.z - TAIL_Z) < 0.06:
			tail_panel += 1
		if p.y < 0.02 and absf(p.x) > 0.45:
			on_road += 1
	var bars := 0
	var level := 0
	var i := 0
	while i < e.size():
		var a := e[i]
		var b := e[i + 1]
		var in_housing: bool = absf(a.x) > LIGHT_IN_X - 0.01 and absf(a.x) < LIGHT_OUT_X + 0.01 \
			and minf(a.y, b.y) > LIGHT_BOT - 0.01 and maxf(a.y, b.y) < LIGHT_TOP + 0.01
		# a bar: a plumb edge inside a housing
		if in_housing and absf(a.x - b.x) < 0.001 and absf(a.z - b.z) < 0.001 and absf(a.y - b.y) > 0.10:
			bars += 1
		# and the housing's own top and bottom edges must be dead level, not slanted
		if in_housing and absf(a.x - b.x) > 0.05 and absf(a.y - b.y) < 0.0005:
			level += 1
		i += 2
	var n := e.size() / 2
	return (
		n > 130 and n < 320               # lean enough to stay cheap, full enough to read
		and ahead == 0                    # nothing survives ahead of the cabin
		and low > -0.001                  # nothing under the road
		and top > ROOF_Y - 0.001          # the roof is the highest thing on this car
		and top < ROOF_Y + 0.001          # ... and nothing pokes above it
		and rear_w > 0.72                 # the rear track and haunches are still the widest
		and tail_panel > 20               # tail cap, lights, plate, notches and pipes present
		and bars >= 2 * BARS + 2          # three vertical bars a side, both sides
		and level >= 8                    # housings dead square: no slant, either side
		and on_road >= 4                  # both tyres reach the road, so the car is grounded
		and PIPE_Y - PIPE_R > VALANCE_Y   # and the pipes are INSIDE the valance, not under it
	)
