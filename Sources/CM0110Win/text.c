// Draws one line of text with GDI as a coverage mask. It uses greyscale
// antialiasing, white on black, because ClearType color fringes would show
// once Swift composites the HUD with per-pixel alpha.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <string.h>
#include <wchar.h>

#include "CM0110Win.h"

static int CALLBACK found_face(const LOGFONTW *font, const TEXTMETRICW *metrics, DWORD type, LPARAM found) {
    (void)font;
    (void)metrics;
    (void)type;
    *(int *)found = 1;
    return 0;
}

static int installed(const wchar_t *face) {
    LOGFONTW font;
    memset(&font, 0, sizeof font);
    font.lfCharSet = DEFAULT_CHARSET;
    wcsncpy_s(font.lfFaceName, LF_FACESIZE, face, _TRUNCATE);
    int found = 0;
    HDC screen = GetDC(NULL);
    EnumFontFamiliesExW(screen, &font, found_face, (LPARAM)&found, 0);
    ReleaseDC(NULL, screen);
    return found;
}

static void pick_face(const wchar_t *faces, wchar_t face[LF_FACESIZE]) {
    face[0] = 0;
    while (*faces) {
        const wchar_t *end = wcschr(faces, L';');
        size_t length = end ? (size_t)(end - faces) : wcslen(faces);
        if (length > 0 && length < LF_FACESIZE) {
            wmemcpy(face, faces, length);
            face[length] = 0;
            if (installed(face)) return;
        }
        if (!end) break;
        faces = end + 1;
    }
    face[0] = 0;
}

int32_t m0110_text(const uint16_t *text, const uint16_t *faces, int32_t size, int32_t weight, uint8_t *mask,
                   int32_t width, int32_t height, int32_t *line_height) {
    wchar_t face[LF_FACESIZE];
    pick_face((const wchar_t *)faces, face);
    if (!face[0]) return -1;

    HFONT font = CreateFontW(-size, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_PRECIS,
                             CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, face);
    HDC dc = CreateCompatibleDC(NULL);
    HGDIOBJ previous_font = SelectObject(dc, font);
    TEXTMETRICW metrics;
    GetTextMetricsW(dc, &metrics);
    if (line_height) *line_height = metrics.tmHeight;

    const UINT format = DT_SINGLELINE | DT_NOPREFIX | DT_LEFT | DT_TOP;
    RECT natural = {0, 0, 0, metrics.tmHeight};
    DrawTextW(dc, (const wchar_t *)text, -1, &natural, format | DT_CALCRECT);
    int32_t used = natural.right - natural.left;
    if (width > 0 && used > width) used = width;

    if (mask && width > 0 && height > 0) {
        BITMAPINFO info;
        memset(&info, 0, sizeof info);
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        void *bits = NULL;
        HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, NULL, 0);
        if (bitmap && bits) {
            HGDIOBJ previous_bitmap = SelectObject(dc, bitmap);
            memset(bits, 0, (size_t)width * (size_t)height * 4);
            SetTextColor(dc, RGB(255, 255, 255));
            SetBkMode(dc, TRANSPARENT);
            RECT box = {0, 0, width, height};
            DrawTextW(dc, (const wchar_t *)text, -1, &box, format | DT_END_ELLIPSIS);
            GdiFlush();
            const uint8_t *pixel = (const uint8_t *)bits;
            for (size_t i = 0, count = (size_t)width * (size_t)height; i < count; i++, pixel += 4)
                mask[i] = pixel[1];
            SelectObject(dc, previous_bitmap);
        }
        if (bitmap) DeleteObject(bitmap);
    }

    SelectObject(dc, previous_font);
    DeleteObject(font);
    DeleteDC(dc);
    return used;
}
