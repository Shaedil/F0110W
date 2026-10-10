// The Windows clipboard, plus image work through the Windows Imaging Component (WIC).
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <devpropdef.h>
#include <wincodec.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "CM0110Win.h"

// ---- COM, for the Imaging Component ----

/// Any apartment the thread is already in is fine. Returns 1 when com_end must balance it.
static int com_begin(void) {
    HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    return result == S_OK || result == S_FALSE;
}

static void com_end(int started) {
    if (started) CoUninitialize();
}

static IWICImagingFactory *factory(void) {
    IWICImagingFactory *wic = NULL;
    CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&wic);
    return wic;
}

static IWICBitmapSource *decode(IWICImagingFactory *wic, const uint8_t *data, uint32_t length, IWICStream **stream_out,
                                IWICBitmapDecoder **decoder_out) {
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    if (FAILED(IWICImagingFactory_CreateStream(wic, &stream))) return NULL;
    if (FAILED(IWICStream_InitializeFromMemory(stream, (BYTE *)data, length)) ||
        FAILED(IWICImagingFactory_CreateDecoderFromStream(wic, (IStream *)stream, NULL, WICDecodeMetadataCacheOnDemand,
                                                          &decoder)) ||
        FAILED(IWICBitmapDecoder_GetFrame(decoder, 0, &frame))) {
        if (decoder) IWICBitmapDecoder_Release(decoder);
        IWICStream_Release(stream);
        return NULL;
    }
    *stream_out = stream;
    *decoder_out = decoder;
    return (IWICBitmapSource *)frame;
}

static IWICBitmapSource *as_bgra(IWICImagingFactory *wic, IWICBitmapSource *source, REFWICPixelFormatGUID format) {
    IWICFormatConverter *converter = NULL;
    if (FAILED(IWICImagingFactory_CreateFormatConverter(wic, &converter))) return NULL;
    if (FAILED(IWICFormatConverter_Initialize(converter, source, format, WICBitmapDitherTypeNone, NULL, 0,
                                              WICBitmapPaletteTypeCustom))) {
        IWICFormatConverter_Release(converter);
        return NULL;
    }
    return (IWICBitmapSource *)converter;
}

static int encode(IWICImagingFactory *wic, IWICBitmapSource *source, int jpeg, float quality, uint8_t **out,
                  uint32_t *out_length) {
    IStream *memory = NULL;
    IWICBitmapEncoder *encoder = NULL;
    IWICBitmapFrameEncode *frame = NULL;
    IPropertyBag2 *options = NULL;
    int ok = 0;
    if (FAILED(CreateStreamOnHGlobal(NULL, TRUE, &memory))) return 0;
    if (FAILED(IWICImagingFactory_CreateEncoder(wic, jpeg ? &GUID_ContainerFormatJpeg : &GUID_ContainerFormatPng,
                                                NULL, &encoder)) ||
        FAILED(IWICBitmapEncoder_Initialize(encoder, memory, WICBitmapEncoderNoCache)) ||
        FAILED(IWICBitmapEncoder_CreateNewFrame(encoder, &frame, &options)))
        goto done;
    if (jpeg && options) {
        PROPBAG2 name;
        memset(&name, 0, sizeof name);
        name.pstrName = L"ImageQuality";
        VARIANT value;
        VariantInit(&value);
        value.vt = VT_R4;
        value.fltVal = quality;
        IPropertyBag2_Write(options, 1, &name, &value);
    }
    if (FAILED(IWICBitmapFrameEncode_Initialize(frame, options))) goto done;
    UINT width = 0, height = 0;
    IWICBitmapSource_GetSize(source, &width, &height);
    IWICBitmapFrameEncode_SetSize(frame, width, height);
    WICPixelFormatGUID format = jpeg ? GUID_WICPixelFormat24bppBGR : GUID_WICPixelFormat32bppBGRA;
    IWICBitmapFrameEncode_SetPixelFormat(frame, &format);
    if (FAILED(IWICBitmapFrameEncode_WriteSource(frame, source, NULL)) ||
        FAILED(IWICBitmapFrameEncode_Commit(frame)) || FAILED(IWICBitmapEncoder_Commit(encoder)))
        goto done;

    HGLOBAL global = NULL;
    if (FAILED(GetHGlobalFromStream(memory, &global))) goto done;
    STATSTG stat;
    if (FAILED(IStream_Stat(memory, &stat, STATFLAG_NONAME))) goto done;
    uint32_t length = (uint32_t)stat.cbSize.QuadPart;
    void *bytes = GlobalLock(global);
    if (bytes && (*out = (uint8_t *)malloc(length))) {
        memcpy(*out, bytes, length);
        *out_length = length;
        ok = 1;
    }
    if (bytes) GlobalUnlock(global);
done:
    if (options) IPropertyBag2_Release(options);
    if (frame) IWICBitmapFrameEncode_Release(frame);
    if (encoder) IWICBitmapEncoder_Release(encoder);
    IStream_Release(memory);
    return ok;
}

