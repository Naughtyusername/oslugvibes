package slugvibes

import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import vk "vendor:vulkan"
import sdl "vendor:sdl3"

// ===================================================
// Slug Renderer — Vulkan init, pipeline, draw calls
// Uses SDL3 for windowing and Vulkan surface creation.
// ===================================================

// --- Push constant layout (must match vertex shader) ---
Slug_Push_Constants :: struct {
	mvp:      matrix[4, 4]f32,  // 64 bytes
	viewport: [2]f32,           // 8 bytes
}

// --- Initialization ---

slug_init :: proc(ctx: ^Slug_Context, window: ^sdl.Window) -> bool {
	ctx.window = window

	// Load Vulkan via SDL3
	if !sdl.Vulkan_LoadLibrary(nil) {
		fmt.eprintln("SDL3: Failed to load Vulkan library:", sdl.GetError())
		return false
	}

	get_instance_proc := sdl.Vulkan_GetVkGetInstanceProcAddr()
	if get_instance_proc == nil {
		fmt.eprintln("SDL3: Failed to get vkGetInstanceProcAddr")
		return false
	}

	vk.load_proc_addresses_global(rawptr(get_instance_proc))

	if !create_instance(ctx)      do return false
	vk.load_proc_addresses_instance(ctx.instance)

	when ENABLE_VALIDATION {
		setup_debug_messenger(ctx)
	}

	// Create surface via SDL3
	if !sdl.Vulkan_CreateSurface(window, ctx.instance, nil, &ctx.surface) {
		fmt.eprintln("SDL3: Failed to create Vulkan surface:", sdl.GetError())
		return false
	}

	if !pick_physical_device(ctx)    do return false
	if !create_logical_device(ctx)   do return false
	vk.load_proc_addresses_device(ctx.device)

	if !create_swapchain(ctx, window)   do return false
	if !create_image_views(ctx)         do return false
	if !create_command_pool(ctx)        do return false
	if !create_render_pass(ctx)         do return false
	if !create_framebuffers(ctx)        do return false
	if !create_descriptor_set_layout(ctx)  do return false
	if !create_slug_pipeline(ctx)       do return false
	if !create_command_buffers(ctx)     do return false
	if !create_sync_objects(ctx)        do return false
	if !create_vertex_index_buffers(ctx)   do return false

	return true
}

slug_shutdown :: proc(ctx: ^Slug_Context) {
	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
	}

	// Fonts (slot 0 textures are aliases of ctx.curve_texture/band_texture)
	font_destroy(&ctx.font)
	gpu_texture_destroy(ctx, &ctx.curve_texture)
	gpu_texture_destroy(ctx, &ctx.band_texture)

	// Extra font slots (1+)
	for i in 1..<MAX_FONT_SLOTS {
		fi := &ctx.font_slots[i]
		if fi.loaded {
			font_destroy(&fi.font)
			gpu_texture_destroy(ctx, &fi.curve_texture)
			gpu_texture_destroy(ctx, &fi.band_texture)
		}
	}

	// Vertex/index buffers
	if ctx.vertex_buffer != 0 do vk.DestroyBuffer(ctx.device, ctx.vertex_buffer, nil)
	if ctx.vertex_memory != 0 do vk.FreeMemory(ctx.device, ctx.vertex_memory, nil)
	if ctx.index_buffer != 0  do vk.DestroyBuffer(ctx.device, ctx.index_buffer, nil)
	if ctx.index_memory != 0  do vk.FreeMemory(ctx.device, ctx.index_memory, nil)

	// Descriptors
	if ctx.descriptor_pool != 0       do vk.DestroyDescriptorPool(ctx.device, ctx.descriptor_pool, nil)
	if ctx.descriptor_set_layout != 0 do vk.DestroyDescriptorSetLayout(ctx.device, ctx.descriptor_set_layout, nil)

	// Pipeline
	if ctx.pipeline != 0        do vk.DestroyPipeline(ctx.device, ctx.pipeline, nil)
	if ctx.pipeline_layout != 0 do vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)

	// Command pool
	if ctx.command_pool != 0 do vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

	// Sync objects
	for sem in ctx.image_available {
		if sem != 0 do vk.DestroySemaphore(ctx.device, sem, nil)
	}
	delete(ctx.image_available)
	for sem in ctx.render_finished {
		if sem != 0 do vk.DestroySemaphore(ctx.device, sem, nil)
	}
	delete(ctx.render_finished)
	for fence in ctx.in_flight_fences {
		if fence != 0 do vk.DestroyFence(ctx.device, fence, nil)
	}
	delete(ctx.in_flight_fences)

	// Framebuffers + swapchain
	for fb in ctx.framebuffers {
		if fb != 0 do vk.DestroyFramebuffer(ctx.device, fb, nil)
	}
	delete(ctx.framebuffers)
	delete(ctx.command_buffers)
	for view in ctx.swapchain_views {
		if view != 0 do vk.DestroyImageView(ctx.device, view, nil)
	}
	delete(ctx.swapchain_views)
	delete(ctx.swapchain_images)
	if ctx.swapchain != 0 do vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)

	if ctx.render_pass != 0 do vk.DestroyRenderPass(ctx.device, ctx.render_pass, nil)
	if ctx.device != nil    do vk.DestroyDevice(ctx.device, nil)

	when ENABLE_VALIDATION {
		if ctx.debug_messenger != 0 {
			vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)
		}
	}

	if ctx.surface != 0   do vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
	if ctx.instance != nil do vk.DestroyInstance(ctx.instance, nil)
}

