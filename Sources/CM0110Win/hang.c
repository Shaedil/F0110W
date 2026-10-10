// What the app was doing when it stopped answering.
//
// The app thread runs the tray, the HUD and the window, so when it stops
// answering everything stops with it. A watchdog thread asks it a trivial
// question every half second; when the answer is two seconds late, the
// watchdog records where the thread is stuck, as a stack with names from the
// .pdb shipped beside the executable, and the last things the app logged,
// in %LOCALAPPDATA%\M0110HUD\hang.log. It costs nothing until something hangs.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dbghelp.h>
#include <share.h>
#include <stdio.h>
#include <string.h>

#include "CM0110Win.h"

// ---- Recent log lines ----

#define TRACE_LINES 200
#define TRACE_WIDTH 240

static char trace[TRACE_LINES][TRACE_WIDTH];
static unsigned trace_next;
static SRWLOCK trace_lock = SRWLOCK_INIT;

void m0110_trace(const char *line) {
    SYSTEMTIME t;
    GetLocalTime(&t);
    AcquireSRWLockExclusive(&trace_lock);
    snprintf(trace[trace_next % TRACE_LINES], TRACE_WIDTH, "%02d:%02d:%02d.%03d %s", t.wHour, t.wMinute, t.wSecond,
             t.wMilliseconds, line);
    trace_next++;
    ReleaseSRWLockExclusive(&trace_lock);
}

// ---- The watchdog ----

static HANDLE app_thread;
static HWND watched;
/// Open only while a report is written, and shared, so the log can be read
/// while the app runs.
static FILE *report;

static FILE *open_report(void) {
    wchar_t path[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", path, MAX_PATH);
    if (length == 0 || length > MAX_PATH - 40) return NULL;
    wcscat_s(path, MAX_PATH, L"\\M0110HUD");
    CreateDirectoryW(path, NULL);
    wcscat_s(path, MAX_PATH, L"\\hang.log");
    // Kept to the last few hangs: start over past a megabyte.
    WIN32_FILE_ATTRIBUTE_DATA info;
    int fresh = GetFileAttributesExW(path, GetFileExInfoStandard, &info) && info.nFileSizeLow > 1024 * 1024;
    return _wfsopen(path, fresh ? L"w" : L"a", _SH_DENYNO);
}

/// The suspended thread's return addresses, by unwinding its x64 stack.
/// Nothing here allocates or takes a lock the app thread could be holding.
static int capture(DWORD64 *frames, int capacity) {
    int count = 0;
#if defined(_M_X64) || defined(__x86_64__)
    CONTEXT context;
    memset(&context, 0, sizeof context);
    context.ContextFlags = CONTEXT_FULL;
    if (!GetThreadContext(app_thread, &context)) return 0;
    while (count < capacity && context.Rip) {
        frames[count++] = context.Rip;
        DWORD64 base = 0;
        PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(context.Rip, &base, NULL);
        if (function) {
            PVOID data;
            DWORD64 frame;
            RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, context.Rip, function, &context, &data, &frame, NULL);
        } else {
            context.Rip = *(DWORD64 *)context.Rsp;
            context.Rsp += 8;
        }
    }
#else
    (void)frames;
    (void)capacity;
#endif
    return count;
}

static void write_stack(DWORD64 *frames, int count) {
    static int symbols;
    if (!symbols) {
        SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
        symbols = SymInitialize(GetCurrentProcess(), NULL, TRUE) ? 1 : -1;
    }
    for (int i = 0; i < count; i++) {
        char module[MAX_PATH] = "?";
        DWORD64 base = 0;
        HMODULE handle;
        if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               (LPCSTR)frames[i], &handle)) {
            GetModuleFileNameA(handle, module, MAX_PATH);
            base = (DWORD64)handle;
        }
        const char *name = strrchr(module, '\\');
        name = name ? name + 1 : module;
        char buffer[sizeof(SYMBOL_INFO) + 512];
        SYMBOL_INFO *symbol = (SYMBOL_INFO *)buffer;
        memset(buffer, 0, sizeof buffer);
        symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
        symbol->MaxNameLen = 511;
        DWORD64 offset = 0;
        if (symbols == 1 && SymFromAddr(GetCurrentProcess(), frames[i], &offset, symbol))
            fprintf(report, "  %2d %s!%s+0x%llx\n", i, name, symbol->Name, offset);
        else
            fprintf(report, "  %2d %s+0x%llx\n", i, name, frames[i] - base);
    }
}

static void write_trace(void) {
    // A thread hung while logging would hold this; then the lines are lost,
    // not the report.
    for (int tries = 0; !TryAcquireSRWLockShared(&trace_lock); tries++) {
        if (tries == 20) {
            fprintf(report, "  (recent log unavailable)\n");
            return;
        }
        Sleep(5);
    }
    unsigned first = trace_next > TRACE_LINES ? trace_next - TRACE_LINES : 0;
    for (unsigned i = first; i < trace_next; i++) fprintf(report, "  %s\n", trace[i % TRACE_LINES]);
    ReleaseSRWLockShared(&trace_lock);
}

static void stamp(const char *what, ULONGLONG ms) {
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(report, "%04d-%02d-%02d %02d:%02d:%02d %s %llu ms\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute,
            t.wSecond, what, ms);
}

static void record(ULONGLONG stuck, int first) {
    DWORD64 frames[48];
    if (SuspendThread(app_thread) == (DWORD)-1) return;
    int count = capture(frames, 48);
    ResumeThread(app_thread);

    if (!(report = open_report())) return;
    stamp(first ? "\n==== app thread not answering for" : "still not answering after", stuck);
    fprintf(report, "it is in:\n");
    write_stack(frames, count);
    if (first) {
        fprintf(report, "the app's last log lines:\n");
        write_trace();
    }
    fclose(report);
    report = NULL;
}

static DWORD WINAPI watchdog(void *unused) {
    (void)unused;
    ULONGLONG stuck_since = 0, recorded_at = 0;
    for (;;) {
        Sleep(500);
        ULONGLONG asked = GetTickCount64();
        DWORD_PTR result;
        if (SendMessageTimeoutW(watched, WM_NULL, 0, 0, SMTO_NORMAL, 2000, &result)) {
            if (stuck_since && recorded_at && (report = open_report())) {
                stamp("answered again after", GetTickCount64() - stuck_since);
                fclose(report);
                report = NULL;
            }
            stuck_since = recorded_at = 0;
            continue;
        }
        if (GetLastError() != ERROR_TIMEOUT) return 0; // The window is gone: the app is quitting.
        if (!stuck_since) stuck_since = asked;
        ULONGLONG now = GetTickCount64();
        // Once on catching it, then every ten seconds while it lasts.
        if (!recorded_at || now - recorded_at >= 10000) {
            record(now - stuck_since, !recorded_at);
            recorded_at = now;
        }
    }
}

void m0110_watch_app_thread(void *window) {
    watched = (HWND)window;
    app_thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE,
                            GetCurrentThreadId());
    if (!app_thread) return;
    HANDLE thread = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    if (thread) CloseHandle(thread);
}
