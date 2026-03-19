package slugvibes

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// ===================================================
// Entry point — SDL3 window + Slug text rendering demo
// ===================================================

WINDOW_TITLE   :: "SlugVibes — GPU Text Rendering"
INITIAL_WIDTH  :: 1280
INITIAL_HEIGHT :: 720

FONT_PATH :: "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"

// Demo text samples
DEMO_TEXT       :: "The quick brown fox jumps over the lazy dog"
DEMO_TEXT_UPPER :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789"
DEMO_TEXT_LOWER :: "abcdefghijklmnopqrstuvwxyz !@#$%^&*()"
DEMO_TEXT_SLUG  :: "SlugVibes — GPU Bezier Text"
DEMO_TEXT_RES   :: "Resolution Independent!"

// Text colors
COLOR_WHITE  :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_CYAN   :: [4]f32{0.0, 0.9, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.2, 1.0}
COLOR_GREEN  :: [4]f32{0.3, 1.0, 0.4, 1.0}
COLOR_PINK   :: [4]f32{1.0, 0.4, 0.7, 1.0}
COLOR_RED    :: [4]f32{1.0, 0.2, 0.1, 1.0}
COLOR_ORANGE :: [4]f32{1.0, 0.6, 0.1, 1.0}

// Zoom limits
ZOOM_MIN     :: f32(0.1)
ZOOM_MAX     :: f32(50.0)
ZOOM_SPEED   :: f32(1.15)  // Multiplicative per scroll tick
PAN_SPEED    :: f32(5.0)

// --- Damage number system ---

MAX_DAMAGE_NUMBERS :: 64
DAMAGE_LIFETIME    :: f32(1.5)   // Seconds before fully faded
DAMAGE_RISE_SPEED  :: f32(80.0)  // Pixels/sec upward
DAMAGE_START_SIZE  :: f32(48.0)  // Initial font size
DAMAGE_END_SIZE    :: f32(16.0)  // Final font size
DAMAGE_SPAWN_RATE  :: f32(0.4)   // Seconds between auto-spawns

Damage_Number :: struct {
	x, y:      f32,
	age:       f32,
	value:     int,
	active:    bool,
}

damage_numbers: [MAX_DAMAGE_NUMBERS]Damage_Number
damage_spawn_timer: f32

spawn_damage_number :: proc(x, y: f32, value: int) {
	for &d in damage_numbers {
		if !d.active {
			d = Damage_Number{
				x      = x + rand.float32_range(-30, 30),
				y      = y + rand.float32_range(-10, 10),
				age    = 0,
				value  = value,
				active = true,
			}
			return
		}
	}
}

update_damage_numbers :: proc(dt: f32) {
	for &d in damage_numbers {
		if !d.active do continue
		d.age += dt
		d.y -= DAMAGE_RISE_SPEED * dt
		if d.age >= DAMAGE_LIFETIME {
			d.active = false
		}
	}
}

draw_damage_numbers :: proc(ctx: ^Slug_Context) {
	buf: [16]u8
	for &d in damage_numbers {
		if !d.active do continue

		t := d.age / DAMAGE_LIFETIME  // 0..1 over lifetime

		// Size: starts big, shrinks. Use ease-out curve for "pop" feel.
		pop := 1.0 - t
		pop_scale := 1.0 + pop * pop * 0.5  // Extra 50% size at birth, decays
		size := math.lerp(DAMAGE_END_SIZE, DAMAGE_START_SIZE, pop) * pop_scale

		// Alpha: fully opaque for first 60%, then fade out
		alpha: f32 = 1.0
		if t > 0.6 {
			alpha = 1.0 - (t - 0.6) / 0.4
		}

		// Color: white-hot at spawn, red as it fades
		color := [4]f32{
			1.0,
			math.lerp(f32(0.2), f32(1.0), pop),
			math.lerp(f32(0.1), f32(0.8), pop * pop),
			alpha,
		}

		// Format number as string
		text := fmt.bprintf(buf[:], "%d", d.value)
		slug_draw_text(ctx, text, d.x, d.y, size, color)
	}
}

