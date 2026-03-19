package slugvibes

import "base:runtime"
import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

// ===================================================
// Vulkan helper functions — buffer, texture, pipeline utilities
// Adapted from the metroidvaniavibes project.
// ===================================================

ENABLE_VALIDATION :: #config(ENABLE_VALIDATION, true)

// --- Memory type selection ---

find_memory_type :: proc(
	ctx: ^Slug_Context,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> (u32, bool) {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_properties)

	for i in 0..<mem_properties.memoryTypeCount {
		type_bit := u32(1) << i
		has_type := (type_filter & type_bit) != 0
		has_props := properties <= mem_properties.memoryTypes[i].propertyFlags
		if has_type && has_props {
			return i, true
		}
	}

	return 0, false
}

// --- Buffer creation ---

create_buffer :: proc(
	ctx: ^Slug_Context,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (buffer: vk.Buffer, memory: vk.DeviceMemory, ok: bool) {
	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	result := vk.CreateBuffer(ctx.device, &buf_info, nil, &buffer)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create buffer:", result)
		return {}, {}, false
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, buffer, &mem_requirements)

	mem_type, mem_type_ok := find_memory_type(ctx, mem_requirements.memoryTypeBits, properties)
	if !mem_type_ok {
		fmt.eprintln("Failed to find suitable memory type for buffer")
		vk.DestroyBuffer(ctx.device, buffer, nil)
		return {}, {}, false
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = mem_type,
	}

	result = vk.AllocateMemory(ctx.device, &alloc_info, nil, &memory)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate buffer memory:", result)
		vk.DestroyBuffer(ctx.device, buffer, nil)
		return {}, {}, false
	}

	vk.BindBufferMemory(ctx.device, buffer, memory, 0)
	return buffer, memory, true
}

// --- One-shot command buffer helpers ---

begin_one_shot_commands :: proc(ctx: ^Slug_Context) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	vk.AllocateCommandBuffers(ctx.device, &alloc_info, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)
	return cmd
}

end_one_shot_commands :: proc(ctx: ^Slug_Context, cmd: vk.CommandBuffer) {
	vk.EndCommandBuffer(cmd)

	cmd_buf := cmd
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd_buf,
	}
	vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(ctx.graphics_queue)

	vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buf)
}

// --- Image layout transitions ---

transition_image_layout :: proc(
	ctx: ^Slug_Context,
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {
	cmd := begin_one_shot_commands(ctx)

	barrier := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}

	src_stage, dst_stage: vk.PipelineStageFlags

	if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
		barrier.srcAccessMask = {}
		barrier.dstAccessMask = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
	} else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstAccessMask = {.SHADER_READ}
		src_stage = {.TRANSFER}
		dst_stage = {.FRAGMENT_SHADER}
	}

	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)

	end_one_shot_commands(ctx, cmd)
}

// --- GPU texture creation ---

