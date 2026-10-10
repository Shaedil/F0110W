// The paired keyboard through the Win32 BLE GATT API. Windows owns the link.
// Each GATT service is a child devnode of BTHLE\DEV_<address> whose interface
// class GUID is the service UUID. Opening that interface gives the GATT handle.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <bluetoothleapis.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "CM0110Win.h"

#ifndef DN_DEVICE_DISCONNECTED
#define DN_DEVICE_DISCONNECTED 0x02000000
#endif

// Defined here because devpkey.h only provides storage under initguid.h.
static const DEVPROPKEY friendly_name_key = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};
/// The "Connected" flag in Bluetooth settings. Not in the SDK headers, but stable since Windows 8.
static const DEVPROPKEY connected_key = {
    {0x83da6326, 0x97a6, 0x4088, {0x94, 0x53, 0xa1, 0x92, 0x3f, 0x57, 0x3b, 0x29}}, 15};

static GUID guid_from_bytes(const uint8_t b[16]) {
    GUID guid;
    guid.Data1 = ((unsigned long)b[0] << 24) | ((unsigned long)b[1] << 16) | ((unsigned long)b[2] << 8) | b[3];
    guid.Data2 = (unsigned short)((b[4] << 8) | b[5]);
    guid.Data3 = (unsigned short)((b[6] << 8) | b[7]);
    memcpy(guid.Data4, b + 8, 8);
    return guid;
}

static int same_guid(const GUID *a, const GUID *b) { return memcmp(a, b, sizeof *a) == 0; }

static int uuid_is(const BTH_LE_UUID *uuid, const GUID *wanted) {
    if (!uuid->IsShortUuid) return same_guid(&uuid->Value.LongUuid, wanted);
    // A 16-bit UUID expands into the Bluetooth base UUID.
    GUID full = {0x00000000, 0x0000, 0x1000, {0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb}};
    full.Data1 = uuid->Value.ShortUuid;
    return same_guid(&full, wanted);
}

// ---- The device ----

