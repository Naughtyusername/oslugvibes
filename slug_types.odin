package slugvibes

import vk "vendor:vulkan"
import stbtt "vendor:stb/truetype"

// ===================================================
// Shared types for the Slug font rendering system
// ===================================================

// Texture dimensions — matches kLogBandTextureWidth in the shader
BAND_TEXTURE_WIDTH_LOG2 :: 12
BAND_TEXTURE_WIDTH      :: 1 << BAND_TEXTURE_WIDTH_LOG2  // 4096

// Maximum number of glyphs we cache (ASCII + extended Latin)
MAX_CACHED_GLYPHS :: 256

// Maximum quads (one quad per glyph instance on screen)
MAX_GLYPH_QUADS    :: 4096
VERTICES_PER_QUAD  :: 4
INDICES_PER_QUAD   :: 6
MAX_GLYPH_VERTICES :: MAX_GLYPH_QUADS * VERTICES_PER_QUAD
MAX_GLYPH_INDICES  :: MAX_GLYPH_QUADS * INDICES_PER_QUAD

// Vulkan sync
MAX_FRAMES_IN_FLIGHT :: 2

// --- Slug Vertex Format ---
// Matches the 5x vec4 attribute layout from the reference vertex shader.
// Total: 80 bytes per vertex.

Slug_Vertex :: struct {
	pos: [4]f32,   // .xy = object-space position, .zw = dilation normal
	tex: [4]f32,   // .xy = em-space texcoord, .zw = packed glyph data (bit-cast)
	jac: [4]f32,   // inverse Jacobian (00, 01, 10, 11)
	bnd: [4]f32,   // band transform (scale_x, scale_y, offset_x, offset_y)
	col: [4]f32,   // vertex color RGBA
}

// --- Glyph metrics and curve data ---

Bezier_Curve :: struct {
	p1: [2]f32,    // First control point
	p2: [2]f32,    // Second control point (off-curve)
	p3: [2]f32,    // Third control point
}

Band :: struct {
	curve_count: u16,
	data_offset: u16,  // Offset into the band texture curve list
}

// Per-glyph data after processing
Glyph_Data :: struct {
	// Metrics (in em-space, normalized)
	bbox_min:       [2]f32,
	bbox_max:       [2]f32,
	advance_width:  f32,
	left_bearing:   f32,

	// Curve data
	curves:         [dynamic]Bezier_Curve,

	// Band data
	h_bands:        [dynamic]Band,   // Horizontal bands
	v_bands:        [dynamic]Band,   // Vertical bands
	h_curve_lists:  [dynamic]u16,    // Curve indices for horizontal bands
	v_curve_lists:  [dynamic]u16,    // Curve indices for vertical bands

	// Location in the GPU textures (set during packing)
	curve_tex_x:    u16,   // X offset in curve texture
	curve_tex_y:    u16,   // Y offset in curve texture
	band_tex_x:     u16,   // X offset in band texture
	band_tex_y:     u16,   // Y offset in band texture
	band_max_x:     u16,   // Number of vertical bands - 1
	band_max_y:     u16,   // Number of horizontal bands - 1

	// Band transform for shader
	band_scale:     [2]f32,
	band_offset:    [2]f32,

	// Codepoint this glyph represents
	codepoint:      rune,
	glyph_index:    i32,
	valid:          bool,
}

// Font data loaded from a TTF file
Font :: struct {
	// stb_truetype font info
	info:           stbtt.fontinfo,
	font_data:      []u8,  // Raw TTF file data (must stay alive)

	// Font metrics
	ascent:         f32,   // Distance from baseline to top
	descent:        f32,   // Distance from baseline to bottom (negative)
	line_gap:       f32,   // Extra spacing between lines
	em_scale:       f32,   // Scale factor: 1.0 / units_per_em

	// Glyph cache (indexed by codepoint for ASCII range)
	glyphs:         [MAX_CACHED_GLYPHS]Glyph_Data,
}

// Vulkan GPU texture handle
GPU_Texture :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
	width:   u32,
	height:  u32,
}

// The main Vulkan rendering context for Slug
Slug_Context :: struct {
	// Core Vulkan state
	instance:          vk.Instance,
	debug_messenger:   vk.DebugUtilsMessengerEXT,
	surface:           vk.SurfaceKHR,
	physical_device:   vk.PhysicalDevice,
	device:            vk.Device,
	graphics_queue:    vk.Queue,
	present_queue:     vk.Queue,
	graphics_family:   u32,
	present_family:    u32,

	// Swapchain
	swapchain:         vk.SwapchainKHR,
	swapchain_images:  []vk.Image,
	swapchain_views:   []vk.ImageView,
	swapchain_format:  vk.SurfaceFormatKHR,
	swapchain_extent:  vk.Extent2D,

	// Render pass and framebuffers (direct to swapchain)
	render_pass:       vk.RenderPass,
	framebuffers:      []vk.Framebuffer,

	// Slug pipeline
	pipeline_layout:   vk.PipelineLayout,
	pipeline:          vk.Pipeline,

	// Descriptors (curve texture + band texture)
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_pool:       vk.DescriptorPool,
	descriptor_set:        vk.DescriptorSet,

	// GPU textures
	curve_texture:     GPU_Texture,
	band_texture:      GPU_Texture,

	// Vertex/index buffers
	vertex_buffer:     vk.Buffer,
	vertex_memory:     vk.DeviceMemory,
	vertex_mapped:     [^]Slug_Vertex,
	index_buffer:      vk.Buffer,
	index_memory:      vk.DeviceMemory,

	// Command state
	command_pool:      vk.CommandPool,
	command_buffers:   []vk.CommandBuffer,

	// Sync
	image_available:   []vk.Semaphore,
	render_finished:   []vk.Semaphore,
	in_flight_fences:  []vk.Fence,
	current_frame:     u32,

	// Per-frame draw state
	quad_count:        u32,

	// View transform (zoom/pan)
	zoom:              f32,
	pan:               [2]f32,

	// Font
	font:              Font,
}