// --- Swapchain recreation (window resize) ---

@(private="file")
cleanup_swapchain :: proc(ctx: ^Slug_Context) {
	// Destroy framebuffers
	for fb in ctx.framebuffers {
		if fb != 0 do vk.DestroyFramebuffer(ctx.device, fb, nil)
	}
	delete(ctx.framebuffers)

	// Destroy image views
	for view in ctx.swapchain_views {
		if view != 0 do vk.DestroyImageView(ctx.device, view, nil)
	}
	delete(ctx.swapchain_views)

	// Destroy swapchain images slice (images are owned by the swapchain, not us)
	delete(ctx.swapchain_images)

	// Destroy old swapchain
	if ctx.swapchain != 0 do vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)
}

recreate_swapchain :: proc(ctx: ^Slug_Context) -> bool {
	// Handle minimized window: wait until we have a non-zero size
	w, h: i32
	sdl.GetWindowSizeInPixels(ctx.window, &w, &h)
	for w == 0 || h == 0 {
		sdl.GetWindowSizeInPixels(ctx.window, &w, &h)
		_ = sdl.WaitEvent(nil)
	}

	vk.DeviceWaitIdle(ctx.device)

	// Free old command buffers (count may change with new swapchain image count)
	if ctx.command_buffers != nil {
		vk.FreeCommandBuffers(
			ctx.device, ctx.command_pool,
			u32(len(ctx.command_buffers)), raw_data(ctx.command_buffers),
		)
		delete(ctx.command_buffers)
	}

	cleanup_swapchain(ctx)

	if !create_swapchain(ctx, ctx.window) {
		fmt.eprintln("recreate_swapchain: failed to create swapchain")
		return false
	}
	if !create_image_views(ctx) {
		fmt.eprintln("recreate_swapchain: failed to create image views")
		return false
	}
	if !create_framebuffers(ctx) {
		fmt.eprintln("recreate_swapchain: failed to create framebuffers")
		return false
	}
	if !create_command_buffers(ctx) {
		fmt.eprintln("recreate_swapchain: failed to create command buffers")
		return false
	}

	// Reset current_frame in case the new swapchain has fewer images
	ctx.current_frame = 0

	ctx.framebuffer_resized = false

	return true
}

// --- Instance creation ---

@(private="file")
create_instance :: proc(ctx: ^Slug_Context) -> bool {
	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "SlugVibes",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "Slug",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	// Get SDL3's required Vulkan extensions
	ext_count: sdl.Uint32
	sdl_exts := sdl.Vulkan_GetInstanceExtensions(&ext_count)

	extensions: [dynamic]cstring
	defer delete(extensions)

	if sdl_exts != nil {
		for i in 0..<ext_count {
			append(&extensions, sdl_exts[i])
		}
	}

	when ENABLE_VALIDATION {
		append(&extensions, "VK_EXT_debug_utils")
	}

	validation_layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	when ENABLE_VALIDATION {
		create_info.enabledLayerCount   = len(validation_layers)
		create_info.ppEnabledLayerNames = &validation_layers[0]
	}

	result := vk.CreateInstance(&create_info, nil, &ctx.instance)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create Vulkan instance:", result)
		return false
	}

	return true
}

// --- Debug messenger ---

when ENABLE_VALIDATION {
	@(private="file")
	setup_debug_messenger :: proc(ctx: ^Slug_Context) {
		create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = debug_callback,
		}
		vk.CreateDebugUtilsMessengerEXT(ctx.instance, &create_info, nil, &ctx.debug_messenger)
	}
}

// --- Physical device ---

@(private="file")
pick_physical_device :: proc(ctx: ^Slug_Context) -> bool {
	device_count: u32
	vk.EnumeratePhysicalDevices(ctx.instance, &device_count, nil)
	if device_count == 0 {
		fmt.eprintln("No Vulkan-capable GPU found")
		return false
	}

	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(ctx.instance, &device_count, raw_data(devices))

	for device in devices {
		gfx_family, gfx_found := find_queue_family(device, {.GRAPHICS})
		pres_family, pres_found := find_present_family(ctx, device)

		if !gfx_found || !pres_found do continue

		// Check swapchain support
		ext_count: u32
		vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, nil)
		exts := make([]vk.ExtensionProperties, ext_count)
		defer delete(exts)
		vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, raw_data(exts))

		has_swapchain := false
		for &ext in exts {
			name := cstring(raw_data(&ext.extensionName))
			if name == "VK_KHR_swapchain" {
				has_swapchain = true
				break
			}
		}
		if !has_swapchain do continue

		ctx.physical_device = device
		ctx.graphics_family = gfx_family
		ctx.present_family = pres_family
		return true
	}

	fmt.eprintln("No suitable GPU found")
	return false
}

@(private="file")
find_queue_family :: proc(device: vk.PhysicalDevice, required: vk.QueueFlags) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	families := make([]vk.QueueFamilyProperties, count)
	defer delete(families)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if required <= family.queueFlags {
			return u32(i), true
		}
	}
	return 0, false
}

@(private="file")
find_present_family :: proc(ctx: ^Slug_Context, device: vk.PhysicalDevice) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	for i in 0..<count {
		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, i, ctx.surface, &supported)
		if supported do return i, true
	}
	return 0, false
}

// --- Logical device ---

