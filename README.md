# SlugVibes — GPU Bézier Text Rendering

A from-scratch implementation of Eric Lengyel's **Slug** algorithm for resolution-independent GPU text rendering, written in **Odin** with a **Vulkan** backend and **SDL3** windowing.

## What is Slug?

Slug renders text by evaluating quadratic Bézier curves directly in the fragment shader. Unlike traditional approaches (bitmap atlases, signed distance fields), Slug produces perfectly sharp text at **any** zoom level — there are no textures to blur, no atlas resolution limits, no SDF artifacts at extreme magnification.

Each glyph is rendered as a single screen-space quad. The fragment shader:
1. Fires dual rays (horizontal + vertical) through the pixel
2. Solves quadratic polynomials for ray-curve intersections
3. Uses an 8-class equivalence LUT (`0x2E74`) for robust root eligibility classification
4. Accumulates a fractional winding number for antialiased coverage

### Patent History

The Slug algorithm was patented by Eric Lengyel in 2021 (US Patent 10,936,792). For years it was a technically superior approach to GPU text rendering that nobody could freely use — the patent covered the core innovation of using quadratic polynomial root-finding with winding number accumulation in a fragment shader. Commercial use required licensing the Slug Library from Terathon Software.

On **March 17, 2026**, Lengyel dedicated the patent to the public domain via a Terminal Disclaimer, making the algorithm freely available to everyone. Two days later, this implementation was written.

This is significant because most game engines and applications still use bitmap atlas rendering (Freetype → texture atlas → textured quads) or signed distance fields (SDF, popularized by Valve in 2007). Both approaches bake glyph shapes into textures at fixed resolutions, which means they blur or show artifacts at extreme zoom levels. Slug has no such limitation — it evaluates the actual mathematical curves per-pixel, producing perfect results at any scale. Now that the patent is free, there's no reason new projects can't adopt this approach.

This implementation references Lengyel's public HLSL/GLSL shader code and the Slug Library documentation.

## Features

### Core Rendering
- **Resolution-independent text** — zoom from 0.1x to 50x with perfectly crisp curves
- **Dual-ray antialiasing** — horizontal + vertical coverage for smooth edges without MSAA
- **Dynamic dilation** — vertex shader auto-expands quads by half a pixel for correct AA at any scale

### Multi-Font Support
- **Multiple simultaneous fonts** — up to 4 font slots, each with independent GPU textures and descriptor sets
- **Kerning** — automatic kern pair adjustment via stb_truetype's kern table (visible on proportional fonts like Liberation Sans/Serif)
- **Cubic curve support** — CFF/PostScript font outlines automatically converted to quadratic approximations via recursive De Casteljau subdivision

### Text Effects (all CPU-side, zero shader changes)
- **Rainbow cycling** — per-character HSV color cycling
- **Wobble** — per-character sine wave displacement with configurable amplitude/frequency/phase
- **Shake** — per-character pseudo-random jitter (critical hit effect)
- **Rotating text** — arbitrary-angle rendering using full 2x2 Jacobian transform
- **Circular text** — glyphs positioned and rotated along a circular arc
- **Wave text** — glyphs following a sine wave path, rotated to match the tangent
- **Text measurement** — `measure_text()` returns width/height without drawing

### Game UI Demos
- **Damage numbers** — floating combat text that pops large, shrinks, and fades as it rises
- **Scrolling combat log** — color-coded RPG-style messages with age-based fade
- **Interactive zoom/pan** — mouse wheel zoom, middle-click drag pan

## Architecture

```
main.odin               Entry point, event loop, demo scenes, damage numbers
slug_types.odin          All shared types (vertex format, glyph data, Vulkan context, font slots)
ttf_parser.odin          Font loading via stb_truetype, kerning, cubic-to-quadratic conversion
glyph_processor.odin     Band generation, curve sorting, texture packing, f32→f16
slug_renderer.odin       Vulkan init, pipeline, multi-font draw calls, text drawing
text_effects.odin        Per-character effects (rainbow, wobble, shake, rotation, paths)
vulkan_helpers.odin      Buffer/texture creation, image transitions, shader modules
shaders/slug.vert        Vertex shader — dynamic dilation, data unpacking
shaders/slug.frag        Fragment shader — core Slug algorithm (ray intersection, winding, coverage)
```

