# SlugVibes — Project Context

## What This Is
A from-scratch implementation of Eric Lengyel's Slug GPU text rendering algorithm, written in Odin with Vulkan backend and SDL3 windowing. The Slug patent was dedicated to the public domain on 2026-03-17.

Slug renders resolution-independent text by evaluating quadratic Bézier curves directly in the fragment shader — no texture atlases, no SDFs. Each glyph is a single screen-space quad. The fragment shader fires dual rays (horizontal + vertical), solves quadratic polynomials for ray-curve intersections, and accumulates fractional winding numbers for antialiased coverage.

## Architecture

| File | Purpose |
|------|---------|
| `slug_types.odin` | All shared types: `Slug_Vertex`, `Bezier_Curve`, `Band`, `Glyph_Data`, `Font`, `GPU_Texture`, `Slug_Context` |
| `ttf_parser.odin` | Font loading via `vendor:stb/truetype`. Lines promoted to degenerate quadratic Béziers. Cubics skipped (v1). |
| `glyph_processor.odin` | Band generation (spatial acceleration), curve sorting, texture packing, f32→f16 conversion |
| `slug_renderer.odin` | Full Vulkan init (SDL3 surface), pipeline, descriptor sets, vertex emission, draw frame |
| `vulkan_helpers.odin` | Buffer creation, texture upload, image layout transitions, shader module loading |
| `main.odin` | Entry point, demo text rendering, event loop |
| `shaders/slug.vert` | GLSL 4.50 vertex shader — dynamic dilation, data unpacking |
| `shaders/slug.frag` | GLSL 4.50 fragment shader — core Slug algorithm (ray-curve intersection, winding number, coverage) |

## Key Technical Details

- **Vertex format**: 80 bytes/vertex, 5×vec4 (pos, tex, jac, bnd, col)
- **Curve texture**: `R16G16B16A16_SFLOAT`, 4096 wide. Each curve = 2 texels.
- **Band texture**: `R16G16_UINT`, 4096 wide. Headers + curve index lists.
- **Push constants**: `mat4 mvp` (64 bytes) + `vec2 viewport` (8 bytes) = 72 bytes, vertex stage only
- **Coordinate system**: Screen Y-down (Vulkan NDC), font em-space Y-up. Jacobian flips Y.
- **Band count heuristic**: `sqrt(num_curves) * 2`, clamped to >= 1

## Build

```sh
bash build.sh
./slugvibes
```

Requires: `glslc` (from shaderc/vulkan-tools), Odin compiler, SDL3, Vulkan SDK, stb_truetype (built via `make unix` in Odin vendor/stb).

## Vibe Code Project
This is a vibe-code project — Claude can write code directly (not teaching mode). User's only constraint: no destructive commands without approval.

## Known Issues / Areas for Future Work
- Cubic curves (CFF/PostScript fonts) are skipped — only TrueType quadratic outlines work
- No swapchain recreation on window resize
- No kerning support yet
- Font path is hardcoded to Liberation Mono
