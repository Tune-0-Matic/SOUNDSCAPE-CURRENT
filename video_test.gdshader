shader_type canvas_item;
// "Video TEST" picture, in one of two colour modes (VideoTest.ColorMode, the TBS VIDEO COLOR row):
//   ORIGINAL -- the proxy's own RGB, straight through: no palette, no quantizing, no scanlines.
//   PALETTE  -- crushed to four stops of the active palette (2-bit) by a 4x4 Bayer ordered
//               dither, under hard scanlines: a terminal drawn in the skin's own colours.
//
// The palette is a ramp texture, dark to light: the skin's screen -> accent -> screen text
// (Skins.video_ramp), or the user gradient picked on the VISUAL tab (player.gd
// _video_palette). The kick lifts every stop up the ramp, so the picture flushes toward the
// palette's bright end on the beat, and the four stops never merge: the top one is already
// at the end and the rest close in on it.
//
// The dither is indexed by SOURCE TEXEL, not by screen pixel. The proxy is only VIDEO_W
// texels wide (audio_engine.gd) and drawn NEAREST, so every texel is already a fat block on
// screen; a screen-space pattern would crawl across those blocks whenever the visualizer
// cell is resized, where a texel-space one scales with the picture. Scanlines, as in
// crt.gdshader, are the one thing that stays in screen space.

const int MODE_ORIGINAL = 0;
const int MODE_PALETTE = 1;

uniform int color_mode : hint_range(0, 1) = 1;           // MODE_ORIGINAL or MODE_PALETTE
uniform int levels : hint_range(2, 8) = 4;                // stops taken from the ramp; 4 is 2-bit
// NEAREST: the four stops are read at exact offsets, so blending neighbouring texels buys nothing
uniform sampler2D ramp : source_color, filter_nearest, repeat_disable;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;         // kick energy, VideoTest.kick()
uniform float pulse_depth : hint_range(0.0, 1.0) = 0.35;  // how far a full kick lifts the stops
uniform float scan_strength : hint_range(0.0, 1.0) = 0.35;
uniform float scan_period : hint_range(2.0, 12.0) = 3.0;

const float BAYER[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };

void fragment() {
	if (color_mode == MODE_ORIGINAL) {
		COLOR = vec4(texture(TEXTURE, UV).rgb, 1.0);
	} else {
		vec2 texel = floor(UV / TEXTURE_PIXEL_SIZE);
		vec3 src = texture(TEXTURE, (texel + 0.5) * TEXTURE_PIXEL_SIZE).rgb;
		float lum = dot(src, vec3(0.299, 0.587, 0.114));
		ivec2 b = ivec2(mod(texel, 4.0));
		float steps = float(levels - 1);
		// ordered dither: the fraction between two stops becomes the share of cells that round up
		float stop = clamp(floor(lum * steps + (BAYER[b.y * 4 + b.x] + 0.5) / 16.0) / steps, 0.0, 1.0);
		vec3 col = texture(ramp, vec2(mix(stop, 1.0, pulse * pulse_depth), 0.5)).rgb;
		float lit = step(scan_period * 0.5, mod(FRAGCOORD.y, scan_period));
		COLOR = vec4(col * mix(1.0 - scan_strength, 1.0, lit), 1.0);
	}
}