@(private="file")
create_logical_device :: proc(ctx: ^Slug_Context) -> bool {
	unique_families: [2]u32
	family_count: u32 = 1
	unique_families[0] = ctx.graphics_family
	if ctx.present_family != ctx.graphics_family {
		unique_families[1] = ctx.present_family
		family_count = 2
	}

	queue_priority: f32 = 1.0
	queue_create_infos: [2]vk.DeviceQueueCreateInfo
	for i in 0..<family_count {
		queue_create_infos[i] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = unique_families[i],
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
	}

	device_extensions := [?]cstring{"VK_KHR_swapchain"}
	features := vk.PhysicalDeviceFeatures{}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = family_count,
		pQueueCreateInfos       = &queue_create_infos[0],
		enabledExtensionCount   = len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
		pEnabledFeatures        = &features,
	}

	result := vk.CreateDevice(ctx.physical_device, &create_info, nil, &ctx.device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create logical device:", result)
		return false
	}

	vk.GetDeviceQueue(ctx.device, ctx.graphics_family, 0, &ctx.graphics_queue)
	vk.GetDeviceQueue(ctx.device, ctx.present_family, 0, &ctx.present_queue)

	return true
}

// --- Swapchain ---

@(private="file")
create_swapchain :: proc(ctx: ^Slug_Context, window: ^sdl.Window) -> bool {
	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, raw_data(formats))

	chosen_format := formats[0]
	for sf in formats {
		if sf.format == .B8G8R8A8_SRGB && sf.colorSpace == .SRGB_NONLINEAR {
			chosen_format = sf
			break
		}
	}
	ctx.swapchain_format = chosen_format

	// FIFO = vsync, avoids tearing on Wayland compositors
	chosen_mode := vk.PresentModeKHR.FIFO

	extent: vk.Extent2D
	if capabilities.currentExtent.width != max(u32) {
		extent = capabilities.currentExtent
	} else {
		w, h: i32
		sdl.GetWindowSizeInPixels(window, &w, &h)
		extent = vk.Extent2D {
			width  = clamp(u32(w), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(u32(h), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		}
	}
	ctx.swapchain_extent = extent

	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ctx.surface,
		minImageCount    = image_count,
		imageFormat      = chosen_format.format,
		imageColorSpace  = chosen_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = chosen_mode,
		clipped          = true,
	}

	queue_families := [?]u32{ctx.graphics_family, ctx.present_family}
	if ctx.graphics_family != ctx.present_family {
		create_info.imageSharingMode      = .CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices   = &queue_families[0]
	} else {
		create_info.imageSharingMode = .EXCLUSIVE
	}

	result := vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &ctx.swapchain)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create swapchain:", result)
		return false
	}

	sc_count: u32
	vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &sc_count, nil)
	ctx.swapchain_images = make([]vk.Image, sc_count)
	vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &sc_count, raw_data(ctx.swapchain_images))

	return true
}

@(private="file")
create_image_views :: proc(ctx: ^Slug_Context) -> bool {
	ctx.swapchain_views = make([]vk.ImageView, len(ctx.swapchain_images))

	for img, i in ctx.swapchain_images {
		create_info := vk.ImageViewCreateInfo {
			sType    = .IMAGE_VIEW_CREATE_INFO,
			image    = img,
			viewType = .D2,
			format   = ctx.swapchain_format.format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask     = {.COLOR},
				baseMipLevel   = 0,
				levelCount     = 1,
				baseArrayLayer = 0,
				layerCount     = 1,
			},
		}

		result := vk.CreateImageView(ctx.device, &create_info, nil, &ctx.swapchain_views[i])
		if result != .SUCCESS {
			fmt.eprintln("Failed to create image view:", result)
			return false
		}
	}

	return true
}

// --- Command pool ---

@(private="file")
create_command_pool :: proc(ctx: ^Slug_Context) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.graphics_family,
	}

	result := vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.command_pool)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create command pool:", result)
		return false
	}

	return true
}

// --- Render pass ---

@(private="file")
create_render_pass :: proc(ctx: ^Slug_Context) -> bool {
	color_attachment := vk.AttachmentDescription {
		format         = ctx.swapchain_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}

	color_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_ref,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}

	create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	result := vk.CreateRenderPass(ctx.device, &create_info, nil, &ctx.render_pass)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create render pass:", result)
		return false
	}

	return true
}

// --- Framebuffers ---

@(private="file")
create_framebuffers :: proc(ctx: ^Slug_Context) -> bool {
	ctx.framebuffers = make([]vk.Framebuffer, len(ctx.swapchain_views))

	for view, i in ctx.swapchain_views {
		attachments := [1]vk.ImageView{view}

		fb_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = ctx.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = ctx.swapchain_extent.width,
			height          = ctx.swapchain_extent.height,
			layers          = 1,
		}

		result := vk.CreateFramebuffer(ctx.device, &fb_info, nil, &ctx.framebuffers[i])
		if result != .SUCCESS {
			fmt.eprintln("Failed to create framebuffer:", result)
			return false
		}
	}

	return true
}

// --- Descriptor set layout ---

@(private="file")
create_descriptor_set_layout :: proc(ctx: ^Slug_Context) -> bool {
	// Binding 0: curve texture (combined image sampler)
	// Binding 1: band texture (combined image sampler — uses usampler2D in shader)
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding         = 0,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
		{
			binding         = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}

	result := vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.descriptor_set_layout)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create descriptor set layout:", result)
		return false
	}

	return true
}

// --- Slug graphics pipeline ---

