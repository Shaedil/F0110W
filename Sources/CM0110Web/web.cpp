// A Win32 window filled by a WebView2. The COM handlers are written by hand instead of
// WRL, so only the Windows SDK and WebView2.h are needed. No STL, since this Clang may be
// older than Visual Studio's STL requires.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shellscalingapi.h>
#include <wchar.h>

#include <WebView2.h>

#include "CM0110Web.h"

namespace {

// ---- COM handlers ----

// Implements one WebView2 handler interface, with Invoke calling a lambda.
#define M0110_HANDLER(Name, Interface, Params, Args)                                     \
    template <typename F> class Name final : public Interface {                            \
      public:                                                                              \
        explicit Name(F function) : function_(static_cast<F &&>(function)) {}              \
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {        \
            if (iid == __uuidof(Interface) || iid == __uuidof(IUnknown)) {                 \
                *out = static_cast<Interface *>(this);                                     \
                AddRef();                                                                  \
                return S_OK;                                                               \
            }                                                                              \
            *out = nullptr;                                                                \
            return E_NOINTERFACE;                                                          \
        }                                                                                  \
        ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); } \
        ULONG STDMETHODCALLTYPE Release() override {                                       \
            ULONG refs = InterlockedDecrement(&refs_);                                     \
            if (refs == 0) delete this;                                                    \
            return refs;                                                                   \
        }                                                                                  \
        HRESULT STDMETHODCALLTYPE Invoke Params override { return function_ Args; }        \
                                                                                           \
      private:                                                                             \
        LONG refs_ = 1;                                                                    \
        F function_;                                                                       \
    };                                                                                     \
    template <typename F> Name<F> *make_##Name(F function) { return new Name<F>(static_cast<F &&>(function)); }

M0110_HANDLER(EnvironmentDone, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
              (HRESULT result, ICoreWebView2Environment *environment), (result, environment))
M0110_HANDLER(ControllerDone, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
              (HRESULT result, ICoreWebView2Controller *controller), (result, controller))
M0110_HANDLER(MessageReceived, ICoreWebView2WebMessageReceivedEventHandler,
              (ICoreWebView2 * sender, ICoreWebView2WebMessageReceivedEventArgs *args), (sender, args))
M0110_HANDLER(ProcessFailed, ICoreWebView2ProcessFailedEventHandler,
              (ICoreWebView2 * sender, ICoreWebView2ProcessFailedEventArgs *args), (sender, args))
M0110_HANDLER(NewWindow, ICoreWebView2NewWindowRequestedEventHandler,
              (ICoreWebView2 * sender, ICoreWebView2NewWindowRequestedEventArgs *args), (sender, args))

#undef M0110_HANDLER

template <typename T> void release(T *&pointer) {
    if (pointer) pointer->Release();
    pointer = nullptr;
}

// ---- State ----

const wchar_t *const window_class = L"M0110HUD.Window";
const wchar_t *const host_name = L"m0110.ui";

m0110_web_callbacks callbacks;
HWND window;
ICoreWebView2Environment *environment;
bool environment_pending;
ICoreWebView2Controller *controller;
ICoreWebView2 *webview;
wchar_t folder[MAX_PATH * 2], data_folder[MAX_PATH * 2];
const DWORD window_style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

bool developer_mode() { return GetEnvironmentVariableW(L"M0110_WEB_DEV", nullptr, 0) > 0; }


/// Page background. The same near-black in light and dark, as on the Mac.
const COLORREF ground = RGB(0x0b, 0x0a, 0x09);

void apply_frame_theme() {
    if (!window) return;
    // Dark caption in the page's black for any theme. 20 is DWMWA_USE_IMMERSIVE_DARK_MODE
    // (Windows 10 20H1+) and 35 is DWMWA_CAPTION_COLOR (Windows 11).
    BOOL dark = TRUE;
    DwmSetWindowAttribute(window, 20, &dark, sizeof dark);
    COLORREF caption = ground;
    DwmSetWindowAttribute(window, 35, &caption, sizeof caption);
    if (controller) {
        ICoreWebView2Controller2 *controller2 = nullptr;
        if (SUCCEEDED(controller->QueryInterface(__uuidof(ICoreWebView2Controller2), (void **)&controller2))) {
            COLORREF c = ground;
            COREWEBVIEW2_COLOR color = {255, GetRValue(c), GetGValue(c), GetBValue(c)};
            controller2->put_DefaultBackgroundColor(color);
            controller2->Release();
        }
    }
}

