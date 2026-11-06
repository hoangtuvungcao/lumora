// `lumora/camera` for Windows: Media Foundation webcam capture for calls.
// Frames go straight from a capture thread into the core
// (lumora_push_camera_yuv in lumora_ffi.dll); Dart only starts/stops it.
#ifndef RUNNER_LUMORA_CAMERA_H_
#define RUNNER_LUMORA_CAMERA_H_

#include <cstdint>  // binary_messenger.h uses uint8_t without including it

#include <flutter/binary_messenger.h>

namespace lumora_camera {

// Registers the channel. Call once on the platform thread after
// RegisterPlugins().
void RegisterChannel(flutter::BinaryMessenger* messenger);

// Stops capture (camera light off), joins the worker threads and drops the
// channel. Call on the platform thread while the engine is still alive
// (FlutterWindow::OnDestroy). Idempotent.
void Shutdown();

}  // namespace lumora_camera

#endif  // RUNNER_LUMORA_CAMERA_H_
