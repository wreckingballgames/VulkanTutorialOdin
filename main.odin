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

    window = init_window()
    init_vulkan()
    // TODO: Integrate error handling into init_vulkan
    if vk_instance == nil {
        fmt.println("Could not create vk_instance!")
        return
    }
    main_loop()
    cleanup()
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
    create_info.enabledLayerCount = 0

    extension_count: u32
    vk.EnumerateInstanceExtensionProperties(nil, &extension_count, nil)
    extensions := make([]vk.ExtensionProperties, extension_count)
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
