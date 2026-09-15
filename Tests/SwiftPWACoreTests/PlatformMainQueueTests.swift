// The handle that makes an app's own `@MainActor` code work off Apple (#216).
//
// There is deliberately no *behavioural* test here. In a `swift test` process
// the main queue is already drained by the test harness's own main-thread
// runner, so the failure this guards against — a platform loop that owns the
// main thread and drains nothing — cannot be reproduced in-process. The real
// checks drive a scaffolded app through a real loop:
// `Scripts/verify-main-actor.sh` (Linux) and
// `Scripts/verify-windows-main-actor.ps1`.
//
// What this *can* catch is the seam rotting under a toolchain bump: if
// libdispatch stops offering a main-queue handle, every backend's watch goes
// quiet and every adopting app's main-actor code hangs again, silently.
#if os(Linux) || os(Windows) || os(Android)
    import SwiftPWACore
    import Testing

    @Suite("Platform main queue")
    struct PlatformMainQueueTests {
        @Test("libdispatch offers a main-queue handle to watch")
        func handleIsAvailable() {
            #expect(PlatformMainQueue.handle != nil)
        }
    }
#endif
