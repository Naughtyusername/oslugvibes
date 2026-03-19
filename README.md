# SlugVibes — GPU Bézier Text Rendering

A from-scratch implementation of Eric Lengyel's **Slug** algorithm for resolution-independent GPU text rendering, written in **Odin** with a **Vulkan** backend and **SDL3** windowing.

## What is Slug?

Slug renders text by evaluating quadratic Bézier curves directly in the fragment shader. Unlike traditional approaches (bitmap atlases, signed distance fields), Slug produces perfectly sharp text at **any** zoom level — there are no textures to blur, no atlas resolution limits, no SDF artifacts at extreme magnification.

Each glyph is rendered as a single screen-space quad. The fragment shader:
1. Fires dual rays (horizontal + vertical) through the pixel
2. Solves quadratic polynomials for ray-curve intersections
3. Uses an 8-class equivalence LUT (`0x2E74`) for robust root eligibility classification
4. Accumulates a fractional winding number for antialiased coverage

The Slug patent (US 10,936,792) was **dedicated to the public domain** by Eric Lengyel on March 17, 2026. This implementation references his public HLSL/GLSL shader code and the Slug Library documentation.

## Features

- **Resolution-independent text** — zoom from 0.1x to 50x with perfectly crisp curves
- **Interactive zoom/pan** — mouse wheel to zoom, middle-click drag to pan
- **Damage number particles** — floating combat text that pops and fades (game dev demo)
- **Multiple text sizes** — renders the same font from 12px to 48px simultaneously
- **Animated text** — sine wave title animation
- **Dual-ray antialiasing** — horizontal + vertical coverage for smooth edges without MSAA

## Architecture

```
main.odin               Entry point, event loop, demo scenes, damage numbers
slug_types.odin          All shared types (vertex format, glyph data, Vulkan context)
ttf_parser.odin          Font loading via stb_truetype (TrueType outlines → quadratic Béziers)
glyph_processor.odin     Band generation, curve sorting, texture packing, f32→f16
slug_renderer.odin       Vulkan init, pipeline, descriptor sets, text drawing, frame rendering
vulkan_helpers.odin      Buffer/texture creation, image transitions, shader modules
shaders/slug.vert        Vertex shader — dynamic dilation, data unpacking
shaders/slug.frag        Fragment shader — core Slug algorithm (ray intersection, winding, coverage)
```

### Data Flow

1. **TTF parsing**: `stb_truetype` extracts glyph contours → quadratic Bézier curves (lines promoted to degenerate quadratics)
2. **Band generation**: Each glyph's bounding box is divided into horizontal/vertical bands for spatial acceleration
3. **Texture packing**: Curve control points packed into an `R16G16B16A16_SFLOAT` texture; band headers + curve index lists packed into an `R16G16_UINT` texture
4. **Vertex emission**: Each visible glyph becomes 4 vertices (80 bytes each, 5×vec4) with position, em-space texcoords, packed glyph metadata, inverse Jacobian, band transform, and color
5. **Vertex shader**: Expands the glyph quad by half a pixel in viewport space (dynamic dilation) so the antialiasing kernel has room to work
6. **Fragment shader**: Fetches curve data from textures, evaluates ray-curve intersections band by band, computes coverage

## Building

### Prerequisites
- Odin compiler
- Vulkan SDK (runtime + validation layers)
- `glslc` shader compiler (from shaderc or vulkan-tools)
- SDL3 development libraries
- stb_truetype (built via `make unix` in Odin's `vendor/stb/`)
- A TrueType font (defaults to Liberation Mono)

### Build and Run
```sh
bash build.sh
./slugvibes
```

### Controls
| Input | Action |
|-------|--------|
| Mouse wheel | Zoom in/out |
| Middle mouse drag | Pan |
| R | Reset zoom/pan |
| Space | Spawn damage number |
| ESC | Quit |

## AI Disclosure

This project was built collaboratively with **Claude Code** (Anthropic's Claude Opus). The entire codebase — Odin source, GLSL shaders, Vulkan pipeline setup, and the Slug algorithm port — was generated through an interactive conversation where the human provided direction, the reference specification, architectural decisions, and bug analysis, while Claude wrote the implementation code.

The HLSL→GLSL shader port was done mechanically from Eric Lengyel's publicly available Slug shader code. The Odin/Vulkan integration draws patterns from a prior Vulkan project in the same workspace.

## Future Ideas

### For Roguelikes / Games
- **Damage numbers** (implemented) — floating combat text with pop-and-fade animation, demonstrating dynamic text at varying sizes
- **Log window** — scrolling message log with mixed colors, sizes, and styles
- **Tooltips** — crisp text overlays at any UI scale, immune to pixel-grid snapping
- **Dynamic UI scaling** — since text is resolution-independent, the entire UI can scale smoothly with a slider or pinch gesture
- **Stylized fonts** — load multiple TTF files for headers, body text, and flavor text
- **Per-glyph effects** — wobble, color cycling, typewriter reveal — all just vertex data manipulation

### Technical Improvements
- **Cubic curve support** — handle CFF/PostScript font outlines (currently skipped)
- **Kerning** — use stb_truetype's kerning tables for proper letter spacing
- **Swapchain recreation** — handle window resize properly
- **Font atlas switching** — load multiple fonts simultaneously, switch per-draw-call
- **Subpixel rendering** — evaluate coverage per RGB subpixel for LCD-quality antialiasing
- **GPU compute preprocessing** — move band generation and curve sorting to compute shaders
- **Text shaping** — integrate HarfBuzz for complex scripts (Arabic, Devanagari, etc.)

## References

- Eric Lengyel, "GPU-Centered Font Rendering Directly from Glyph Outlines" (Journal of Computer Graphics Techniques, 2017)
- Slug Library documentation: terathon.com/slug
- US Patent 10,936,792 — dedicated to public domain 2026-03-17

## License

Public domain / unlicense. The Slug algorithm itself is now public domain. This implementation is released without restriction.