// ---- Shrinking ----

/// Longest side and JPEG quality, tried in order until the result fits. Same steps as the Mac.
static const struct { UINT side; float quality; } ladder[] = {
    {2048, 0.6f}, {1600, 0.6f}, {1280, 0.5f}, {1024, 0.5f}, {800, 0.45f},
    {640, 0.4f},  {480, 0.4f},  {320, 0.35f}, {200, 0.3f},
};

/// Scales to fit `side` and flattens onto white, since JPEG has no transparency.
static IWICBitmapSource *scaled_onto_white(IWICImagingFactory *wic, IWICBitmapSource *source, UINT side) {
    UINT width = 0, height = 0;
    IWICBitmapSource_GetSize(source, &width, &height);
    if (!width || !height) return NULL;
    double factor = (double)side / (double)(width > height ? width : height);
    if (factor > 1) factor = 1;
    UINT w = (UINT)(width * factor + 0.5), h = (UINT)(height * factor + 0.5);
    if (!w) w = 1;
    if (!h) h = 1;

    IWICBitmapScaler *scaler = NULL;
    if (FAILED(IWICImagingFactory_CreateBitmapScaler(wic, &scaler))) return NULL;
    if (FAILED(IWICBitmapScaler_Initialize(scaler, source, w, h, WICBitmapInterpolationModeFant))) {
        IWICBitmapScaler_Release(scaler);
        return NULL;
    }
    IWICBitmapSource *straight = as_bgra(wic, (IWICBitmapSource *)scaler, &GUID_WICPixelFormat32bppBGRA);
    IWICBitmapScaler_Release(scaler);
    if (!straight) return NULL;

    uint8_t *pixels = (uint8_t *)malloc((size_t)w * h * 4);
    IWICBitmap *flat = NULL;
    if (pixels && SUCCEEDED(IWICBitmapSource_CopyPixels(straight, NULL, w * 4, w * h * 4, pixels))) {
        for (size_t i = 0; i < (size_t)w * h; i++) {
            uint8_t *p = pixels + i * 4;
            unsigned a = p[3];
            for (int c = 0; c < 3; c++) p[c] = (uint8_t)((p[c] * a + 255 * (255 - a) + 127) / 255);
            p[3] = 255;
        }
        IWICImagingFactory_CreateBitmapFromMemory(wic, w, h, &GUID_WICPixelFormat32bppBGRA, w * 4, w * h * 4, pixels,
                                                  &flat);
    }
    free(pixels);
    IWICBitmapSource_Release(straight);
    return (IWICBitmapSource *)flat;
}

int32_t m0110_image_shrink(const uint8_t *data, uint32_t length, uint32_t budget, uint8_t **out,
                           uint32_t *out_length) {
    int started = com_begin();
    IWICImagingFactory *wic = factory();
    int32_t fitted = 0;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapSource *source = wic ? decode(wic, data, length, &stream, &decoder) : NULL;
    for (size_t i = 0; source && !fitted && i < sizeof ladder / sizeof ladder[0]; i++) {
        IWICBitmapSource *flat = scaled_onto_white(wic, source, ladder[i].side);
        if (!flat) continue;
        uint8_t *bytes = NULL;
        uint32_t size = 0;
        if (encode(wic, flat, 1, ladder[i].quality, &bytes, &size)) {
            if (size <= budget) {
                *out = bytes;
                *out_length = size;
                fitted = 1;
            } else {
                free(bytes);
            }
        }
        IWICBitmapSource_Release(flat);
    }
    if (source) IWICBitmapSource_Release(source);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (wic) IWICImagingFactory_Release(wic);
    com_end(started);
    return fitted;
}

void m0110_free(void *bytes) { free(bytes); }

// ---- Reading the clipboard ----

static UINT format(const wchar_t *name) {
    static UINT png, exclude, history, cloud;
    if (!png) {
        png = RegisterClipboardFormatW(L"PNG");
        // Password managers use these to keep an item out of clipboard history
        // and cloud sync. Some set the first one, others set the other two to zero.
        exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
        history = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
        cloud = RegisterClipboardFormatW(L"CanUploadToCloudClipboard");
    }
    if (wcscmp(name, L"PNG") == 0) return png;
    if (wcscmp(name, L"exclude") == 0) return exclude;
    if (wcscmp(name, L"history") == 0) return history;
    return cloud;
}