int32_t m0110_ble_connected(const uint16_t *instance, int32_t *source) {
    DEVINST device;
    if (CM_Locate_DevNodeW(&device, (DEVINSTID_W)instance, CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS) {
        // A phantom devnode means paired but out of range.
        if (CM_Locate_DevNodeW(&device, (DEVINSTID_W)instance, CM_LOCATE_DEVNODE_PHANTOM) == CR_SUCCESS) {
            if (source) *source = 2;
            return 0;
        }
        return -1;
    }

    DEVPROPTYPE type = 0;
    BYTE value[8] = {0};
    ULONG size = sizeof value;
    if (CM_Get_DevNode_PropertyW(device, &connected_key, &type, value, &size, 0) == CR_SUCCESS &&
        type == DEVPROP_TYPE_BOOLEAN) {
        if (source) *source = 1;
        return value[0] != 0;
    }

    ULONG status = 0, problem = 0;
    if (CM_Get_DevNode_Status(&status, &problem, device, 0) != CR_SUCCESS) return -1;
    if (source) *source = 2;
    return (status & DN_DEVICE_DISCONNECTED) ? 0 : 1;
}

static int device_name(HDEVINFO set, SP_DEVINFO_DATA *info, wchar_t *name, DWORD bytes) {
    DEVPROPTYPE type = 0;
    if (SetupDiGetDevicePropertyW(set, info, &friendly_name_key, &type, (BYTE *)name, bytes, NULL, 0) &&
        type == DEVPROP_TYPE_STRING)
        return 1;
    return SetupDiGetDeviceRegistryPropertyW(set, info, SPDRP_FRIENDLYNAME, NULL, (BYTE *)name, bytes, NULL);
}

int32_t m0110_ble_find(const uint16_t *name, uint16_t *instance, uint32_t capacity) {
    // No DIGCF_PRESENT, because some Windows builds show an away keyboard as absent.
    HDEVINFO set = SetupDiGetClassDevsW(NULL, L"BTHLE", NULL, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) return 0;

    int best = 0;
    SP_DEVINFO_DATA info = {sizeof info};
    for (DWORD index = 0; SetupDiEnumDeviceInfo(set, index, &info); index++) {
        wchar_t id[MAX_DEVICE_ID_LEN];
        if (!SetupDiGetDeviceInstanceIdW(set, &info, id, MAX_DEVICE_ID_LEN, NULL)) continue;
        if (_wcsnicmp(id, L"BTHLE\\DEV_", 10) != 0) continue;

        wchar_t found[256];
        if (!device_name(set, &info, found, sizeof found - sizeof found[0])) continue;
        found[255] = 0;
        if (wcscmp(found, (const wchar_t *)name) != 0) continue;

        // Prefer connected, then present, then only remembered.
        int connected = m0110_ble_connected((const uint16_t *)id, NULL);
        int rank = connected == 1 ? 3 : connected == 0 ? 2 : 1;
        if (rank > best && wcslen(id) < capacity) {
            best = rank;
            wcscpy_s((wchar_t *)instance, capacity, id);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return best > 0;
}

// ---- Its services ----

struct m0110_gatt {
    HANDLE service;
    BTH_LE_GATT_CHARACTERISTIC characteristic;
    BLUETOOTH_GATT_EVENT_HANDLE event;
    m0110_gatt_notify notify;
    void *context;
};

static void device_address(const wchar_t *instance, wchar_t address[13]) {
    address[0] = 0;
    const wchar_t *start = instance + 10;
    if (wcslen(instance) < 22) return;
    wmemcpy(address, start, 12);
    address[12] = 0;
    _wcsupr_s(address, 13);
}

/// True if `instance` is the parent, or else if the service ID has the same address.
static int belongs_to(DEVINST service, const wchar_t *instance, const wchar_t *address) {
    wchar_t id[MAX_DEVICE_ID_LEN];
    DEVINST parent;
    if (CM_Get_Parent(&parent, service, 0) == CR_SUCCESS &&
        CM_Get_Device_IDW(parent, id, MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS && _wcsicmp(id, instance) == 0)
        return 1;
    if (!address[0] || CM_Get_Device_IDW(service, id, MAX_DEVICE_ID_LEN, 0) != CR_SUCCESS) return 0;
    _wcsupr_s(id, MAX_DEVICE_ID_LEN);
    return wcsstr(id, address) != NULL;
}

static HANDLE open_service(const wchar_t *instance, const GUID *service, int32_t *error) {
    *error = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    HDEVINFO set = SetupDiGetClassDevsW(service, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) {
        *error = HRESULT_FROM_WIN32(GetLastError());
        return INVALID_HANDLE_VALUE;
    }

    wchar_t address[13];
    device_address(instance, address);
    HANDLE handle = INVALID_HANDLE_VALUE;
    SP_DEVICE_INTERFACE_DATA interface_data = {sizeof interface_data};
    for (DWORD index = 0; handle == INVALID_HANDLE_VALUE &&
                          SetupDiEnumDeviceInterfaces(set, NULL, service, index, &interface_data);
         index++) {
        DWORD size = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &interface_data, NULL, 0, &size, NULL);
        if (size == 0) continue;
        SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = (SP_DEVICE_INTERFACE_DETAIL_DATA_W *)malloc(size);
        if (!detail) break;
        detail->cbSize = sizeof *detail;
        SP_DEVINFO_DATA info = {sizeof info};
        if (SetupDiGetDeviceInterfaceDetailW(set, &interface_data, detail, size, NULL, &info) &&
            belongs_to(info.DevInst, instance, address)) {
            // Subscribing needs write access. Read-only still allows reads.
            handle = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            if (handle == INVALID_HANDLE_VALUE)
                handle = CreateFileW(detail->DevicePath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                     OPEN_EXISTING, 0, NULL);
            if (handle == INVALID_HANDLE_VALUE) *error = HRESULT_FROM_WIN32(GetLastError());
        }
        free(detail);
    }
    SetupDiDestroyDeviceInfoList(set);
    return handle;
}

m0110_gatt *m0110_gatt_open(const uint16_t *instance, const uint8_t service_uuid[16],
                            const uint8_t characteristic_uuid[16], int32_t *error) {
    GUID service = guid_from_bytes(service_uuid);
    GUID wanted = guid_from_bytes(characteristic_uuid);
    HANDLE handle = open_service((const wchar_t *)instance, &service, error);
    if (handle == INVALID_HANDLE_VALUE) return NULL;

    USHORT count = 0;
    HRESULT result = BluetoothGATTGetCharacteristics(handle, NULL, 0, NULL, &count, BLUETOOTH_GATT_FLAG_NONE);
    if (result != HRESULT_FROM_WIN32(ERROR_MORE_DATA) || count == 0) {
        *error = FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_MORE_DATA) ? result
                                                                                : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
        CloseHandle(handle);
        return NULL;
    }

    BTH_LE_GATT_CHARACTERISTIC *list = (BTH_LE_GATT_CHARACTERISTIC *)calloc(count, sizeof *list);
    m0110_gatt *gatt = NULL;
    *error = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    if (list) {
        result = BluetoothGATTGetCharacteristics(handle, NULL, count, list, &count, BLUETOOTH_GATT_FLAG_NONE);
        if (FAILED(result)) *error = result;
        for (USHORT i = 0; SUCCEEDED(result) && i < count; i++) {
            if (!uuid_is(&list[i].CharacteristicUuid, &wanted)) continue;
            gatt = (m0110_gatt *)calloc(1, sizeof *gatt);
            if (gatt) {
                gatt->service = handle;
                gatt->characteristic = list[i];
                *error = 0;
            }
            break;
        }
        free(list);
    }
    if (!gatt) CloseHandle(handle);
    return gatt;
}

int32_t m0110_gatt_read(m0110_gatt *gatt, uint8_t *out, uint32_t capacity) {
    USHORT size = 0;
    HRESULT result = BluetoothGATTGetCharacteristicValue(gatt->service, &gatt->characteristic, 0, NULL, &size,
                                                         BLUETOOTH_GATT_FLAG_FORCE_READ_FROM_DEVICE);
    if (result != HRESULT_FROM_WIN32(ERROR_MORE_DATA) || size == 0) return FAILED(result) ? result : E_FAIL;

    BTH_LE_GATT_CHARACTERISTIC_VALUE *value = (BTH_LE_GATT_CHARACTERISTIC_VALUE *)calloc(1, size);
    if (!value) return E_OUTOFMEMORY;
    result = BluetoothGATTGetCharacteristicValue(gatt->service, &gatt->characteristic, size, value, NULL,
                                                 BLUETOOTH_GATT_FLAG_FORCE_READ_FROM_DEVICE);
    if (FAILED(result)) {
        free(value);
        return result;
    }
    uint32_t length = value->DataSize < capacity ? value->DataSize : capacity;
    memcpy(out, value->Data, length);
    free(value);
    return (int32_t)length;
}

static VOID CALLBACK value_changed(BTH_LE_GATT_EVENT_TYPE type, PVOID parameter, PVOID context) {
    m0110_gatt *gatt = (m0110_gatt *)context;
    BLUETOOTH_GATT_VALUE_CHANGED_EVENT *event = (BLUETOOTH_GATT_VALUE_CHANGED_EVENT *)parameter;
    if (type != CharacteristicValueChangedEvent || !event || !event->CharacteristicValue || !gatt->notify) return;
    gatt->notify(gatt->context, event->CharacteristicValue->Data, event->CharacteristicValue->DataSize);
}

/// Some Windows builds leave the CCCD write to the caller. Failure is fine.
static void enable_updates(m0110_gatt *gatt) {
    USHORT count = 0;
    HRESULT result =
        BluetoothGATTGetDescriptors(gatt->service, &gatt->characteristic, 0, NULL, &count, BLUETOOTH_GATT_FLAG_NONE);
    if (result != HRESULT_FROM_WIN32(ERROR_MORE_DATA) || count == 0) return;
    BTH_LE_GATT_DESCRIPTOR *list = (BTH_LE_GATT_DESCRIPTOR *)calloc(count, sizeof *list);
    if (!list) return;
    result = BluetoothGATTGetDescriptors(gatt->service, &gatt->characteristic, count, list, &count,
                                         BLUETOOTH_GATT_FLAG_NONE);
    for (USHORT i = 0; SUCCEEDED(result) && i < count; i++) {
        if (list[i].DescriptorType != ClientCharacteristicConfiguration) continue;
        BTH_LE_GATT_DESCRIPTOR_VALUE value;
        memset(&value, 0, sizeof value);
        value.DescriptorType = ClientCharacteristicConfiguration;
        if (gatt->characteristic.IsNotifiable)
            value.ClientCharacteristicConfiguration.IsSubscribeToNotification = TRUE;
        else
            value.ClientCharacteristicConfiguration.IsSubscribeToIndication = TRUE;
        BluetoothGATTSetDescriptorValue(gatt->service, &list[i], &value, BLUETOOTH_GATT_FLAG_NONE);
    }
    free(list);
}

int32_t m0110_gatt_subscribe(m0110_gatt *gatt, m0110_gatt_notify notify, void *context) {
    if (!gatt->characteristic.IsNotifiable && !gatt->characteristic.IsIndicatable)
        return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    gatt->notify = notify;
    gatt->context = context;
    enable_updates(gatt);

    BLUETOOTH_GATT_VALUE_CHANGED_EVENT_REGISTRATION registration;
    memset(&registration, 0, sizeof registration);
    registration.NumCharacteristics = 1;
    registration.Characteristics[0] = gatt->characteristic;
    return BluetoothGATTRegisterEvent(gatt->service, CharacteristicValueChangedEvent, &registration, value_changed,
                                      gatt, &gatt->event, BLUETOOTH_GATT_FLAG_NONE);
}

int32_t m0110_gatt_write(m0110_gatt *gatt, const uint8_t *data, uint32_t length) {
    BTH_LE_GATT_CHARACTERISTIC_VALUE *value =
        (BTH_LE_GATT_CHARACTERISTIC_VALUE *)calloc(1, sizeof *value + length);
    if (!value) return E_OUTOFMEMORY;
    value->DataSize = length;
    memcpy(value->Data, data, length);
    ULONG flags = gatt->characteristic.IsWritableWithoutResponse ? BLUETOOTH_GATT_FLAG_WRITE_WITHOUT_RESPONSE
                                                                 : BLUETOOTH_GATT_FLAG_NONE;
    HRESULT result = BluetoothGATTSetCharacteristicValue(gatt->service, &gatt->characteristic, value, 0, flags);
    free(value);
    return (int32_t)result;
}

void m0110_gatt_close(m0110_gatt *gatt) {
    if (!gatt) return;
    if (gatt->event) BluetoothGATTUnregisterEvent(gatt->event, BLUETOOTH_GATT_FLAG_NONE);
    CloseHandle(gatt->service);
    free(gatt);
}
