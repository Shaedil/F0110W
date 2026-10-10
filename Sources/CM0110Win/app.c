// The hidden app window, message loop, timers, the layered HUD window and the tray icon.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shellscalingapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "CM0110Win.h"

#define WM_M0110_WAKE (WM_APP + 1)
#define WM_M0110_TRAY (WM_APP + 2)
#define WM_M0110_SETTINGS (WM_APP + 3)

void m0110_watch_app_thread(void *window);
#define TRAY_ID 1

static const wchar_t *const run_key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static const wchar_t *const theme_key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";

static m0110_callbacks callbacks;
static HWND app_window;
static HWND hud_window;
static UINT taskbar_created;
static volatile LONG wake_pending;
static volatile LONG settings_pending;

static NOTIFYICONDATAW tray;
static HICON tray_icon;
static int tray_shown;

static void add_tray(void) {
    tray_shown = Shell_NotifyIconW(NIM_ADD, &tray) ? 1 : 0;
    if (tray_shown) {
        tray.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &tray);
    }
}

static LRESULT CALLBACK app_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_M0110_WAKE:
        // Clear first, so a wake requested during this callback posts again.
        InterlockedExchange(&wake_pending, 0);
        if (callbacks.wake) callbacks.wake();
        return 0;
    case WM_TIMER:
        KillTimer(window, wparam);
        if (callbacks.timer) callbacks.timer((uint32_t)wparam);
        return 0;
    case WM_M0110_TRAY:
        switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
            if (callbacks.tray) callbacks.tray(1);
            break;
        case WM_CONTEXTMENU:
            if (callbacks.tray) callbacks.tray(2);
            break;
        }
        return 0;
    case WM_SETTINGCHANGE:
    case WM_DISPLAYCHANGE:
        // Handled later. Explorer often sends these as a broadcast, and updating
        // the tray icon inside one can deadlock with Explorer. Repeated messages merge.
        if (InterlockedExchange(&settings_pending, 1) == 0) PostMessageW(window, WM_M0110_SETTINGS, 0, 0);
        return 0;
    case WM_CLIPBOARDUPDATE:
        if (callbacks.clipboard) callbacks.clipboard();
        return 0;
    case WM_M0110_SETTINGS:
        InterlockedExchange(&settings_pending, 0);
        if (callbacks.settings_changed) callbacks.settings_changed();
        return 0;
    default:
        // Explorer restarted and dropped the tray icon.
        if (message == taskbar_created && taskbar_created != 0) {
            if (tray_icon) add_tray();
            return 0;
        }
        break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

typedef BOOL(WINAPI *set_dpi_context_fn)(DPI_AWARENESS_CONTEXT);
typedef int(WINAPI *set_app_mode_fn)(int);

/// Must run before any screen query, or Windows reports 96 DPI for every monitor.
static void opt_in(void) {
    static int done;
    if (done) return;
    done = 1;

    // Per-monitor DPI (Windows 10 1703+), so the system does not stretch the HUD.
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    set_dpi_context_fn set_dpi =
        user32 ? (set_dpi_context_fn)(void *)GetProcAddress(user32, "SetProcessDpiAwarenessContext") : NULL;
    if (!set_dpi || !set_dpi(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) SetProcessDPIAware();

    // Undocumented uxtheme ordinal 135 (SetPreferredAppMode) lets the tray menu go dark.
    HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    set_app_mode_fn set_mode =
        uxtheme ? (set_app_mode_fn)(void *)GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)) : NULL;
    if (set_mode) set_mode(1 /* AllowDark */);
}

