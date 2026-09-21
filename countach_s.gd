class_name CountachS
extends Countach
## Wireframe Lamborghini Countach LP5000 S, drawn for the view CRUISE actually shows.
##
## The camera in CRUISE sits BEHIND the car, so the rear three-quarter is the only angle
## anyone ever sees -- and the old body was a generic wedge with a flat plank for a wing.
## This one is built from the back forwards: the V-profile wing, the slanted three-section
## light clusters, the quad pipes in their bay, the louvred engine lid and the 345-section
## rear tyres are all modelled, and the nose gets whatever is left.
##
## Everything the parent owns still applies -- same local space (+Z nose, +Y up, wheels on
## y = 0), same flat PackedVector3Array of point pairs, same suspension jitter -- so CRUISE
## draws this exactly as it draws the original. Only _build() is replaced.
##
## SCALE: 0.80 units per metre, inherited from the original so the car sits on the road at
## the same size. The real LP5000 S is 4140 long, 2000 wide, 1070 tall, 2500 of wheelbase,
## on a 1536 front / 1606 rear track with 225 front and 345 rear tyres -- every number
## below is one of those divided by 1000 and multiplied by 0.80, then rounded to a place
## that reads at 100 px.
##
## ponytail: hand-placed, NOT extracted from the .glb sitting in Gavin's reference folder.
## That mesh is 360,663 triangles (~541k edges, 17.3 MB, 24 textures); this body is ~420
## edges and every one of them is a line somebody can see. Decimating a photoreal mesh down
## to a few hundred edges does not give you a vector car, it gives you triangle soup with
## the silhouette worn off -- and CRUISE is already the heaviest mode at 5.3 ms/frame.

## Cross-sections, nose to tail: z, lower half-width, lower y, waist half-width, waist y,
## top half-width, top y. Same 7-tuple the parent's _ring() takes.
##
## The two roof stations are the whole car in two lines: the waist stays out at 0.72-0.74
## while the top collapses to 0.36 -- that pinch over the hips IS the Countach, and it is
## why the rear view reads as a wedge with shoulders rather than as a box.
const RINGS := [
	[ 1.68, 0.30, 0.09, 0.42, 0.17, 0.36, 0.21],  # nose tip: a blade, 26 cm off the road
	[ 1.42, 0.46, 0.09, 0.60, 0.24, 0.54, 0.30],  # front spoiler / nose break
	[ 1.04, 0.56, 0.10, 0.72, 0.36, 0.64, 0.44],  # front axle
	[ 0.58, 0.54, 0.11, 0.70, 0.42, 0.60, 0.52],  # screen base
	[ 0.14, 0.54, 0.12, 0.72, 0.46, 0.38, 0.86],  # roof front -- the pinch
	[-0.42, 0.56, 0.12, 0.74, 0.47, 0.36, 0.86],  # roof rear
	[-0.86, 0.62, 0.12, 0.80, 0.49, 0.58, 0.78],  # shoulders, engine deck starts
	[-1.24, 0.64, 0.13, 0.80, 0.50, 0.62, 0.74],  # rear axle, widest point
	[-1.63, 0.54, 0.18, 0.68, 0.48, 0.62, 0.70],  # chopped tail
]

const AXLE_FRONT := 1.04
const AXLE_REAR := -0.96
## Tyre radius and the two x planes each tyre lives between. The rear pair is 0.28 apart
## (345 mm) against the front's 0.18 (225 mm): drawn as two rims joined by rails, because
## a single flat ring cannot say "wide" however far out you put it.
const FRONT_R := 0.25
const REAR_R := 0.27
const FRONT_IN := 0.52
const FRONT_OUT := 0.70
const REAR_IN := 0.50
const REAR_OUT := 0.78

const DECK_Z0 := -0.74    # engine lid, front edge
const DECK_Z1 := -1.30    # engine lid, back edge
const TAIL_Z := -1.63

func _build() -> void:
	_edges = PackedVector3Array()
	_body()
	_glass()
	_draw_popups()   # the pop-ups are unchanged from the original car
	_flanks()
	_deck()
	_wing()
	_lights()
	_exhaust()
	_arches()
	_tyres()

## Lofted hull, exactly as the parent does it: ring per station, rails between like points.
func _body() -> void:
	var prev: Array = []
	for s in RINGS:
		var r := _ring(s)
		_loop(r)
		if not prev.is_empty():
			for i in r.size():
				_edge(prev[i], r[i])
		prev = r
	# door cut and sill crease, which is what keeps the flank from reading as one slab
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.73
		_edge(Vector3(x, 0.44, 0.58), Vector3(x * 0.90, 0.12, 0.58))
		_edge(Vector3(x, 0.47, -0.42), Vector3(x * 0.90, 0.12, -0.42))
		_edge(Vector3(x, 0.28, 0.58), Vector3(x, 0.28, -0.42))

