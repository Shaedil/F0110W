// USB CDC ACM serial ports, for the ZMK Studio RPC link.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdlib.h>
#include <string.h>

#include "CM0110Win.h"

#define MAX_PORTS 64

static int port_number(const wchar_t *port) {
    return _wcsnicmp(port, L"COM", 3) == 0 ? _wtoi(port + 3) : 0;
}

int32_t m0110_serial_ports(uint16_t *out, uint32_t capacity) {
    if (capacity < 2) return 0;
    out[0] = out[1] = 0;

    // The kernel's own list: the device behind each COM name. The inbox
    // usbser.sys driver, which takes every CDC ACM port, names them USBSER.
    HKEY key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_READ, &key) != ERROR_SUCCESS)
        return 0;

    wchar_t ports[MAX_PORTS][32];
    int count = 0;
    for (DWORD index = 0; count < MAX_PORTS; index++) {
        wchar_t device[256];
        DWORD device_length = sizeof device / sizeof device[0];
        wchar_t port[32];
        DWORD port_bytes = sizeof port - sizeof port[0];
        DWORD type = 0;
        LSTATUS status =
            RegEnumValueW(key, index, device, &device_length, NULL, &type, (BYTE *)port, &port_bytes);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS || type != REG_SZ) continue;
        port[port_bytes / sizeof port[0]] = 0;
        _wcsupr_s(device, sizeof device / sizeof device[0]);
        if (!wcsstr(device, L"USBSER")) continue;
        wcsncpy_s(ports[count++], 32, port, _TRUNCATE);
    }
    RegCloseKey(key);

    // In COM number order, as the Mac lists /dev/cu.usbmodem*.
    for (int i = 1; i < count; i++) {
        for (int j = i; j > 0 && port_number(ports[j - 1]) > port_number(ports[j]); j--) {
            wchar_t swap[32];
            wcscpy_s(swap, 32, ports[j]);
            wcscpy_s(ports[j], 32, ports[j - 1]);
            wcscpy_s(ports[j - 1], 32, swap);
        }
    }

    uint32_t used = 0;
    int written = 0;
    for (int i = 0; i < count; i++) {
        size_t length = wcslen(ports[i]) + 1;
        if (used + length + 1 > capacity) break;
        memcpy(out + used, ports[i], length * sizeof(uint16_t));
        used += (uint32_t)length;
        written++;
    }
    out[used] = 0;
    return written;
}

void *m0110_serial_open(const uint16_t *port, uint32_t *error) {
    wchar_t path[64] = L"\\\\.\\";
    wcsncat_s(path, 64, (const wchar_t *)port, _TRUNCATE);
    HANDLE handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        *error = GetLastError();
        return NULL;
    }

    DCB dcb;
    memset(&dcb, 0, sizeof dcb);
    dcb.DCBlength = sizeof dcb;
    if (!GetCommState(handle, &dcb)) goto fail;
    // The baud rate means nothing to a CDC ACM device; raw 8N1 does.
    dcb.BaudRate = CBR_115200;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDsrSensitivity = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    dcb.fNull = FALSE;
    dcb.fAbortOnError = FALSE;
    // Asserted, as macOS does on open: a CDC ACM device may hold its output
    // until the host raises DTR.
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    if (!SetCommState(handle, &dcb)) goto fail;

    // A read returns what has arrived, or waits up to 100 ms for the first
    // byte: the VMIN 0 / VTIME 1 the Mac transport uses.
    COMMTIMEOUTS timeouts;
    memset(&timeouts, 0, sizeof timeouts);
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.ReadTotalTimeoutMultiplier = MAXDWORD;
    timeouts.ReadTotalTimeoutConstant = 100;
    timeouts.WriteTotalTimeoutConstant = 1000;
    if (!SetCommTimeouts(handle, &timeouts)) goto fail;
    PurgeComm(handle, PURGE_RXCLEAR | PURGE_TXCLEAR);
    return handle;

fail:
    *error = GetLastError();
    CloseHandle(handle);
    return NULL;
}

int32_t m0110_serial_write(void *port, const uint8_t *data, uint32_t length) {
    uint32_t written = 0;
    while (written < length) {
        DWORD count = 0;
        if (!WriteFile((HANDLE)port, data + written, length - written, &count, NULL) || count == 0) return -1;
        written += count;
    }
    return (int32_t)written;
}

int32_t m0110_serial_read(void *port, uint8_t *out, uint32_t capacity) {
    DWORD count = 0;
    if (!ReadFile((HANDLE)port, out, capacity, &count, NULL)) return -1;
    return (int32_t)count;
}

void m0110_serial_close(void *port) {
    if (port) CloseHandle((HANDLE)port);
}