int32_t m0110_app_init(const m0110_callbacks *app_callbacks) {
    callbacks = *app_callbacks;
    opt_in();

    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSEXW app_class = {sizeof app_class};
    app_class.lpfnWndProc = app_proc;
    app_class.hInstance = instance;
    app_class.lpszClassName = L"M0110HUD.App";
    if (!RegisterClassExW(&app_class)) return (int32_t)GetLastError();

    // Hidden top-level window, since message-only windows miss theme and Explorer broadcasts.
    app_window = CreateWindowExW(WS_EX_TOOLWINDOW, app_class.lpszClassName, L"M0110HUD", WS_POPUP,
                                 0, 0, 0, 0, NULL, NULL, instance, NULL);
    if (!app_window) return (int32_t)GetLastError();
    taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");

    WNDCLASSEXW hud_class = {sizeof hud_class};
    hud_class.lpfnWndProc = DefWindowProcW;
    hud_class.hInstance = instance;
    hud_class.lpszClassName = L"M0110HUD.HUD";
    if (!RegisterClassExW(&hud_class)) return (int32_t)GetLastError();

    hud_window = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
                                     WS_EX_NOACTIVATE,
                                 hud_class.lpszClassName, L"M0110", WS_POPUP, 0, 0, 1, 1, NULL, NULL,
                                 instance, NULL);
    if (!hud_window) return (int32_t)GetLastError();
    AddClipboardFormatListener(app_window);
    m0110_watch_app_thread(app_window);
    return 0;
}

void *m0110_app_window(void) { return app_window; }

int32_t m0110_app_run(void) {
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    m0110_tray_remove();
    return (int32_t)message.wParam;
}

void m0110_app_quit(void) { PostQuitMessage(0); }

void m0110_app_wake(void) {
    if (InterlockedExchange(&wake_pending, 1) == 0) PostMessageW(app_window, WM_M0110_WAKE, 0, 0);
}

void m0110_timer_start(uint32_t id, uint32_t milliseconds) {
    SetTimer(app_window, (UINT_PTR)id, milliseconds, NULL);
}

void m0110_timer_stop(uint32_t id) { KillTimer(app_window, (UINT_PTR)id); }

static void attach(void) {
    // Already has handles if output is redirected or it was built as a console app.
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out != NULL && out != INVALID_HANDLE_VALUE && GetFileType(out) != FILE_TYPE_UNKNOWN) return;
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) return;

    FILE *stream;
    freopen_s(&stream, "CONOUT$", "w", stdout);
    freopen_s(&stream, "CONOUT$", "w", stderr);
    HANDLE console = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 NULL, OPEN_EXISTING, 0, NULL);
    if (console != INVALID_HANDLE_VALUE) {
        SetStdHandle(STD_OUTPUT_HANDLE, console);
        SetStdHandle(STD_ERROR_HANDLE, console);
    }
}

void m0110_attach_console(void) {
    attach();
    // Unbuffered, because the app usually gets killed and buffered output would be lost.
    setvbuf(stdout, NULL, _IONBF, 0);
}

int32_t m0110_single_instance(const uint16_t *name) {
    // Never closed, so the mutex lasts until exit.
    HANDLE mutex = CreateMutexW(NULL, TRUE, (const wchar_t *)name);
    if (!mutex) return 1;
    return GetLastError() == ERROR_ALREADY_EXISTS ? 0 : 1;
}

/// Uses RtlGetVersion because GetVersionEx reports the manifest's version instead of the real one.
uint32_t m0110_windows_build(void) {
    typedef LONG(WINAPI * rtl_get_version)(OSVERSIONINFOW *);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    rtl_get_version get = ntdll ? (rtl_get_version)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    OSVERSIONINFOW info = {0};
    info.dwOSVersionInfoSize = sizeof info;
    if (!get || get(&info) != 0) return 0;
    return info.dwBuildNumber;
}

uint32_t m0110_module_path(uint16_t *out, uint32_t capacity) {
    DWORD length = GetModuleFileNameW(NULL, (wchar_t *)out, capacity);
    return length < capacity ? length : 0;
}

int32_t m0110_run_at_login(const uint16_t *name, const uint16_t *command) {
    HKEY key;
    LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, run_key, 0, KEY_SET_VALUE, &key);
    if (status != ERROR_SUCCESS) return (int32_t)status;
    if (command) {
        DWORD bytes = (DWORD)((wcslen((const wchar_t *)command) + 1) * sizeof(wchar_t));
        status = RegSetValueExW(key, (const wchar_t *)name, 0, REG_SZ, (const BYTE *)command, bytes);
    } else {
        status = RegDeleteValueW(key, (const wchar_t *)name);
        if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return (int32_t)status;
}

