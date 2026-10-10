// The Win32 layer under the Windows build of M0110HUD.
//
// Everything Swift needs from Windows goes through here, in plain C types:
// strings are NUL-terminated UTF-16, images are 32-bit BGRA rows top-down.
// None of it is thread-safe unless it says so. Swift calls it from the thread
// that runs m0110_app_run, and every callback arrives on that thread too,
// except a GATT notification, which arrives on a system thread.
#ifndef CM0110WIN_H
#define CM0110WIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- App ----

typedef struct {
    /// m0110_app_wake was called, from any thread.
    void (*wake)(void);
    /// A timer started with m0110_timer_start fired. Timers fire once.
    void (*timer)(uint32_t id);
    /// The tray icon was clicked: 1 for the left button, 2 for the menu.
    void (*tray)(int32_t event);
    /// The theme, the taskbar or the displays changed.
    void (*settings_changed)(void);
    /// Something new was put on the clipboard, by any program.
    void (*clipboard)(void);
} m0110_callbacks;

/// Creates the hidden window that owns the timers, the tray icon and the HUD.
/// Returns 0 on success, or a Win32 error code.
int32_t m0110_app_init(const m0110_callbacks *callbacks);
/// Runs the message loop until m0110_app_quit. Returns the exit code.
int32_t m0110_app_run(void);
void m0110_app_quit(void);
/// Calls `wake` on the app thread soon. Safe from any thread.
void m0110_app_wake(void);
void m0110_timer_start(uint32_t id, uint32_t milliseconds);
void m0110_timer_stop(uint32_t id);

/// Lets a GUI-subsystem build print: to the pipe or file it was started with,
/// or else to the console it was started from, if any. Leaves stdout
/// unbuffered either way.
void m0110_attach_console(void);
/// 1 if this is the only copy running under `name`, 0 if another one is.
int32_t m0110_single_instance(const uint16_t *name);
/// Windows' build number, which tells 11 (22000 and up) from 10. 0 if it
/// cannot be read.
uint32_t m0110_windows_build(void);
/// The full path of this executable. Returns its length, 0 on failure.
uint32_t m0110_module_path(uint16_t *out, uint32_t capacity);
/// Adds `command` under HKCU\...\Run as `name`, or removes it if `command` is
/// NULL. Returns 0 on success, or a Win32 error code.
int32_t m0110_run_at_login(const uint16_t *name, const uint16_t *command);
/// 1 if `name` is under HKCU\...\Run.
int32_t m0110_runs_at_login(const uint16_t *name);
/// The hidden window everything hangs off, as an opaque handle: the owner of
/// what the app puts on the clipboard.
void *m0110_app_window(void);
/// Keeps `line`, UTF-8, among the last 200 the app logged, for hang.log.
/// Safe from any thread.
void m0110_trace(const char *line);
/// A modal warning with an OK button.
void m0110_message_box(const uint16_t *title, const uint16_t *text);

// ---- Display ----

typedef struct {
    int32_t left, top, right, bottom;
} m0110_rect;

typedef struct {
    /// The work area of the monitor the user is on: the one holding the
    /// foreground window, else the primary one.
    m0110_rect work;
    /// That monitor's DPI; 96 is 100%.
    uint32_t dpi;
    /// Which edge the taskbar is on: 0 left, 1 top, 2 right, 3 bottom.
    int32_t taskbar_edge;
} m0110_screen;

m0110_screen m0110_current_screen(void);
/// 1 when apps are set to dark mode.
int32_t m0110_apps_dark(void);
/// 1 when the taskbar is dark.
int32_t m0110_taskbar_dark(void);
/// 1 when Settings > Accessibility > Visual effects > Animation effects is off.
int32_t m0110_reduce_motion(void);
/// 1 when transparency effects are on.
int32_t m0110_transparency(void);
/// The icon size the tray wants, in pixels at the primary monitor's DPI.
int32_t m0110_tray_icon_size(void);

// ---- HUD window ----

/// Puts `pixels` (premultiplied BGRA, top-down, `width` x `height`) on screen
/// at `x`, `y` with `alpha` over the whole of it. Never takes focus, and lets
/// clicks through.
int32_t m0110_hud_present(const uint8_t *pixels, int32_t width, int32_t height,
                          int32_t x, int32_t y, uint8_t alpha);
/// Moves the HUD and changes its alpha without redrawing it.
void m0110_hud_move(int32_t x, int32_t y, uint8_t alpha);
void m0110_hud_hide(void);

// ---- Tray ----

/// Adds the tray icon, or updates it. `pixels` is straight-alpha BGRA,
/// `size` square. Returns 0 on success.
int32_t m0110_tray_set(const uint8_t *pixels, int32_t size, const uint16_t *tooltip);
void m0110_tray_remove(void);
/// Pops up a menu at the cursor. `items` is a run of NUL-terminated labels
/// ending in an empty one, with "-" for a separator; `flags` has one entry
/// per item, 1 for checked and 2 for disabled. Returns the 1-based index of
/// the item chosen, or 0.
int32_t m0110_menu(const uint16_t *items, const uint8_t *flags);

// ---- Text ----

