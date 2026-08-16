// swiftpwa_bluetooth — Windows Bluetooth LE (`Windows.Devices.Bluetooth`)
// behind a flat C ABI.
//
// Why a C++/WinRT shim and not raw Swift: every step here is asynchronous
// (`IAsyncOperation<BluetoothLEDevice>`, `GetGattServicesAsync`,
// `WriteValueAsync`) and event-based (`BluetoothLEAdvertisementWatcher.Received`,
// `ValueChanged`), over deeply nested WinRT projections. That's the same
// `Completed(...)` plumbing the geolocation and biometric shims do here, and
// Swift bridges each callback back to a continuation / AsyncThrowingStream.
//
// Like those two — and unlike `CPhiSilica` — this is **built-in WinRT**: no
// NuGet package, no Windows App SDK bootstrapper, nothing to provision. It
// rides the `WindowsApp.lib` this target already links.
//
// Access: an unpackaged Win32 app reaches the radio directly, with no
// capability and no prompt. A **packaged** (MSIX) build is gated on the
// `bluetooth` device capability, which `swift-pwa build` emits from
// `permissions.device` in pwa.json.
//
// Events reach Swift as JSON strings rather than structs, matching the Linux
// shim and the Android RPC, so all three decode into the same Swift types
// instead of each inventing its own.

#ifndef SWIFT_PWA_BLUETOOTH_SHIM_H
#define SWIFT_PWA_BLUETOOTH_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Fires on a WinRT callback thread with one JSON object per event. The
// string is only valid for the duration of the call.
typedef void (*swiftpwa_ble_callback)(const char *json, void *user_data);

typedef struct swiftpwa_ble_scan swiftpwa_ble_scan;
typedef struct swiftpwa_ble_link swiftpwa_ble_link;

// 1 when a Bluetooth radio is present and on. `reason_out` is set (caller
// frees with `swiftpwa_ble_free_string`) when it isn't, and never says "this
// platform doesn't do Bluetooth" — every platform this runtime targets does.
int32_t swiftpwa_ble_available(char **reason_out);

// Start watching for advertisements. `service_uuids` is `count` 128-bit UUID
// strings; passing 0 watches everything. Returns NULL on failure with
// `error_out` set.
swiftpwa_ble_scan *swiftpwa_ble_scan_start(
    const char *const *service_uuids, int32_t count,
    swiftpwa_ble_callback callback, void *user_data, char **error_out
);
void swiftpwa_ble_scan_stop(swiftpwa_ble_scan *scan);

// Open a link. `address` is the colon-separated form `ble.scan` reported.
swiftpwa_ble_link *swiftpwa_ble_connect(
    const char *address, swiftpwa_ble_callback callback, void *user_data, char **error_out
);
void swiftpwa_ble_disconnect(swiftpwa_ble_link *link);

int32_t swiftpwa_ble_write(
    swiftpwa_ble_link *link, const char *uuid,
    const uint8_t *bytes, int32_t length, int32_t with_response, char **error_out
);
// Returns a base64 string (caller frees), matching what crosses into Swift
// everywhere else in this contract.
char *swiftpwa_ble_read(swiftpwa_ble_link *link, const char *uuid, char **error_out);
int32_t swiftpwa_ble_set_notify(
    swiftpwa_ble_link *link, const char *uuid, int32_t enabled, char **error_out
);

void swiftpwa_ble_free_string(char *text);

#ifdef __cplusplus
}
#endif

#endif /* SWIFT_PWA_BLUETOOTH_SHIM_H */
