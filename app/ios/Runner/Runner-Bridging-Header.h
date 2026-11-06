#import "GeneratedPluginRegistrant.h"

#include <dns_sd.h>
#include <stdint.h>
#include <stddef.h>

#include "../Shared/lumora_ring.h"

// Lumora Rust core (static liblumora_ffi.a, see Flutter/Lumora.xcconfig) – the C API
// used from Swift. Dart uses the rest through DynamicLibrary.process().
int32_t lumora_lan_candidate(const char *hint, const char *ip, uint16_t port);
int32_t lumora_push_screen_frame(uint32_t width, uint32_t height, uint32_t stride, uint32_t format, const uint8_t *data, size_t len);
void lumora_set_screen_display(uint32_t width, uint32_t height, float scale);
void lumora_clear_screen_frames(void);
// One NV12/I420 camera picture (LumoraCamera.swift); the core rotates it `rotation`
// degrees clockwise. 0 accepted, 1 dropped, -1 bad arguments.
int32_t lumora_push_camera_yuv(uint32_t width, uint32_t height,
    const uint8_t *y, uint32_t y_stride,
    const uint8_t *u, uint32_t u_stride,
    const uint8_t *v, uint32_t v_stride,
    uint32_t uv_pixel_stride, uint32_t rotation);