### Data Flow

1. **TTF parsing**: `stb_truetype` extracts glyph contours → quadratic Bézier curves. Lines promoted to degenerate quadratics. Cubics subdivided via De Casteljau until approximation error < 0.001 em units.
2. **Band generation**: Each glyph's bounding box is divided into horizontal/vertical bands for spatial acceleration. Curves sorted by descending max coordinate for early-exit optimization in the shader.
3. **Texture packing**: Curve control points packed into an `R16G16B16A16_SFLOAT` texture; band headers + curve index lists packed into an `R16G16_UINT` texture. Each font gets its own texture pair.
4. **Vertex emission**: Each visible glyph becomes 4 vertices (80 bytes each, 5×vec4) with position, em-space texcoords, packed glyph metadata, inverse Jacobian, band transform, and color. The Jacobian supports arbitrary rotation/scale via a full 2x2 matrix.
5. **Vertex shader**: Expands the glyph quad by half a pixel in viewport space (dynamic dilation) so the antialiasing kernel has room to work.
6. **Fragment shader**: Fetches curve data from textures, evaluates ray-curve intersections band by band, computes coverage.
7. **Multi-font draw**: Renderer issues separate draw calls per font slot, binding each font's descriptor set (textures).

## Building

### Prerequisites
- Odin compiler
- Vulkan SDK (runtime + validation layers)
- `glslc` shader compiler (from shaderc or vulkan-tools)
- SDL3 development libraries
- stb_truetype (built via `make unix` in Odin's `vendor/stb/`)
- TrueType fonts (defaults to Liberation Mono/Sans/Serif)

### Build and Run
```sh
bash build.sh
./slugvibes
```

### Controls
| Input | Action |
|-------|--------|
| Mouse wheel | Zoom in/out (0.1x – 50x) |
| Middle mouse drag | Pan |
| R | Reset zoom/pan |
| Space | Spawn damage number |
| ESC | Quit |

## AI Disclosure

This project was built collaboratively with **Claude Code** (Anthropic's Claude Opus). The entire codebase — Odin source, GLSL shaders, Vulkan pipeline setup, and the Slug algorithm port — was generated through an interactive conversation where the human provided direction, the reference specification, architectural decisions, and bug analysis, while Claude wrote the implementation code.

The HLSL→GLSL shader port was done mechanically from Eric Lengyel's publicly available Slug shader code. The Odin/Vulkan integration draws patterns from a prior Vulkan project in the same workspace.

## Future Ideas

### For Roguelikes / Games
- **Dynamic UI scaling** — since text is resolution-independent, the entire UI can scale smoothly with a slider or pinch gesture
- **Typewriter reveal** — animate characters appearing one by one, trivial with per-character drawing
- **Outlined/shadowed text** — render the same text twice with offset for drop shadow, or with slightly dilated quads for outline
- **Text wrapping** — automatic line breaking using `measure_text()`

### Technical Improvements
- **Swapchain recreation** — handle window resize properly
- **Subpixel rendering** — evaluate coverage per RGB subpixel for LCD-quality antialiasing
- **GPU compute preprocessing** — move band generation and curve sorting to compute shaders
- **Text shaping** — integrate HarfBuzz for complex scripts (Arabic, Devanagari, etc.)
- **Glyph caching beyond ASCII** — extend to full Unicode (currently limited to codepoints 0-255)
- **Instanced rendering** — one draw call for all fonts using bindless textures

## References

- Eric Lengyel, "GPU-Centered Font Rendering Directly from Glyph Outlines" (Journal of Computer Graphics Techniques, 2017)
- Slug Library documentation: terathon.com/slug
- US Patent 10,936,792 — dedicated to public domain 2026-03-17

## License

Public domain / unlicense. The Slug algorithm itself is now public domain. This implementation is released without restriction.
