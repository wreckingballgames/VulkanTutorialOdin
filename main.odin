package main

import "core:mem"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"
import vk "vendor:vulkan"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600
WINDOW_TITLE :: "Vulkan Tutorial"

window: glfw.WindowHandle

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

    init_window()
    main_loop()
    cleanup()
}

init_window :: proc() {
    glfw.Init()

    // Do not use OpenGL.
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    // Do not allow resizing until we account for it later.
    glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

    window = glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
}

main_loop :: proc() {
    for !glfw.WindowShouldClose(window) {
        glfw.PollEvents()
    }
}

cleanup :: proc() {
    glfw.DestroyWindow(window)
    glfw.Terminate()
}