@(private="file")
create_slug_pipeline :: proc(ctx: ^Slug_Context) -> bool {
	vert_code, vert_err := os.read_entire_file("shaders/slug_vert.spv", context.allocator)
	if vert_err != nil {
		fmt.eprintln("Failed to read slug vertex shader:", vert_err)
		return false
	}
	defer delete(vert_code)

	frag_code, frag_err := os.read_entire_file("shaders/slug_frag.spv", context.allocator)
	if frag_err != nil {
		fmt.eprintln("Failed to read slug fragment shader:", frag_err)
		return false
	}
	defer delete(frag_code)

	vert_module, vert_ok := create_shader_module(ctx, vert_code)
	if !vert_ok do return false
	defer vk.DestroyShaderModule(ctx.device, vert_module, nil)

	frag_module, frag_ok := create_shader_module(ctx, frag_code)
	if !frag_ok do return false
	defer vk.DestroyShaderModule(ctx.device, frag_module, nil)

	shader_stages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = vert_module,
			pName  = "main",
		},
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = frag_module,
			pName  = "main",
		},
	}

	// Slug vertex format: 5x vec4 = 80 bytes per vertex
	binding_desc := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Slug_Vertex),
		inputRate = .VERTEX,
	}

	attrib_descs := [5]vk.VertexInputAttributeDescription {
		{binding = 0, location = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Slug_Vertex, pos))},
		{binding = 0, location = 1, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Slug_Vertex, tex))},
		{binding = 0, location = 2, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Slug_Vertex, jac))},
		{binding = 0, location = 3, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Slug_Vertex, bnd))},
		{binding = 0, location = 4, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Slug_Vertex, col))},
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_desc,
		vertexAttributeDescriptionCount = len(attrib_descs),
		pVertexAttributeDescriptions    = &attrib_descs[0],
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1.0,
		cullMode    = {},  // No culling for text quads
		frontFace   = .COUNTER_CLOCKWISE,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	// Alpha blending: premultiplied alpha (coverage * color in fragment shader)
	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	// Push constants: mat4 (64 bytes) + vec2 viewport (8 bytes) = 72 bytes
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(Slug_Push_Constants),
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &ctx.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}

	result := vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.pipeline_layout)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create pipeline layout:", result)
		return false
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shader_stages),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = ctx.pipeline_layout,
		renderPass          = ctx.render_pass,
		subpass             = 0,
	}

	result = vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &ctx.pipeline)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create Slug graphics pipeline:", result)
		return false
	}

	return true
}

// --- Command buffers ---

@(private="file")
create_command_buffers :: proc(ctx: ^Slug_Context) -> bool {
	ctx.command_buffers = make([]vk.CommandBuffer, len(ctx.swapchain_images))

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(ctx.command_buffers)),
	}

	result := vk.AllocateCommandBuffers(ctx.device, &alloc_info, raw_data(ctx.command_buffers))
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate command buffers:", result)
		return false
	}

	return true
}

// --- Sync objects ---

@(private="file")
create_sync_objects :: proc(ctx: ^Slug_Context) -> bool {
	n := len(ctx.swapchain_images)
	ctx.image_available = make([]vk.Semaphore, n)
	ctx.render_finished = make([]vk.Semaphore, n)
	ctx.in_flight_fences = make([]vk.Fence, n)

	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for i in 0..<n {
		if vk.CreateSemaphore(ctx.device, &sem_info, nil, &ctx.image_available[i]) != .SUCCESS do return false
		if vk.CreateSemaphore(ctx.device, &sem_info, nil, &ctx.render_finished[i]) != .SUCCESS do return false
		if vk.CreateFence(ctx.device, &fence_info, nil, &ctx.in_flight_fences[i]) != .SUCCESS do return false
	}

	return true
}

// --- Vertex and index buffers ---