void fit() {
    if (!controller || !window) return;
    RECT bounds;
    GetClientRect(window, &bounds);
    controller->put_Bounds(bounds);
}

void fail(HRESULT result) {
    if (callbacks.failed) callbacks.failed((int32_t)result);
}

// ---- WebView2 ----

void set_up(ICoreWebView2Controller *new_controller) {
    controller = new_controller;
    controller->AddRef();
    controller->get_CoreWebView2(&webview);
    apply_frame_theme();
    fit();

    bool dev = developer_mode();
    ICoreWebView2Settings *settings = nullptr;
    if (SUCCEEDED(webview->get_Settings(&settings))) {
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_IsZoomControlEnabled(FALSE);
        settings->put_AreDevToolsEnabled(dev);
        settings->put_AreDefaultContextMenusEnabled(dev);
        ICoreWebView2Settings3 *settings3 = nullptr;
        if (SUCCEEDED(settings->QueryInterface(__uuidof(ICoreWebView2Settings3), (void **)&settings3))) {
            settings3->put_AreBrowserAcceleratorKeysEnabled(dev);
            settings3->Release();
        }
        settings->Release();
    }

    EventRegistrationToken token;
    webview->add_WebMessageReceived(make_MessageReceived([](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) {
        LPWSTR json = nullptr;
        if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
            if (callbacks.message) callbacks.message((const uint16_t *)json);
            CoTaskMemFree(json);
        }
        return S_OK;
    }), &token);
    // A renderer crash leaves a blank window, so reload.
    webview->add_ProcessFailed(make_ProcessFailed([](ICoreWebView2 *sender, ICoreWebView2ProcessFailedEventArgs *args) {
        COREWEBVIEW2_PROCESS_FAILED_KIND kind;
        if (SUCCEEDED(args->get_ProcessFailedKind(&kind)) &&
            kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED)
            sender->Reload();
        return S_OK;
    }), &token);
    webview->add_NewWindowRequested(make_NewWindow([](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) {
        LPWSTR uri = nullptr;
        if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
            ShellExecuteW(nullptr, L"open", uri, nullptr, nullptr, SW_SHOWNORMAL);
            CoTaskMemFree(uri);
        }
        args->put_Handled(TRUE);
        return S_OK;
    }), &token);

    ICoreWebView2_3 *webview3 = nullptr;
    if (FAILED(webview->QueryInterface(__uuidof(ICoreWebView2_3), (void **)&webview3))) {
        fail(E_NOINTERFACE);
        return;
    }
    webview3->SetVirtualHostNameToFolderMapping(host_name, folder,
                                                COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
    webview3->Release();
    webview->Navigate(L"https://m0110.ui/index.html");
}

void create_controller() {
    HWND target = window;
    environment->CreateCoreWebView2Controller(
        window, make_ControllerDone([target](HRESULT result, ICoreWebView2Controller *new_controller) {
            // The window was closed while WebView2 was starting.
            if (window != target) {
                if (new_controller) new_controller->Close();
                return S_OK;
            }
            if (FAILED(result) || !new_controller) {
                fail(result);
                return S_OK;
            }
            set_up(new_controller);
            return S_OK;
        }));
}

void create_environment() {
    if (environment_pending) return;
    environment_pending = true;
    HRESULT result = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, data_folder, nullptr,
        make_EnvironmentDone([](HRESULT result, ICoreWebView2Environment *new_environment) {
            environment_pending = false;
            if (FAILED(result) || !new_environment) {
                fail(result);
                return S_OK;
            }
            environment = new_environment;
            environment->AddRef();
            if (window) create_controller();
            return S_OK;
        }));
    if (FAILED(result)) {
        environment_pending = false;
        fail(result);
    }
}

// ---- The window ----

LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_SIZE:
        fit();
        return 0;
    case WM_MOVE:
        if (controller) controller->NotifyParentWindowPositionChanged();
        return 0;
    case WM_SETFOCUS:
        if (controller) controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        return 0;
    case WM_DPICHANGED: {
        RECT *suggested = (RECT *)lparam;
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_ERASEBKGND: {
        RECT area;
        GetClientRect(hwnd, &area);
        HBRUSH brush = CreateSolidBrush(ground);
        FillRect((HDC)wparam, &area, brush);
        DeleteObject(brush);
        return 1;
    }
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (controller) controller->Close();
        release(webview);
        release(controller);
        window = nullptr;
        if (callbacks.closed) callbacks.closed();
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

/// Outer rect for a 96 DPI client size, scaled and centered on the monitor under the mouse.
RECT placement(int width, int height) {
    POINT cursor;
    GetCursorPos(&cursor);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info = {sizeof info};
    GetMonitorInfoW(monitor, &info);
    UINT dpi_x = 96, dpi_y = 96;
    if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) dpi_x = 96;
    RECT frame = {0, 0, MulDiv(width, dpi_x, 96), MulDiv(height, dpi_x, 96)};
    AdjustWindowRectExForDpi(&frame, window_style, FALSE, 0, dpi_x);
    LONG w = frame.right - frame.left, h = frame.bottom - frame.top;
    const RECT &work = info.rcWork;
    if (w > work.right - work.left) w = work.right - work.left;
    if (h > work.bottom - work.top) h = work.bottom - work.top;
    LONG x = work.left + ((work.right - work.left) - w) / 2;
    LONG y = work.top + ((work.bottom - work.top) - h) / 2;
    return RECT{x, y, x + w, y + h};
}

} // namespace

extern "C" int32_t m0110_web_open(const uint16_t *title, const uint16_t *page_folder, const uint16_t *data,
                                  int32_t width, int32_t height, const m0110_web_callbacks *app_callbacks) {
    if (window) {
        if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
        return 0;
    }

    static bool com;
    if (!com) {
        // WebView2 needs an STA on the thread that owns its window and runs the message loop.
        HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(result) && result != RPC_E_CHANGED_MODE) return (int32_t)result;
        com = true;
    }

    callbacks = *app_callbacks;
    wcscpy_s(folder, sizeof folder / sizeof folder[0], (const wchar_t *)page_folder);
    wcscpy_s(data_folder, sizeof data_folder / sizeof data_folder[0], (const wchar_t *)data);

    static bool registered;
    HINSTANCE instance = GetModuleHandleW(nullptr);
    if (!registered) {
        WNDCLASSEXW window_class_info = {sizeof window_class_info};
        window_class_info.lpfnWndProc = window_proc;
        window_class_info.hInstance = instance;
        window_class_info.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        window_class_info.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
        window_class_info.lpszClassName = window_class;
        if (!RegisterClassExW(&window_class_info)) return (int32_t)GetLastError();
        registered = true;
    }

    RECT frame = placement(width, height);
    window = CreateWindowExW(0, window_class, (const wchar_t *)title, window_style, frame.left, frame.top,
                             frame.right - frame.left, frame.bottom - frame.top, nullptr, nullptr, instance, nullptr);
    if (!window) return (int32_t)GetLastError();
    apply_frame_theme();
    ShowWindow(window, SW_SHOWNORMAL);
    SetForegroundWindow(window);

    if (environment)
        create_controller();
    else
        create_environment();
    return 0;
}

extern "C" void m0110_web_post(const uint16_t *json) {
    if (webview) webview->PostWebMessageAsJson((const wchar_t *)json);
}

extern "C" void m0110_web_resize(int32_t width, int32_t height) {
    if (!window) return;
    UINT dpi = GetDpiForWindow(window);
    RECT frame = {0, 0, MulDiv(width, dpi, 96), MulDiv(height, dpi, 96)};
    AdjustWindowRectExForDpi(&frame, window_style, FALSE, 0, dpi);
    SetWindowPos(window, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

extern "C" int32_t m0110_web_is_open(void) { return window ? 1 : 0; }

extern "C" void m0110_web_close(void) {
    if (window) DestroyWindow(window);
}
