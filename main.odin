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

FONT_PATH       :: "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"
FONT_PATH_SANS  :: "/usr/share/fonts/liberation/LiberationSans-Regular.ttf"
FONT_PATH_SERIF :: "/usr/share/fonts/liberation/LiberationSerif-Regular.ttf"

// Text colors
COLOR_WHITE  :: [4]f32{1.0, 1.0, 1.0, 1.0}
COLOR_CYAN   :: [4]f32{0.0, 0.9, 1.0, 1.0}
COLOR_YELLOW :: [4]f32{1.0, 0.9, 0.2, 1.0}
COLOR_GREEN  :: [4]f32{0.3, 1.0, 0.4, 1.0}
COLOR_PINK   :: [4]f32{1.0, 0.4, 0.7, 1.0}
COLOR_RED    :: [4]f32{1.0, 0.2, 0.1, 1.0}
COLOR_ORANGE :: [4]f32{1.0, 0.6, 0.1, 1.0}
COLOR_DIM    :: [4]f32{0.5, 0.5, 0.5, 0.7}

// Zoom limits
ZOOM_MIN     :: f32(0.1)
ZOOM_MAX     :: f32(50.0)
ZOOM_SPEED   :: f32(1.15)

// --- Damage number system ---

MAX_DAMAGE_NUMBERS :: 64
DAMAGE_LIFETIME    :: f32(1.5)
DAMAGE_RISE_SPEED  :: f32(80.0)
DAMAGE_START_SIZE  :: f32(48.0)
DAMAGE_END_SIZE    :: f32(16.0)
DAMAGE_SPAWN_RATE  :: f32(0.4)

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

		t := d.age / DAMAGE_LIFETIME
		pop := 1.0 - t
		pop_scale := 1.0 + pop * pop * 0.5
		size := math.lerp(DAMAGE_END_SIZE, DAMAGE_START_SIZE, pop) * pop_scale

		alpha: f32 = 1.0
		if t > 0.6 {
			alpha = 1.0 - (t - 0.6) / 0.4
		}

		color := [4]f32{
			1.0,
			math.lerp(f32(0.2), f32(1.0), pop),
			math.lerp(f32(0.1), f32(0.8), pop * pop),
			alpha,
		}

		text := fmt.bprintf(buf[:], "%d", d.value)
		slug_draw_text(ctx, text, d.x, d.y, size, color)
	}
}

// --- Combat log auto-message timer ---

