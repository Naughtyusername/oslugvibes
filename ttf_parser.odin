package slugvibes

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import stbtt "vendor:stb/truetype"

// ===================================================
// TTF font loading via stb_truetype
// ===================================================

font_load :: proc(path: string) -> (font: Font, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read font file:", path)
		return {}, false
	}
	font.font_data = data

	// Initialize stb_truetype
	info := &font.info
	if stbtt.InitFont(info, raw_data(data), 0) == false {
		fmt.eprintln("Failed to parse font:", path)
		delete(data)
		return {}, false
	}

	// Get font vertical metrics (in font units)
	ascent_raw, descent_raw, line_gap_raw: c.int
	stbtt.GetFontVMetrics(info, &ascent_raw, &descent_raw, &line_gap_raw)

	// Normalize all coordinates to em-space where the full ascent-to-descent
	// range is ~1.0. This keeps curve control points in a consistent range
	// regardless of the font's internal units (typically 1000 or 2048 per em).
	// The font_size parameter at draw time scales em-space back to pixels.
	units_per_em := f32(ascent_raw - descent_raw)
	font.em_scale = 1.0 / units_per_em
	font.ascent = f32(ascent_raw) * font.em_scale
	font.descent = f32(descent_raw) * font.em_scale
	font.line_gap = f32(line_gap_raw) * font.em_scale

	fmt.printf(
		"Font loaded: ascent=%.3f descent=%.3f line_gap=%.3f em_scale=%.6f\n",
		font.ascent,
		font.descent,
		font.line_gap,
		font.em_scale,
	)

	return font, true
}

font_destroy :: proc(font: ^Font) {
	for &g in font.glyphs {
		glyph_data_destroy(&g)
	}
	delete(font.font_data)
	font^ = {}
}

glyph_data_destroy :: proc(g: ^Glyph_Data) {
	delete(g.curves)
	delete(g.h_bands)
	delete(g.v_bands)
	delete(g.h_curve_lists)
	delete(g.v_curve_lists)
	g^ = {}
}

// Load a single glyph's outline and metrics
font_load_glyph :: proc(font: ^Font, codepoint: rune) -> bool {
	idx := int(codepoint)
	if idx < 0 || idx >= MAX_CACHED_GLYPHS do return false

	g := &font.glyphs[idx]
	if g.valid do return true // Already loaded

	info := &font.info

	// Get glyph index
	glyph_index := stbtt.FindGlyphIndex(info, codepoint)
	if glyph_index == 0 && codepoint != 0 {
		// Glyph not found in font (0 is the .notdef glyph)
		return false
	}

	g.codepoint = codepoint
	g.glyph_index = c.int(glyph_index)

	// Get horizontal metrics
	advance_raw, lsb_raw: c.int
	stbtt.GetGlyphHMetrics(info, c.int(glyph_index), &advance_raw, &lsb_raw)
	g.advance_width = f32(advance_raw) * font.em_scale
	g.left_bearing = f32(lsb_raw) * font.em_scale

	// Get bounding box
	x0, y0, x1, y1: c.int
	if stbtt.GetGlyphBox(info, c.int(glyph_index), &x0, &y0, &x1, &y1) == 0 {
		// Empty glyph (e.g. space) — still valid, just no curves
		g.bbox_min = {f32(0), f32(0)}
		g.bbox_max = {g.advance_width, font.ascent - font.descent}
		g.valid = true
		return true
	}

	g.bbox_min = {f32(x0) * font.em_scale, f32(y0) * font.em_scale}
	g.bbox_max = {f32(x1) * font.em_scale, f32(y1) * font.em_scale}

	// Get glyph shape (contours as lines + quadratic beziers)
	vertices: [^]stbtt.vertex
	num_vertices := stbtt.GetGlyphShape(info, c.int(glyph_index), &vertices)
	if num_vertices <= 0 {
		g.valid = true
		return true
	}
	defer stbtt.FreeShape(info, vertices)

	// Convert stb_truetype vertices to our Bezier_Curve format.
	// stb_truetype gives us: vmove (start contour), vline, vcurve (quadratic), vcubic.
	// The Slug fragment shader only handles quadratic Beziers, so:
	//   - Lines are promoted to degenerate quadratics (control point at midpoint)
	//   - Cubics are recursively subdivided into quadratic approximations

	// stb_truetype vertex type constants (byte values)
	STBTT_VMOVE :: 1
	STBTT_VLINE :: 2
	STBTT_VCURVE :: 3
	STBTT_VCUBIC :: 4

	verts := vertices[:num_vertices]
	for i := 0; i < len(verts); i += 1 {
		v := verts[i]

		switch v.type {
		case STBTT_VLINE:
			// Promote line to degenerate quadratic Bezier
			if i == 0 do continue
			prev := verts[i - 1]
			p1 := [2]f32{f32(prev.x) * font.em_scale, f32(prev.y) * font.em_scale}
			p3 := [2]f32{f32(v.x) * font.em_scale, f32(v.y) * font.em_scale}
			// Middle control point = midpoint of endpoints
			p2 := [2]f32{(p1.x + p3.x) * 0.5, (p1.y + p3.y) * 0.5}
			append(&g.curves, Bezier_Curve{p1, p2, p3})

		case STBTT_VCURVE:
			// Quadratic Bezier curve
			if i == 0 do continue
			prev := verts[i - 1]
			p1 := [2]f32{f32(prev.x) * font.em_scale, f32(prev.y) * font.em_scale}
			p2 := [2]f32{f32(v.cx) * font.em_scale, f32(v.cy) * font.em_scale}
			p3 := [2]f32{f32(v.x) * font.em_scale, f32(v.y) * font.em_scale}
			append(&g.curves, Bezier_Curve{p1, p2, p3})

		case STBTT_VCUBIC:
			// Convert cubic Bezier to quadratic approximation(s)
			if i == 0 do continue
			prev := verts[i - 1]
			cp0 := [2]f32{f32(prev.x) * font.em_scale, f32(prev.y) * font.em_scale}
			cp1 := [2]f32{f32(v.cx) * font.em_scale, f32(v.cy) * font.em_scale}
			cp2 := [2]f32{f32(v.cx1) * font.em_scale, f32(v.cy1) * font.em_scale}
			cp3 := [2]f32{f32(v.x) * font.em_scale, f32(v.y) * font.em_scale}
			cubic_to_quadratics(cp0, cp1, cp2, cp3, &g.curves, 0.001)

		case STBTT_VMOVE:
			// Start of new contour — nothing to draw yet
			continue
		}
	}

	g.valid = true
	return true
}

