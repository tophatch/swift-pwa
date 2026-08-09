import Foundation
#if os(Windows)
    import WinSDK
#endif

/// Sets a process environment variable for the duration of `body`, restoring
/// whatever was there before.
///
/// Lives here because getting it wrong is a **Windows-only compile error** that
/// no amount of local testing on macOS or Linux will surface — `setenv` /
/// `unsetenv` simply aren't in scope there, and the mistake only shows up in
/// CI. It has been made twice; once is enough to justify one implementation.
///
/// On Windows it goes through `SetEnvironmentVariableW` rather than the CRT's
/// `_putenv_s`, because `ProcessInfo.processInfo.environment` reads the Win32
/// environment *block* — the CRT keeps its own copy, which the code under test
/// would never see.
///
/// - Important: the environment is process-global, so a suite using this must
///   be `.serialized`.
public func withEnvironmentVariable<T>(
    _ key: String,
    _ value: String?,
    _ body: () throws -> T
) rethrows -> T {
    let previous = ProcessInfo.processInfo.environment[key]
    setEnvironmentVariable(key, value)
    defer { setEnvironmentVariable(key, previous) }
    return try body()
}

/// Set (or, with `nil`, delete) a process environment variable.
public func setEnvironmentVariable(_ key: String, _ value: String?) {
    #if os(Windows)
        key.withCString(encodedAs: UTF16.self) { name in
            if let value {
                value.withCString(encodedAs: UTF16.self) { _ = SetEnvironmentVariableW(name, $0) }
            } else {
                // A null value deletes the variable.
                _ = SetEnvironmentVariableW(name, nil)
            }
        }
    #else
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    #endif
}
