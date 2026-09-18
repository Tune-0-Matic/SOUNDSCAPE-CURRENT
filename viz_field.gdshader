shader_type canvas_item;
// Colours the two visualizer modes that draw a FIELD of values rather than a set of rects:
// WATERFALL (a scrolling spectrogram) and FIRE (a heat grid).
//
// Both used to build their pixels in GDScript: a Color per cell per frame, three lerps deep for
// FIRE, then Image.set_pixel and an upload. That is 32 x 96 and 56 x 40 Color objects a frame
// built on the main thread to produce an image the GPU was going to upscale anyway. Now the CPU
// writes one BYTE per cell -- the magnitude, which is the only thing it actually knows -- and
// every colour decision happens here.
//
// The palette arrives as a 1 x N strip sampled from the same Visualizer.color_at() the bar modes
// use, so gradients, the rainbow and the colour animations all reach these two modes unchanged.
// A side effect worth having: the palette applies to the WHOLE history every frame, so changing
// gradient recolours the waterfall you already have instead of only the rows yet to arrive.

// 0 = waterfall, 1 = fire
uniform int field_mode : hint_range(0, 1) = 0;
uniform sampler2D palette : repeat_disable, filter_linear;
// Where the newest waterfall row sits in the ring, 0..1. The texture is a ring buffer, so the
// shader rotates it rather than the CPU shifting 96 rows of pixels every frame.
uniform float scroll = 0.0;
// FIRE blows out to white at the top of its range; below this the flame keeps its colour.
uniform float white_at = 0.78;

void fragment() {
	vec2 uv = UV;
	if (field_mode == 0) {
		// oldest row at the top: walk backwards from the write head, wrapping
		uv.y = fract(uv.y + scroll);
	}
	float v = texture(TEXTURE, uv).r;
	vec3 accent = texture(palette, vec2(UV.x, 0.5)).rgb;
	if (field_mode == 0) {
		// squared before it was stored: linear alpha made every cell bright and the display
		// read as a solid wall of colour rather than a spectrogram
		COLOR = vec4(accent * v, v * 0.9);
	} else {
		// black -> accent -> white, with the white stop held back to the top of the range so
		// the body of the flame keeps its colour instead of blowing out
		vec3 col = mix(vec3(0.0), accent, min(v * 1.8, 1.0));
		col = mix(col, vec3(1.0), clamp((v - white_at) * 4.0, 0.0, 1.0));
		COLOR = vec4(col, clamp(v * 1.5, 0.0, 1.0));
	}
}
