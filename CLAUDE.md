# SlugVibes — Project Context

## What This Is
A demo showcase of Eric Lengyel's Slug GPU text rendering algorithm, written in Odin with Vulkan backend and SDL3 windowing. The Slug patent was dedicated to the public domain on 2026-03-17.

Slug renders resolution-independent text by evaluating quadratic Bézier curves directly in the fragment shader — no texture atlases, no SDFs. Each glyph is a single screen-space quad. The fragment shader fires dual rays (horizontal + vertical), solves quadratic polynomials for ray-curve intersections, and accumulates fractional winding numbers for antialiased coverage.

## Architecture

| File | Purpose |
|------|---------|
| `slug_types.odin` | All shared types: `Slug_Vertex`, `Bezier_Curve`, `Band`, `Glyph_Data`, `Font`, `Font_Instance`, `GPU_Texture`, `Slug_Context` |
| `ttf_parser.odin` | Font loading via `vendor:stb/truetype`. Kerning via kern table. Cubic-to-quadratic conversion via De Casteljau subdivision. |
| `glyph_processor.odin` | Band generation (spatial acceleration), curve sorting, texture packing, f32→f16 conversion |
| `slug_renderer.odin` | Full Vulkan init (SDL3 surface), pipeline, multi-font descriptor sets, vertex emission, per-font draw calls |
| `text_effects.odin` | Per-character effects: rainbow, wobble, shake, rotation, circular path, sine wave path |
| `vulkan_helpers.odin` | Buffer creation, texture upload, image layout transitions, shader module loading |
| `main.odin` | Entry point, demo scenes, damage numbers, combat log, event loop |
| `shaders/slug.vert` | GLSL 4.50 vertex shader — dynamic dilation, data unpacking |
| `shaders/slug.frag` | GLSL 4.50 fragment shader — core Slug algorithm (ray-curve intersection, winding number, coverage) |

## Key Technical Details

- **Vertex format**: 80 bytes/vertex, 5×vec4 (pos, tex, jac, bnd, col)
- **Jacobian**: Full 2x2 matrix (not just diagonal) — supports arbitrary rotation and scale
- **Curve texture**: `R16G16B16A16_SFLOAT`, 4096 wide. Each curve = 2 texels.
- **Band texture**: `R16G16_UINT`, 4096 wide. Headers + curve index lists.
- **Push constants**: `mat4 mvp` (64 bytes) + `vec2 viewport` (8 bytes) = 72 bytes, vertex stage only
- **Coordinate system**: Screen Y-down (Vulkan NDC), font em-space Y-up. Jacobian flips Y.
- **Ortho projection**: `matrix_ortho3d_f32(0, w, 0, h, -1, 1)` — bottom=0, top=h for Vulkan Y-down
- **Multi-font**: Up to 4 font slots, each with own textures + descriptor set. Per-font draw calls.
- **Kerning**: `stbtt.GetGlyphKernAdvance` applied between character pairs in `slug_draw_text`
- **Cubic curves**: Recursive De Casteljau subdivision with 0.001 em tolerance, max depth 8

## Build

```sh
bash build.sh
./slugvibes
```

Requires: `glslc` (from shaderc/vulkan-tools), Odin compiler, SDL3, Vulkan SDK, stb_truetype (built via `make unix` in Odin vendor/stb).

## Vibe Code Project
This is a vibe-code project — Claude can write code directly (not teaching mode). User's only constraint: no destructive commands without approval.

## Known Issues / Gotchas
- Vulkan ortho projection: `matrix_ortho3d_f32(0, w, 0, h, ...)` NOT `(0, w, h, 0, ...)` — Vulkan Y-down means bottom < top or everything renders upside-down
- `Slug_Context` is ~340KB on the stack due to font arrays (triggers compiler warning, works fine)
- `emit_glyph_quad` and `emit_glyph_quad_transformed` must NOT be `@(private="file")` — used by `text_effects.odin`
- Swapchain recreation on resize is implemented (tracks `framebuffer_resized` flag + handles `OUT_OF_DATE` / `SUBOPTIMAL`)
- Monospace fonts have zero kerning by definition — test kerning with proportional fonts