@(private="file")
create_vertex_index_buffers :: proc(ctx: ^Slug_Context) -> bool {
	// Vertex buffer: persistently mapped HOST_VISIBLE
	vb_size := vk.DeviceSize(MAX_GLYPH_VERTICES * size_of(Slug_Vertex))
	vb, vm, vb_ok := create_buffer(ctx, vb_size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	if !vb_ok do return false
	ctx.vertex_buffer = vb
	ctx.vertex_memory = vm

	mapped: rawptr
	if vk.MapMemory(ctx.device, vm, 0, vb_size, {}, &mapped) != .SUCCESS {
		fmt.eprintln("Failed to map vertex buffer")
		return false
	}
	ctx.vertex_mapped = cast([^]Slug_Vertex)mapped

	// Index buffer: pre-generated quad indices, uploaded once
	indices := generate_quad_indices(MAX_GLYPH_QUADS)
	defer delete(indices)

	ib_size := vk.DeviceSize(len(indices) * size_of(u32))

	// Create staging buffer for index data
	staging_buf, staging_mem, staging_ok := create_buffer(
		ctx, ib_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !staging_ok do return false
	defer vk.DestroyBuffer(ctx.device, staging_buf, nil)
	defer vk.FreeMemory(ctx.device, staging_mem, nil)

	staging_mapped: rawptr
	vk.MapMemory(ctx.device, staging_mem, 0, ib_size, {}, &staging_mapped)
	mem.copy(staging_mapped, raw_data(indices), int(ib_size))
	vk.UnmapMemory(ctx.device, staging_mem)

	ib, im, ib_ok := create_buffer(ctx, ib_size, {.INDEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL})
	if !ib_ok do return false
	ctx.index_buffer = ib
	ctx.index_memory = im

	// Copy staging -> device
	cmd := begin_one_shot_commands(ctx)
	copy_region := vk.BufferCopy{size = ib_size}
	vk.CmdCopyBuffer(cmd, staging_buf, ib, 1, &copy_region)
	end_one_shot_commands(ctx, cmd)

	return true
}

// --- Upload font textures and create descriptors ---

slug_upload_font :: proc(ctx: ^Slug_Context, pack: ^Texture_Pack_Result) -> bool {
	// Upload curve texture (R16G16B16A16_SFLOAT)
	curve_data_size := len(pack.curve_data) * size_of([4]u16)
	curve_tex, curve_ok := gpu_texture_create(
		ctx,
		pack.curve_width, pack.curve_height,
		.R16G16B16A16_SFLOAT,
		raw_data(pack.curve_data),
		curve_data_size,
	)
	if !curve_ok do return false
	ctx.curve_texture = curve_tex

	// Upload band texture (R16G16_UINT)
	band_data_size := len(pack.band_data) * size_of([2]u16)
	band_tex, band_ok := gpu_texture_create(
		ctx,
		pack.band_width, pack.band_height,
		.R16G16_UINT,
		raw_data(pack.band_data),
		band_data_size,
	)
	if !band_ok do return false
	ctx.band_texture = band_tex

	// Create descriptor pool and set
	pool_sizes := [1]vk.DescriptorPoolSize {
		{
			type            = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 2 * MAX_FONT_SLOTS,  // 2 textures per font
		},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = &pool_sizes[0],
		maxSets       = MAX_FONT_SLOTS,
	}

	result := vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &ctx.descriptor_pool)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create descriptor pool:", result)
		return false
	}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ctx.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ctx.descriptor_set_layout,
	}

	result = vk.AllocateDescriptorSets(ctx.device, &alloc_info, &ctx.descriptor_set)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate descriptor set:", result)
		return false
	}

	// Write descriptor set
	curve_image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = ctx.curve_texture.view,
		sampler     = ctx.curve_texture.sampler,
	}

	band_image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = ctx.band_texture.view,
		sampler     = ctx.band_texture.sampler,
	}

	writes := [2]vk.WriteDescriptorSet {
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = ctx.descriptor_set,
			dstBinding      = 0,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &curve_image_info,
		},
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = ctx.descriptor_set,
			dstBinding      = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &band_image_info,
		},
	}

	vk.UpdateDescriptorSets(ctx.device, len(writes), &writes[0], 0, nil)

	// Register as font slot 0
	ctx.font_slots[0].curve_texture = ctx.curve_texture
	ctx.font_slots[0].band_texture = ctx.band_texture
	ctx.font_slots[0].descriptor_set = ctx.descriptor_set
	ctx.font_slots[0].loaded = true
	ctx.font_slots[0].name = "default"
	ctx.font_slot_count = max(ctx.font_slot_count, 1)

	fmt.println("Font textures uploaded to GPU")
	return true
}

// ===================================================
// Text drawing — builds vertex data for a string
// ===================================================

slug_begin :: proc(ctx: ^Slug_Context) {
	// Wait for ALL in-flight GPU work to complete before overwriting the
	// shared vertex buffer. We have one vertex buffer but multiple frames
	// in flight — any of them could still be reading from it.
	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
	}

	ctx.quad_count = 0
	ctx.active_font_idx = 0
	for i in 0..<MAX_FONT_SLOTS {
		ctx.font_quad_start[i] = 0
		ctx.font_quad_count[i] = 0
	}
}

// Switch the active font for subsequent slug_draw_text calls.
// Font slot 0 is the default (ctx.font).
slug_use_font :: proc(ctx: ^Slug_Context, slot: int) {
	if slot < 0 || slot >= ctx.font_slot_count do return
	// Record where the previous font's quads ended
	prev := ctx.active_font_idx
	ctx.font_quad_count[prev] = ctx.quad_count - ctx.font_quad_start[prev]
	// Start the new font's quads at the current position
	ctx.active_font_idx = slot
	ctx.font_quad_start[slot] = ctx.quad_count
}

// Get the Font pointer for the currently active font slot.
slug_active_font :: proc(ctx: ^Slug_Context) -> ^Font {
	slot := ctx.active_font_idx
	if slot == 0 {
		return &ctx.font
	}
	return &ctx.font_slots[slot].font
}