/// Renders one line of `text` as coverage, 0-255, into `mask`, which is
/// `width` x `height` bytes, top-down. `faces` is a ';'-separated list of
/// font names, the first installed one used. `size` is the em height in
/// pixels. Text wider than `width` ends in an ellipsis.
///
/// Returns the width the text takes, at most `width`, and sets `*height` to
/// its line height; with a NULL `mask`, only measures. Returns -1 if none of
/// the faces is installed.
int32_t m0110_text(const uint16_t *text, const uint16_t *faces, int32_t size, int32_t weight,
                   uint8_t *mask, int32_t width, int32_t height, int32_t *line_height);

// ---- Serial ----

/// The USB CDC ACM ports, as "COM3\0COM7\0\0". Returns how many.
int32_t m0110_serial_ports(uint16_t *out, uint32_t capacity);
/// Opens a port raw, with reads that wait at most 100 ms. Returns NULL and
/// sets `*error` on failure.
void *m0110_serial_open(const uint16_t *port, uint32_t *error);
/// Returns the bytes written, or -1.
int32_t m0110_serial_write(void *port, const uint8_t *data, uint32_t length);
/// Returns the bytes read, 0 if none came within 100 ms, or -1.
int32_t m0110_serial_read(void *port, uint8_t *out, uint32_t capacity);
void m0110_serial_close(void *port);

// ---- Bluetooth LE ----

/// Finds the paired Bluetooth LE device called `name` and writes its device
/// instance ID. A connected one is preferred, in case the name was paired
/// more than once. Returns 1 if found, 0 if not.
int32_t m0110_ble_find(const uint16_t *name, uint16_t *instance, uint32_t capacity);
/// Whether the device is connected: 1 yes, 0 no, -1 no longer paired.
/// `*source` says how Windows was asked: 1 the device's connected property,
/// 2 its devnode status.
int32_t m0110_ble_connected(const uint16_t *instance, int32_t *source);

typedef struct m0110_gatt m0110_gatt;
typedef void (*m0110_gatt_notify)(void *context, const uint8_t *data, uint32_t length);

/// Opens one characteristic of one of the device's GATT services. UUIDs are
/// 16 bytes in the order they are written. Returns NULL and sets `*error` to
/// an HRESULT on failure; E_NOTFOUND-style codes mean the service or the
/// characteristic is not there.
m0110_gatt *m0110_gatt_open(const uint16_t *instance, const uint8_t service[16],
                            const uint8_t characteristic[16], int32_t *error);
/// Reads the value from the device. Returns its length, or a negative HRESULT.
int32_t m0110_gatt_read(m0110_gatt *gatt, uint8_t *out, uint32_t capacity);
/// Calls `notify` with each new value, on a system thread, until closed.
/// Returns 0, or an HRESULT.
int32_t m0110_gatt_subscribe(m0110_gatt *gatt, m0110_gatt_notify notify, void *context);
/// Writes `data` to the characteristic, without response where it allows
/// that. Returns 0 or an HRESULT; a value longer than the link's MTU fails.
int32_t m0110_gatt_write(m0110_gatt *gatt, const uint8_t *data, uint32_t length);
void m0110_gatt_close(m0110_gatt *gatt);

// ---- Clipboard ----

enum {
    /// Another program had the clipboard open throughout.
    M0110_CLIP_BUSY = -2,
    /// Marked by a password manager as not to be recorded or synced.
    M0110_CLIP_PRIVATE = -1,
    M0110_CLIP_NOTHING = 0,
    /// UTF-8 with LF line endings.
    M0110_CLIP_TEXT = 1,
    M0110_CLIP_PNG = 2,
};

typedef struct {
    int32_t kind;
    /// Owned by the struct until m0110_clip_free.
    uint8_t *data;
    uint32_t length;
} m0110_clip;

/// Changes whenever anything is put on the clipboard.
uint32_t m0110_clip_sequence(void);
/// What is on the clipboard: text if there is any, else an image as PNG.
/// Returns the kind, also in `clip`.
int32_t m0110_clip_read(m0110_clip *clip);
void m0110_clip_free(m0110_clip *clip);
/// Puts text, UTF-8 with LF line endings, on the clipboard as `owner`.
int32_t m0110_clip_write_text(void *owner, const uint8_t *utf8, uint32_t length);
/// Puts a PNG or JPEG on the clipboard, as a bitmap and a PNG.
int32_t m0110_clip_write_image(void *owner, const uint8_t *data, uint32_t length);
/// An image scaled down and re-encoded as JPEG until it is at most `budget`
/// bytes, in `*out` for m0110_free. 0 if nothing fits.
int32_t m0110_image_shrink(const uint8_t *data, uint32_t length, uint32_t budget, uint8_t **out,
                           uint32_t *out_length);
void m0110_free(void *bytes);
/// 1 if a USB device with these IDs, whose name contains `name`, is plugged
/// in.
int32_t m0110_usb_present(uint16_t vendor, uint16_t product, const uint16_t *name);
/// For --clipboard-probe: text marked as a password manager marks it, and a
/// 2x2 bitmap on its own.
int32_t m0110_clip_probe_concealed(const uint16_t *text);
int32_t m0110_clip_probe_bitmap(void);

#ifdef __cplusplus
}
#endif

#endif
