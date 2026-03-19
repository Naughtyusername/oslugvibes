package slugvibes

import "core:math"

// ===================================================
// Text effect drawing procs — per-character manipulation
// All CPU-side vertex data, zero shader changes needed.
// ===================================================

// --- HSV to RGB conversion for color cycling ---

hsv_to_rgb :: proc(h, s, v: f32) -> [3]f32 {
	c := v * s
	hp := math.mod(h / 60.0, 6.0)
	x := c * (1.0 - abs(math.mod(hp, 2.0) - 1.0))
	m := v - c

	r, g, b: f32
	if hp <
	   1 {r, g, b = c, x, 0} else if hp < 2 {r, g, b = x, c, 0} else if hp < 3 {r, g, b = 0, c, x} else if hp < 4 {r, g, b = 0, x, c} else if hp < 5 {r, g, b = x, 0, c} else {r, g, b = c, 0, x}

	return {r + m, g + m, b + m}
}

// --- Per-character color cycling ---
// Each character gets a rainbow hue offset by its position in the string.

draw_text_rainbow :: proc(
	ctx: ^Slug_Context,
	text: string,
	x, y: f32,
	font_size: f32,
	time: f32,
	speed: f32, // hue rotation speed (degrees/sec)
	spread: f32, // hue offset per character (degrees)
) {
	font := slug_active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		hue := math.mod(time * speed + f32(char_idx) * spread, 360.0)
		rgb := hsv_to_rgb(hue, 1.0, 1.0)
		color := [4]f32{rgb.x, rgb.y, rgb.z, 1.0}

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Per-character wobble ---
// Each character bobs up and down with a sine wave offset.

draw_text_wobble :: proc(
	ctx: ^Slug_Context,
	text: string,
	x, y: f32,
	font_size: f32,
	time: f32,
	amplitude: f32, // max vertical displacement in pixels
	frequency: f32, // wave speed
	phase_step: f32, // phase offset per character
) {
	font := slug_active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		y_offset := math.sin(time * frequency + f32(char_idx) * phase_step) * amplitude

		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := (y + y_offset) - g.bbox_max.y * font_size
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		// Rainbow color on wobble too
		hue := math.mod(time * 120.0 + f32(char_idx) * 25.0, 360.0)
		rgb := hsv_to_rgb(hue, 0.8, 1.0)
		color := [4]f32{rgb.x, rgb.y, rgb.z, 1.0}

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Per-character shake ---
// Each character jitters randomly, like damage text or an earthquake effect.

draw_text_shake :: proc(
	ctx: ^Slug_Context,
	text: string,
	x, y: f32,
	font_size: f32,
	intensity: f32, // max displacement in pixels
	time: f32, // used to vary the shake over time
) {
	font := slug_active_font(ctx)
	pen_x := x
	char_idx := 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		// Deterministic pseudo-random shake based on char index and time
		// Using sin/cos with prime multipliers for cheap "randomness"
		seed := f32(char_idx) * 7.13 + time * 31.7
		dx := math.sin(seed * 3.7) * intensity
		dy := math.cos(seed * 5.3) * intensity

		glyph_x := pen_x + g.bbox_min.x * font_size + dx
		glyph_y := (y - g.bbox_max.y * font_size) + dy
		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, [4]f32{1.0, 0.3, 0.3, 1.0})
		}

		pen_x += g.advance_width * font_size
		char_idx += 1
	}
}

// --- Rotating text ---
// Renders text rotated around a center point.

draw_text_rotated :: proc(
	ctx: ^Slug_Context,
	text: string,
	cx, cy: f32, // center of rotation in screen space
	font_size: f32,
	angle: f32, // radians
	color: [4]f32,
) {
	font := slug_active_font(ctx)

	// Measure total width to center the text
	total_w, text_h := measure_text(font, text, font_size)

	cos_a := math.cos(angle)
	sin_a := math.sin(angle)

	// 2x2 rotation+scale matrix: maps em-space to screen-space
	// font_size scales em coords to pixels, rotation rotates them
	xform := matrix[2, 2]f32{
		cos_a * font_size, -sin_a * font_size, 
		sin_a * font_size, cos_a * font_size, 
	}

	// Walk characters, computing each glyph's position relative to text center
	pen_x: f32 = -total_w * 0.5 // start offset so text is centered

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		// Glyph center in un-rotated text-local coordinates
		em_cx := (g.bbox_min.x + g.bbox_max.x) * 0.5
		em_cy := (g.bbox_min.y + g.bbox_max.y) * 0.5
		local_x := pen_x + em_cx * font_size
		local_y := -em_cy * font_size + text_h * 0.5 // center vertically, flip Y

		// Rotate to screen space
		screen_x := cx + local_x * cos_a - local_y * sin_a
		screen_y := cy + local_x * sin_a + local_y * cos_a

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, screen_x, screen_y, xform, color)
		}

		pen_x += g.advance_width * font_size
	}
}

// --- Text on a circular path ---
// Each character is positioned along a circle, rotated to follow the tangent.

draw_text_on_circle :: proc(
	ctx: ^Slug_Context,
	text: string,
	cx, cy: f32, // circle center
	radius: f32, // circle radius
	start_angle: f32, // starting angle in radians
	font_size: f32,
	color: [4]f32,
) {
	font := slug_active_font(ctx)

	// Total angular span: each character's advance width maps to an arc
	pen_angle := start_angle

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		// Arc length per character → angle
		advance_arc := g.advance_width * font_size
		char_angle := advance_arc / radius

		// Position at midpoint of this character's arc
		mid_angle := pen_angle + char_angle * 0.5
		pos_x := cx + radius * math.cos(mid_angle)
		pos_y := cy + radius * math.sin(mid_angle)

		// Tangent direction (perpendicular to radius, pointing along the arc)
		tangent_angle := mid_angle + math.PI * 0.5
		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size, 
			sin_t * font_size, cos_t * font_size, 
		}

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, pos_x, pos_y, xform, color)
		}

		pen_angle += char_angle
	}
}

