package main

import "core:mem"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"
import vk "vendor:vulkan"

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)
WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600
WINDOW_TITLE :: "Vulkan Tutorial"

window: glfw.WindowHandle
vk_instance: vk.Instance
vk_surface: vk.SurfaceKHR
vk_physical_device: vk.PhysicalDevice // Implicitly cleaned up when instance is destroyed
vk_device: vk.Device
device_features: vk.PhysicalDeviceFeatures
graphics_queue: vk.Queue // Implicitly cleaned up when device is destroyed
present_queue: vk.Queue // Implicitly cleaned up when device is destroyed
vk_swapchain: vk.SwapchainKHR
swapchain_images: []vk.Image // Implicitly cleaned up when swapchain is destroyed
swapchain_image_format: vk.Format
swapchain_extent: vk.Extent2D

validation_layers: []cstring = {
    "VK_LAYER_KHRONOS_validation",
}
device_extensions: []cstring = {
    // "VK_KHR_SWAPCHAIN_EXTENSION_NAME",
}

Queue_Family_Indices :: struct {
    graphics_family: Maybe(u32),
    present_family: Maybe(u32),
}

are_queue_family_indices_complete :: proc(indices: Queue_Family_Indices) -> b32 {
    return indices.graphics_family != nil && indices.present_family != nil
}

Swapchain_Support_Details :: struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
}

main :: proc() {
    // Tracking allocator code adapted from Karl Zylinski's tutorials.
    track: mem.Tracking_Allocator = ---
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
        for _, entry in track.allocation_map {
            fmt.eprintf("%v leaked %v bytes.\n", entry.location, entry.size)
        }
        for entry in track.bad_free_array {
            fmt.eprintf("%v bad free.\n", entry.location)
        }
        mem.tracking_allocator_destroy(&track)
    }

    defer cleanup()

    window = init_window()
    init_vulkan()
    main_loop()
}

init_window :: proc() -> glfw.WindowHandle {
    glfw.Init()

    // Do not use OpenGL.
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    // Do not allow resizing until we account for it later.
    glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

    return glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
}

init_vulkan :: proc() {
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

    vk_instance = create_vk_instance()
    if vk_instance == nil {
        panic("Vulkan instance could not be created!")
    }
    vk.load_proc_addresses_instance(vk_instance)

    surface := create_window_surface(vk_instance, window)
    if surface == nil {
        panic("Vulkan window surface could not be created!")
    } else {
        vk_surface = surface.(vk.SurfaceKHR)
    }

    setup_debug_messenger()
    vk_physical_device = pick_physical_device(vk_instance, vk_surface)
    if vk_physical_device == nil {
        panic("Vulkan physical device handle could not be created!")
    }

    vk_device = create_logical_device(vk_physical_device, vk_surface, &graphics_queue, &present_queue)
    if vk_device == nil {
        panic("Vulkan logical device could not be created!")
    }
    vk.load_proc_addresses_device(vk_device)
}

main_loop :: proc() {
    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }
}

cleanup :: proc() {
    vk.DestroySwapchainKHR(vk_device, vk_swapchain, nil)
    vk.DestroyDevice(vk_device, nil)
    vk.DestroySurfaceKHR(vk_instance, vk_surface, nil)
    vk.DestroyInstance(vk_instance, nil)
    glfw.DestroyWindow(window)
    glfw.Terminate()
}

create_vk_instance :: proc(allocator := context.allocator) -> vk.Instance {
    if ENABLE_VALIDATION_LAYERS && !check_validation_layer_support() {
        return nil
    }

    instance: vk.Instance = ---

    app_info: vk.ApplicationInfo = ---
    app_info.sType = .APPLICATION_INFO
    app_info.pApplicationName = "Hello Triangle"
    app_info.applicationVersion = vk.MAKE_VERSION(1, 0, 0)
    app_info.pEngineName = "No Engine"
    app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0)
    app_info.apiVersion = vk.API_VERSION_1_0

    create_info: vk.InstanceCreateInfo = ---
    create_info.sType = .INSTANCE_CREATE_INFO
    create_info.pApplicationInfo = &app_info

    glfw_extensions := glfw.GetRequiredInstanceExtensions()

    create_info.enabledExtensionCount = u32(len(glfw_extensions))
    create_info.ppEnabledExtensionNames = raw_data(glfw_extensions[:])
    if ENABLE_VALIDATION_LAYERS {
        create_info.enabledLayerCount = u32(len(validation_layers))
        create_info.ppEnabledLayerNames = raw_data(validation_layers[:])
    } else {
        create_info.enabledLayerCount = 0
    }

    extension_count: u32
    vk.EnumerateInstanceExtensionProperties(nil, &extension_count, nil)
    extensions := make([]vk.ExtensionProperties, extension_count, allocator)
    defer delete(extensions)
    vk.EnumerateInstanceExtensionProperties(nil, &extension_count, raw_data(extensions[:]))
    when ODIN_DEBUG {
        fmt.println("Available extensions:")
        for extension in extensions {
            fmt.printfln("\t%v", extension.extensionName)
        }
        // Confirm that all GLFW required extensions are supported.
        fmt.printfln("Are all GLFW required instance extensions supported? %v", are_all_instance_extensions_supported(glfw_extensions, extensions))
    }

    if vk.CreateInstance(&create_info, nil, &instance) != .SUCCESS {
        return nil
    } else {
        return instance
    }
}