## Screen, roof and the short steep rear pane. The rear glass matters here: from behind it
## is the dark slot between the shoulders, sitting just above the louvres.
func _glass() -> void:
	var sb := 0.60   # half-width at the screen base
	var rf := 0.38   # half-width at the roof
	_loop([Vector3(-sb, 0.52, 0.58), Vector3(sb, 0.52, 0.58),
		Vector3(rf, 0.86, 0.14), Vector3(-rf, 0.86, 0.14)])
	_edge(Vector3(0.0, 0.52, 0.58), Vector3(0.0, 0.86, 0.14))
	_loop([Vector3(-rf, 0.86, 0.14), Vector3(rf, 0.86, 0.14),
		Vector3(0.36, 0.86, -0.42), Vector3(-0.36, 0.86, -0.42)])
	# rear pane, dropping onto the deck
	_loop([Vector3(-0.36, 0.86, -0.42), Vector3(0.36, 0.86, -0.42),
		Vector3(0.40, 0.80, -0.72), Vector3(-0.40, 0.80, -0.72)])
	for sx in [-1.0, 1.0]:
		_loop([Vector3(sx * sb, 0.52, 0.58), Vector3(sx * rf, 0.86, 0.14),
			Vector3(sx * 0.36, 0.86, -0.42), Vector3(sx * 0.73, 0.47, -0.42)])

## The flank ducts ahead of the rear arch, louvred. Horizontal slats rather than the single
## centre rib the original had: the slats are what say "intake" at this line weight.
func _flanks() -> void:
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.80
		_loop([Vector3(x, 0.22, 0.06), Vector3(x, 0.18, -0.34),
			Vector3(x, 0.40, -0.40), Vector3(x, 0.44, 0.02)])
		for k in 3:
			var t := (float(k) + 1.0) / 4.0
			_edge(Vector3(x, lerpf(0.22, 0.44, t), 0.04), Vector3(x, lerpf(0.18, 0.40, t), -0.37))

## Engine bay: the raised louvred lid down the middle and the two shoulder ear intakes
## either side of it, each with its own slats. Six lid slats is what the car has and what
## reads without turning into a solid block at 100 px.
func _deck() -> void:
	_loop([Vector3(-0.34, 0.78, DECK_Z0), Vector3(0.34, 0.78, DECK_Z0),
		Vector3(0.38, 0.75, DECK_Z1), Vector3(-0.38, 0.75, DECK_Z1)])
	for k in 6:
		var t := (float(k) + 0.5) / 6.0
		var z := lerpf(DECK_Z0, DECK_Z1, t)
		var w := lerpf(0.34, 0.38, t)
		var y := lerpf(0.78, 0.75, t)
		_edge(Vector3(-w, y, z), Vector3(w, y, z))
	for sx in [-1.0, 1.0]:
		var xi: float = sx * 0.46
		var xo: float = sx * 0.66
		# the ear: a box let into the shoulder, falling away toward the tail
		_loop([Vector3(xi, 0.78, -0.72), Vector3(xo, 0.74, -0.72),
			Vector3(xo, 0.68, -1.04), Vector3(xi, 0.72, -1.04)])
		for k in 3:
			var t := (float(k) + 1.0) / 4.0
			_edge(Vector3(lerpf(xi, xo, t), lerpf(0.78, 0.74, t), -0.74),
				Vector3(lerpf(xi, xo, t), lerpf(0.72, 0.68, t), -1.02))

## THE WING. A broad blade carried clear of the engine lid on two pylons, and NOT flat:
## the centre sits at 0.955 and the tips at 1.06, so the span reads as a shallow V from
## behind. That V is the single most recognisable thing about the car from this angle, and
## the plank the original drew is why it never looked like a Countach.
## Span pulled in to 0.70 against the body's 0.80: the wing sits 0.7 units NEARER the camera
## than the rear arches do, so at CRUISE's focal length a wing built to the same half-width as
## the arches projects visibly wider than the car and reads as a shelf bolted on.
## Rise from 0.945 at the centre to 1.09 at the tips -- 18 cm across the half span. The real
## blade's kink is shallower than that; this is the one place the drawing is louder than the
## car, because the V is what the eye uses to name it and a subtle one vanishes at 100 px.
const WING_X := [-0.70, -0.38, 0.0, 0.38, 0.70]
const WING_Y := [1.09, 0.975, 0.945, 0.975, 1.09]
const WING_LEAD := -1.28
const WING_TRAIL := -1.62
const WING_THICK := 0.035

