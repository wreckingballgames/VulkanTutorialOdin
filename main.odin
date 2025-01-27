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
vk_physical_device: vk.PhysicalDevice
validation_layers: []cstring = {
    "VK_LAYER_KHRONOS_validation",
}

Queue_Family_Indices :: struct {
    graphics_family: Maybe(u32),
}

main :: proc() {
    // Tracking allocator code adapted from Karl Zylinski's tutorials.
    track: mem.Tracking_Allocator
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

    setup_debug_messenger()
    vk_physical_device = pick_physical_device()
    if vk_physical_device == nil {
        panic("Vulkan physical device handle could not be created!")
    }
}

main_loop :: proc() {
    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }
}

cleanup :: proc() {
    vk.DestroyInstance(vk_instance, nil)
    glfw.DestroyWindow(window)
    glfw.Terminate()
}

create_vk_instance :: proc() -> vk.Instance {
    if ENABLE_VALIDATION_LAYERS && !check_validation_layer_support() {
        return nil
    }

    instance: vk.Instance

    app_info: vk.ApplicationInfo
    app_info.sType = .APPLICATION_INFO
    app_info.pApplicationName = "Hello Triangle"
    app_info.applicationVersion = vk.MAKE_VERSION(1, 0, 0)
    app_info.pEngineName = "No Engine"
    app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0)
    app_info.apiVersion = vk.API_VERSION_1_0

    create_info: vk.InstanceCreateInfo
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
    extensions := make([]vk.ExtensionProperties, extension_count)
    defer delete(extensions)
    vk.EnumerateInstanceExtensionProperties(nil, &extension_count, raw_data(extensions))
    fmt.println("Available extensions:")
    for extension in extensions {
        fmt.printfln("\t%v", extension.extensionName)
    }
    when ODIN_DEBUG {
        // Confirm that all GLFW required extensions are supported.
        fmt.printfln("Are all GLFW required instance extensions supported? %v", are_all_instance_extensions_supported(glfw_extensions, extensions))
    }

    if vk.CreateInstance(&create_info, nil, &instance) != .SUCCESS {
        return nil
    } else {
        return instance
    }
}

are_all_instance_extensions_supported :: proc(extensions: []cstring, enumerated_extensions: []vk.ExtensionProperties) -> bool {
    for extension in extensions {
        is_extension_in_enumerated_extensions: bool
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

check_validation_layer_support :: proc() -> bool {
    layer_count: u32
    vk.EnumerateInstanceLayerProperties(&layer_count, nil)

    available_layers := make([]vk.LayerProperties, layer_count)
    defer delete(available_layers)
    vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers[:]))

    for layer_name in validation_layers {
        is_layer_found: bool
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

pick_physical_device :: proc() -> vk.PhysicalDevice {
    device_count: u32
    vk.EnumeratePhysicalDevices(vk_instance, &device_count, nil)

    if device_count == 0 {
        return nil
    }

    physical_device: vk.PhysicalDevice

    devices := make([]vk.PhysicalDevice, device_count)
    defer delete(devices)
    vk.EnumeratePhysicalDevices(vk_instance, &device_count, raw_data(devices[:]))

    // Pick the first suitable device we find.
    for device in devices {
        if is_physical_device_suitable(device) {
            physical_device = device
        }
    }

    return physical_device
}

// TODO: Implement scoring system to select most suitable GPU
is_physical_device_suitable :: proc(device: vk.PhysicalDevice) -> b32 {
    indices := find_queue_families(device)

    return indices.graphics_family != nil
}

find_queue_families :: proc(device: vk.PhysicalDevice) -> Queue_Family_Indices {
    indices: Queue_Family_Indices

    queue_family_count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

    queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
    defer delete(queue_families)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_families[:]))

    i: u32
    for queue_family in queue_families {
        if vk.QueueFlag.GRAPHICS in queue_family.queueFlags {
            indices.graphics_family = i
        }
        if indices.graphics_family != nil {
            break
        }

        i += 1
    }

    return indices
}
