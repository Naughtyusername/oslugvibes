package slugvibes

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// ===================================================
// Minimal SVG path parser for single-path icons.
//
// Parses the <path d="..."> attribute from simple SVGs (like game-icons.net)
// into Bezier_Curve data that feeds directly into the Slug rendering pipeline.
//
// Supported SVG path commands:
//   M/m  moveto           L/l  lineto           H/h  horizontal line
//   V/v  vertical line    C/c  cubic bezier      S/s  smooth cubic
//   Q/q  quadratic bezier T/t  smooth quadratic  Z/z  closepath
//
// Arc (A/a) is NOT supported — game-icons.net doesn't use arcs.
// ===================================================

SVG_Icon :: struct {
	glyph:     Glyph_Data,
	viewbox_w: f32,
	viewbox_h: f32,
}

svg_icon_destroy :: proc(icon: ^SVG_Icon) {
	glyph_data_destroy(&icon.glyph)
	icon^ = {}
}

// Load an SVG file from disk, parse it, process it for GPU rendering.
svg_load_icon :: proc(path: string) -> (icon: SVG_Icon, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read SVG file:", path)
		return {}, false
	}
	defer delete(data)

	return svg_parse(string(data))
}

// Parse SVG string into an icon with processed glyph data.
svg_parse :: proc(svg_data: string) -> (icon: SVG_Icon, ok: bool) {
	// Extract viewBox dimensions
	vb_x, vb_y, vb_w, vb_h: f32
	if !svg_extract_viewbox(svg_data, &vb_x, &vb_y, &vb_w, &vb_h) {
		// Default to 512x512 (game-icons.net standard)
		vb_x, vb_y, vb_w, vb_h = 0, 0, 512, 512
	}
	icon.viewbox_w = vb_w
	icon.viewbox_h = vb_h

	// Extract path d attribute
	path_d := svg_extract_path_d(svg_data)
	if len(path_d) == 0 {
		fmt.eprintln("SVG: no path d attribute found")
		return {}, false
	}

	// Parse path commands into curves
	// SVG coordinate space: origin top-left, Y down
	// We normalize to [0, 1] and flip Y to match font em-space (Y up)
	svg_parse_path_data(path_d, vb_x, vb_y, vb_w, vb_h, &icon.glyph)

	if len(icon.glyph.curves) == 0 {
		fmt.eprintln("SVG: no curves parsed from path data")
		return {}, false
	}

	// Compute bounding box from actual curves
	svg_compute_bbox(&icon.glyph)

	// Set metrics for rendering (treat as 1em square)
	icon.glyph.advance_width = icon.glyph.bbox_max.x - icon.glyph.bbox_min.x
	icon.glyph.left_bearing = icon.glyph.bbox_min.x
	icon.glyph.valid = true

	// Process: generate bands for spatial acceleration
	glyph_process(&icon.glyph)

	fmt.printf(
		"SVG loaded: %d curves, bbox=(%.3f,%.3f)-(%.3f,%.3f)\n",
		len(icon.glyph.curves),
		icon.glyph.bbox_min.x,
		icon.glyph.bbox_min.y,
		icon.glyph.bbox_max.x,
		icon.glyph.bbox_max.y,
	)

	return icon, true
}

// ===================================================
// XML attribute extraction (minimal, no full XML parser)
// ===================================================

svg_extract_viewbox :: proc(svg: string, x, y, w, h: ^f32) -> bool {
	// Find viewBox="..."
	vb_start := strings.index(svg, "viewBox=\"")
	if vb_start < 0 do return false
	vb_start += len("viewBox=\"")
	vb_end := strings.index(svg[vb_start:], "\"")
	if vb_end < 0 do return false
	vb_str := svg[vb_start:][:vb_end]

	// Parse "x y w h"
	parts := strings.fields(vb_str)
	defer delete(parts)
	if len(parts) != 4 do return false

	x^ = parse_f32(parts[0])
	y^ = parse_f32(parts[1])
	w^ = parse_f32(parts[2])
	h^ = parse_f32(parts[3])
	return w^ > 0 && h^ > 0
}