create_window_surface :: proc(instance: vk.Instance, window: glfw.WindowHandle) -> Maybe(vk.SurfaceKHR) {
    surface: vk.SurfaceKHR = ---
    if glfw.CreateWindowSurface(instance, window, nil, &surface) != .SUCCESS {
        return nil
    } else {
        return surface
    }
}

are_all_instance_extensions_supported :: proc(extensions: []cstring, enumerated_extensions: []vk.ExtensionProperties) -> b32 {
    for extension in extensions {
        is_extension_in_enumerated_extensions: b32
        for &enum_extension in enumerated_extensions {
            if extension == cstring(raw_data(enum_extension.extensionName[:])) {
                is_extension_in_enumerated_extensions = true
            }
        }
        if !is_extension_in_enumerated_extensions {
            return false
        }
    }
    return true
}

check_validation_layer_support :: proc(allocator := context.allocator) -> b32 {
    layer_count: u32
    vk.EnumerateInstanceLayerProperties(&layer_count, nil)

    available_layers := make([]vk.LayerProperties, layer_count, allocator)
    defer delete(available_layers)
    vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers[:]))

    for layer_name in validation_layers {
        is_layer_found: b32
        for &layer_properties in available_layers {
            if layer_name == cstring(raw_data(layer_properties.layerName[:])) {
                is_layer_found = true
                break
            }
        }

        if !is_layer_found {
            return false
        }
    }

    return true
}

// TODO
setup_debug_messenger :: proc() {

}

pick_physical_device :: proc(instance: vk.Instance, surface: vk.SurfaceKHR, allocator := context.allocator) -> vk.PhysicalDevice {
    device_count: u32
    vk.EnumeratePhysicalDevices(instance, &device_count, nil)

    if device_count == 0 {
        return nil
    }

    physical_device: vk.PhysicalDevice

    devices := make([]vk.PhysicalDevice, device_count, allocator)
    defer delete(devices)
    vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices[:]))

    // Pick the first suitable device we find.
    for device in devices {
        if is_physical_device_suitable(device, surface) {
            physical_device = device
            break
        }
    }

    return physical_device
}

// TODO: Implement scoring system to select most suitable GPU
is_physical_device_suitable :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> b32 {
    indices := find_queue_families(device, surface)

    are_extensions_supported := check_device_extension_support(device)

    is_swapchain_adequate: b32
    if are_extensions_supported {
        swapchain_support := query_swapchain_support(device, surface)
        is_swapchain_adequate = len(swapchain_support.formats) != 0 && len(swapchain_support.present_modes) != 0
    }

    return are_queue_family_indices_complete(indices) && are_extensions_supported && is_swapchain_adequate
}

find_queue_families :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR, allocator := context.allocator) -> Queue_Family_Indices {
    indices: Queue_Family_Indices

    queue_family_count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

    queue_families := make([]vk.QueueFamilyProperties, queue_family_count, allocator)
    defer delete(queue_families)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_families[:]))

    i: u32
    for queue_family in queue_families {
        if .GRAPHICS in queue_family.queueFlags {
            indices.graphics_family = i
        }
        if indices.graphics_family != nil {
            break
        }

        i += 1
    }

    present_support: b32
    vk.GetPhysicalDeviceSurfaceSupportKHR(device, i, surface, &present_support)

    if present_support {
        indices.present_family = i
    }

    return indices
}

create_logical_device :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, graphics_queue, present_queue: ^vk.Queue) -> vk.Device {
    device: vk.Device
    indices := find_queue_families(physical_device, surface)

    queue_priority: f32 = 1.0

    // TODO: Figure out how to make closer to tutorial (case of separate drawing and presenting devices)
    queue_create_info: vk.DeviceQueueCreateInfo = ---
    queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO
    queue_create_info.queueFamilyIndex = indices.graphics_family.(u32)
    queue_create_info.queueCount = 1
    queue_create_info.pQueuePriorities = &queue_priority

    create_info: vk.DeviceCreateInfo = ---
    create_info.sType = .DEVICE_CREATE_INFO
    create_info.queueCreateInfoCount = 1
    create_info.pQueueCreateInfos = &queue_create_info

    create_info.pEnabledFeatures = &device_features
    create_info.enabledExtensionCount = u32(len(device_extensions))
    create_info.ppEnabledExtensionNames = raw_data(device_extensions[:])

    if ENABLE_VALIDATION_LAYERS {
        create_info.enabledLayerCount = u32(len(validation_layers))
        create_info.ppEnabledLayerNames = raw_data(validation_layers[:])
    } else {
        create_info.enabledLayerCount = 0
    }

    if vk.CreateDevice(physical_device, &create_info, nil, &device) != .SUCCESS {
        return nil
    } else {
        // I think these procedure calls are in the right place...
        vk.GetDeviceQueue(device, indices.graphics_family.(u32), 0, graphics_queue)
        vk.GetDeviceQueue(device, indices.present_family.(u32), 0, present_queue)
        return device
    }
}