static int open_clipboard(HWND owner, int tries) {
    for (int i = 0; i < tries; i++) {
        if (OpenClipboard(owner)) return 1;
        Sleep(10);
    }
    return 0;
}

static uint8_t *copy_format(UINT kind, uint32_t *length) {
    if (!kind || !IsClipboardFormatAvailable(kind)) return NULL;
    HANDLE handle = GetClipboardData(kind);
    if (!handle) return NULL;
    void *pointer = GlobalLock(handle);
    if (!pointer) return NULL;
    SIZE_T size = GlobalSize(handle);
    uint8_t *copy = (uint8_t *)malloc(size ? size : 1);
    if (copy) memcpy(copy, pointer, size);
    GlobalUnlock(handle);
    *length = (uint32_t)size;
    return copy;
}

static int is_private(void) {
    if (IsClipboardFormatAvailable(format(L"exclude"))) return 1;
    UINT kinds[2] = {format(L"history"), format(L"cloud")};
    for (int i = 0; i < 2; i++) {
        uint32_t length = 0;
        uint8_t *value = copy_format(kinds[i], &length);
        // A DWORD, where zero means not allowed.
        int no = value && length >= 4 && !(value[0] | value[1] | value[2] | value[3]);
        free(value);
        if (no) return 1;
    }
    return 0;
}

/// The PNG's real length from its chunks, since the clipboard copy can have padding after IEND.
static uint32_t png_length(const uint8_t *png, uint32_t length) {
    uint32_t at = 8;
    while (at + 12 <= length) {
        uint32_t chunk = (uint32_t)png[at] << 24 | (uint32_t)png[at + 1] << 16 | (uint32_t)png[at + 2] << 8 | png[at + 3];
        if (memcmp(png + at + 4, "IEND", 4) == 0) return at + 12;
        at += 12 + chunk;
    }
    return length;
}

static int dib_to_png(const uint8_t *dib, uint32_t length, uint8_t **out, uint32_t *out_length) {
    if (length < sizeof(BITMAPINFOHEADER)) return 0;
    const BITMAPINFOHEADER *info = (const BITMAPINFOHEADER *)dib;
    DWORD palette = info->biClrUsed ? info->biClrUsed : (info->biBitCount <= 8 ? 1u << info->biBitCount : 0);
    DWORD masks = info->biCompression == BI_BITFIELDS && info->biSize == sizeof(BITMAPINFOHEADER) ? 12 : 0;
    DWORD offset = sizeof(BITMAPFILEHEADER) + info->biSize + masks + palette * 4;
    uint32_t total = sizeof(BITMAPFILEHEADER) + length;
    uint8_t *bmp = (uint8_t *)malloc(total);
    if (!bmp) return 0;
    BITMAPFILEHEADER file;
    memset(&file, 0, sizeof file);
    file.bfType = 0x4D42;
    file.bfSize = total;
    file.bfOffBits = offset;
    memcpy(bmp, &file, sizeof file);
    memcpy(bmp + sizeof file, dib, length);

    int started = com_begin();
    IWICImagingFactory *wic = factory();
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapSource *source = wic ? decode(wic, bmp, total, &stream, &decoder) : NULL;
    int ok = 0;
    if (source) {
        IWICBitmapSource *bgra = as_bgra(wic, source, &GUID_WICPixelFormat32bppBGRA);
        if (bgra) {
            ok = encode(wic, bgra, 0, 0, out, out_length);
            IWICBitmapSource_Release(bgra);
        }
        IWICBitmapSource_Release(source);
    }
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (wic) IWICImagingFactory_Release(wic);
    com_end(started);
    free(bmp);
    return ok;
}

uint32_t m0110_clip_sequence(void) { return GetClipboardSequenceNumber(); }