main :: proc() {
	// --- SDL3 init ---
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL3 init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(WINDOW_TITLE, INITIAL_WIDTH, INITIAL_HEIGHT, {.VULKAN, .RESIZABLE})
	if window == nil {
		fmt.eprintln("SDL3 window creation failed:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// --- Vulkan + Slug init ---
	ctx: Slug_Context
	ctx.zoom = 1.0
	if !slug_init(&ctx, window) {
		fmt.eprintln("Slug/Vulkan init failed")
		return
	}
	defer slug_shutdown(&ctx)

	// --- Load font ---
	font, font_ok := font_load(FONT_PATH)
	if !font_ok {
		fmt.eprintln("Failed to load font")
		return
	}
	ctx.font = font

	// Load ASCII glyphs and process them
	font_load_ascii(&ctx.font)

	for gi in 0..<MAX_CACHED_GLYPHS {
		g := &ctx.font.glyphs[gi]
		if g.valid && len(g.curves) > 0 {
			glyph_process(g)
		}
	}

	// Pack glyph data into GPU textures
	pack := pack_glyph_textures(&ctx.font)
	defer pack_result_destroy(&pack)

	if !slug_upload_font(&ctx, &pack) {
		fmt.eprintln("Failed to upload font textures")
		return
	}

	fmt.println("SlugVibes initialized.")
	fmt.println("  Mouse wheel: zoom in/out")
	fmt.println("  Middle mouse drag: pan")
	fmt.println("  R: reset zoom/pan")
	fmt.println("  Space: spawn damage number")
	fmt.println("  ESC: quit")

	// --- Main loop state ---
	running := true
	frame_count: u64
	last_time := time.now()
	middle_dragging := false
	last_mouse_x, last_mouse_y: f32

	for running {
		// Poll events
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false

			case .KEY_DOWN:
				key := event.key.key
				if key == sdl.K_ESCAPE {
					running = false
				} else if key == sdl.K_R {
					// Reset zoom/pan
					ctx.zoom = 1.0
					ctx.pan = {0, 0}
				} else if key == sdl.K_SPACE {
					// Manual damage number spawn
					spawn_damage_number(
						rand.float32_range(100, 800),
						rand.float32_range(200, 500),
						int(rand.int31_max(9999)) + 1,
					)
				}

			case .MOUSE_WHEEL:
				// Zoom in/out
				scroll := event.wheel.y
				if scroll > 0 {
					ctx.zoom = min(ctx.zoom * ZOOM_SPEED, ZOOM_MAX)
				} else if scroll < 0 {
					ctx.zoom = max(ctx.zoom / ZOOM_SPEED, ZOOM_MIN)
				}

			case .MOUSE_BUTTON_DOWN:
				if event.button.button == 2 {  // Middle mouse
					middle_dragging = true
					last_mouse_x = event.button.x
					last_mouse_y = event.button.y
				}

			case .MOUSE_BUTTON_UP:
				if event.button.button == 2 {
					middle_dragging = false
				}

			case .MOUSE_MOTION:
				if middle_dragging {
					dx := event.motion.x - last_mouse_x
					dy := event.motion.y - last_mouse_y
					last_mouse_x = event.motion.x
					last_mouse_y = event.motion.y
					// Pan in screen space (divide by zoom so pan feels consistent)
					ctx.pan.x += dx / ctx.zoom
					ctx.pan.y += dy / ctx.zoom
				}

			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				// TODO: recreate swapchain on resize
				break
			}
		}

		// Calculate dt
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		if dt > 0.05 do dt = 0.05

		// Auto-spawn damage numbers periodically
		damage_spawn_timer += dt
		if damage_spawn_timer >= DAMAGE_SPAWN_RATE {
			damage_spawn_timer -= DAMAGE_SPAWN_RATE
			spawn_damage_number(
				rand.float32_range(200, 1000),
				rand.float32_range(400, 600),
				int(rand.int31_max(999)) + 1,
			)
		}

		update_damage_numbers(dt)

		// --- Build text geometry ---
		slug_begin(&ctx)

		// Animated Y offset for visual interest
		t := f32(frame_count) * 0.02
		wave := math.sin(t) * 10.0

		// Multiple text samples at different sizes
		y_pos: f32 = 50

		slug_draw_text(&ctx, DEMO_TEXT_SLUG, 30, y_pos + wave, 48, COLOR_CYAN)
		y_pos += 70

		slug_draw_text(&ctx, DEMO_TEXT, 30, y_pos, 32, COLOR_WHITE)
		y_pos += 50

		slug_draw_text(&ctx, DEMO_TEXT_UPPER, 30, y_pos, 24, COLOR_YELLOW)
		y_pos += 40

		slug_draw_text(&ctx, DEMO_TEXT_LOWER, 30, y_pos, 24, COLOR_GREEN)
		y_pos += 50

		// Size ramp: same text at multiple sizes to show scaling
		sizes := [?]f32{12, 16, 20, 28, 36, 48}
		for size in sizes {
			slug_draw_text(&ctx, "Slug", 30, y_pos, size, COLOR_PINK)
			y_pos += size + 8
		}

		// Resolution independence demo text
		y_pos += 20
		slug_draw_text(&ctx, DEMO_TEXT_RES, 30, y_pos, 36, COLOR_ORANGE)
		y_pos += 50

		// Zoom level indicator
		zoom_buf: [32]u8
		zoom_text := fmt.bprintf(zoom_buf[:], "Zoom: %.1fx", ctx.zoom)
		slug_draw_text(&ctx, zoom_text, 30, y_pos, 18, COLOR_GREEN)

		// Damage numbers on top
		draw_damage_numbers(&ctx)

		slug_end(&ctx)

		// --- Render ---
		if !slug_draw_frame(&ctx) {
			fmt.eprintln("Draw frame failed")
			break
		}

		frame_count += 1
	}

	// Wait for GPU to finish before cleanup
	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
	}

	fmt.println("Shutting down.")
}