svg_extract_path_d :: proc(svg: string) -> string {
	// Find d="..." in a <path> element
	d_start := strings.index(svg, " d=\"")
	if d_start < 0 do return ""
	d_start += len(" d=\"")
	d_end := strings.index(svg[d_start:], "\"")
	if d_end < 0 do return ""
	return svg[d_start:][:d_end]
}

// ===================================================
// SVG path data parser
// ===================================================

SVG_Parser :: struct {
	data:      string,
	pos:       int,
	// Current point (absolute SVG coordinates)
	cx, cy:    f32,
	// Start of current subpath (for Z command)
	sx, sy:    f32,
	// Previous control point (for S/T smooth curves)
	prev_cp_x: f32,
	prev_cp_y: f32,
	prev_cmd:  u8, // Previous command letter for smooth continuation
	// Coordinate transform
	vb_x:      f32,
	vb_y:      f32,
	vb_w:      f32,
	vb_h:      f32,
}

svg_parse_path_data :: proc(path_d: string, vb_x, vb_y, vb_w, vb_h: f32, glyph: ^Glyph_Data) {
	p := SVG_Parser {
		data = path_d,
		vb_x = vb_x,
		vb_y = vb_y,
		vb_w = vb_w,
		vb_h = vb_h,
	}

	for p.pos < len(p.data) {
		svg_skip_whitespace_and_commas(&p)
		if p.pos >= len(p.data) do break

		ch := p.data[p.pos]

		// If it's a command letter, consume it
		if svg_is_command(ch) {
			p.pos += 1
			svg_execute_command(&p, ch, glyph)
		} else if svg_is_number_start(ch) {
			// Implicit repeat of previous command
			// After M, implicit repeats become L; after m, becomes l
			repeat_cmd := p.prev_cmd
			if repeat_cmd == 'M' do repeat_cmd = 'L'
			if repeat_cmd == 'm' do repeat_cmd = 'l'
			if repeat_cmd != 0 {
				svg_execute_command(&p, repeat_cmd, glyph)
			} else {
				p.pos += 1 // skip unknown
			}
		} else {
			p.pos += 1 // skip unknown character
		}
	}
}