// --- Text on a sine wave path ---

draw_text_on_wave :: proc(
	ctx: ^Slug_Context,
	text: string,
	x, y: f32, // starting position
	font_size: f32,
	amplitude: f32, // wave height in pixels
	wavelength: f32, // pixels per full cycle
	phase: f32, // phase offset (animated with time)
	color: [4]f32,
) {
	font := slug_active_font(ctx)
	pen_x := x
	freq := math.TAU / wavelength

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS do continue
		g := &font.glyphs[idx]
		if !g.valid do continue

		// Position on wave
		wave_y := amplitude * math.sin(freq * pen_x + phase)
		// Tangent of the wave: dy/dx = amplitude * freq * cos(freq * x + phase)
		slope := amplitude * freq * math.cos(freq * pen_x + phase)
		tangent_angle := math.atan(slope)

		cos_t := math.cos(tangent_angle)
		sin_t := math.sin(tangent_angle)

		xform := matrix[2, 2]f32{
			cos_t * font_size, -sin_t * font_size, 
			sin_t * font_size, cos_t * font_size, 
		}

		em_cx := (g.bbox_min.x + g.bbox_max.x) * 0.5

		screen_x := pen_x + em_cx * font_size * cos_t
		screen_y := (y + wave_y) + em_cx * font_size * sin_t

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad_transformed(ctx, g, screen_x, screen_y, xform, color)
		}

		pen_x += g.advance_width * font_size
	}
}

// --- Scrolling combat log ---

MAX_LOG_ENTRIES :: 32
LOG_FONT_SIZE :: f32(16.0)
LOG_LINE_HEIGHT :: f32(22.0)
LOG_FADE_TIME :: f32(5.0) // seconds before entries start fading

Combat_Log_Entry :: struct {
	text:  [128]u8,
	len:   int,
	color: [4]f32,
	age:   f32,
}

Combat_Log :: struct {
	entries: [MAX_LOG_ENTRIES]Combat_Log_Entry,
	count:   int,
	head:    int, // ring buffer head
}

combat_log_messages := [?]string {
	"You strike the goblin for %d damage!",
	"The skeleton misses you!",
	"You find a potion of healing.",
	"Critical hit! %d damage!",
	"The dragon breathes fire!",
	"You dodge the arrow.",
	"Level up! You are now level %d.",
	"You pick up %d gold coins.",
	"The trap deals %d damage!",
	"You cast fireball for %d damage!",
}

combat_log_colors := [?][4]f32 {
	{1.0, 0.8, 0.8, 1.0}, // damage dealt (light red)
	{0.7, 0.7, 0.7, 1.0}, // miss (gray)
	{0.5, 1.0, 0.5, 1.0}, // item found (green)
	{1.0, 1.0, 0.3, 1.0}, // crit (yellow)
	{1.0, 0.4, 0.2, 1.0}, // dragon (orange)
	{0.6, 0.8, 1.0, 1.0}, // dodge (light blue)
	{1.0, 1.0, 0.6, 1.0}, // level up (bright yellow)
	{1.0, 0.85, 0.0, 1.0}, // gold (gold)
	{1.0, 0.3, 0.3, 1.0}, // trap (red)
	{0.8, 0.4, 1.0, 1.0}, // spell (purple)
}

combat_log_add :: proc(log: ^Combat_Log, text: string, color: [4]f32) {
	entry := &log.entries[log.head]
	copy_len := min(len(text), len(entry.text))
	copy(entry.text[:copy_len], text[:copy_len])
	entry.len = copy_len
	entry.color = color
	entry.age = 0

	log.head = (log.head + 1) % MAX_LOG_ENTRIES
	if log.count < MAX_LOG_ENTRIES {
		log.count += 1
	}
}

combat_log_update :: proc(log: ^Combat_Log, dt: f32) {
	for i in 0 ..< log.count {
		// Ring buffer index math: head points past the newest entry, so
		// (head - count) is the oldest. Double-mod handles negative wraparound.
		idx := ((log.head - log.count + i) % MAX_LOG_ENTRIES + MAX_LOG_ENTRIES) % MAX_LOG_ENTRIES
		log.entries[idx].age += dt
	}
}

combat_log_draw :: proc(ctx: ^Slug_Context, log: ^Combat_Log, panel_x, panel_y, panel_h: f32) {
	// Draw entries from oldest (top) to newest (bottom)
	max_visible := int(panel_h / LOG_LINE_HEIGHT)
	visible_count := min(log.count, max_visible)

	for i in 0 ..< visible_count {
		// Index from newest backwards
		entry_idx :=
			((log.head - visible_count + i) % MAX_LOG_ENTRIES + MAX_LOG_ENTRIES) % MAX_LOG_ENTRIES
		entry := &log.entries[entry_idx]

		y := panel_y + f32(i) * LOG_LINE_HEIGHT

		// Fade old entries
		alpha: f32 = 1.0
		if entry.age > LOG_FADE_TIME {
			alpha = max(0.0, 1.0 - (entry.age - LOG_FADE_TIME) / 3.0)
		}
		if alpha <= 0 do continue

		color := entry.color
		color.a = alpha

		text := string(entry.text[:entry.len])
		slug_draw_text(ctx, text, panel_x, y, LOG_FONT_SIZE, color)
	}
}
