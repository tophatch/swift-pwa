# Changelog

All notable changes to swift-pwa will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Platform-agnostic `SwiftPWACore`: `CommandRegistry`, `Invocation` envelope, `Window` / `WebView` / `AppRuntime` protocols, `Plugin` model, built-in `WindowPlugin`.
- Apple `SwiftPWAWebKit` backend (macOS 15+, iOS 18+) with WKWebView, `pwa://` scheme handler, full UIScene multi-window support.
- Linux `SwiftPWAGTK` backend (GTK3 + WebKitGTK 4.1) via hand-rolled C shims.
- `swift-pwa` CLI: `init`, `dev`, `build` (macOS `.app`, iOS `.ipa`, Linux AppImage). Windows / Android stubs.
- `__SWIFT_PWA__.invoke()` / `subscribe()` JS runtime injected at document start.
- Test support target (`_SwiftPWATestSupport`) with reusable `MockWindow` / `MockWebView`.