func _wing() -> void:
	var lead: Array[Vector3] = []
	var trail: Array[Vector3] = []
	for i in WING_X.size():
		lead.append(Vector3(WING_X[i], WING_Y[i], WING_LEAD))
		trail.append(Vector3(WING_X[i], WING_Y[i], WING_TRAIL))
	for i in lead.size() - 1:
		_edge(lead[i], lead[i + 1])
		_edge(trail[i], trail[i + 1])
		_edge(lead[i] - Vector3(0.0, WING_THICK, 0.0), lead[i + 1] - Vector3(0.0, WING_THICK, 0.0))
	for i in lead.size():
		_edge(lead[i], trail[i])
		_edge(lead[i], lead[i] - Vector3(0.0, WING_THICK, 0.0))
	# End fairings, hanging BELOW each tip. Standing them up instead turns the tips into two
	# goalposts either side of the car, which is the one thing this wing must not look like.
	for i in [0, WING_X.size() - 1]:
		var tip: Vector3 = lead[i]
		var back: Vector3 = trail[i]
		var drop := Vector3(0.0, 0.075, 0.0)
		_loop([tip, back, back - drop, tip - drop])
	# pylons: flat blades off the deck, raked back the way the real ones are
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.32
		_loop([Vector3(x, 0.76, -1.14), Vector3(x, 0.955, WING_LEAD),
			Vector3(x, 0.955, WING_TRAIL), Vector3(x, 0.74, -1.44)])

## Tail lights: one slanted housing per side, each split into three lamps. The housing
## falls as it runs inboard -- outer corner at 0.58, inner at 0.50 -- so the pair point
## down into the exhaust bay between them, which is the line the whole tail is built on.
const LIGHT_OUT_X := 0.60
const LIGHT_IN_X := 0.24
const LIGHT_OUT_TOP := 0.58
const LIGHT_OUT_BOT := 0.42
const LIGHT_IN_TOP := 0.50
const LIGHT_IN_BOT := 0.34

func _lights() -> void:
	for sx in [-1.0, 1.0]:
		var z := TAIL_Z - 0.01
		_loop([Vector3(sx * LIGHT_OUT_X, LIGHT_OUT_TOP, z), Vector3(sx * LIGHT_IN_X, LIGHT_IN_TOP, z),
			Vector3(sx * LIGHT_IN_X, LIGHT_IN_BOT, z), Vector3(sx * LIGHT_OUT_X, LIGHT_OUT_BOT, z)])
		# three lamps, cut across the slant so each one keeps the housing's angle
		for k in 3:
			var t0 := float(k) / 3.0 + 0.05
			var t1 := float(k + 1) / 3.0 - 0.05
			var lens := z - 0.01
			_loop([
				Vector3(sx * lerpf(LIGHT_OUT_X, LIGHT_IN_X, t0), lerpf(LIGHT_OUT_TOP, LIGHT_IN_TOP, t0) - 0.02, lens),
				Vector3(sx * lerpf(LIGHT_OUT_X, LIGHT_IN_X, t1), lerpf(LIGHT_OUT_TOP, LIGHT_IN_TOP, t1) - 0.02, lens),
				Vector3(sx * lerpf(LIGHT_OUT_X, LIGHT_IN_X, t1), lerpf(LIGHT_OUT_BOT, LIGHT_IN_BOT, t1) + 0.02, lens),
				Vector3(sx * lerpf(LIGHT_OUT_X, LIGHT_IN_X, t0), lerpf(LIGHT_OUT_BOT, LIGHT_IN_BOT, t0) + 0.02, lens),
			])

## The bay under the tail panel, and the four pipes in it. Each pipe is a hexagon at the
## mouth with a second ring set forward, so it reads as a tube pointing at the camera
## rather than as a dot.
func _exhaust() -> void:
	var z := TAIL_Z + 0.02
	_loop([Vector3(-0.30, 0.34, z), Vector3(0.30, 0.34, z),
		Vector3(0.30, 0.14, z), Vector3(-0.30, 0.14, z)])
	for sx in [-1.0, 1.0]:   # bay depth, back to the valance
		_edge(Vector3(sx * 0.30, 0.34, z), Vector3(sx * 0.26, 0.32, z + 0.10))
		_edge(Vector3(sx * 0.30, 0.14, z), Vector3(sx * 0.26, 0.16, z + 0.10))
	for x in [-0.20, -0.085, 0.085, 0.20]:
		var mouth: Array[Vector3] = []
		var inner: Array[Vector3] = []
		for k in 6:
			var a := TAU * float(k) / 6.0
			var p := Vector3(x + cos(a) * 0.055, 0.24 + sin(a) * 0.055, z - 0.01)
			mouth.append(p)
			inner.append(p + Vector3(0.0, 0.0, 0.08))
		_loop(mouth)
		for k in range(0, 6, 2):
			_edge(mouth[k], inner[k])

