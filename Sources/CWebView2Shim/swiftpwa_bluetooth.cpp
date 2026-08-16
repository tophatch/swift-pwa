// swiftpwa_bluetooth — Windows.Devices.Bluetooth via C++/WinRT.
// See include/swiftpwa_bluetooth.h for the ABI + rationale.

#if defined(_WIN32) || defined(_WIN64)

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "swiftpwa_bluetooth.h"

#include <windows.h>
// Same ordering requirement as the other shims here: `<unknwn.h>` between
// `<windows.h>` and `<winrt/base.h>`, or `guid_of<T>` trips a static_assert
// at template-instantiation time.
#include <unknwn.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <mutex>
#include <string>
#include <vector>

namespace WDB = winrt::Windows::Devices::Bluetooth;
namespace WDBA = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace WDBG = winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
namespace WDR = winrt::Windows::Devices::Radios;
namespace WF = winrt::Windows::Foundation;
namespace WSS = winrt::Windows::Storage::Streams;

namespace {

bool ensure_apartment() {
    // Multithreaded: every entry point here can be called from whatever thread
    // Swift's cooperative pool happens to be on, and an STA would tie the
    // callbacks to a message loop nothing here pumps.
    static thread_local bool initialized = false;
    if (initialized) return true;
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (winrt::hresult_error const &) {
        // RPC_E_CHANGED_MODE — someone already initialized this thread as an
        // STA, which is fine: the projections still work.
    }
    initialized = true;
    return true;
}

char *copy_string(std::string const &text) {
    char *out = static_cast<char *>(::malloc(text.size() + 1));
    if (!out) return nullptr;
    ::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

void set_error(char **error_out, std::string const &message) {
    if (error_out) *error_out = copy_string(message);
}

std::string narrow(std::wstring_view text) {
    if (text.empty()) return {};
    int size = ::WideCharToMultiByte(
        CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr
    );
    std::string out(static_cast<size_t>(size), '\0');
    ::WideCharToMultiByte(
        CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr
    );
    return out;
}

/// JSON string escaping. Device names are arbitrary UTF-8 from the peripheral,
/// so quotes and control bytes are entirely possible and would otherwise
/// produce JSON the Swift side silently fails to decode.
std::string escape(std::string const &text) {
    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buffer[8];
                ::sprintf_s(buffer, sizeof(buffer), "\\u%04x", c);
                out += buffer;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string base64(std::vector<uint8_t> const &bytes) {
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < bytes.size(); i += 3) {
        uint32_t triple = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        out += alphabet[(triple >> 18) & 0x3F];
        out += alphabet[(triple >> 12) & 0x3F];
        out += alphabet[(triple >> 6) & 0x3F];
        out += alphabet[triple & 0x3F];
    }
    if (i < bytes.size()) {
        uint32_t triple = bytes[i] << 16;
        bool two = (i + 1) < bytes.size();
        if (two) triple |= bytes[i + 1] << 8;
        out += alphabet[(triple >> 18) & 0x3F];
        out += alphabet[(triple >> 12) & 0x3F];
        out += two ? alphabet[(triple >> 6) & 0x3F] : '=';
        out += '=';
    }
    return out;
}

std::vector<uint8_t> read_buffer(WSS::IBuffer const &buffer) {
    if (!buffer) return {};
    auto reader = WSS::DataReader::FromBuffer(buffer);
    std::vector<uint8_t> bytes(buffer.Length());
    if (!bytes.empty()) reader.ReadBytes(bytes);
    return bytes;
}

/// `AA:BB:CC:DD:EE:FF` <-> the `uint64_t` WinRT addresses peripherals by.
uint64_t parse_address(std::string const &text) {
    uint64_t address = 0;
    for (char c : text) {
        if (c == ':' || c == '-') continue;
        address <<= 4;
        if (c >= '0' && c <= '9') address |= static_cast<uint64_t>(c - '0');
        else if (c >= 'a' && c <= 'f') address |= static_cast<uint64_t>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') address |= static_cast<uint64_t>(c - 'A' + 10);
        else return 0;
    }
    return address;
}

std::string format_address(uint64_t address) {
    char buffer[32];
    ::sprintf_s(
        buffer, sizeof(buffer), "%02X:%02X:%02X:%02X:%02X:%02X",
        static_cast<unsigned>((address >> 40) & 0xFF), static_cast<unsigned>((address >> 32) & 0xFF),
        static_cast<unsigned>((address >> 24) & 0xFF), static_cast<unsigned>((address >> 16) & 0xFF),
        static_cast<unsigned>((address >> 8) & 0xFF), static_cast<unsigned>(address & 0xFF)
    );
    return buffer;
}

std::string uuid_string(winrt::guid const &id) {
    char buffer[64];
    ::sprintf_s(
        buffer, sizeof(buffer),
        "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        id.Data1, id.Data2, id.Data3,
        id.Data4[0], id.Data4[1], id.Data4[2], id.Data4[3],
        id.Data4[4], id.Data4[5], id.Data4[6], id.Data4[7]
    );
    return buffer;
}

double now_seconds() {
    return std::chrono::duration<double>(
        std::chrono::system_clock::now().time_since_epoch()
    ).count();
}

} // namespace

// ---------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------

extern "C" int32_t swiftpwa_ble_available(char **reason_out) {
    ensure_apartment();
    try {
        auto adapter = WDB::BluetoothAdapter::GetDefaultAsync().get();
        if (!adapter) {
            set_error(reason_out, "this machine has no Bluetooth adapter");
            return 0;
        }
        if (!adapter.IsLowEnergySupported()) {
            set_error(reason_out, "this machine's Bluetooth adapter has no Low Energy support");
            return 0;
        }
        // The adapter can exist while the radio is switched off in Settings or
        // by a hardware key, which is a different sentence to show a user.
        auto radio = adapter.GetRadioAsync().get();
        if (radio && radio.State() != WDR::RadioState::On) {
            set_error(reason_out, "Bluetooth is switched off");
            return 0;
        }
        return 1;
    } catch (winrt::hresult_error const &error) {
        set_error(reason_out, "the Bluetooth adapter could not be reached: " + narrow(error.message()));
        return 0;
    } catch (...) {
        set_error(reason_out, "the Bluetooth adapter could not be reached");
        return 0;
    }
}

// ---------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------

struct swiftpwa_ble_scan {
    WDBA::BluetoothLEAdvertisementWatcher watcher{nullptr};
    winrt::event_token token{};
    swiftpwa_ble_callback callback = nullptr;
    void *user_data = nullptr;
    std::vector<std::string> filter_uuids;
};

extern "C" swiftpwa_ble_scan *swiftpwa_ble_scan_start(
    const char *const *service_uuids, int32_t count,
    swiftpwa_ble_callback callback, void *user_data, char **error_out
) {
    ensure_apartment();
    try {
        auto *scan = new swiftpwa_ble_scan();
        scan->callback = callback;
        scan->user_data = user_data;
        for (int32_t i = 0; i < count; i++) {
            std::string uuid = service_uuids[i];
            for (auto &c : uuid) c = static_cast<char>(::tolower(c));
            scan->filter_uuids.push_back(uuid);
        }

        scan->watcher = WDBA::BluetoothLEAdvertisementWatcher();
        // Active scanning, so the scan response — which is where a peripheral
        // usually puts its name — is requested too. A passive watcher sees
        // only the advertisement, and most devices would arrive nameless.
        scan->watcher.ScanningMode(WDBA::BluetoothLEScanningMode::Active);

        scan->token = scan->watcher.Received([scan](
            WDBA::BluetoothLEAdvertisementWatcher const &,
            WDBA::BluetoothLEAdvertisementReceivedEventArgs const &args
        ) {
            if (!scan->callback) return;
            auto advertisement = args.Advertisement();

            std::vector<std::string> services;
            for (auto const &id : advertisement.ServiceUuids()) {
                services.push_back(uuid_string(id));
            }
            if (!scan->filter_uuids.empty()) {
                bool matched = false;
                for (auto const &wanted : scan->filter_uuids) {
                    for (auto const &found : services) {
                        if (found == wanted) matched = true;
                    }
                }
                if (!matched) return;
            }

            std::string json = "{\"advertisement\":{\"id\":";
            json += escape(format_address(args.BluetoothAddress()));
            auto name = narrow(advertisement.LocalName());
            if (!name.empty()) json += ",\"name\":" + escape(name);
            json += ",\"rssi\":" + std::to_string(args.RawSignalStrengthInDBm());
            json += ",\"services\":[";
            for (size_t i = 0; i < services.size(); i++) {
                if (i) json += ",";
                json += escape(services[i]);
            }
            json += "]";
            json += std::string(",\"isConnectable\":") + (args.IsConnectable() ? "true" : "false");

            auto sections = advertisement.ManufacturerData();
            if (sections.Size() > 0) {
                auto section = sections.GetAt(0);
                auto bytes = read_buffer(section.Data());
                // The company id goes back in front of the bytes, so the field
                // matches what the peripheral put on the air — WinRT splits it
                // out, Apple doesn't.
                std::vector<uint8_t> combined;
                combined.push_back(static_cast<uint8_t>(section.CompanyId() & 0xFF));
                combined.push_back(static_cast<uint8_t>((section.CompanyId() >> 8) & 0xFF));
                combined.insert(combined.end(), bytes.begin(), bytes.end());
                json += ",\"manufacturerDataBase64\":" + escape(base64(combined));
            }

            char timestamp[32];
            ::sprintf_s(timestamp, sizeof(timestamp), "%.3f", now_seconds());
            json += ",\"timestamp\":" + std::string(timestamp) + "}}";
            scan->callback(json.c_str(), scan->user_data);
        });

        scan->watcher.Start();
        return scan;
    } catch (winrt::hresult_error const &error) {
        set_error(error_out, "the scan could not start: " + narrow(error.message()));
        return nullptr;
    } catch (...) {
        set_error(error_out, "the scan could not start");
        return nullptr;
    }
}

extern "C" void swiftpwa_ble_scan_stop(swiftpwa_ble_scan *scan) {
    if (!scan) return;
    scan->callback = nullptr;
    try {
        if (scan->watcher) {
            scan->watcher.Received(scan->token);
            scan->watcher.Stop();
        }
    } catch (winrt::hresult_error const &) {
        // The watcher may already have stopped with the radio.
    }
    delete scan;
}

// ---------------------------------------------------------------------
// A link
// ---------------------------------------------------------------------

struct swiftpwa_ble_link {
    WDB::BluetoothLEDevice device{nullptr};
    // Windows drops an LE link the moment nothing needs it, and reconnects on
    // the next GATT call — which shows up as `ready` firing over and over and
    // a peripheral that seems to keep falling off. A `GattSession` with
    // `MaintainConnection` is the documented way to hold it open, and it has
    // no counterpart on the other three platforms.
    WDBG::GattSession session{nullptr};
    winrt::event_token connection_token{};
    swiftpwa_ble_callback callback = nullptr;
    void *user_data = nullptr;
    std::mutex lock;
    std::vector<std::pair<std::string, WDBG::GattCharacteristic>> characteristics;
    std::vector<std::pair<WDBG::GattCharacteristic, winrt::event_token>> subscriptions;
    bool released = false;

