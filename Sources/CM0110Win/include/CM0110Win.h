// Win32 layer for M0110HUD. Strings are NUL-terminated UTF-16, images are top-down 32-bit BGRA.
// Nothing is thread-safe unless noted. Callbacks run on the m0110_app_run thread, except
// GATT notifications, which come on a system thread.
#ifndef CM0110WIN_H
#define CM0110WIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- App ----

typedef struct {
    void (*wake)(void);
    /// Timers fire once.
    void (*timer)(uint32_t id);
    /// 1 for a left click, 2 for the menu.
    void (*tray)(int32_t event);
    void (*settings_changed)(void);
    void (*clipboard)(void);
} m0110_callbacks;

/// Creates the hidden window for timers, tray and HUD. Returns 0 or a Win32 error code.
int32_t m0110_app_init(const m0110_callbacks *callbacks);
int32_t m0110_app_run(void);
void m0110_app_quit(void);
/// Calls `wake` on the app thread soon. Safe from any thread.
void m0110_app_wake(void);
void m0110_timer_start(uint32_t id, uint32_t milliseconds);
void m0110_timer_stop(uint32_t id);

/// Sends unbuffered stdout to the parent's pipe, file or console, if any.
void m0110_attach_console(void);
/// 1 if no other copy is running under `name`.
int32_t m0110_single_instance(const uint16_t *name);
/// 22000 and up is Windows 11. 0 if it cannot be read.
uint32_t m0110_windows_build(void);
uint32_t m0110_module_path(uint16_t *out, uint32_t capacity);
/// Adds `command` to HKCU Run, or removes it when NULL. Returns 0 or a Win32 error code.
int32_t m0110_run_at_login(const uint16_t *name, const uint16_t *command);
int32_t m0110_runs_at_login(const uint16_t *name);
/// The hidden window, used as the clipboard owner.
void *m0110_app_window(void);
/// Keeps the last 200 lines (UTF-8) for hang.log. Safe from any thread.
void m0110_trace(const char *line);
void m0110_message_box(const uint16_t *title, const uint16_t *text);

// ---- Display ----

typedef struct {
    int32_t left, top, right, bottom;
} m0110_rect;

typedef struct {
    /// Work area of the monitor with the foreground window, else the primary one.
    m0110_rect work;
    /// 96 is 100%.
    uint32_t dpi;
    /// 0 left, 1 top, 2 right, 3 bottom.
    int32_t taskbar_edge;
} m0110_screen;

m0110_screen m0110_current_screen(void);
int32_t m0110_apps_dark(void);
int32_t m0110_taskbar_dark(void);
/// 1 when "Animation effects" is off in Settings.
int32_t m0110_reduce_motion(void);
int32_t m0110_transparency(void);
/// In pixels at the primary monitor's DPI.
int32_t m0110_tray_icon_size(void);

// ---- HUD window ----

/// `pixels` is premultiplied BGRA. The window never takes focus and lets clicks through.
int32_t m0110_hud_present(const uint8_t *pixels, int32_t width, int32_t height,
                          int32_t x, int32_t y, uint8_t alpha);
void m0110_hud_move(int32_t x, int32_t y, uint8_t alpha);
void m0110_hud_hide(void);

// ---- Tray ----

/// Adds or updates the icon. `pixels` is straight-alpha BGRA. Returns 0 on success.
int32_t m0110_tray_set(const uint8_t *pixels, int32_t size, const uint16_t *tooltip);
void m0110_tray_remove(void);
/// `items` is NUL-terminated labels ending in an empty one, "-" for a separator.
/// `flags` per item: 1 checked, 2 disabled. Returns the 1-based choice, or 0.
int32_t m0110_menu(const uint16_t *items, const uint8_t *flags);

// ---- Text ----

/// Draws one line as 0-255 coverage into `mask` (top-down). `faces` is a ';' list and the
/// first installed one is used. `size` is the em height in pixels. A NULL `mask` only measures.
/// Returns the width used and sets `*line_height`, or -1 if no face is installed.
int32_t m0110_text(const uint16_t *text, const uint16_t *faces, int32_t size, int32_t weight,
                   uint8_t *mask, int32_t width, int32_t height, int32_t *line_height);

