// swiftpwa_geolocation — Windows.Devices.Geolocation via C++/WinRT.
// See include/swiftpwa_geolocation.h for the ABI + rationale.

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

#include "swiftpwa_geolocation.h"

#include <windows.h>
// Same ordering requirement as the biometric shim: `<unknwn.h>` between
// `<windows.h>` and `<winrt/base.h>`, or `guid_of<T>` trips a static_assert
// at template-instantiation time.
#include <unknwn.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.Geolocation.h>

#include <chrono>
#include <string>

namespace WDG = winrt::Windows::Devices::Geolocation;
namespace WF = winrt::Windows::Foundation;

namespace {

bool ensure_apartment() {
    // Multithreaded, because the bridge calls in from a worker rather than a
    // UI thread. RPC_E_CHANGED_MODE isn't a failure here — an apartment
    // already initialized in another mode still works for these calls.
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (winrt::hresult_error const &) {
        return true;
    } catch (...) {
        return false;
    }
    return true;
}

void report_error(
    swiftpwa_wingeo_callback callback,
    void *user_data,
    swiftpwa_wingeo_error_kind kind,
    std::wstring const &message
) {
    if (callback) callback(nullptr, kind, message.c_str(), user_data);
}

/// Map `GeolocationAccessStatus`. `Unspecified` is treated as denied: it's
/// what an unpackaged app sees when the desktop-apps location toggle is off,
/// and reporting it as "unavailable" would send the user hunting for hardware
/// rather than for the switch.
bool access_allowed(swiftpwa_wingeo_callback callback, void *user_data) {
    try {
        auto status = WDG::Geolocator::RequestAccessAsync().get();
        if (status == WDG::GeolocationAccessStatus::Allowed) return true;
        report_error(
            callback, user_data, SWIFTPWA_WINGEO_DENIED,
            L"location is off for this app — Settings > Privacy & security > Location"
        );
        return false;
    } catch (winrt::hresult_error const &e) {
        report_error(
            callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
            std::wstring(L"RequestAccessAsync failed: ") + e.message().c_str()
        );
        return false;
    }
}

swiftpwa_geo_position to_position(WDG::Geoposition const &geoposition) {
    swiftpwa_geo_position out{};
    auto coordinate = geoposition.Coordinate();
    auto point = coordinate.Point().Position();
    out.latitude = point.Latitude;
    out.longitude = point.Longitude;

    // `Accuracy` is a plain double here (metres). WinRT has no notion of an
    // unknown horizontal accuracy, so it always has a value.
    out.accuracy = coordinate.Accuracy();

    // Altitude rides on the position; WinRT reports it as part of
    // BasicGeoposition, and `AltitudeAccuracy` separately as IReference.
    out.altitude = point.Altitude;
    out.has_altitude = 1;
    if (auto altitude_accuracy = coordinate.AltitudeAccuracy()) {
        out.altitude_accuracy = altitude_accuracy.Value();
        out.has_altitude_accuracy = 1;
    }
    if (auto speed = coordinate.Speed()) {
        out.speed = speed.Value();
        out.has_speed = 1;
    }
    if (auto heading = coordinate.Heading()) {
        out.heading = heading.Value();
        out.has_heading = 1;
    }

    // WinRT timestamps are a DateTime (100ns ticks since 1601). Convert to
    // seconds since 1970, which is what the rest of the bridge carries.
    auto ticks = coordinate.Timestamp().time_since_epoch().count();
    constexpr int64_t ticks_per_second = 10000000LL;
    constexpr int64_t epoch_difference = 11644473600LL;  // 1601 → 1970, seconds
    out.timestamp = static_cast<double>(ticks) / ticks_per_second - epoch_difference;
    return out;
}

}  // namespace

struct swiftpwa_wingeo_session {
    WDG::Geolocator locator{nullptr};
    winrt::event_token token{};
};

extern "C" void swiftpwa_wingeo_get_position(
    int32_t high_accuracy,
    uint32_t timeout_ms,
    uint32_t maximum_age_seconds,
    swiftpwa_wingeo_callback callback,
    void *user_data
) {
    if (!ensure_apartment()) {
        report_error(callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
                     L"couldn't initialize a WinRT apartment");
        return;
    }
    if (!access_allowed(callback, user_data)) return;

    try {
        WDG::Geolocator locator;
        locator.DesiredAccuracy(
            high_accuracy ? WDG::PositionAccuracy::High : WDG::PositionAccuracy::Default
        );
        // `GetGeopositionAsync(maximumAge, timeout)` is the overload that
        // bounds the wait itself, so there's no timer to race.
        auto operation = locator.GetGeopositionAsync(
            WF::TimeSpan{std::chrono::seconds(maximum_age_seconds)},
            WF::TimeSpan{std::chrono::milliseconds(timeout_ms)}
        );
        auto geoposition = operation.get();
        auto position = to_position(geoposition);
        if (callback) callback(&position, SWIFTPWA_WINGEO_NONE, nullptr, user_data);
    } catch (winrt::hresult_error const &e) {
        // A timeout surfaces as an hresult rather than a distinct type, so
        // it's classified by code — retrying a timeout is reasonable, where
        // retrying "no source" is not.
        auto kind = (e.code() == HRESULT_FROM_WIN32(ERROR_TIMEOUT))
            ? SWIFTPWA_WINGEO_TIMEOUT
            : SWIFTPWA_WINGEO_UNAVAILABLE;
        report_error(callback, user_data, kind, std::wstring(e.message().c_str()));
    } catch (...) {
        report_error(callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
                     L"GetGeopositionAsync failed");
    }
}

extern "C" swiftpwa_wingeo_session *swiftpwa_wingeo_watch(
    int32_t high_accuracy,
    swiftpwa_wingeo_callback callback,
    void *user_data
) {
    if (!ensure_apartment()) {
        report_error(callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
                     L"couldn't initialize a WinRT apartment");
        return nullptr;
    }
    if (!access_allowed(callback, user_data)) return nullptr;

    try {
        auto *session = new swiftpwa_wingeo_session();
        session->locator = WDG::Geolocator();
        session->locator.DesiredAccuracy(
            high_accuracy ? WDG::PositionAccuracy::High : WDG::PositionAccuracy::Default
        );
        // Without a report interval `PositionChanged` may never fire: the
        // default is driven by the source's own cadence, which for an IP-only
        // machine can be "never again after the first".
        session->locator.ReportInterval(1000);
        session->token = session->locator.PositionChanged(
            [callback, user_data](WDG::Geolocator const &, WDG::PositionChangedEventArgs const &args) {
                auto position = to_position(args.Position());
                if (callback) callback(&position, SWIFTPWA_WINGEO_NONE, nullptr, user_data);
            }
        );
        return session;
    } catch (winrt::hresult_error const &e) {
        report_error(callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
                     std::wstring(e.message().c_str()));
        return nullptr;
    } catch (...) {
        report_error(callback, user_data, SWIFTPWA_WINGEO_UNAVAILABLE,
                     L"couldn't start a Geolocator");
        return nullptr;
    }
}

extern "C" void swiftpwa_wingeo_stop(swiftpwa_wingeo_session *session) {
    if (!session) return;
    try {
        if (session->locator) session->locator.PositionChanged(session->token);
    } catch (...) {
        // Detaching a handler on a torn-down locator throws; nothing to do
        // and nothing to report — the caller has already gone away.
    }
    delete session;
}

#endif