// Load a font into a slot (slot 0 is reserved for ctx.font).
slug_load_font_slot :: proc(ctx: ^Slug_Context, slot: int, path: string, name: string) -> bool {
	if slot < 1 || slot >= MAX_FONT_SLOTS {
		fmt.eprintln("Invalid font slot:", slot)
		return false
	}

	fi := &ctx.font_slots[slot]

	font, font_ok := font_load(path)
	if !font_ok {
		fmt.eprintln("Failed to load font:", path)
		return false
	}
	fi.font = font
	fi.name = name

	font_load_ascii(&fi.font)

	for gi in 0..<MAX_CACHED_GLYPHS {
		g := &fi.font.glyphs[gi]
		if g.valid && len(g.curves) > 0 {
			glyph_process(g)
		}
	}

	pack := pack_glyph_textures(&fi.font)
	defer pack_result_destroy(&pack)

	// Upload curve texture
	curve_data_size := len(pack.curve_data) * size_of([4]u16)
	curve_tex, curve_ok := gpu_texture_create(
		ctx,
		pack.curve_width, pack.curve_height,
		.R16G16B16A16_SFLOAT,
		raw_data(pack.curve_data),
		curve_data_size,
	)
	if !curve_ok do return false
	fi.curve_texture = curve_tex

	// Upload band texture
	band_data_size := len(pack.band_data) * size_of([2]u16)
	band_tex, band_ok := gpu_texture_create(
		ctx,
		pack.band_width, pack.band_height,
		.R16G16_UINT,
		raw_data(pack.band_data),
		band_data_size,
	)
	if !band_ok do return false
	fi.band_texture = band_tex

	// Allocate descriptor set from the existing pool
	alloc_info := vk.DescriptorSetAllocateInfo{
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ctx.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ctx.descriptor_set_layout,
	}

	result := vk.AllocateDescriptorSets(ctx.device, &alloc_info, &fi.descriptor_set)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate descriptor set for font slot:", slot)
		return false
	}

	// Write descriptor set
	curve_image_info := vk.DescriptorImageInfo{
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = fi.curve_texture.view,
		sampler     = fi.curve_texture.sampler,
	}
	band_image_info := vk.DescriptorImageInfo{
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = fi.band_texture.view,
		sampler     = fi.band_texture.sampler,
	}
	writes := [2]vk.WriteDescriptorSet{
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = fi.descriptor_set,
			dstBinding      = 0,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &curve_image_info,
		},
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = fi.descriptor_set,
			dstBinding      = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &band_image_info,
		},
	}
	vk.UpdateDescriptorSets(ctx.device, len(writes), &writes[0], 0, nil)

	fi.loaded = true
	if slot >= ctx.font_slot_count {
		ctx.font_slot_count = slot + 1
	}
	fmt.printf("Font slot %d loaded: %s\n", slot, name)
	return true
}

// Measure a string's dimensions without drawing.
// Returns (width, height) in screen pixels at the given font_size.
measure_text :: proc(font: ^Font, text: string, font_size: f32, use_kerning: bool = true) -> (width: f32, height: f32) {
	pen_x: f32 = 0
	prev_rune: rune = 0
	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS {
			prev_rune = ch
			continue
		}
		g := &font.glyphs[idx]
		if !g.valid {
			prev_rune = ch
			continue
		}
		if use_kerning && prev_rune != 0 {
			pen_x += font_get_kerning(font, prev_rune, ch) * font_size
		}
		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
	return pen_x, (font.ascent - font.descent) * font_size
}

// Draw a string of text at the given position and size.
// x, y is the baseline-left position in world/screen coordinates.
// font_size is the height in pixels (or world units) of the em square.
slug_draw_text :: proc(
	ctx: ^Slug_Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: [4]f32,
	use_kerning: bool = true,
) {
	font := slug_active_font(ctx)
	pen_x := x

	prev_rune: rune = 0

	for ch in text {
		idx := int(ch)
		if idx < 0 || idx >= MAX_CACHED_GLYPHS {
			prev_rune = ch
			continue
		}

		g := &font.glyphs[idx]
		if !g.valid {
			prev_rune = ch
			continue
		}

		// Apply kerning from previous character
		if use_kerning && prev_rune != 0 {
			kern := font_get_kerning(font, prev_rune, ch)
			pen_x += kern * font_size
		}

		// Position the glyph quad in Y-down screen space.
		glyph_x := pen_x + g.bbox_min.x * font_size
		glyph_y := y - g.bbox_max.y * font_size

		glyph_w := (g.bbox_max.x - g.bbox_min.x) * font_size
		glyph_h := (g.bbox_max.y - g.bbox_min.y) * font_size

		if len(g.curves) > 0 && ctx.quad_count < MAX_GLYPH_QUADS {
			emit_glyph_quad(ctx, g, glyph_x, glyph_y, glyph_w, glyph_h, color)
		}

		pen_x += g.advance_width * font_size
		prev_rune = ch
	}
}

emit_glyph_quad :: proc(
	ctx: ^Slug_Context,
	g: ^Glyph_Data,
	x, y, w, h: f32,
	color: [4]f32,
) {
	base := ctx.quad_count * VERTICES_PER_QUAD
	if base + VERTICES_PER_QUAD > MAX_GLYPH_VERTICES do return

	// Em-space texcoords (the glyph's bounding box in em-space)
	em_min := g.bbox_min
	em_max := g.bbox_max

	// Pack glyph data into float bits (matching the vertex shader's unpack)
	// tex.z = (band_tex_y << 16) | band_tex_x
	// tex.w = (band_max_y << 16) | band_max_x  (with flags in high bits of band_max_y)
	glyph_loc := transmute(f32)(u32(g.band_tex_x) | (u32(g.band_tex_y) << 16))
	band_max  := transmute(f32)(u32(g.band_max_x) | (u32(g.band_max_y) << 16))

	// Inverse Jacobian: maps object-space displacement to em-space displacement
	// Since we're doing a simple scale: em = (obj - origin) / size * em_range
	// The Jacobian is diagonal: d(em)/d(obj) = em_range / obj_size
	em_w := em_max.x - em_min.x
	em_h := em_max.y - em_min.y
	jac_00 := em_w / w if w > 0 else 0    // d(em_x)/d(obj_x)
	jac_11 := -(em_h / h) if h > 0 else 0 // d(em_y)/d(obj_y) — negative because screen Y is down, em Y is up

	// Dilation normals (pointing outward from each corner)
	// These are not unit length — the vertex shader normalizes them.
	// For a simple quad, normals point diagonally outward at corners.
	DILATION_SCALE :: f32(1.0)

	// 4 vertices in screen-space (Y-down): TL, TR, BR, BL
	// In screen space: (x,y) is top-left, (x+w, y+h) is bottom-right.
	// Em-space has Y-up: top-left in em = (em_min.x, em_max.y),
	//                    bottom-right in em = (em_max.x, em_min.y).
	corners := [4][2]f32{
		{x,     y},         // TL (screen)
		{x + w, y},         // TR
		{x + w, y + h},     // BR
		{x,     y + h},     // BL
	}

	normals := [4][2]f32{
		{-DILATION_SCALE,  -DILATION_SCALE},  // TL -> out toward top-left
		{ DILATION_SCALE,  -DILATION_SCALE},  // TR
		{ DILATION_SCALE,   DILATION_SCALE},  // BR
		{-DILATION_SCALE,   DILATION_SCALE},  // BL
	}

	em_coords := [4][2]f32{
		{em_min.x, em_max.y},  // TL in em-space (Y-up: max.y is top)
		{em_max.x, em_max.y},  // TR
		{em_max.x, em_min.y},  // BR (Y-up: min.y is bottom)
		{em_min.x, em_min.y},  // BL
	}

	for vi in 0..<4 {
		ctx.vertex_mapped[base + u32(vi)] = Slug_Vertex {
			pos = {corners[vi].x, corners[vi].y, normals[vi].x, normals[vi].y},
			tex = {em_coords[vi].x, em_coords[vi].y, glyph_loc, band_max},
			jac = {jac_00, 0, 0, jac_11},
			bnd = {g.band_scale.x, g.band_scale.y, g.band_offset.x, g.band_offset.y},
			col = color,
		}
	}

	ctx.quad_count += 1
}

