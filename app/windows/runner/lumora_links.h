// Single instance + `lumora://` links for Windows (channel "lumora/links").
//
// The first Lumora holds a named mutex (one per data folder, so test setups
// with LUMORA_DATA_DIR can still run side by side). A second launch, e.g.
// from a clicked lumora:// link, finds the first one's window, hands it the
// link with WM_COPYDATA, brings it to the front and exits. The first one
// forwards the link to Dart (lib/platform/desktop_links.dart).
#ifndef RUNNER_LUMORA_LINKS_H_
#define RUNNER_LUMORA_LINKS_H_

#include <windows.h>

#include <string>
#include <vector>

namespace flutter {
class BinaryMessenger;
}

namespace lumora_links {

// wWinMain, before the window exists. True if another Lumora (same data
// folder) is running and got |args|' link: this process should exit.
bool HandOffToRunningInstance(const std::vector<std::string>& args);

// After the Flutter engine exists: marks |window| so later launches find it
// and registers the channel. Platform thread.
void RegisterWindow(HWND window, flutter::BinaryMessenger* messenger);

// FlutterWindow::MessageHandler for WM_COPYDATA. True if it was ours.
bool HandleCopyData(HWND window, LPARAM lparam);

// FlutterWindow::OnDestroy, while the engine is alive. Idempotent.
void Shutdown();

}  // namespace lumora_links

#endif  // RUNNER_LUMORA_LINKS_H_