int32_t m0110_runs_at_login(const uint16_t *name) {
    return RegGetValueW(HKEY_CURRENT_USER, run_key, (const wchar_t *)name, RRF_RT_REG_SZ, NULL, NULL, NULL) ==
           ERROR_SUCCESS;
}

void m0110_message_box(const uint16_t *title, const uint16_t *text) {
    MessageBoxW(NULL, (const wchar_t *)text, (const wchar_t *)title, MB_OK | MB_ICONWARNING | MB_SETFOREGROUND);
}

// ---- Display ----

m0110_screen m0110_current_screen(void) {
    m0110_screen screen;
    memset(&screen, 0, sizeof screen);
    opt_in();

    HWND foreground = GetForegroundWindow();
    POINT origin = {0, 0};
    HMONITOR monitor = foreground ? MonitorFromWindow(foreground, MONITOR_DEFAULTTOPRIMARY)
                                  : MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info = {sizeof info};
    if (!GetMonitorInfoW(monitor, &info)) {
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &info.rcWork, 0);
        info.rcMonitor = info.rcWork;
    }
    screen.work.left = info.rcWork.left;
    screen.work.top = info.rcWork.top;
    screen.work.right = info.rcWork.right;
    screen.work.bottom = info.rcWork.bottom;

    UINT dpi_x = 96, dpi_y = 96;
    if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) dpi_x = 96;
    screen.dpi = dpi_x;

    // The taskbar is on the edge where the work area stops short. An auto-hide
    // taskbar or one on another monitor leaves no gap, so assume the bottom.
    if (info.rcWork.top > info.rcMonitor.top) screen.taskbar_edge = 1;
    else if (info.rcWork.left > info.rcMonitor.left) screen.taskbar_edge = 0;
    else if (info.rcWork.right < info.rcMonitor.right) screen.taskbar_edge = 2;
    else screen.taskbar_edge = 3;
    return screen;
}

static DWORD theme_value(const wchar_t *name, DWORD fallback) {
    DWORD value = fallback, size = sizeof value;
    if (RegGetValueW(HKEY_CURRENT_USER, theme_key, name, RRF_RT_REG_DWORD, NULL, &value, &size) != ERROR_SUCCESS)
        return fallback;
    return value;
}

int32_t m0110_apps_dark(void) { return theme_value(L"AppsUseLightTheme", 1) == 0; }
int32_t m0110_taskbar_dark(void) { return theme_value(L"SystemUsesLightTheme", 0) == 0; }
int32_t m0110_transparency(void) { return theme_value(L"EnableTransparency", 1) != 0; }

int32_t m0110_reduce_motion(void) {
    BOOL animate = TRUE;
    if (!SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animate, 0)) return 0;
    return !animate;
}

int32_t m0110_tray_icon_size(void) { return GetSystemMetrics(SM_CXSMICON); }

// ---- HUD ----

int32_t m0110_hud_present(const uint8_t *pixels, int32_t width, int32_t height, int32_t x, int32_t y,
                          uint8_t alpha) {
    if (!hud_window || width <= 0 || height <= 0) return ERROR_INVALID_PARAMETER;

    HDC screen = GetDC(NULL);
    HDC memory = CreateCompatibleDC(screen);
    BITMAPINFO info;
    memset(&info, 0, sizeof info);
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, NULL, 0);
    DWORD error = 0;
    if (bitmap && bits) {
        memcpy(bits, pixels, (size_t)width * (size_t)height * 4);
        HGDIOBJ previous = SelectObject(memory, bitmap);
        POINT source = {0, 0};
        POINT destination = {x, y};
        SIZE size = {width, height};
        BLENDFUNCTION blend = {AC_SRC_OVER, 0, alpha, AC_SRC_ALPHA};
        if (!UpdateLayeredWindow(hud_window, screen, &destination, &size, memory, &source, 0, &blend,
                                 ULW_ALPHA))
            error = GetLastError();
        SelectObject(memory, previous);
        DeleteObject(bitmap);
    } else {
        error = GetLastError();
    }
    DeleteDC(memory);
    ReleaseDC(NULL, screen);

    if (!error && !IsWindowVisible(hud_window)) ShowWindow(hud_window, SW_SHOWNOACTIVATE);
    // Raise again above windows that became topmost since.
    SetWindowPos(hud_window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    return (int32_t)error;
}

