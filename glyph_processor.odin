package slugvibes

import "core:fmt"
import "core:math"

// ===================================================
// Glyph processing: band generation and texture packing
// ===================================================

// Process a glyph: generate horizontal and vertical bands, sort curves.
glyph_process :: proc(g: ^Glyph_Data) {
	if len(g.curves) == 0 do return

	num_curves := len(g.curves)

	// Band count heuristic: more bands = fewer curves per band = faster shader
	band_count := max(1, int(math.sqrt(f32(num_curves)) * 2.0))

	bbox_w := g.bbox_max.x - g.bbox_min.x
	bbox_h := g.bbox_max.y - g.bbox_min.y

	if bbox_w <= 0 || bbox_h <= 0 do return

	// --- Generate horizontal bands ---
	// Horizontal bands are divided along the Y axis.
	// Each band stores curves whose Y extent intersects it.
	// Curves are sorted by descending max X for early-exit.

	h_band_count := band_count
	v_band_count := band_count

	// Resize band arrays
	resize(&g.h_bands, h_band_count)
	resize(&g.v_bands, v_band_count)

	// Temporary: per-band curve index lists
	h_lists := make([][dynamic]u16, h_band_count)
	defer {
		for &l in h_lists do delete(l)
		delete(h_lists)
	}
	v_lists := make([][dynamic]u16, v_band_count)
	defer {
		for &l in v_lists do delete(l)
		delete(v_lists)
	}

	for ci in 0..<num_curves {
		curve := &g.curves[ci]

		// Y extent for horizontal band membership
		min_y := min(curve.p1.y, curve.p2.y, curve.p3.y)
		max_y := max(curve.p1.y, curve.p2.y, curve.p3.y)

		// X extent for vertical band membership
		min_x := min(curve.p1.x, curve.p2.x, curve.p3.x)
		max_x := max(curve.p1.x, curve.p2.x, curve.p3.x)

		// Determine which horizontal bands this curve intersects
		band_y_start := int(math.floor((min_y - g.bbox_min.y) / bbox_h * f32(h_band_count)))
		band_y_end   := int(math.floor((max_y - g.bbox_min.y) / bbox_h * f32(h_band_count)))
		band_y_start = clamp(band_y_start, 0, h_band_count - 1)
		band_y_end   = clamp(band_y_end, 0, h_band_count - 1)

		for bi in band_y_start..=band_y_end {
			append(&h_lists[bi], u16(ci))
		}

		// Determine which vertical bands this curve intersects
		band_x_start := int(math.floor((min_x - g.bbox_min.x) / bbox_w * f32(v_band_count)))
		band_x_end   := int(math.floor((max_x - g.bbox_min.x) / bbox_w * f32(v_band_count)))
		band_x_start = clamp(band_x_start, 0, v_band_count - 1)
		band_x_end   = clamp(band_x_end, 0, v_band_count - 1)

		for bi in band_x_start..=band_x_end {
			append(&v_lists[bi], u16(ci))
		}
	}

	// Sort band curve lists by descending max coordinate (for early-exit optimization in shader)
	// Manual sort since Odin closures can't capture variables
	for &list in h_lists {
		sort_curve_indices_by_max_x(list[:], g.curves[:])
	}
	for &list in v_lists {
		sort_curve_indices_by_max_y(list[:], g.curves[:])
	}

	// Pack curve lists into flat arrays and record band headers
	clear(&g.h_curve_lists)
	for bi in 0..<h_band_count {
		g.h_bands[bi] = Band{
			curve_count = u16(len(h_lists[bi])),
			data_offset = u16(len(g.h_curve_lists)),
		}
		for ci in h_lists[bi] {
			append(&g.h_curve_lists, ci)
		}
	}

	clear(&g.v_curve_lists)
	for bi in 0..<v_band_count {
		g.v_bands[bi] = Band{
			curve_count = u16(len(v_lists[bi])),
			data_offset = u16(len(g.v_curve_lists)),
		}
		for ci in v_lists[bi] {
			append(&g.v_curve_lists, ci)
		}
	}

	// Store band max indices (shader uses these)
	g.band_max_x = u16(v_band_count - 1)
	g.band_max_y = u16(h_band_count - 1)

	// Compute band transform: maps em-space coordinate to band index
	// bandIndex = renderCoord * scale + offset
	// For horizontal bands (Y axis): band_index_y = (y - bbox_min.y) / bbox_h * h_band_count
	//   = y * (h_band_count / bbox_h) + (-bbox_min.y * h_band_count / bbox_h)
	g.band_scale = {
		f32(v_band_count) / bbox_w,
		f32(h_band_count) / bbox_h,
	}
	g.band_offset = {
		-g.bbox_min.x * f32(v_band_count) / bbox_w,
		-g.bbox_min.y * f32(h_band_count) / bbox_h,
	}
}