// Emit a glyph quad with an arbitrary 2x2 transform (rotation + scale).
// center_x, center_y is the glyph center in screen space.
// xform is a 2x2 matrix applied to the em-space bounding box to produce screen-space corners.
emit_glyph_quad_transformed :: proc(
	ctx: ^Slug_Context,
	g: ^Glyph_Data,
	center_x, center_y: f32,
	xform: matrix[2, 2]f32,  // maps em-space-sized offsets to screen-space
	color: [4]f32,
) {
	base := ctx.quad_count * VERTICES_PER_QUAD
	if base + VERTICES_PER_QUAD > MAX_GLYPH_VERTICES do return

	em_min := g.bbox_min
	em_max := g.bbox_max
	em_w := em_max.x - em_min.x
	em_h := em_max.y - em_min.y
	em_cx := (em_min.x + em_max.x) * 0.5
	em_cy := (em_min.y + em_max.y) * 0.5

	// Pack glyph data
	glyph_loc := transmute(f32)(u32(g.band_tex_x) | (u32(g.band_tex_y) << 16))
	band_max  := transmute(f32)(u32(g.band_max_x) | (u32(g.band_max_y) << 16))

	// Em-space corner offsets relative to em-space center (Y-up in em-space)
	// Order: TL, TR, BR, BL in em-space
	em_offsets := [4][2]f32{
		{em_min.x - em_cx,  em_max.y - em_cy},  // TL in em (left, top)
		{em_max.x - em_cx,  em_max.y - em_cy},  // TR
		{em_max.x - em_cx,  em_min.y - em_cy},  // BR
		{em_min.x - em_cx,  em_min.y - em_cy},  // BL
	}

	em_coords := [4][2]f32{
		{em_min.x, em_max.y},  // TL
		{em_max.x, em_max.y},  // TR
		{em_max.x, em_min.y},  // BR
		{em_min.x, em_min.y},  // BL
	}

	// Inverse Jacobian: maps screen-space delta to em-space delta
	// Forward: screen = xform * em_offset
	// Inverse: em_delta = xform^-1 * screen_delta
	// But we also need the Y-flip (em Y-up vs screen Y-down)
	det := xform[0, 0] * xform[1, 1] - xform[0, 1] * xform[1, 0]
	inv_det := 1.0 / det if abs(det) > 1e-10 else 0.0
	// Inverse of xform, with Y negation for em-space Y-up
	inv_jac := matrix[2, 2]f32{
		 xform[1, 1] * inv_det,
		-xform[0, 1] * inv_det,
		 xform[1, 0] * inv_det,  // negated again for Y-flip = positive
		-xform[0, 0] * inv_det,  // negated again for Y-flip = negative
	}

	DILATION_SCALE :: f32(1.0)

	for vi in 0..<4 {
		// Transform em-space offset to screen-space offset
		// Note: em Y-up, screen Y-down, so negate Y component of em offset
		off := em_offsets[vi]
		screen_off := [2]f32{
			xform[0, 0] * off.x + xform[0, 1] * (-off.y),
			xform[1, 0] * off.x + xform[1, 1] * (-off.y),
		}

		// Dilation normal: points outward from center
		nx := screen_off.x
		ny := screen_off.y
		len_n := math.sqrt(nx * nx + ny * ny)
		if len_n > 0 {
			nx = nx / len_n * DILATION_SCALE
			ny = ny / len_n * DILATION_SCALE
		}

		ctx.vertex_mapped[base + u32(vi)] = Slug_Vertex{
			pos = {center_x + screen_off.x, center_y + screen_off.y, nx, ny},
			tex = {em_coords[vi].x, em_coords[vi].y, glyph_loc, band_max},
			jac = {inv_jac[0, 0], inv_jac[0, 1], inv_jac[1, 0], inv_jac[1, 1]},
			bnd = {g.band_scale.x, g.band_scale.y, g.band_offset.x, g.band_offset.y},
			col = color,
		}
	}

	ctx.quad_count += 1
}