int32_t m0110_clip_read(m0110_clip *clip) {
    memset(clip, 0, sizeof *clip);
    if (!open_clipboard(NULL, 10)) return M0110_CLIP_BUSY;
    int32_t kind = M0110_CLIP_NOTHING;
    uint8_t *dib = NULL;
    uint32_t dib_length = 0;
    if (is_private()) {
        kind = M0110_CLIP_PRIVATE;
    } else if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE handle = GetClipboardData(CF_UNICODETEXT);
        const wchar_t *text = handle ? (const wchar_t *)GlobalLock(handle) : NULL;
        if (text) {
            int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
            char *utf8 = size > 0 ? (char *)malloc((size_t)size) : NULL;
            if (utf8 && WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, size, NULL, NULL) > 0) {
                uint32_t out = 0;
                for (int i = 0; utf8[i]; i++)
                    if (!(utf8[i] == '\r' && utf8[i + 1] == '\n')) utf8[out++] = utf8[i];
                if (out) {
                    clip->data = (uint8_t *)utf8;
                    clip->length = out;
                    kind = M0110_CLIP_TEXT;
                    utf8 = NULL;
                }
            }
            free(utf8);
            GlobalUnlock(handle);
        }
    }
    if (kind == M0110_CLIP_NOTHING) {
        uint32_t length = 0;
        uint8_t *png = copy_format(format(L"PNG"), &length);
        if (png && length > 8) {
            clip->data = png;
            clip->length = png_length(png, length);
            kind = M0110_CLIP_PNG;
        } else {
            free(png);
            // Windows makes CF_DIB from any bitmap format, so this covers them all.
            dib = copy_format(CF_DIB, &dib_length);
        }
    }
    CloseClipboard();
    // Convert after closing, so the clipboard is not held longer than needed.
    if (dib) {
        if (dib_to_png(dib, dib_length, &clip->data, &clip->length)) kind = M0110_CLIP_PNG;
        free(dib);
    }
    clip->kind = kind;
    return kind;
}

// ---- Writing the clipboard ----

static int put(UINT kind, const void *data, size_t length) {
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, length);
    if (!handle) return 0;
    void *pointer = GlobalLock(handle);
    if (!pointer) {
        GlobalFree(handle);
        return 0;
    }
    memcpy(pointer, data, length);
    GlobalUnlock(handle);
    // On success the clipboard owns the memory.
    if (!SetClipboardData(kind, handle)) {
        GlobalFree(handle);
        return 0;
    }
    return 1;
}

int32_t m0110_clip_write_text(void *owner, const uint8_t *utf8, uint32_t length) {
    // Windows programs expect CRLF line endings on the clipboard.
    size_t crlf = length;
    for (uint32_t i = 0; i < length; i++)
        if (utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) crlf++;
    char *text = (char *)malloc(crlf + 1);
    if (!text) return 0;
    size_t at = 0;
    for (uint32_t i = 0; i < length; i++) {
        if (utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) text[at++] = '\r';
        text[at++] = (char)utf8[i];
    }
    text[at] = 0;
    int wide = MultiByteToWideChar(CP_UTF8, 0, text, (int)at + 1, NULL, 0);
    wchar_t *unicode = wide > 0 ? (wchar_t *)malloc((size_t)wide * sizeof(wchar_t)) : NULL;
    int ok = 0;
    // Retry the clipboard for about a second, since a paste is waiting on this.
    if (unicode && MultiByteToWideChar(CP_UTF8, 0, text, (int)at + 1, unicode, wide) > 0 &&
        open_clipboard((HWND)owner, 100)) {
        ok = EmptyClipboard() && put(CF_UNICODETEXT, unicode, (size_t)wide * sizeof(wchar_t));
        CloseClipboard();
    }
    free(unicode);
    free(text);
    return ok;
}