## Arches. The rear pair is drawn TWICE -- an inboard arc and an outboard one, rungged
## together -- because the flare has real width on this car and a single arc reads as a
## line drawn on a flat flank.
func _arches() -> void:
	for sx in [-1.0, 1.0]:
		_arc(sx * FRONT_OUT, AXLE_FRONT, FRONT_R + 0.05, 0.10)
		var outer := _arc(sx * (REAR_OUT + 0.02), AXLE_REAR, REAR_R + 0.09, 0.10)
		var inner := _arc(sx * 0.60, AXLE_REAR, REAR_R + 0.05, 0.10)
		for k in range(0, outer.size(), 2):
			_edge(outer[k], inner[k])

## One arch arc on a flank plane, returned so the caller can rung two of them together.
func _arc(x: float, az: float, r: float, y0: float) -> Array[Vector3]:
	var pts: Array[Vector3] = []
	for k in 9:
		var a := PI * float(k) / 8.0
		pts.append(Vector3(x, y0 + sin(a) * r, az + cos(a) * r))
	for k in pts.size() - 1:
		_edge(pts[k], pts[k + 1])
	return pts

## Octagons, like the original -- but each tyre is two of them, on its inboard and outboard
## planes, joined round the tread. The rear pair is 0.28 units wide against the front's
## 0.18, which is the 345/35 against the 225/50, and it is most of what "stance" means here.
func _tyres() -> void:
	for sx in [-1.0, 1.0]:
		_tyre(sx * FRONT_IN, sx * FRONT_OUT, AXLE_FRONT, FRONT_R)
		_tyre(sx * REAR_IN, sx * REAR_OUT, AXLE_REAR, REAR_R)

func _tyre(x_in: float, x_out: float, az: float, r: float) -> void:
	var inner: Array[Vector3] = []
	var outer: Array[Vector3] = []
	for k in 8:
		var a := TAU * float(k) / 8.0
		var y := r + sin(a) * r
		var z := az + cos(a) * r
		inner.append(Vector3(x_in, y, z))
		outer.append(Vector3(x_out, y, z))
	_loop(inner)
	_loop(outer)
	for k in range(0, 8, 2):
		_edge(inner[k], outer[k])
	var hub := Vector3(x_out, r, az)
	for k in range(0, 8, 2):
		_edge(hub, outer[k])

# --- check -----------------------------------------------------------------
## The silhouette, asserted. Every one of these is a thing that was WRONG about the old car
## or a thing a careless edit would quietly undo, and all of it is pure geometry, so it runs
## in the suite without a viewport. Called from test_viz_fps.
static func model_test() -> bool:
	var car := CountachS.new()
	var old := Countach.new()
	var e := car.edges()
	var n_new := e.size() / 2
	var n_old := old.edges().size() / 2
	old.free()
	car.free()
	if e.is_empty() or e.size() % 2 != 0:
		return false
	var top := -99.0
	var top_x := 0.0
	var low := 99.0
	var rear_w := 0.0
	var front_w := 0.0
	var deck_slats := 0
	for i in e.size():
		var p := e[i]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return false
		if p.y > top:
			top = p.y
			top_x = absf(p.x)
		low = minf(low, p.y)
		if p.z < -0.9:
			rear_w = maxf(rear_w, absf(p.x))
		elif p.z > 0.9:
			front_w = maxf(front_w, absf(p.x))
	# horizontal lines lying across the engine lid: the louvres
	var i := 0
	while i < e.size():
		var a := e[i]
		var b := e[i + 1]
		if a.y > 0.70 and a.y < 0.82 and absf(a.y - b.y) < 0.001 \
				and absf(a.z - b.z) < 0.001 and a.z < DECK_Z0 + 0.01 and a.z > DECK_Z1 - 0.01 \
				and absf(b.x - a.x) > 0.5:
			deck_slats += 1
		i += 2
	return (
		n_new > n_old                      # denser than the car it replaces
		and n_new < 700                    # ... but still a vector drawing, not a mesh
		and low > -0.001                   # nothing under the road
		and top > 1.0                      # the wing clears the 0.86 roof
		and top_x > 0.6                    # and its HIGHEST point is a tip: that is the V
		and rear_w > front_w + 0.05        # rear track and flares wider than the front
		and deck_slats >= 6                # engine lid louvres
	)
