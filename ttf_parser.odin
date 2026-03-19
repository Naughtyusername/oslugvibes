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

	// Calculate em scale: we normalize everything to em-space [0, ~1]
	// units_per_em = ascent - descent (approximately)
	units_per_em := f32(ascent_raw - descent_raw)
	font.em_scale = 1.0 / units_per_em
	font.ascent = f32(ascent_raw) * font.em_scale
	font.descent = f32(descent_raw) * font.em_scale
	font.line_gap = f32(line_gap_raw) * font.em_scale

	fmt.printf("Font loaded: ascent=%.3f descent=%.3f line_gap=%.3f em_scale=%.6f\n",
		font.ascent, font.descent, font.line_gap, font.em_scale)

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
	if g.valid do return true  // Already loaded

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
	// stb_truetype gives us: vmove (start contour), vline, vcurve (quadratic), vcubic (skip)
	// We need all curves to be quadratic Bezier curves.

	// stb_truetype vertex type constants (byte values)
	STBTT_VMOVE  :: 1
	STBTT_VLINE  :: 2
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
			// Skip cubic curves for v1 (PostScript/CFF fonts)
			continue

		case STBTT_VMOVE:
			// Start of new contour — nothing to draw yet
			continue
		}
	}

	g.valid = true
	return true
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
