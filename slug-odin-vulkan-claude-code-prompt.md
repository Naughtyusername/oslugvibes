# Slug Algorithm — Odin + Vulkan Port

## Claude Code Task Prompt

You are porting Eric Lengyel's Slug font rendering algorithm to Odin with a Vulkan backend. This is a GPU text renderer that draws glyphs directly from quadratic Bézier curve data in the fragment shader — no texture atlases, no signed distance fields. Each glyph is a single quad. The patent was dedicated to the public domain on March 17, 2026.

## What Slug Does (Algorithm Summary)

Slug renders resolution-independent text on the GPU by:

1. **Parsing TTF/OTF fonts** to extract quadratic Bézier curve contours for each glyph
2. **Preprocessing glyphs** into two GPU textures:
   - A **curve texture** (float16x4): stores all Bézier control points. Each curve uses 2 texels — first texel holds p1 (xy) and p2 (zw), second holds p3 (xy). The third control point of one curve equals the first of the next curve in the contour.
   - A **band texture** (uint16x2): stores spatial acceleration data. Each glyph's bounding box is divided into horizontal and vertical bands. Each band contains a list of curve indices (sorted by max coordinate for early-exit). Band entries store (curve_count, offset_to_curve_list).
3. **Rendering each glyph as a single quad** with a fragment shader that:
   - Fires two rays (horizontal and vertical) from the pixel center
   - Loops over curves in the relevant bands
   - Solves quadratic polynomials to find ray-curve intersections
   - Classifies curves into 8 equivalence classes using a 16-bit LUT (the robustness trick)
   - Accumulates fractional winding number for antialiased coverage
   - Combines horizontal and vertical coverage for 2D antialiasing

## Reference Sources

Read these in order of priority:

### 1. Reference Shaders (PORT THESE DIRECTLY)
- **Repo**: https://github.com/EricLengyel/Slug (MIT license)
- `SlugPixelShader.hlsl` — ~272 lines, the core rendering algorithm
- `SlugVertexShader.hlsl` — dynamic dilation (auto-expands glyph bounding polygons by half a pixel in viewport space)
- These are HLSL. Port to GLSL (Vulkan uses SPIR-V compiled from GLSL).

### 2. i3D 2018 Slides (ALGORITHM UNDERSTANDING)
- **URL**: https://terathon.com/i3d2018_lengyel.pdf
- Best visual explanation of the algorithm
- Contains the key code snippets: `CalcRootCode`, `SolvePoly`, the main winding loop
- Explains the equivalence class approach, banding, antialiasing

### 3. "A Decade of Slug" Blog Post (WHAT CHANGED SINCE THE PAPER)
- **URL**: https://terathon.com/blog/decade-slug.html
- Symmetric band split optimization was REMOVED (simpler shader)
- Supersampling was REMOVED (dynamic dilation handles small text)
- Multi-color emoji moved from shader loop to multiple draw calls
- Dynamic dilation derivation (vertex shader auto-calculates optimal expansion)
- Band texture now uses 2 components (uint16x2) instead of 4

### 4. JCGT Paper (DEEP REFERENCE)
- **URL**: https://jcgt.org/published/0006/02/02/
- Full academic treatment of the algorithm
- Reference for edge cases and correctness proofs

### 5. Sluggish (CPU-SIDE REFERENCE IMPLEMENTATION)
- **Repo**: https://github.com/mightycow/Sluggish (Unlicense)
- C implementation with both CPU and GPU rendering paths
- **Use this as reference for the host-side pipeline**: TTF parsing, curve extraction, band generation, texture packing
- Old codebase (VS2013, OpenGL) but the data pipeline logic is what matters
- NOTE: This implements an older version of the algorithm (before dynamic dilation, before symmetric band removal). The reference shaders from EricLengyel/Slug are the authoritative shader code.

## Architecture

### Module Structure

```
slug/
├── ttf_parser.odin      -- TTF/OTF file parsing (glyph outlines, metrics, cmap)
├── glyph_processor.odin -- Band generation, curve sorting, texture packing
├── slug_renderer.odin   -- Vulkan pipeline setup, draw calls, text layout
├── slug_types.odin      -- Shared types (Glyph, Band, CurveData, etc.)
└── shaders/
    ├── slug_vert.glsl   -- Vertex shader (dynamic dilation)
    └── slug_frag.glsl   -- Fragment shader (core Slug algorithm)
```

### TTF Parsing (`ttf_parser.odin`)

For the initial implementation, use `stb_truetype.h` via Odin's C FFI (`foreign import`). Odin's vendor library collection may already include stb bindings — check `vendor:stb/truetype`. If not, bind it manually.