// Sort curve indices by descending max X coordinate
sort_curve_indices_by_max_x :: proc(indices: []u16, curves: []Bezier_Curve) {
	// Simple insertion sort — band lists are small
	for i := 1; i < len(indices); i += 1 {
		key := indices[i]
		key_max_x := max(curves[key].p1.x, curves[key].p2.x, curves[key].p3.x)
		j := i - 1
		for j >= 0 {
			j_max_x := max(curves[indices[j]].p1.x, curves[indices[j]].p2.x, curves[indices[j]].p3.x)
			if j_max_x >= key_max_x do break
			indices[j + 1] = indices[j]
			j -= 1
		}
		indices[j + 1] = key
	}
}

// Sort curve indices by descending max Y coordinate
sort_curve_indices_by_max_y :: proc(indices: []u16, curves: []Bezier_Curve) {
	for i := 1; i < len(indices); i += 1 {
		key := indices[i]
		key_max_y := max(curves[key].p1.y, curves[key].p2.y, curves[key].p3.y)
		j := i - 1
		for j >= 0 {
			j_max_y := max(curves[indices[j]].p1.y, curves[indices[j]].p2.y, curves[indices[j]].p3.y)
			if j_max_y >= key_max_y do break
			indices[j + 1] = indices[j]
			j -= 1
		}
		indices[j + 1] = key
	}
}

// ===================================================
// Texture packing: pack all glyph data into curve and band textures
// ===================================================

Texture_Pack_Result :: struct {
	// Curve texture: each curve takes 2 texels (p1+p2 in first, p3 in second)
	// Format: float16x4 per texel — we store as [4]f16 but pack as [4]u16 for upload
	curve_data:   [dynamic][4]u16,
	curve_width:  u32,
	curve_height: u32,

	// Band texture: headers + curve index lists
	// Format: uint16x2 per texel
	band_data:    [dynamic][2]u16,
	band_width:   u32,
	band_height:  u32,
}

pack_result_destroy :: proc(r: ^Texture_Pack_Result) {
	delete(r.curve_data)
	delete(r.band_data)
}

