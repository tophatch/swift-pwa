#if os(Windows)
    import Foundation
    import WinSDK

    /// Whether Windows is currently asking *apps* to render dark.
    ///
    /// `AppsUseLightTheme`, not `SystemUsesLightTheme` — the two are
    /// independently settable, and this one is what Chromium (so WebView2)
    /// reports to the page as `prefers-color-scheme`. Following it keeps the
    /// native surface behind the page in the same appearance as the page.
    ///
    /// Read fresh each time rather than cached: the value changes while the
    /// app runs, and a registry read costs nothing next to a repaint. A
    /// missing value means light, which is the Windows default.
    enum WindowsAppearance {
        static var prefersDark: Bool {
            var value: DWORD = 1
            var size = DWORD(MemoryLayout<DWORD>.size)
            let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
                .withCString(encodedAs: UTF16.self) { subkey in
                    "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                        withUnsafeMutablePointer(to: &value) { valuePointer in
                            RegGetValueW(
                                HKEY_CURRENT_USER, subkey, name,
                                DWORD(RRF_RT_REG_DWORD), nil,
                                UnsafeMutableRawPointer(valuePointer), &size
                            )
                        }
                    }
                }
            guard status == ERROR_SUCCESS else { return false }
            return value == 0
        }

        /// Whether a `WM_SETTINGCHANGE` is the one Windows broadcasts when the
        /// user switches between light and dark. The message is also sent for
        /// unrelated settings, so the string has to be checked.
        static func isColorSchemeChange(lParam: LPARAM) -> Bool {
            // `LPARAM` is `Int64`, a distinct type from `Int` even on 64-bit
            // Windows, so the pointer needs the explicit hop.
            guard let raw = UnsafePointer<WCHAR>(bitPattern: UInt(bitPattern: Int(lParam))) else { return false }
            return String(decodingCString: raw, as: UTF16.self) == "ImmersiveColorSet"
        }
    }
#endif
