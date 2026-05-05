#if os(Windows)
    import WinSDK

    // Win32 sentinel HWND values are defined in `winuser.h` as casts of
    // negative integer literals to `HWND`, which Swift's clang importer
    // doesn't translate. Re-declare the ones we use as plain Swift
    // constants. Values must match `winuser.h` exactly.

    // `nonisolated(unsafe)` because Swift 6 strict concurrency flags
    // pointer-typed module-level lets as not-Sendable. The values are
    // immutable address constants; treat them like any other Sendable
    // global by externally asserting safety.

    /// `((HWND)-3)` — special parent for message-only windows.
    nonisolated(unsafe) let HWND_MESSAGE: HWND? = HWND(bitPattern: -3)

    /// `((HWND)0)` — z-order constant for `SetWindowPos`.
    nonisolated(unsafe) let HWND_TOP: HWND? = nil

    /// `IDC_ARROW` is `MAKEINTRESOURCE(32512)` — a `LPCWSTR` carrying
    /// the integer 32512 in its low 16 bits. Swift's WinSDK overlay
    /// hasn't always imported it consistently across releases, so we
    /// construct it ourselves.
    nonisolated(unsafe) let IDC_ARROW_W: UnsafePointer<WCHAR>? = UnsafePointer(bitPattern: 32512)

    /// `((DPI_AWARENESS_CONTEXT)-4)` — Per-Monitor V2 awareness. This
    /// is a sentinel "pseudo-handle" the OS recognizes; the Win10 SDK
    /// expresses it as a cast of a small negative integer. Swift's
    /// WinSDK overlay imports `DPI_AWARENESS_CONTEXT` as
    /// `OpaquePointer?` but doesn't ship the constants, so we construct
    /// the bit pattern by hand.
    nonisolated(unsafe) let DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT? =
        DPI_AWARENESS_CONTEXT(bitPattern: -4)
#endif