LOG_MESSAGE_RATE :: f32(0.8)  // seconds between auto messages
log_message_timer: f32

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
	// Heap-allocate: Slug_Context is ~340KB with font arrays, too large for stack
	ctx_ptr := new(Slug_Context)
	defer free(ctx_ptr)
	ctx := ctx_ptr
	ctx.zoom = 1.0
	if !slug_init(ctx, window) {
		fmt.eprintln("Slug/Vulkan init failed")
		return
	}
	defer slug_shutdown(ctx)

	// --- Load font ---
	font, font_ok := font_load(FONT_PATH)
	if !font_ok {
		fmt.eprintln("Failed to load font")
		return
	}
	ctx.font = font

	font_load_ascii(&ctx.font)

	for gi in 0..<MAX_CACHED_GLYPHS {
		g := &ctx.font.glyphs[gi]
		if g.valid && len(g.curves) > 0 {
			glyph_process(g)
		}
	}

	pack := pack_glyph_textures(&ctx.font)
	defer pack_result_destroy(&pack)

	if !slug_upload_font(ctx, &pack) {
		fmt.eprintln("Failed to upload font textures")
		return
	}

	// Load additional fonts
	slug_load_font_slot(ctx, 1, FONT_PATH_SANS, "Liberation Sans")
	slug_load_font_slot(ctx, 2, FONT_PATH_SERIF, "Liberation Serif")

	fmt.println("SlugVibes initialized.")
	fmt.println("  Mouse wheel: zoom in/out")
	fmt.println("  Middle mouse drag: pan")
	fmt.println("  R: reset zoom/pan")
	fmt.println("  Space: spawn damage number")
	fmt.println("  ESC: quit")

	// --- Combat log ---
	combat_log: Combat_Log
	combat_log_add(&combat_log, "Welcome to SlugVibes!", COLOR_CYAN)
	combat_log_add(&combat_log, "GPU Bezier text rendering demo.", COLOR_GREEN)

	// --- Main loop state ---
	running := true
	frame_count: u64
	last_time := time.now()
	middle_dragging := false
	last_mouse_x, last_mouse_y: f32
	mouse_x, mouse_y: f32

	for running {
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
					ctx.zoom = 1.0
					ctx.pan = {0, 0}
				} else if key == sdl.K_SPACE {
					spawn_damage_number(
						rand.float32_range(100, 800),
						rand.float32_range(200, 500),
						int(rand.int31_max(9999)) + 1,
					)
				}

			case .MOUSE_WHEEL:
				scroll := event.wheel.y
				if scroll > 0 {
					ctx.zoom = min(ctx.zoom * ZOOM_SPEED, ZOOM_MAX)
				} else if scroll < 0 {
					ctx.zoom = max(ctx.zoom / ZOOM_SPEED, ZOOM_MIN)
				}

			case .MOUSE_BUTTON_DOWN:
				if event.button.button == 2 {
					middle_dragging = true
					last_mouse_x = event.button.x
					last_mouse_y = event.button.y
				}

			case .MOUSE_BUTTON_UP:
				if event.button.button == 2 {
					middle_dragging = false
				}

			case .MOUSE_MOTION:
				mouse_x = event.motion.x
				mouse_y = event.motion.y
				if middle_dragging {
					dx := event.motion.x - last_mouse_x
					dy := event.motion.y - last_mouse_y
					last_mouse_x = event.motion.x
					last_mouse_y = event.motion.y
					ctx.pan.x += dx / ctx.zoom
					ctx.pan.y += dy / ctx.zoom
				}

			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				ctx.framebuffer_resized = true
			}
		}

		// Calculate dt
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		if dt > 0.05 do dt = 0.05

		t := f32(frame_count) * 0.02
		total_time := f32(frame_count) / 60.0  // approximate seconds

		// Auto-spawn damage numbers
		damage_spawn_timer += dt
		if damage_spawn_timer >= DAMAGE_SPAWN_RATE {
			damage_spawn_timer -= DAMAGE_SPAWN_RATE
			spawn_damage_number(
				rand.float32_range(750, 1100),
				rand.float32_range(80, 200),
				int(rand.int31_max(999)) + 1,
			)
		}
		update_damage_numbers(dt)

		// Auto-add combat log messages
		log_message_timer += dt
		if log_message_timer >= LOG_MESSAGE_RATE {
			log_message_timer -= LOG_MESSAGE_RATE
			msg_idx := int(rand.int31_max(i32(len(combat_log_messages))))
			buf: [128]u8
			msg := combat_log_messages[msg_idx]
			// Format with random number if message has %d
			text := fmt.bprintf(buf[:], msg, int(rand.int31_max(99)) + 1)
			combat_log_add(&combat_log, text, combat_log_colors[msg_idx])
		}
		combat_log_update(&combat_log, dt)

		// ===================================================
		// BUILD TEXT GEOMETRY
		// ===================================================
		slug_begin(ctx)

		// --- Left column: Original demos + effects ---
		y_pos: f32 = 40

		// Title with wobble effect
		draw_text_wobble(ctx, "SlugVibes", 30, y_pos, 42, total_time, 8.0, 4.0, 0.8)
		y_pos += 60

		// Original text samples (same as v1)
		slug_draw_text(ctx, "The quick brown fox jumps over the lazy dog", 30, y_pos, 32, COLOR_WHITE)
		y_pos += 50

		slug_draw_text(ctx, "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789", 30, y_pos, 24, COLOR_YELLOW)
		y_pos += 40

		slug_draw_text(ctx, "abcdefghijklmnopqrstuvwxyz !@#$%^&*()", 30, y_pos, 24, COLOR_GREEN)
		y_pos += 40

		// Per-character effects
		draw_text_rainbow(ctx, "Rainbow cycling per-character", 30, y_pos, 20, total_time, 200.0, 15.0)
		y_pos += 30

		draw_text_shake(ctx, "CRITICAL HIT!", 30, y_pos, 28, 3.0, total_time * 30.0)
		y_pos += 40

		// Size ramp
		sizes := [?]f32{12, 16, 20, 28, 36, 48}
		for size in sizes {
			slug_draw_text(ctx, "Slug", 30, y_pos, size, COLOR_PINK)
			y_pos += size + 8
		}

		// Resolution independence callout
		y_pos += 10
		slug_draw_text(ctx, "Resolution Independent!", 30, y_pos, 36, COLOR_ORANGE)
		y_pos += 50

		// --- Rotating text ---
		// Slowly spinning text in the upper-right area
		draw_text_rotated(
			ctx,
			"Resolution Independent!",
			900, 120,
			22,
			total_time * 0.5,  // radians, slow spin
			COLOR_ORANGE,
		)

		// Second rotating text, opposite direction
		draw_text_rotated(
			ctx,
			"* GPU Bezier Curves *",
			900, 120,
			16,
			-total_time * 0.3,
			COLOR_CYAN,
		)

		// --- Text on a circle ---
		draw_text_on_circle(
			ctx,
			"  Slug Patent Now Public Domain!  ",
			640, 420,
			150,                    // radius
			-total_time * 0.4,      // rotating start angle
			18,
			COLOR_YELLOW,
		)

		// Inner circle, opposite direction
		draw_text_on_circle(
			ctx,
			"  Odin + Vulkan + SDL3  ",
			640, 420,
			100,
			total_time * 0.6,
			14,
			COLOR_GREEN,
		)

		// --- Text on a sine wave ---
		draw_text_on_wave(
			ctx,
			"waves of text flowing smoothly",
			30, 680,
			18,
			20.0,                   // amplitude
			300.0,                  // wavelength
			total_time * 2.0,       // phase (animates the wave)
			COLOR_PINK,
		)

		// --- Damage numbers (upper right area) ---
		draw_damage_numbers(ctx)

		// --- Combat log (right side, font 0) ---
		combat_log_draw(ctx, &combat_log, 850, 300, 300)

		// --- HUD info (font 0) ---
		zoom_buf: [32]u8
		zoom_text := fmt.bprintf(zoom_buf[:], "Zoom: %.1fx", ctx.zoom)
		slug_draw_text(ctx, zoom_text, 30, 692, 14, COLOR_DIM)
		slug_draw_text(ctx, "Scroll: zoom | MMB: pan | R: reset | Space: hit!", 30, 708, 12, COLOR_DIM)

		// --- Multi-font demo ---
		// Liberation Sans (proportional, has kerning)
		slug_use_font(ctx, 1)
		slug_draw_text(ctx, "Liberation Sans (proportional)", 30, y_pos, 16, COLOR_DIM)
		y_pos += 22
		slug_draw_text(ctx, "The quick brown fox jumps over the lazy dog", 30, y_pos, 24, COLOR_WHITE)
		y_pos += 34
		slug_draw_text(ctx, "AV WA To LT VA — kerned pairs", 30, y_pos, 28, COLOR_CYAN)
		y_pos += 40

		// Liberation Serif
		slug_use_font(ctx, 2)
		slug_draw_text(ctx, "Liberation Serif", 30, y_pos, 16, COLOR_DIM)
		y_pos += 22
		slug_draw_text(ctx, "The quick brown fox jumps over the lazy dog", 30, y_pos, 24, COLOR_WHITE)
		y_pos += 34
		slug_draw_text(ctx, "AV WA To LT VA — kerned pairs", 30, y_pos, 28, COLOR_YELLOW)
		y_pos += 40

		// Back to mono for comparison
		slug_use_font(ctx, 0)
		slug_draw_text(ctx, "Liberation Mono (monospace, no kerning)", 30, y_pos, 16, COLOR_DIM)
		y_pos += 22
		slug_draw_text(ctx, "AV WA To LT VA — no kerning", 30, y_pos, 28, COLOR_DIM)

		slug_end(ctx)

		// --- Render ---
		if !slug_draw_frame(ctx) {
			fmt.eprintln("Draw frame failed")
			break
		}

		frame_count += 1
	}

	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
	}

	fmt.println("Shutting down.")
}