check_device_extension_support :: proc(device: vk.PhysicalDevice, allocator := context.allocator) -> b32 {
    extension_count: u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)

    available_extensions := make([]vk.ExtensionProperties, extension_count, allocator)
    defer delete(available_extensions)
    vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(available_extensions[:]))

    for extension_name in device_extensions {
        is_extension_found: b32
        for &extension_properties in available_extensions {
            if extension_name == cstring(raw_data(extension_properties.extensionName[:])) {
                is_extension_found = true
                break
            }
        }

        if !is_extension_found {
            return false
        }
    }

    return true
}

query_swapchain_support :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR, allocator := context.allocator) -> Swapchain_Support_Details {
    details: Swapchain_Support_Details

    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities)

    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, nil)

    if format_count != 0 {
        details.formats = make([]vk.SurfaceFormatKHR, format_count, allocator)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, raw_data(details.formats[:]))
    }

    present_mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, nil)

    if present_mode_count != 0 {
        details.present_modes = make([]vk.PresentModeKHR, present_mode_count, allocator)
        vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, raw_data(details.present_modes[:]))
    }

    return details
}

choose_swap_surface_format :: proc(available_formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for available_format in available_formats {
        if available_format.format == vk.Format.B8G8R8_SRGB && available_format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
            return available_format
        }
    }

    // TODO: Rank available formats to return best one
    return available_formats[0]
}

choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
    // TODO: Implement ranking system to pick best present mode, i.e. preserve energy on mobile
    for available_present_mode in available_present_modes {
        if available_present_mode == vk.PresentModeKHR.MAILBOX {
            return available_present_mode
        }
    }

    // Only FIFO present mode is guaranteed to be available.
    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, window: glfw.WindowHandle) -> vk.Extent2D {
    if capabilities.currentExtent.width != max(u32) {
        return capabilities.currentExtent
    } else {
        width, height := glfw.GetFramebufferSize(window)

        actual_extent := vk.Extent2D {
            u32(width),
            u32(height),
        }

        actual_extent.width = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
        actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

        return actual_extent
    }
}

create_swapchain :: proc(physical_device: vk.PhysicalDevice, logical_device: vk.Device, surface: vk.SurfaceKHR, window: glfw.WindowHandle, allocator := context.allocator) -> Maybe(vk.SwapchainKHR) {
    swapchain_support := query_swapchain_support(physical_device, surface)

    surface_format := choose_swap_surface_format(swapchain_support.formats)
    present_mode := choose_swap_present_mode(swapchain_support.present_modes)
    extent := choose_swap_extent(swapchain_support.capabilities, window)

    // Request one more than the minimum image count to reduce time spent waiting on images.
    // maxImageCount has a special case, 0, where there is no maximum. That will not be selected in either case of max().
    image_count := max(swapchain_support.capabilities.minImageCount + 1, swapchain_support.capabilities.maxImageCount)

    create_info: vk.SwapchainCreateInfoKHR = ---
    create_info.sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR
    create_info.surface = surface
    create_info.minImageCount = image_count
    create_info.imageFormat = surface_format.format
    create_info.imageColorSpace = surface_format.colorSpace
    create_info.imageExtent = extent
    create_info.imageArrayLayers = 1
    create_info.imageUsage = vk.ImageUsageFlags {vk.ImageUsageFlag.COLOR_ATTACHMENT}

    indices := find_queue_families(physical_device, surface)
    indices_values := []u32 {indices.graphics_family.(u32), indices.present_family.(u32)}

    if indices.graphics_family.(u32) != indices.present_family.(u32) {
        create_info.imageSharingMode = vk.SharingMode.CONCURRENT
        create_info.queueFamilyIndexCount = 2
        create_info.pQueueFamilyIndices = raw_data(indices_values[:])
    } else {
        create_info.imageSharingMode = vk.SharingMode.EXCLUSIVE
        create_info.queueFamilyIndexCount = 0
        create_info.pQueueFamilyIndices = nil
    }

    create_info.preTransform = swapchain_support.capabilities.currentTransform
    create_info.compositeAlpha = vk.CompositeAlphaFlagsKHR {vk.CompositeAlphaFlagKHR.OPAQUE}
    create_info.presentMode = present_mode
    create_info.clipped = true
    // TODO: Ensure this is the best way to nullify oldSwapchain (u64)
    create_info.oldSwapchain = 0

    swapchain: vk.SwapchainKHR = ---
    vk.GetSwapchainImagesKHR(logical_device, swapchain, &image_count, nil)
    swapchain_images = make([]vk.Image, image_count, allocator)
    vk.GetSwapchainImagesKHR(logical_device, swapchain, &image_count, raw_data(swapchain_images[:]))

    swapchain_image_format = surface_format.format
    swapchain_extent = extent

    if vk.CreateSwapchainKHR(logical_device, &create_info, nil, &swapchain) != .SUCCESS {
        return nil
    } else {
        return swapchain
    }
}