// Get kerning adjustment between two glyphs (in em-space units).
// Returns the horizontal offset to add after the first glyph's advance width.
// Negative values mean the glyphs should be pulled closer together.
font_get_kerning :: proc(font: ^Font, left, right: rune) -> f32 {
	left_idx := int(left)
	right_idx := int(right)
	if left_idx < 0 || left_idx >= MAX_CACHED_GLYPHS do return 0
	if right_idx < 0 || right_idx >= MAX_CACHED_GLYPHS do return 0

	gl := &font.glyphs[left_idx]
	gr := &font.glyphs[right_idx]
	if !gl.valid || !gr.valid do return 0

	kern_raw := stbtt.GetGlyphKernAdvance(&font.info, c.int(gl.glyph_index), c.int(gr.glyph_index))
	return f32(kern_raw) * font.em_scale
}

// Load all ASCII printable glyphs (32-126)
font_load_ascii :: proc(font: ^Font) -> int {
	loaded := 0
	for cp := rune(32); cp <= 126; cp += 1 {
		if font_load_glyph(font, cp) {
			loaded += 1
		}
	}
	fmt.printf("Loaded %d ASCII glyphs\n", loaded)
	return loaded
}

// ===================================================
// Cubic-to-quadratic Bezier conversion
// ===================================================
//
// Recursively subdivides a cubic Bezier into quadratic approximations.
// Uses De Casteljau subdivision at t=0.5 when the approximation error
// exceeds the tolerance. Typical glyph cubics need 2-4 quadratics each.

cubic_to_quadratics :: proc(
	p0, p1, p2, p3: [2]f32,
	output: ^[dynamic]Bezier_Curve,
	tolerance: f32,
	depth: int = 0,
) {
	// Maximum recursion depth to prevent infinite subdivision
	MAX_DEPTH :: 8

	// Try to approximate this cubic with a single quadratic.
	// Best-fit quadratic control point: average of the two cubic control points,
	// weighted to minimize error: q1 = (3*p1 - p0 + 3*p2 - p3) / 4
	// But a simpler approximation that works well: q1 = (p1 + p2) * 0.5
	// adjusted toward the cubic's midpoint.

	// Compute midpoint of the cubic via De Casteljau at t=0.5
	mid01 := (p0 + p1) * 0.5
	mid12 := (p1 + p2) * 0.5
	mid23 := (p2 + p3) * 0.5
	mid012 := (mid01 + mid12) * 0.5
	mid123 := (mid12 + mid23) * 0.5
	cubic_mid := (mid012 + mid123) * 0.5

	// Best-fit quadratic control point
	q1 := (p1 * 3.0 - p0 + p2 * 3.0 - p3) * 0.25

	// Quadratic midpoint at t=0.5: (p0 + 2*q1 + p3) / 4
	quad_mid := (p0 + q1 * 2.0 + p3) * 0.25

	// Error = distance between cubic and quadratic midpoints
	err := cubic_mid - quad_mid
	error_sq := err.x * err.x + err.y * err.y

	if error_sq <= tolerance * tolerance || depth >= MAX_DEPTH {
		// Good enough — emit a single quadratic
		append(output, Bezier_Curve{p0, q1, p3})
		return
	}

	// Subdivide cubic at t=0.5 using De Casteljau
	// Left half: (p0, mid01, mid012, cubic_mid)
	// Right half: (cubic_mid, mid123, mid23, p3)
	cubic_to_quadratics(p0, mid01, mid012, cubic_mid, output, tolerance, depth + 1)
	cubic_to_quadratics(cubic_mid, mid123, mid23, p3, output, tolerance, depth + 1)
}