svg_execute_command :: proc(p: ^SVG_Parser, cmd: u8, glyph: ^Glyph_Data) {
	is_rel := cmd >= 'a' && cmd <= 'z'

	switch cmd {
	case 'M', 'm':
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		if is_rel {
			p.cx += x
			p.cy += y
		} else {
			p.cx = x
			p.cy = y
		}
		p.sx = p.cx
		p.sy = p.cy
		p.prev_cmd = cmd

	case 'L', 'l':
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cx += x
			p.cy += y
		} else {
			p.cx = x
			p.cy = y
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'H', 'h':
		x := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cx += x
		} else {
			p.cx = x
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'V', 'v':
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			p.cy += y
		} else {
			p.cy = y
		}
		svg_emit_line(p, glyph, x0, y0, p.cx, p.cy)
		p.prev_cmd = cmd

	case 'C', 'c':
		c1x := svg_parse_number(p)
		c1y := svg_parse_number(p)
		c2x := svg_parse_number(p)
		c2y := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			c1x += x0
			c1y += y0
			c2x += x0
			c2y += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = c2x
		p.prev_cp_y = c2y
		svg_emit_cubic(p, glyph, x0, y0, c1x, c1y, c2x, c2y, x, y)
		p.prev_cmd = cmd

	case 'S', 's':
		// Smooth cubic: reflect previous control point
		c2x := svg_parse_number(p)
		c2y := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		// Reflect previous cp2 through current point
		c1x, c1y: f32
		if p.prev_cmd == 'C' || p.prev_cmd == 'c' || p.prev_cmd == 'S' || p.prev_cmd == 's' {
			c1x = 2 * p.cx - p.prev_cp_x
			c1y = 2 * p.cy - p.prev_cp_y
		} else {
			c1x = p.cx
			c1y = p.cy
		}
		if is_rel {
			c2x += x0
			c2y += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = c2x
		p.prev_cp_y = c2y
		svg_emit_cubic(p, glyph, x0, y0, c1x, c1y, c2x, c2y, x, y)
		p.prev_cmd = cmd

	case 'Q', 'q':
		cpx := svg_parse_number(p)
		cpy := svg_parse_number(p)
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		if is_rel {
			cpx += x0
			cpy += y0
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = cpx
		p.prev_cp_y = cpy
		svg_emit_quadratic(p, glyph, x0, y0, cpx, cpy, x, y)
		p.prev_cmd = cmd

	case 'T', 't':
		// Smooth quadratic: reflect previous control point
		x := svg_parse_number(p)
		y := svg_parse_number(p)
		x0, y0 := p.cx, p.cy
		cpx, cpy: f32
		if p.prev_cmd == 'Q' || p.prev_cmd == 'q' || p.prev_cmd == 'T' || p.prev_cmd == 't' {
			cpx = 2 * p.cx - p.prev_cp_x
			cpy = 2 * p.cy - p.prev_cp_y
		} else {
			cpx = p.cx
			cpy = p.cy
		}
		if is_rel {
			x += x0
			y += y0
		}
		p.cx = x
		p.cy = y
		p.prev_cp_x = cpx
		p.prev_cp_y = cpy
		svg_emit_quadratic(p, glyph, x0, y0, cpx, cpy, x, y)
		p.prev_cmd = cmd

	case 'Z', 'z':
		// Close path: line back to subpath start
		if p.cx != p.sx || p.cy != p.sy {
			svg_emit_line(p, glyph, p.cx, p.cy, p.sx, p.sy)
		}
		p.cx = p.sx
		p.cy = p.sy
		p.prev_cmd = cmd
	}
}

// ===================================================
// Curve emission — transform from SVG space to em-space
// ===================================================

// Transform SVG coordinate to normalized em-space:
// X: (svg_x - vb_x) / vb_w  → [0, 1]
// Y: flip so Y increases upward: 1.0 - (svg_y - vb_y) / vb_h
svg_to_em :: proc(p: ^SVG_Parser, sx, sy: f32) -> [2]f32 {
	return {(sx - p.vb_x) / p.vb_w, 1.0 - (sy - p.vb_y) / p.vb_h}
}

svg_emit_line :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p3 := svg_to_em(p, x1, y1)
	// Degenerate quadratic: control point at midpoint
	p2 := (p1 + p3) * 0.5
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

svg_emit_quadratic :: proc(p: ^SVG_Parser, glyph: ^Glyph_Data, x0, y0, cpx, cpy, x1, y1: f32) {
	p1 := svg_to_em(p, x0, y0)
	p2 := svg_to_em(p, cpx, cpy)
	p3 := svg_to_em(p, x1, y1)
	append(&glyph.curves, Bezier_Curve{p1, p2, p3})
}

svg_emit_cubic :: proc(
	p: ^SVG_Parser,
	glyph: ^Glyph_Data,
	x0, y0, c1x, c1y, c2x, c2y, x1, y1: f32,
) {
	// Convert to em-space then subdivide cubic into quadratic approximations
	cp0 := svg_to_em(p, x0, y0)
	cp1 := svg_to_em(p, c1x, c1y)
	cp2 := svg_to_em(p, c2x, c2y)
	cp3 := svg_to_em(p, x1, y1)
	cubic_to_quadratics(cp0, cp1, cp2, cp3, &glyph.curves, 0.001)
}

// ===================================================
// Bounding box computation from curves
// ===================================================

svg_compute_bbox :: proc(glyph: ^Glyph_Data) {
	if len(glyph.curves) == 0 do return

	min_x := max(f32)
	min_y := max(f32)
	max_x := min(f32)
	max_y := min(f32)

	for &curve in glyph.curves {
		for pt in ([3][2]f32{curve.p1, curve.p2, curve.p3}) {
			min_x = math.min(min_x, pt.x)
			min_y = math.min(min_y, pt.y)
			max_x = math.max(max_x, pt.x)
			max_y = math.max(max_y, pt.y)
		}
	}

	glyph.bbox_min = {min_x, min_y}
	glyph.bbox_max = {max_x, max_y}
}

// ===================================================
// Tokenizer helpers
// ===================================================

svg_skip_whitespace_and_commas :: proc(p: ^SVG_Parser) {
	for p.pos < len(p.data) {
		ch := p.data[p.pos]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' {
			p.pos += 1
		} else {
			break
		}
	}
}

