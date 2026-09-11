#if os(macOS)
    import AppKit
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing

    /// The point of a pair is that AppKit re-resolves it, so the test asks the
    /// colour what it is under each appearance rather than reading it once.
    @Suite("Apple window background colour")
    @MainActor
    struct BackgroundColorAppleTests {
        private func srgb(_ color: NSColor, in appearance: NSAppearance.Name) -> (r: Int, g: Int, b: Int) {
            var resolved = color
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            return (
                Int((resolved.redComponent * 255).rounded()),
                Int((resolved.greenComponent * 255).rounded()),
                Int((resolved.blueComponent * 255).rounded())
            )
        }

        @Test("a pair resolves to a different colour in each appearance")
        func pairIsDynamic() throws {
            let color = try #require(WindowBackgroundColor.dayNight(light: "#FF0000", dark: "#0000FF").nsColor())
            #expect(srgb(color, in: .aqua) == (255, 0, 0))
            #expect(srgb(color, in: .darkAqua) == (0, 0, 255))
        }

        @Test("one colour is the same in both appearances")
        func singleIsStatic() throws {
            let color = try #require(WindowBackgroundColor.single("#123456").nsColor())
            #expect(srgb(color, in: .aqua) == (0x12, 0x34, 0x56))
            #expect(srgb(color, in: .darkAqua) == (0x12, 0x34, 0x56))
        }

        /// `NSView.layer` takes a `CGColor`, which carries no appearance of
        /// its own — the one part of a light/dark pair AppKit can't re-resolve
        /// for us, and so the one part worth asserting.
        @Test("the webview layer's fill is resolved against the window's appearance")
        func layerFillFollowsTheWindow() throws {
            let color = try #require(WindowBackgroundColor.dayNight(light: "#FF0000", dark: "#0000FF").nsColor())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            view.wantsLayer = true
            window.contentView = view

            func layerBytes() throws -> (Int, Int, Int) {
                let cg = try #require(view.layer?.backgroundColor)
                let ns = try #require(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
                return (
                    Int((ns.redComponent * 255).rounded()),
                    Int((ns.greenComponent * 255).rounded()),
                    Int((ns.blueComponent * 255).rounded())
                )
            }

            window.appearance = NSAppearance(named: .aqua)
            MacWindow.applyLayerBackground(color, to: view, in: window)
            #expect(try layerBytes() == (255, 0, 0))

            window.appearance = NSAppearance(named: .darkAqua)
            MacWindow.applyLayerBackground(color, to: view, in: window)
            #expect(try layerBytes() == (0, 0, 255))
        }

        /// `MacWindow` repaints that layer from an `effectiveAppearance`
        /// observation, which is only as good as the key being KVO-compliant.
        @Test("an appearance change notifies an effectiveAppearance observer")
        func effectiveAppearanceIsObservable() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.appearance = NSAppearance(named: .aqua)
            var seen: [String] = []
            let observation = window.observe(\.effectiveAppearance) { window, _ in
                seen.append(window.effectiveAppearance.name.rawValue)
            }
            defer { observation.invalidate() }

            window.appearance = NSAppearance(named: .darkAqua)
            #expect(seen.last == NSAppearance.Name.darkAqua.rawValue)
            window.appearance = NSAppearance(named: .aqua)
            #expect(seen.last == NSAppearance.Name.aqua.rawValue)
        }

        @Test("unparseable hex in either half yields no colour at all")
        func badHex() {
            #expect(WindowBackgroundColor.single("nope").nsColor() == nil)
            #expect(WindowBackgroundColor.dayNight(light: "#FFF", dark: "nope").nsColor() == nil)
        }
    }
#endif