gpu_texture_create :: proc(
	ctx: ^Slug_Context,
	width, height: u32,
	format: vk.Format,
	data: rawptr,
	data_size: int,
) -> (tex: GPU_Texture, ok: bool) {
	tex.width = width
	tex.height = height
	image_size := vk.DeviceSize(data_size)

	// Create staging buffer
	staging_buf, staging_mem, staging_ok := create_buffer(
		ctx, image_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !staging_ok do return {}, false
	defer vk.DestroyBuffer(ctx.device, staging_buf, nil)
	defer vk.FreeMemory(ctx.device, staging_mem, nil)

	// Copy data to staging
	mapped: rawptr
	vk.MapMemory(ctx.device, staging_mem, 0, image_size, {}, &mapped)
	mem.copy(mapped, data, data_size)
	vk.UnmapMemory(ctx.device, staging_mem)

	// Create the Vulkan image
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		format        = format,
		tiling        = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage         = {.TRANSFER_DST, .SAMPLED},
		sharingMode   = .EXCLUSIVE,
		samples       = {._1},
	}

	result := vk.CreateImage(ctx.device, &image_info, nil, &tex.image)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create image:", result)
		return {}, false
	}

	// Allocate and bind image memory
	mem_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(ctx.device, tex.image, &mem_requirements)

	mem_type, mem_type_ok := find_memory_type(ctx, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL})
	if !mem_type_ok {
		fmt.eprintln("Failed to find memory type for image")
		vk.DestroyImage(ctx.device, tex.image, nil)
		return {}, false
	}

	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = mem_type,
	}

	result = vk.AllocateMemory(ctx.device, &alloc, nil, &tex.memory)
	if result != .SUCCESS {
		fmt.eprintln("Failed to allocate image memory:", result)
		vk.DestroyImage(ctx.device, tex.image, nil)
		return {}, false
	}

	vk.BindImageMemory(ctx.device, tex.image, tex.memory, 0)

	// Transition, copy, transition
	transition_image_layout(ctx, tex.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

	// Copy buffer to image
	{
		cmd := begin_one_shot_commands(ctx)
		region := vk.BufferImageCopy {
			imageSubresource = {
				aspectMask = {.COLOR},
				layerCount = 1,
			},
			imageExtent = {width, height, 1},
		}
		vk.CmdCopyBufferToImage(cmd, staging_buf, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		end_one_shot_commands(ctx, cmd)
	}

	transition_image_layout(ctx, tex.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

	// Create image view
	view_info := vk.ImageViewCreateInfo {
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = tex.image,
		viewType = .D2,
		format   = format,
		subresourceRange = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}

	result = vk.CreateImageView(ctx.device, &view_info, nil, &tex.view)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create image view:", result)
		gpu_texture_destroy(ctx, &tex)
		return {}, false
	}

	// Create sampler — texelFetch doesn't use sampler, but Vulkan requires one for combined image sampler
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		mipmapMode   = .NEAREST,
		maxLod       = 0,
	}

	result = vk.CreateSampler(ctx.device, &sampler_info, nil, &tex.sampler)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create sampler:", result)
		gpu_texture_destroy(ctx, &tex)
		return {}, false
	}

	return tex, true
}

gpu_texture_destroy :: proc(ctx: ^Slug_Context, tex: ^GPU_Texture) {
	if tex.sampler != 0 do vk.DestroySampler(ctx.device, tex.sampler, nil)
	if tex.view != 0    do vk.DestroyImageView(ctx.device, tex.view, nil)
	if tex.image != 0   do vk.DestroyImage(ctx.device, tex.image, nil)
	if tex.memory != 0  do vk.FreeMemory(ctx.device, tex.memory, nil)
	tex^ = {}
}

// --- Shader module creation ---

create_shader_module :: proc(ctx: ^Slug_Context, code: []u8) -> (vk.ShaderModule, bool) {
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}

	mod: vk.ShaderModule
	result := vk.CreateShaderModule(ctx.device, &create_info, nil, &mod)
	if result != .SUCCESS {
		fmt.eprintln("Failed to create shader module:", result)
		return {}, false
	}

	return mod, true
}

// --- Validation layer debug callback ---

when ENABLE_VALIDATION {
	debug_callback :: proc "system" (
		severity: vk.DebugUtilsMessageSeverityFlagsEXT,
		types: vk.DebugUtilsMessageTypeFlagsEXT,
		callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
		user_data: rawptr,
	) -> b32 {
		context = #force_inline runtime_default_context()
		if .ERROR in severity {
			fmt.eprintln("VK ERROR:", callback_data.pMessage)
		} else {
			fmt.eprintln("VK WARN:", callback_data.pMessage)
		}
		return false
	}

	@(private="file")
	runtime_default_context :: #force_inline proc "contextless" () -> runtime.Context {
		return runtime.default_context()
	}
}

// --- Index buffer generation ---

generate_quad_indices :: proc(max_quads: int, allocator := context.allocator) -> []u32 {
	indices := make([]u32, max_quads * INDICES_PER_QUAD, allocator)
	for i in 0..<max_quads {
		base_vertex := u32(i * VERTICES_PER_QUAD)
		base_index := i * INDICES_PER_QUAD
		indices[base_index + 0] = base_vertex + 0
		indices[base_index + 1] = base_vertex + 1
		indices[base_index + 2] = base_vertex + 2
		indices[base_index + 3] = base_vertex + 2
		indices[base_index + 4] = base_vertex + 3
		indices[base_index + 5] = base_vertex + 0
	}
	return indices
}