svg_is_command :: proc(ch: u8) -> bool {
	switch ch {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v':
		return true
	case 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't':
		return true
	case 'A', 'a':
		// Arc — not implemented but recognized
		return true
	case 'Z', 'z':
		return true
	}
	return false
}

svg_is_number_start :: proc(ch: u8) -> bool {
	return (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.'
}

svg_parse_number :: proc(p: ^SVG_Parser) -> f32 {
	svg_skip_whitespace_and_commas(p)
	if p.pos >= len(p.data) do return 0

	start := p.pos

	// Optional sign
	if p.pos < len(p.data) && (p.data[p.pos] == '-' || p.data[p.pos] == '+') {
		p.pos += 1
	}

	// Integer part
	for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
		p.pos += 1
	}

	// Decimal part
	if p.pos < len(p.data) && p.data[p.pos] == '.' {
		p.pos += 1
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos += 1
		}
	}

	// Scientific notation (e.g., 1.5e-3)
	if p.pos < len(p.data) && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E') {
		p.pos += 1
		if p.pos < len(p.data) && (p.data[p.pos] == '-' || p.data[p.pos] == '+') {
			p.pos += 1
		}
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos += 1
		}
	}

	if p.pos == start do return 0

	num_str := p.data[start:p.pos]
	return parse_f32(num_str)
}

parse_f32 :: proc(s: string) -> f32 {
	val, ok := strconv.parse_f32(s)
	if !ok do return 0
	return val
}

// ===================================================
// Font integration — load an SVG icon into a font glyph slot.
//
// Places the icon's curves into font.glyphs[slot_index] so it gets
// packed and rendered through the exact same pipeline as text glyphs.
// Use indices 128+ to avoid colliding with ASCII (32-126).
// ===================================================

// Load an SVG file and place it into a font's glyph array at the given index.
// Must be called BEFORE pack_glyph_textures and glyph_process.
svg_load_into_font :: proc(font: ^Font, slot_index: int, path: string) -> bool {
	if slot_index < 0 || slot_index >= MAX_CACHED_GLYPHS {
		fmt.eprintln("SVG: invalid glyph slot index:", slot_index)
		return false
	}

	icon, icon_ok := svg_load_icon(path)
	if !icon_ok do return false

	// Move glyph data into the font's glyph array
	g := &font.glyphs[slot_index]
	g^ = icon.glyph
	g.codepoint = rune(slot_index)
	g.valid = true

	// Zero out the icon's glyph so its dynamic arrays aren't double-freed
	icon.glyph = {}

	return true
}

// Draw an SVG icon at the given screen position and size.
// icon_index is the glyph slot index used in svg_load_into_font.
slug_draw_icon :: proc(ctx: ^Slug_Context, icon_index: int, x, y: f32, size: f32, color: [4]f32) {
	font := slug_active_font(ctx)
	if icon_index < 0 || icon_index >= MAX_CACHED_GLYPHS do return
	g := &font.glyphs[icon_index]
	if !g.valid || len(g.curves) == 0 do return

	glyph_w := (g.bbox_max.x - g.bbox_min.x) * size
	glyph_h := (g.bbox_max.y - g.bbox_min.y) * size

	// Center the icon at (x, y)
	glyph_x := x - glyph_w * 0.5
	glyph_y := y - glyph_h * 0.5

	if ctx.quad_count < MAX_GLYPH_QUADS {
		emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
	}
}