What we need from the font:
- `stbtt_GetGlyphShape()` — returns quadratic Bézier contours (control points)
- `stbtt_GetCodepointGlyphIndex()` — character to glyph mapping
- `stbtt_GetGlyphHMetrics()` — advance width, left side bearing
- `stbtt_GetGlyphBox()` — bounding box
- `stbtt_GetFontVMetrics()` — ascent, descent, line gap
- `stbtt_ScaleForPixelHeight()` — em-to-pixel scaling

A future iteration can replace stb_truetype with a native Odin TTF parser. For now, the goal is getting the rendering pipeline working.

**IMPORTANT**: stb_truetype returns glyph outlines as a mix of lines and quadratic Bézier curves. Lines need to be promoted to degenerate quadratic curves (set the middle control point to the midpoint of the two endpoints). All curves must be quadratic — Slug does not handle cubics. TrueType fonts are natively quadratic. PostScript/CFF fonts (some .otf files) use cubic curves and would need conversion — skip these for v1.

### Glyph Processing (`glyph_processor.odin`)

This is the CPU-side preprocessing that builds the two GPU textures.

For each glyph:

1. **Extract contours** from stb_truetype, normalize coordinates to em-space [0,1]
2. **Compute bounding box** in em-space
3. **Generate bands**:
   - Divide bounding box into N horizontal bands and M vertical bands
   - For each curve, determine which bands it intersects (based on y-extent for horizontal bands, x-extent for vertical bands)
   - Sort curves within each band by descending maximum x-coordinate (horizontal bands) or descending maximum y-coordinate (vertical bands) for early-exit optimization
   - Merge adjacent bands that contain identical curve sets (saves texture space)
4. **Pack curve texture**: For each unique curve, store p1.xy + p2.xy in one texel (float16x4) and p3.xy in the next texel. Adjacent curves share the p3/p1 control point, but store them redundantly for texture fetch simplicity.
5. **Pack band texture**: For each glyph, store band headers (curve_count, offset) followed by curve index lists. Layout in the band texture:
   - First: horizontal band headers (bandMax.y + 1 entries)
   - Then: vertical band headers (bandMax.x + 1 entries)
   - Then: curve lists for all bands
   - All packed into a 4096-wide texture, wrapping to next row as needed

**Band count heuristic**: More bands = fewer curves per band = faster shader. Use something like `max(1, sqrt(num_curves) * 2)` for both horizontal and vertical. The Sluggish implementation is a good reference for tuning this.

**Texture formats**:
- Curve texture: `VK_FORMAT_R16G16B16A16_SFLOAT` (half-precision float RGBA)
- Band texture: `VK_FORMAT_R16G16_UINT` (16-bit unsigned int RG)

Both textures have a fixed width of 4096 texels (see `kLogBandTextureWidth` in the shader). Height grows as needed.

### Shaders

#### Fragment Shader (`slug_frag.glsl`)

Port `SlugPixelShader.hlsl` to GLSL. The translation is mostly mechanical:

| HLSL | GLSL |
|------|------|
| `float2/3/4` | `vec2/3/4` |
| `int2/3/4` | `ivec2/3/4` |
| `uint` | `uint` |
| `saturate(x)` | `clamp(x, 0.0, 1.0)` |
| `asuint(x)` | `floatBitsToUint(x)` |
| `asint(x)` | `floatBitsToInt(x)` |
| `fwidth(x)` | `fwidth(x)` (same) |
| `Texture2D.Load(int3(x,y,0))` | `texelFetch(sampler, ivec2(x,y), 0)` |
| `SV_Position` | `gl_FragCoord` |
| `SV_Target` | `layout(location=0) out vec4 fragColor` |

Key functions to port:
- `CalcRootCode()` — the 8-class LUT, bit manipulation
- `SolveHorizPoly()` / `SolveVertPoly()` — quadratic solver
- `CalcBandLoc()` — texture coordinate wrapping
- `CalcCoverage()` — dual-ray coverage combination
- `SlugRender()` — main function: band lookup, curve loop, coverage accumulation

The `nointerpolation` qualifier in HLSL maps to `flat` in GLSL.

#### Vertex Shader (`slug_vert.glsl`)

Port `SlugVertexShader.hlsl`. This handles:
- Standard MVP transform
- **Dynamic dilation**: calculates per-vertex offset to expand the bounding polygon by exactly half a pixel in viewport space. The derivation is in the "Decade of Slug" blog post. The formula solves a quadratic equation using the MVP matrix and viewport dimensions.
- Passes through: color, em-space texcoord, banding data (scale/offset), glyph data (texture coordinates for band/curve lookup)

#### Vertex Format