void m0110_hud_move(int32_t x, int32_t y, uint8_t alpha) {
    POINT destination = {x, y};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, alpha, AC_SRC_ALPHA};
    UpdateLayeredWindow(hud_window, NULL, &destination, NULL, NULL, NULL, 0, &blend, ULW_ALPHA);
}

void m0110_hud_hide(void) { ShowWindow(hud_window, SW_HIDE); }

// ---- Tray ----

static HICON make_icon(const uint8_t *pixels, int32_t size) {
    BITMAPV5HEADER header;
    memset(&header, 0, sizeof header);
    header.bV5Size = sizeof header;
    header.bV5Width = size;
    header.bV5Height = -size;
    header.bV5Planes = 1;
    header.bV5BitCount = 32;
    header.bV5Compression = BI_BITFIELDS;
    header.bV5RedMask = 0x00FF0000;
    header.bV5GreenMask = 0x0000FF00;
    header.bV5BlueMask = 0x000000FF;
    header.bV5AlphaMask = 0xFF000000;

    HDC screen = GetDC(NULL);
    void *bits = NULL;
    HBITMAP color = CreateDIBSection(screen, (BITMAPINFO *)&header, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen);
    if (!color || !bits) return NULL;
    memcpy(bits, pixels, (size_t)size * (size_t)size * 4);

    // The color bitmap's alpha does the masking, but an icon still needs a mask.
    size_t stride = (size_t)((size + 15) / 16) * 2;
    void *zeros = calloc(stride * (size_t)size, 1);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, zeros);
    free(zeros);

    ICONINFO info;
    memset(&info, 0, sizeof info);
    info.fIcon = TRUE;
    info.hbmMask = mask;
    info.hbmColor = color;
    HICON icon = CreateIconIndirect(&info);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

int32_t m0110_tray_set(const uint8_t *pixels, int32_t size, const uint16_t *tooltip) {
    HICON icon = make_icon(pixels, size);
    if (!icon) return (int32_t)GetLastError();

    tray.cbSize = sizeof tray;
    tray.hWnd = app_window;
    tray.uID = TRAY_ID;
    tray.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
    tray.uCallbackMessage = WM_M0110_TRAY;
    tray.hIcon = icon;
    wcsncpy_s(tray.szTip, sizeof tray.szTip / sizeof tray.szTip[0], (const wchar_t *)tooltip, _TRUNCATE);

    if (tray_shown) {
        if (!Shell_NotifyIconW(NIM_MODIFY, &tray)) add_tray();
    } else {
        add_tray();
    }
    if (tray_icon) DestroyIcon(tray_icon);
    tray_icon = icon;
    return tray_shown ? 0 : 1;
}

void m0110_tray_remove(void) {
    if (tray_shown) Shell_NotifyIconW(NIM_DELETE, &tray);
    tray_shown = 0;
}

int32_t m0110_menu(const uint16_t *items, const uint8_t *flags) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return 0;
    UINT index = 0;
    for (const wchar_t *item = (const wchar_t *)items; *item; item += wcslen(item) + 1, index++) {
        if (wcscmp(item, L"-") == 0) {
            AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            continue;
        }
        UINT style = MF_STRING;
        if (flags[index] & 1) style |= MF_CHECKED;
        if (flags[index] & 2) style |= MF_GRAYED;
        AppendMenuW(menu, style, index + 1, item);
    }

    POINT cursor;
    GetCursorPos(&cursor);
    // Without this the menu stays up after a click elsewhere.
    SetForegroundWindow(app_window);
    UINT align = GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN : TPM_LEFTALIGN;
    int chosen = (int)TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | align,
                                       cursor.x, cursor.y, app_window, NULL);
    PostMessageW(app_window, WM_NULL, 0, 0);
    DestroyMenu(menu);
    return chosen;
}