slug_end :: proc(ctx: ^Slug_Context) {
	// Finalize the last active font's quad count
	prev := ctx.active_font_idx
	ctx.font_quad_count[prev] = ctx.quad_count - ctx.font_quad_start[prev]
}

// --- Draw frame ---

slug_draw_frame :: proc(ctx: ^Slug_Context) -> bool {
	frame := ctx.current_frame

	// Fence wait already done in slug_begin() to protect vertex buffer writes.
	// Acquire next swapchain image
	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		ctx.device, ctx.swapchain, max(u64),
		ctx.image_available[frame], 0, &image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		// Swapchain is incompatible with the surface — must recreate before drawing.
		// Do NOT reset the fence: AcquireNextImage failed, so nothing was submitted
		// against it. The fence is still signaled from the previous frame's completion.
		if !recreate_swapchain(ctx) do return false
		return true
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintln("Failed to acquire swapchain image:", acquire_result)
		return false
	}

	// Only reset the fence AFTER we know we will actually submit work.
	// If we reset before acquire and acquire fails, the fence stays unsignaled
	// and WaitForFences deadlocks on the next frame.
	vk.ResetFences(ctx.device, 1, &ctx.in_flight_fences[frame])

	cmd := ctx.command_buffers[image_index]
	vk.ResetCommandBuffer(cmd, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	// Begin render pass
	clear_color := vk.ClearValue{}
	clear_color.color.float32 = {0.05, 0.05, 0.08, 1.0}

	rp_begin := vk.RenderPassBeginInfo {
		sType       = .RENDER_PASS_BEGIN_INFO,
		renderPass  = ctx.render_pass,
		framebuffer = ctx.framebuffers[image_index],
		renderArea  = {{0, 0}, ctx.swapchain_extent},
		clearValueCount = 1,
		pClearValues    = &clear_color,
	}

	vk.CmdBeginRenderPass(cmd, &rp_begin, .INLINE)

	// Set viewport and scissor
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(ctx.swapchain_extent.width),
		height   = f32(ctx.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = ctx.swapchain_extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	if ctx.quad_count > 0 {
		// Bind pipeline
		vk.CmdBindPipeline(cmd, .GRAPHICS, ctx.pipeline)

		// Push constants: orthographic projection + viewport
		w := f32(ctx.swapchain_extent.width)
		h := f32(ctx.swapchain_extent.height)

		proj := linalg.matrix_ortho3d_f32(0, w, 0, h, -1, 1)

		// View transform: zoom centered on screen center, then pan
		zoom := ctx.zoom if ctx.zoom > 0 else 1.0
		cx := w * 0.5
		cy := h * 0.5
		view := linalg.matrix4_translate_f32({cx + ctx.pan.x, cy + ctx.pan.y, 0}) *
		        linalg.matrix4_scale_f32({zoom, zoom, 1}) *
		        linalg.matrix4_translate_f32({-cx, -cy, 0})

		pc := Slug_Push_Constants {
			mvp = proj * view,
			viewport = {w, h},
		}

		vk.CmdPushConstants(cmd, ctx.pipeline_layout, {.VERTEX}, 0, size_of(Slug_Push_Constants), &pc)

		// Bind vertex and index buffers
		vb_offset := vk.DeviceSize(0)
		vk.CmdBindVertexBuffers(cmd, 0, 1, &ctx.vertex_buffer, &vb_offset)
		vk.CmdBindIndexBuffer(cmd, ctx.index_buffer, 0, .UINT32)

		// Issue per-font draw calls (each font has its own textures/descriptor set)
		for fi in 0..<MAX_FONT_SLOTS {
			qcount := ctx.font_quad_count[fi]
			if qcount == 0 do continue

			ds := ctx.font_slots[fi].descriptor_set
			if ds == 0 do continue

			vk.CmdBindDescriptorSets(cmd, .GRAPHICS, ctx.pipeline_layout, 0, 1, &ds, 0, nil)

			first_index := ctx.font_quad_start[fi] * INDICES_PER_QUAD
			vk.CmdDrawIndexed(cmd, qcount * INDICES_PER_QUAD, 1, first_index, 0, 0)
		}
	}

	vk.CmdEndRenderPass(cmd)
	vk.EndCommandBuffer(cmd)

	// Submit
	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &ctx.image_available[frame],
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &ctx.command_buffers[image_index],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &ctx.render_finished[frame],
	}

	submit_result := vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, ctx.in_flight_fences[frame])
	if submit_result != .SUCCESS {
		fmt.eprintln("Failed to submit draw command:", submit_result)
		return false
	}

	// Present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &ctx.render_finished[frame],
		swapchainCount     = 1,
		pSwapchains        = &ctx.swapchain,
		pImageIndices      = &image_index,
	}

	present_result := vk.QueuePresentKHR(ctx.present_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || ctx.framebuffer_resized {
		// Swapchain is stale — recreate it. This is the correct place to handle
		// SUBOPTIMAL too: the frame was presented, but the swapchain no longer
		// matches the surface optimally (e.g. after a resize on Wayland).
		if !recreate_swapchain(ctx) do return false
	} else if present_result != .SUCCESS {
		fmt.eprintln("Failed to present swapchain image:", present_result)
		return false
	}

	ctx.current_frame = (frame + 1) % u32(len(ctx.swapchain_images))

	return true
}