// ---- Serial ----

/// USB CDC ACM ports, as "COM3\0COM7\0\0". Returns how many.
int32_t m0110_serial_ports(uint16_t *out, uint32_t capacity);
/// Reads time out after 100 ms. Returns NULL and sets `*error` on failure.
void *m0110_serial_open(const uint16_t *port, uint32_t *error);
int32_t m0110_serial_write(void *port, const uint8_t *data, uint32_t length);
/// Returns the bytes read, 0 on timeout, or -1.
int32_t m0110_serial_read(void *port, uint8_t *out, uint32_t capacity);
void m0110_serial_close(void *port);

// ---- Bluetooth LE ----

/// Writes the instance ID of paired LE device `name`, preferring a connected one. Returns 1 if found.
int32_t m0110_ble_find(const uint16_t *name, uint16_t *instance, uint32_t capacity);
/// 1 connected, 0 not, -1 no longer paired. `*source` is 1 for the connected
/// property, 2 for the devnode status.
int32_t m0110_ble_connected(const uint16_t *instance, int32_t *source);

typedef struct m0110_gatt m0110_gatt;
typedef void (*m0110_gatt_notify)(void *context, const uint8_t *data, uint32_t length);

/// UUIDs are 16 bytes in written order. Returns NULL and sets `*error` to an
/// HRESULT on failure (a not-found code means the service or characteristic is missing).
m0110_gatt *m0110_gatt_open(const uint16_t *instance, const uint8_t service[16],
                            const uint8_t characteristic[16], int32_t *error);
/// Returns the length, or a negative HRESULT.
int32_t m0110_gatt_read(m0110_gatt *gatt, uint8_t *out, uint32_t capacity);
/// `notify` runs on a system thread until close. Returns 0 or an HRESULT.
int32_t m0110_gatt_subscribe(m0110_gatt *gatt, m0110_gatt_notify notify, void *context);
/// Writes without response when allowed. Fails if longer than the MTU. Returns 0 or an HRESULT.
int32_t m0110_gatt_write(m0110_gatt *gatt, const uint8_t *data, uint32_t length);
void m0110_gatt_close(m0110_gatt *gatt);

// ---- Clipboard ----

enum {
    /// Another program kept the clipboard open.
    M0110_CLIP_BUSY = -2,
    /// A password manager marked it as not to be recorded or synced.
    M0110_CLIP_PRIVATE = -1,
    M0110_CLIP_NOTHING = 0,
    /// UTF-8 with LF line endings.
    M0110_CLIP_TEXT = 1,
    M0110_CLIP_PNG = 2,
};

typedef struct {
    int32_t kind;
    /// Freed by m0110_clip_free.
    uint8_t *data;
    uint32_t length;
} m0110_clip;

uint32_t m0110_clip_sequence(void);
/// Text if there is any, else an image as PNG. Returns the kind.
int32_t m0110_clip_read(m0110_clip *clip);
void m0110_clip_free(m0110_clip *clip);
int32_t m0110_clip_write_text(void *owner, const uint8_t *utf8, uint32_t length);
/// Takes a PNG or JPEG and puts it on as both a bitmap and a PNG.
int32_t m0110_clip_write_image(void *owner, const uint8_t *data, uint32_t length);
/// Scales down and re-encodes as JPEG until it fits in `budget` bytes. Free
/// `*out` with m0110_free. Returns 0 if nothing fits.
int32_t m0110_image_shrink(const uint8_t *data, uint32_t length, uint32_t budget, uint8_t **out,
                           uint32_t *out_length);
void m0110_free(void *bytes);
/// 1 if a USB device with these IDs and `name` in its name is plugged in.
int32_t m0110_usb_present(uint16_t vendor, uint16_t product, const uint16_t *name);
/// Test helpers for --clipboard-probe.
int32_t m0110_clip_probe_concealed(const uint16_t *text);
int32_t m0110_clip_probe_bitmap(void);

#ifdef __cplusplus
}
#endif

#endif
