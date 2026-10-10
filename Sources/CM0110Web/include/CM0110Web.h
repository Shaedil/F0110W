// The M0110 window on Windows: a top-level window holding a WebView2, which
// shows the HTML interface in WindowsUI. Swift talks to the page in JSON:
// m0110_web_post sends a message to it, and the `message` callback brings the
// page's messages back.
//
// Everything here runs on the app thread, the one running m0110_app_run, and
// every callback arrives on it.
#ifndef CM0110WEB_H
#define CM0110WEB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /// A message from the page: NUL-terminated UTF-16 JSON, valid for the call.
    void (*message)(const uint16_t *json);
    /// The window was closed. The next m0110_web_open makes a new one.
    void (*closed)(void);
    /// The WebView2 could not be made: an HRESULT, most often because the
    /// WebView2 Runtime is not installed.
    void (*failed)(int32_t hresult);
} m0110_web_callbacks;

/// Opens the window, or brings it to the front if it is open. `folder` holds
/// index.html; `data` is where WebView2 keeps its profile. The client area is
/// `width` x `height` at 96 DPI, and only the page resizes it, as the Mac
/// window does. Returns 0, or a Win32 error if the window could not be made.
int32_t m0110_web_open(const uint16_t *title, const uint16_t *folder, const uint16_t *data, int32_t width,
                       int32_t height, const m0110_web_callbacks *callbacks);
/// Sends `json`, an object, to the page. Dropped if the page is not loaded.
void m0110_web_post(const uint16_t *json);
/// Sets the client area to `width` x `height` at 96 DPI, keeping the window's
/// top-left corner where it is: the page asks for this as its layout changes.
void m0110_web_resize(int32_t width, int32_t height);
/// 1 while the window exists.
int32_t m0110_web_is_open(void);
/// Closes the window, as its close button does.
void m0110_web_close(void);

#ifdef __cplusplus
}
#endif

#endif