    void emit(std::string const &json) {
        if (callback) callback(json.c_str(), user_data);
    }
};

namespace {

/// Walk the peripheral's services, cache every characteristic by UUID, and
/// report them as one `ready`.
///
/// `Uncached` on purpose: Windows keeps a GATT cache per device, and a
/// peripheral whose services changed since it was last seen — a dev board
/// being reflashed, which is exactly what an adopter is doing — otherwise
/// reports the old tree with handles that no longer resolve.
void discover(swiftpwa_ble_link *link) try {
    // Built to the side and swapped in at the end. Clearing first leaves a
    // window where the peripheral has no characteristics at all, and a write
    // that lands in it is answered "this peripheral has no characteristic …" —
    // about one it does have, on a link that is up. Rediscovery happens after
    // every reconnect, so that window is hit in practice, not in theory.
    std::vector<std::pair<std::string, WDBG::GattCharacteristic>> discovered;
    std::string json = "{\"kind\":\"ready\",\"services\":[";
    int service_count = 0;
    auto services = link->device.GetGattServicesAsync(WDB::BluetoothCacheMode::Uncached).get();
    if (services.Status() != WDBG::GattCommunicationStatus::Success) {
        // Say which. An empty `ready` is indistinguishable from a peripheral
        // with nothing on it, and the three failure statuses mean very
        // different things: Unreachable is "it went away", AccessDenied is
        // "something else holds it", ProtocolError carries a GATT code.
        const char *reason = "the service tree could not be read";
        switch (services.Status()) {
        case WDBG::GattCommunicationStatus::Unreachable:
            reason = "the peripheral became unreachable while reading its services";
            break;
        case WDBG::GattCommunicationStatus::AccessDenied:
            reason = "Windows refused access to this peripheral's services — "
                     "another app may hold it, or it needs pairing in Settings";
            break;
        case WDBG::GattCommunicationStatus::ProtocolError:
            reason = "the peripheral reported a GATT protocol error while reading its services";
            break;
        default:
            break;
        }
        link->emit(std::string("{\"kind\":\"failed\",\"message\":") + escape(reason) + "}");
        return;
    }
    {
        for (auto const &service : services.Services()) {
            if (service_count++) json += ",";
            json += "{\"uuid\":" + escape(uuid_string(service.Uuid()));
            json += ",\"isPrimary\":true,\"characteristics\":[";
            int characteristic_count = 0;
            auto found = service.GetCharacteristicsAsync(WDB::BluetoothCacheMode::Uncached).get();
            if (found.Status() == WDBG::GattCommunicationStatus::Success) {
                for (auto const &characteristic : found.Characteristics()) {
                    auto uuid = uuid_string(characteristic.Uuid());
                    discovered.emplace_back(uuid, characteristic);
                    if (characteristic_count++) json += ",";
                    json += "{\"uuid\":" + escape(uuid) + ",\"properties\":[";
                    auto properties = characteristic.CharacteristicProperties();
                    std::vector<std::string> names;
                    using P = WDBG::GattCharacteristicProperties;
                    if ((properties & P::Read) == P::Read) names.push_back("read");
                    if ((properties & P::Write) == P::Write) names.push_back("write");
                    if ((properties & P::WriteWithoutResponse) == P::WriteWithoutResponse) {
                        names.push_back("writeWithoutResponse");
                    }
                    if ((properties & P::Notify) == P::Notify) names.push_back("notify");
                    if ((properties & P::Indicate) == P::Indicate) names.push_back("indicate");
                    for (size_t i = 0; i < names.size(); i++) {
                        if (i) json += ",";
                        json += escape(names[i]);
                    }
                    json += "]}";
                }
            }
            json += "]}";
        }
    }
    json += "]}";
    {
        std::lock_guard<std::mutex> guard(link->lock);
        link->characteristics = std::move(discovered);
    }
    link->emit(json);
} catch (...) {
    link->emit("{\"kind\":\"failed\",\"message\":\"the service tree could not be read\"}");
}

WDBG::GattCharacteristic find(swiftpwa_ble_link *link, std::string uuid) {
    for (auto &c : uuid) c = static_cast<char>(::tolower(c));
    std::lock_guard<std::mutex> guard(link->lock);
    for (auto const &entry : link->characteristics) {
        if (entry.first == uuid) return entry.second;
    }
    return nullptr;
}

} // namespace

extern "C" swiftpwa_ble_link *swiftpwa_ble_connect(
    const char *address, swiftpwa_ble_callback callback, void *user_data, char **error_out
) {
    ensure_apartment();
    try {
        uint64_t value = parse_address(address);
        if (value == 0) {
            set_error(error_out, std::string("'") + address + "' isn't a Bluetooth address");
            return nullptr;
        }
        auto device = WDB::BluetoothLEDevice::FromBluetoothAddressAsync(value).get();
        if (!device) {
            set_error(
                error_out,
                std::string("no peripheral ") + address +
                    " — scan for it first, or it may have gone away"
            );
            return nullptr;
        }

        auto *link = new swiftpwa_ble_link();
        link->device = device;
        link->callback = callback;
        link->user_data = user_data;
        try {
            link->session = WDBG::GattSession::FromDeviceIdAsync(device.BluetoothDeviceId()).get();
            link->session.MaintainConnection(true);
        } catch (winrt::hresult_error const &) {
            // Older Windows builds without GattSession still work; the link
            // just churns more, which the reconnect path already handles.
        }

        link->connection_token = device.ConnectionStatusChanged(
            [link](WDB::BluetoothLEDevice const &sender, WF::IInspectable const &) {
                bool connected = sender.ConnectionStatus() == WDB::BluetoothConnectionStatus::Connected;
                std::string json = "{\"kind\":\"state\",\"connected\":";
                json += connected ? "true" : "false";
                if (!connected) json += ",\"reason\":\"reconnecting\"";
                json += "}";
                link->emit(json);
                // Windows has no explicit connect: a GATT operation is what
                // opens the link, so re-reading the services is how a dropped
                // one is asked to come back — and the handles are new anyway.
                if (connected && !link->released) discover(link);
            }
        );

        // …which is also why the first `discover` is the connection: there is
        // no `Connect()` on `BluetoothLEDevice`. Reading the service tree is
        // what makes Windows open the link.
        link->emit("{\"kind\":\"state\",\"connected\":true}");
        discover(link);
        return link;
    } catch (winrt::hresult_error const &error) {
        set_error(error_out, "the peripheral could not be reached: " + narrow(error.message()));
        return nullptr;
    } catch (...) {
        set_error(error_out, "the peripheral could not be reached");
        return nullptr;
    }
}

extern "C" void swiftpwa_ble_disconnect(swiftpwa_ble_link *link) {
    if (!link) return;
    link->released = true;
    link->callback = nullptr;
    try {
        {
            std::lock_guard<std::mutex> guard(link->lock);
            for (auto &entry : link->subscriptions) {
                entry.first.ValueChanged(entry.second);
            }
            link->subscriptions.clear();
            link->characteristics.clear();
        }
        if (link->session) {
            link->session.MaintainConnection(false);
            link->session.Close();
            link->session = nullptr;
        }
        if (link->device) {
            link->device.ConnectionStatusChanged(link->connection_token);
            // Releasing the device object is the only way to drop the link:
            // Windows keeps it open for as long as anything holds a reference,
            // and a leaked one locks out every other central.
            link->device.Close();
            link->device = nullptr;
        }
    } catch (winrt::hresult_error const &) {
        // Already gone.
    }
    delete link;
}

extern "C" int32_t swiftpwa_ble_write(
    swiftpwa_ble_link *link, const char *uuid,
    const uint8_t *bytes, int32_t length, int32_t with_response, char **error_out
) {
    if (!link) { set_error(error_out, "the link is closed"); return 0; }
    try {
        auto characteristic = find(link, uuid);
        if (!characteristic) {
            set_error(error_out, std::string("this peripheral has no characteristic ") + uuid);
            return 0;
        }
        WSS::DataWriter writer;
        writer.WriteBytes(winrt::array_view<uint8_t const>(bytes, bytes + length));
        auto status = characteristic.WriteValueAsync(
            writer.DetachBuffer(),
            with_response ? WDBG::GattWriteOption::WriteWithResponse
                          : WDBG::GattWriteOption::WriteWithoutResponse
        ).get();
        if (status != WDBG::GattCommunicationStatus::Success) {
            set_error(error_out, "the peripheral refused the write");
            return 0;
        }
        return 1;
    } catch (winrt::hresult_error const &error) {
        set_error(error_out, narrow(error.message()));
        return 0;
    } catch (...) {
        set_error(error_out, "the operation failed");
        return 0;
    }
}

extern "C" char *swiftpwa_ble_read(swiftpwa_ble_link *link, const char *uuid, char **error_out) {
    if (!link) { set_error(error_out, "the link is closed"); return nullptr; }
    try {
        auto characteristic = find(link, uuid);
        if (!characteristic) {
            set_error(error_out, std::string("this peripheral has no characteristic ") + uuid);
            return nullptr;
        }
        auto result = characteristic.ReadValueAsync(WDB::BluetoothCacheMode::Uncached).get();
        if (result.Status() != WDBG::GattCommunicationStatus::Success) {
            set_error(error_out, "the peripheral refused the read");
            return nullptr;
        }
        return copy_string(base64(read_buffer(result.Value())));
    } catch (winrt::hresult_error const &error) {
        set_error(error_out, narrow(error.message()));
        return nullptr;
    } catch (...) {
        set_error(error_out, "the read failed");
        return nullptr;
    }
}

extern "C" int32_t swiftpwa_ble_set_notify(
    swiftpwa_ble_link *link, const char *uuid, int32_t enabled, char **error_out
) {
    if (!link) { set_error(error_out, "the link is closed"); return 0; }
    try {
        auto characteristic = find(link, uuid);
        if (!characteristic) {
            set_error(error_out, std::string("this peripheral has no characteristic ") + uuid);
            return 0;
        }
        if (enabled) {
            {
                std::lock_guard<std::mutex> guard(link->lock);
                for (auto it = link->subscriptions.begin(); it != link->subscriptions.end();) {
                    if (it->first.Uuid() == characteristic.Uuid()) {
                        it->first.ValueChanged(it->second);
                        it = link->subscriptions.erase(it);
                    } else {
                        ++it;
                    }
                }
            }
            auto token = characteristic.ValueChanged([link](
                WDBG::GattCharacteristic const &sender,
                WDBG::GattValueChangedEventArgs const &args
            ) {
                std::string json = "{\"kind\":\"notify\",\"characteristic\":";
                json += escape(uuid_string(sender.Uuid()));
                json += ",\"value\":" + escape(base64(read_buffer(args.CharacteristicValue())));
                json += "}";
                link->emit(json);
            });
            std::lock_guard<std::mutex> guard(link->lock);
            link->subscriptions.emplace_back(characteristic, token);
        } else {
            std::lock_guard<std::mutex> guard(link->lock);
            for (auto it = link->subscriptions.begin(); it != link->subscriptions.end();) {
                if (it->first.Uuid() == characteristic.Uuid()) {
                    it->first.ValueChanged(it->second);
                    it = link->subscriptions.erase(it);
                } else {
                    ++it;
                }
            }
        }
        // The descriptor write is what actually reaches the peripheral;
        // registering `ValueChanged` alone only asks Windows to stop
        // discarding the packets, so on its own it looks like a peripheral
        // that never notifies. Indicate is preferred where offered — it's
        // acknowledged, so a notification can't be silently dropped.
        auto properties = characteristic.CharacteristicProperties();
        using P = WDBG::GattCharacteristicProperties;
        auto value = !enabled
            ? WDBG::GattClientCharacteristicConfigurationDescriptorValue::None
            : ((properties & P::Indicate) == P::Indicate
                   ? WDBG::GattClientCharacteristicConfigurationDescriptorValue::Indicate
                   : WDBG::GattClientCharacteristicConfigurationDescriptorValue::Notify);
        auto status =
            characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(value).get();
        if (status != WDBG::GattCommunicationStatus::Success) {
            set_error(error_out, "the peripheral refused the notification request");
            return 0;
        }
        return 1;
    } catch (winrt::hresult_error const &error) {
        set_error(error_out, narrow(error.message()));
        return 0;
    } catch (...) {
        set_error(error_out, "the operation failed");
        return 0;
    }
}

extern "C" void swiftpwa_ble_free_string(char *text) {
    if (text) ::free(text);
}

#endif /* _WIN32 */
