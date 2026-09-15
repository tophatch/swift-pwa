// The seam that makes an app's own `@MainActor` code work off Apple (#216).
//
// There is deliberately no *behavioural* test here, and — learned the hard way
// — no assertion on the handle's value either.
//
// The failure this guards against is a platform loop that owns the main thread
// and drains nothing. That cannot be reproduced in a `swift test` process,
// because there libdispatch owns the main thread itself: the bundle parks it in
// `dispatch_main()` (see `Scripts/ci-test-linux.sh`, which exists because of
// that park). And the `_4CF` handle exists for exactly the *opposite* case — a
// foreign loop that needs to be told when the main queue has work — so
// libdispatch offers none here. Measured nil on a CI runner and on a GTK box
// alike, while the same call in a real app process returns a live eventfd.
//
// An earlier version of this file asserted `handle != nil` and so failed
// everywhere it ran, against a fix that works. The real checks drive a
// scaffolded app through a real loop: `Scripts/verify-main-actor.sh` (Linux),
// `Scripts/verify-windows-main-actor.ps1`, `Scripts/verify-android-main-actor.sh`
// — each in both directions, fix on and fix off.
//
// What this file *can* guard is the linkage. Both symbols are bound by name
// with `@_silgen_name`, so a rename or removal in libdispatch surfaces as a
// failure to load this bundle rather than as every adopting app's main-actor
// code hanging again, silently — which is the shape #216 had for four releases.
#if os(Linux) || os(Windows) || os(Android)
    import SwiftPWACore
    import Testing

    @Suite("Platform main queue")
    struct PlatformMainQueueTests {
        @Test("the main-queue handle accessor is reachable")
        func handleAccessorIsReachable() {
            // Calling it is the test: the value is environment-dependent (see
            // above) and asserting on it is what broke. Reaching the accessor
            // at all means `_dispatch_get_main_queue_handle_4CF` still resolves.
            _ = PlatformMainQueue.handle
        }
    }
#endif