int32_t m0110_clip_write_image(void *owner, const uint8_t *data, uint32_t length) {
    int started = com_begin();
    IWICImagingFactory *wic = factory();
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapSource *source = wic ? decode(wic, data, length, &stream, &decoder) : NULL;
    int ok = 0;
    uint8_t *png = NULL, *dib = NULL;
    uint32_t png_size = 0;
    size_t dib_size = 0;
    if (source) {
        IWICBitmapSource *bgra = as_bgra(wic, source, &GUID_WICPixelFormat32bppBGRA);
        UINT w = 0, h = 0;
        if (bgra) IWICBitmapSource_GetSize(bgra, &w, &h);
        if (bgra && w && h) {
            // Most programs paste this bitmap. It is 32-bit and bottom-up.
            dib_size = sizeof(BITMAPINFOHEADER) + (size_t)w * h * 4;
            dib = (uint8_t *)malloc(dib_size);
            if (dib) {
                BITMAPINFOHEADER *info = (BITMAPINFOHEADER *)dib;
                memset(info, 0, sizeof *info);
                info->biSize = sizeof *info;
                info->biWidth = (LONG)w;
                info->biHeight = (LONG)h;
                info->biPlanes = 1;
                info->biBitCount = 32;
                info->biCompression = BI_RGB;
                info->biSizeImage = w * h * 4;
                uint8_t *rows = dib + sizeof *info;
                uint8_t *top_down = (uint8_t *)malloc((size_t)w * h * 4);
                if (top_down && SUCCEEDED(IWICBitmapSource_CopyPixels(bgra, NULL, w * 4, w * h * 4, top_down))) {
                    for (UINT y = 0; y < h; y++) memcpy(rows + (size_t)(h - 1 - y) * w * 4, top_down + (size_t)y * w * 4, (size_t)w * 4);
                    ok = 1;
                }
                free(top_down);
            }
            // The PNG is for programs that would otherwise lose transparency.
            if (ok && !encode(wic, bgra, 0, 0, &png, &png_size)) png = NULL;
        }
        if (bgra) IWICBitmapSource_Release(bgra);
        IWICBitmapSource_Release(source);
    }
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (wic) IWICImagingFactory_Release(wic);
    com_end(started);

    if (ok && open_clipboard((HWND)owner, 100)) {
        ok = EmptyClipboard();
        if (ok) {
            int placed = png ? put(format(L"PNG"), png, png_size) : 0;
            placed = put(CF_DIB, dib, dib_size) || placed;
            ok = placed;
        }
        CloseClipboard();
    } else {
        ok = 0;
    }
    free(png);
    free(dib);
    return ok;
}

void m0110_clip_free(m0110_clip *clip) {
    free(clip->data);
    clip->data = NULL;
    clip->length = 0;
}

// ---- The keyboard on USB ----

// Defined here because devpkey.h only provides storage under initguid.h.
static const DEVPROPKEY bus_reported_description = {
    {0x540b947e, 0x8b40, 0x45bc, {0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2}}, 4};

int32_t m0110_usb_present(uint16_t vendor, uint16_t product, const uint16_t *name) {
    wchar_t pattern[32];
    swprintf(pattern, 32, L"VID_%04X&PID_%04X", vendor, product);
    HDEVINFO set = SetupDiGetClassDevsW(NULL, L"USB", NULL, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return 0;
    int found = 0;
    SP_DEVINFO_DATA info = {sizeof info};
    for (DWORD index = 0; !found && SetupDiEnumDeviceInfo(set, index, &info); index++) {
        wchar_t id[MAX_DEVICE_ID_LEN];
        if (!SetupDiGetDeviceInstanceIdW(set, &info, id, MAX_DEVICE_ID_LEN, NULL)) continue;
        _wcsupr_s(id, MAX_DEVICE_ID_LEN);
        if (!wcsstr(id, pattern)) continue;
        // Every ZMK keyboard shares these default IDs, so match the product name too.
        wchar_t description[256] = {0};
        DEVPROPTYPE type = 0;
        if (SetupDiGetDevicePropertyW(set, &info, &bus_reported_description, &type, (BYTE *)description,
                                      sizeof description - sizeof(wchar_t), NULL, 0) &&
            type == DEVPROP_TYPE_STRING) {
            _wcsupr_s(description, 256);
            wchar_t wanted[64];
            wcsncpy_s(wanted, 64, (const wchar_t *)name, _TRUNCATE);
            _wcsupr_s(wanted, 64);
            if (wcsstr(description, wanted)) found = 1;
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return found;
}

// ---- For --clipboard-probe ----

int32_t m0110_clip_probe_concealed(const uint16_t *text) {
    if (!open_clipboard(NULL, 10)) return 0;
    int ok = EmptyClipboard() && put(CF_UNICODETEXT, text, (wcslen((const wchar_t *)text) + 1) * sizeof(wchar_t));
    char flag = 0;
    ok = ok && put(format(L"exclude"), &flag, 1);
    CloseClipboard();
    return ok;
}

int32_t m0110_clip_probe_bitmap(void) {
    struct {
        BITMAPINFOHEADER header;
        uint8_t pixels[16];
    } dib;
    memset(&dib, 0, sizeof dib);
    dib.header.biSize = sizeof dib.header;
    dib.header.biWidth = 2;
    dib.header.biHeight = 2;
    dib.header.biPlanes = 1;
    dib.header.biBitCount = 32;
    dib.header.biCompression = BI_RGB;
    const uint8_t pixels[16] = {0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255};
    memcpy(dib.pixels, pixels, sizeof pixels);
    if (!open_clipboard(NULL, 10)) return 0;
    int ok = EmptyClipboard() && put(CF_DIB, &dib, sizeof dib);
    CloseClipboard();
    return ok;
}
