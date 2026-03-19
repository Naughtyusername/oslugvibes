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

You need four things on every platform: the **Odin compiler**, a **Vulkan implementation**, the **glslc** SPIR-V shader compiler, and **SDL3**.

Fonts are bundled in `assets/fonts/` (Liberation Mono, Sans, Serif) — no system font dependencies.

#### Odin Compiler

Install from [odin-lang.org](https://odin-lang.org). Either grab a nightly build or clone and build from source.

After installing, you must build the **stb vendor library** that provides `stb_truetype`:

**Linux / macOS:**
```sh
make -C $ODIN_ROOT/vendor/stb/src unix
```

**Windows (from a Visual Studio Developer Command Prompt):**
```cmd
cd %ODIN_ROOT%\vendor\stb\src
nmake -f Windows.mak
```

If you skip this step, the build will fail with linker errors about missing `stb_truetype` symbols.

Odin's SDL3 vendor bindings also need the SDL3 shared library present at link time — see platform sections below.

#### glslc (SPIR-V Shader Compiler)

`glslc` compiles the GLSL vertex/fragment shaders (`shaders/slug.vert`, `shaders/slug.frag`) into SPIR-V bytecode that Vulkan can consume. It is part of Google's **shaderc** project. The build scripts call `glslc` before invoking `odin build`, so it must be on your `PATH`.

How to get it varies by platform — see below.

---

### Linux (Arch)

```sh
sudo pacman -S vulkan-devel shaderc sdl3
```

`vulkan-devel` pulls in the Vulkan loader, headers, and validation layers. `shaderc` provides `glslc`. `sdl3` provides the shared library that Odin's vendor bindings link against.

Build the stb vendor lib (if not already done):
```sh
make -C $(odin root)/vendor/stb/src unix
```

Build and run:
```sh
bash build.sh
./slugvibes
```

### Linux (Ubuntu / Debian)

```sh
sudo apt install vulkan-tools vulkan-validationlayers libvulkan-dev \
                 glslc libsdl3-dev
```

On older Ubuntu releases, `glslc` may not be packaged separately — install `shaderc` or grab `glslc` from the [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home).

Build the stb vendor lib:
```sh
make -C $(odin root)/vendor/stb/src unix
```

Build and run:
```sh
bash build.sh
./slugvibes
```

### Windows

**Prerequisites:**
- **Visual Studio Build Tools** (or full Visual Studio) — required for `nmake` and the MSVC linker that Odin uses. Download from [visualstudio.microsoft.com](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022). Select the "C++ Build Tools" workload.

1. **Vulkan SDK** — Download and install from [vulkan.lunarg.com](https://vulkan.lunarg.com/sdk/home). The SDK includes `glslc.exe`, the Vulkan loader, and validation layers. Make sure the SDK `Bin` directory is on your `PATH` (the installer usually does this).

2. **SDL3** — Go to the [SDL3 releases page](https://github.com/libsdl-org/SDL/releases) and download the **VC** development package (e.g., `SDL3-devel-3.x.x-VC.zip`). Extract it. You need two things from it:
   - `SDL3.dll` — copy this into the project directory (next to where `slugvibes.exe` will be built)
   - `SDL3.lib` — the import library. Either copy it to your project directory or add its location to your `LIB` environment variable so the linker can find it.

3. **Odin** — Install from [odin-lang.org](https://odin-lang.org). Build the stb vendor lib from a **Developer Command Prompt** (not a regular cmd — search "Developer Command Prompt" in the Start menu):
   ```cmd
   cd %ODIN_ROOT%\vendor\stb\src
   nmake -f Windows.mak
   ```

Build and run (cmd):
```cmd
build.bat
slugvibes.exe
```

Build and run (PowerShell):
```powershell
# If you get an execution policy error, run this first:
# Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\build.ps1
.\slugvibes.exe
```

### macOS (Untested)

macOS does not have native Vulkan — it would run through **MoltenVK** (Vulkan-on-Metal translation layer). This project has not been tested on macOS, but in principle:

```sh
brew install molten-vk shaderc sdl3
```

You may also need the [LunarG Vulkan SDK for macOS](https://vulkan.lunarg.com/sdk/home) for validation layers and the ICD.

Build the stb vendor lib:
```sh
make -C $(odin root)/vendor/stb/src unix
```

Build and run:
```sh
bash build.sh
./slugvibes
```

If you get it working on macOS, contributions are welcome.

---

### Important: Run from the Project Root

The program loads fonts from `assets/fonts/` using relative paths. You must run the binary from the project root directory (where `assets/` lives), not from inside a subdirectory.

---

### Troubleshooting

**`glslc: command not found`**
- **Linux (Arch):** `sudo pacman -S shaderc`
- **Linux (Ubuntu/Debian):** `sudo apt install glslc` or `sudo apt install shaderc`
- **Windows:** Install the Vulkan SDK from LunarG and ensure its `Bin` directory is on your `PATH`
- **macOS:** `brew install shaderc`

**Linker errors mentioning `stb_truetype` / `stbi_` symbols**
- You need to build the stb vendor library first. See the Odin setup section above. This is the most common first-build issue.

**`SDL3` not found / linker errors about SDL**
- **Linux:** Install `sdl3` (Arch) or `libsdl3-dev` (Ubuntu/Debian)
- **Windows:** Download the SDL3 **VC development package** from the SDL3 GitHub releases. Place `SDL3.lib` where the linker can find it and `SDL3.dll` next to the exe.
- **macOS:** `brew install sdl3`
- Check that Odin's `vendor/sdl3` bindings match your installed SDL3 version

**`SDL3.dll not found` or crash on startup (Windows)**
- Place `SDL3.dll` in the same directory as `slugvibes.exe` (the project root). The OS searches the exe's directory for DLLs first.

**Vulkan validation layer not found (`VK_LAYER_KHRONOS_validation`)**
- **Linux (Arch):** This is included in `vulkan-devel`. If you installed only `vulkan-icd-loader`, add `vulkan-validation-layers`.
- **Linux (Ubuntu/Debian):** `sudo apt install vulkan-validationlayers`
- **Windows:** Reinstall the Vulkan SDK with validation layers selected (they are included by default)
- The program will still run without validation layers, but you lose helpful debug messages.

**`Failed to create Vulkan instance` / no Vulkan driver**
- Ensure you have a Vulkan-capable GPU driver installed. On Linux, this means `mesa-vulkan` (AMD/Intel) or the proprietary NVIDIA driver. On Windows, update your GPU drivers.

**Window opens but text is garbled or missing**
- Check that `shaders/slug_vert.spv` and `shaders/slug_frag.spv` exist — the build script should have created them. If you edited shaders, re-run the build script to recompile them.
- Verify fonts exist at `assets/fonts/LiberationMono-Regular.ttf` (and Sans/Serif).

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