```
struct SlugVertex {
    position:       [2]f32,    // Object-space 2D position
    color:          [4]f32,    // RGBA vertex color
    texcoord:       [2]f32,    // Em-space sample coordinates
    normal:         [2]f32,    // Dilation normal (scaled, not unit length)
    inv_jacobian:   [4]f32,    // 2x2 inverse Jacobian for em-space offset during dilation
    band_transform: [4]f32,    // (scale_x, scale_y, offset_x, offset_y) for band index calculation
    glyph_data:     [4]i32,    // (glyph_tex_x, glyph_tex_y, band_max_x, band_max_y_and_flags)
}
```

The `band_transform` and `glyph_data` are constant across all vertices of a glyph (flat/nointerpolation).

### Vulkan Pipeline (`slug_renderer.odin`)

Standard 2D overlay pipeline:

1. **Descriptor set layout**: Two texture samplers (curve texture, band texture)
2. **Pipeline**: 
   - Vertex input matching `SlugVertex`
   - Alpha blending enabled (premultiplied alpha)
   - Depth test disabled
   - Orthographic projection (for screen-aligned text) or full MVP (for in-world text)
3. **Per-frame**: 
   - Map vertex buffer
   - For each text string: lay out glyphs (advance width + kerning), emit 4 or 6 vertices per glyph (quad as two triangles or triangle strip)
   - Submit draw call(s)

For Odin's Vulkan bindings, check `vendor:vulkan`. The Vulkan boilerplate (instance, device, swapchain, render pass) is outside the scope of the Slug port — assume a working Vulkan context is provided.

### Text Layout

Given a UTF-8 string:
1. Decode each codepoint
2. Look up glyph index via cmap
3. Get advance width and left side bearing from hmtx
4. Optionally apply kerning (kern table or GPOS)
5. For each glyph, emit a quad positioned at the current pen position
6. Advance pen by advance_width * scale

Output is a vertex buffer ready to draw.

## Build & Compile Shaders

Compile GLSL to SPIR-V:
```bash
glslangValidator -V slug_vert.glsl -o slug_vert.spv
glslangValidator -V slug_frag.glsl -o slug_frag.spv
```

Or use `glslc` from the Vulkan SDK.

## What to Skip in v1

- PostScript/CFF font support (cubic curves need conversion)
- Ligature replacement, combining diacritical marks, OpenType features
- Multi-color emoji
- Even-odd fill rule (only nonzero fill needed for standard fonts)
- Optical weight boosting (`SLUG_WEIGHT` ifdef)
- Bounding polygons tighter than quads (3-6 vertex optimization)
- Rectangle primitives (`GL_NV_fill_rectangle` — Vulkan doesn't have this)

## What to Include in v1

- TTF parsing via stb_truetype
- Band generation with curve sorting and early-exit optimization
- Curve and band texture generation and upload
- Full fragment shader port (dual-ray antialiasing, fractional coverage)
- Dynamic dilation in vertex shader
- Basic text layout (advance width, no kerning)
- ASCII + extended Latin codepoint range
- Single font loaded at startup

## Testing

1. Render "The quick brown fox jumps over the lazy dog" at various sizes (12px to 200px)
2. Zoom in/out smoothly — text should remain crisp at all scales
3. Rotate text in 3D — no artifacts at oblique angles
4. Check for sparkle/streak artifacts (indicates robustness issues in root eligibility)
5. Compare against Slug Library demo screenshots for visual correctness

## Notes for the Porter

- The pixel shader reference code has extensive comments. Trust them.
- The `0x2E74` magic number in `CalcRootCode` is the packed 8-entry lookup table for root eligibility. Don't change it.
- `kLogBandTextureWidth = 12` means texture width is 4096. This is hardcoded in the shader; match it on the CPU side.
- The curve texture stores coordinates in em-space (approximately [0,1]). The vertex shader transforms object-space positions; the fragment shader works in em-space.
- `pixelsPerEm` is computed per-fragment using `fwidth()` (screen-space derivatives of the em-space texcoord). This is what makes the antialiasing resolution-aware.
- For Vulkan: the band texture must be created with `VK_FORMAT_R16G16_UINT` and sampled with `texelFetch` (integer lookup, no filtering). The curve texture uses `VK_FORMAT_R16G16B16A16_SFLOAT` also with `texelFetch`.
- Dynamic dilation requires the MVP matrix and viewport dimensions as push constants or UBO data in the vertex shader.

## License

- Reference shaders: MIT (EricLengyel/Slug)
- Sluggish reference: Unlicense (mightycow/Sluggish)  
- Slug patent: Public domain as of 2026-03-17
- Your Odin port: Your choice