// Pack all glyphs into GPU textures
pack_glyph_textures :: proc(font: ^Font) -> (result: Texture_Pack_Result) {
	// Curve texture: width = 4096, packed left to right, wrapping to next row
	curve_x: u32 = 0
	curve_y: u32 = 0

	// Band texture: same layout
	band_x: u32 = 0
	band_y: u32 = 0

	for gi in 0..<MAX_CACHED_GLYPHS {
		g := &font.glyphs[gi]
		if !g.valid || len(g.curves) == 0 do continue

		// --- Pack curves into curve texture ---
		// Each curve takes 2 texels: [p1.x, p1.y, p2.x, p2.y] and [p3.x, p3.y, 0, 0]
		num_curve_texels := u32(len(g.curves) * 2)

		// If this glyph's curves don't fit on the current row, pad and wrap
		if curve_x + num_curve_texels > BAND_TEXTURE_WIDTH {
			// Pad remainder of current row
			for curve_x < BAND_TEXTURE_WIDTH {
				append(&result.curve_data, [4]u16{0, 0, 0, 0})
				curve_x += 1
			}
			curve_x = 0
			curve_y += 1
		}

		g.curve_tex_x = u16(curve_x)
		g.curve_tex_y = u16(curve_y)

		for &curve in g.curves {
			// Texel 1: p1.xy, p2.xy
			append(&result.curve_data, [4]u16{
				f32_to_f16(curve.p1.x), f32_to_f16(curve.p1.y),
				f32_to_f16(curve.p2.x), f32_to_f16(curve.p2.y),
			})
			// Texel 2: p3.xy, unused
			append(&result.curve_data, [4]u16{
				f32_to_f16(curve.p3.x), f32_to_f16(curve.p3.y),
				0, 0,
			})
			curve_x += 2
		}

		// --- Pack band data into band texture ---
		// Layout per glyph:
		//   [h_band headers]  (bandMax.y + 1 entries)
		//   [v_band headers]  (bandMax.x + 1 entries)
		//   [curve index lists for all horizontal bands]
		//   [curve index lists for all vertical bands]

		h_count := len(g.h_bands)
		v_count := len(g.v_bands)
		total_band_texels := u32(h_count + v_count + len(g.h_curve_lists) + len(g.v_curve_lists))

		// If this glyph's band data doesn't fit on the current row, pad and wrap
		if band_x + total_band_texels > BAND_TEXTURE_WIDTH {
			for band_x < BAND_TEXTURE_WIDTH {
				append(&result.band_data, [2]u16{0, 0})
				band_x += 1
			}
			band_x = 0
			band_y += 1
		}

		g.band_tex_x = u16(band_x)
		g.band_tex_y = u16(band_y)

		// The curve lists start after all band headers
		curve_list_base := u32(h_count + v_count)

		// Horizontal band headers: (curve_count, data_offset_from_glyph_start)
		for bi in 0..<h_count {
			band := &g.h_bands[bi]
			// data_offset is relative to the glyph's position in the band texture
			// The shader uses CalcBandLoc(glyphLoc, offset) where offset is the band header's y component
			append(&result.band_data, [2]u16{
				band.curve_count,
				u16(curve_list_base + u32(band.data_offset)),
			})
		}

		// Vertical band headers
		for bi in 0..<v_count {
			band := &g.v_bands[bi]
			append(&result.band_data, [2]u16{
				band.curve_count,
				u16(curve_list_base + u32(len(g.h_curve_lists)) + u32(band.data_offset)),
			})
		}

		// Horizontal curve index lists — each entry is the (x, y) position of the curve in the curve texture
		for ci in g.h_curve_lists {
			// Convert curve index to curve texture location
			curve_texel_offset := u32(ci) * 2  // Each curve is 2 texels
			ctx_x := u32(g.curve_tex_x) + curve_texel_offset
			ctx_y := u32(g.curve_tex_y)
			// Handle wrapping
			ctx_y += ctx_x / BAND_TEXTURE_WIDTH
			ctx_x = ctx_x % BAND_TEXTURE_WIDTH
			append(&result.band_data, [2]u16{u16(ctx_x), u16(ctx_y)})
		}

		// Vertical curve index lists
		for ci in g.v_curve_lists {
			curve_texel_offset := u32(ci) * 2
			ctx_x := u32(g.curve_tex_x) + curve_texel_offset
			ctx_y := u32(g.curve_tex_y)
			ctx_y += ctx_x / BAND_TEXTURE_WIDTH
			ctx_x = ctx_x % BAND_TEXTURE_WIDTH
			append(&result.band_data, [2]u16{u16(ctx_x), u16(ctx_y)})
		}

		band_x += total_band_texels
	}

	// Set texture dimensions
	result.curve_width = BAND_TEXTURE_WIDTH
	result.curve_height = max(curve_y + 1, 1)
	result.band_width = BAND_TEXTURE_WIDTH
	result.band_height = max(band_y + 1, 1)

	// Pad to fill full rows
	target_curve_texels := result.curve_width * result.curve_height
	for u32(len(result.curve_data)) < target_curve_texels {
		append(&result.curve_data, [4]u16{0, 0, 0, 0})
	}

	target_band_texels := result.band_width * result.band_height
	for u32(len(result.band_data)) < target_band_texels {
		append(&result.band_data, [2]u16{0, 0})
	}

	fmt.printf("Texture pack: curve=%dx%d (%d texels), band=%dx%d (%d texels)\n",
		result.curve_width, result.curve_height, len(result.curve_data),
		result.band_width, result.band_height, len(result.band_data))

	return result
}


// ===================================================
// Float16 conversion (f32 -> f16 stored as u16)
// ===================================================

f32_to_f16 :: proc(value: f32) -> u16 {
	bits := transmute(u32)value

	sign := (bits >> 16) & 0x8000
	exp  := i32((bits >> 23) & 0xFF) - 127
	mant := bits & 0x007FFFFF

	if exp == 128 {
		// Inf/NaN
		return u16(sign | 0x7C00 | (mant != 0 ? 0x0200 : 0))
	}

	if exp > 15 {
		// Overflow -> Inf
		return u16(sign | 0x7C00)
	}

	if exp < -14 {
		// Underflow -> denorm or zero
		if exp < -24 do return u16(sign)
		mant |= 0x00800000
		shift := u32(-exp - 14 + 13)
		return u16(sign | u32(mant >> shift))
	}

	return u16(sign | u32((exp + 15) << 10) | (mant >> 13))
}
