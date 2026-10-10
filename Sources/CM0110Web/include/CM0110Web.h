// The M0110 window on Windows, a WebView2 showing the WindowsUI page. Swift and
// the page exchange JSON. Everything, callbacks included, runs on the m0110_app_run thread.
#ifndef CM0110WEB_H
#define CM0110WEB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /// UTF-16 JSON, valid only during the call.
    void (*message)(const uint16_t *json);
    /// The next m0110_web_open makes a new window.
    void (*closed)(void);
    /// Usually means the WebView2 Runtime is not installed.
    void (*failed)(int32_t hresult);
} m0110_web_callbacks;

/// Opens or raises the window. `folder` holds index.html and `data` holds the WebView2
/// profile. The size is the client area at 96 DPI. Returns 0 or a Win32 error.
int32_t m0110_web_open(const uint16_t *title, const uint16_t *folder, const uint16_t *data, int32_t width,
                       int32_t height, const m0110_web_callbacks *callbacks);
/// `json` is an object. Dropped if the page is not loaded.
void m0110_web_post(const uint16_t *json);
/// Client area at 96 DPI. Keeps the top-left corner in place.
void m0110_web_resize(int32_t width, int32_t height);
int32_t m0110_web_is_open(void);
void m0110_web_close(void);

#ifdef __cplusplus
}
#endif

#endif
