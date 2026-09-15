// Post a hardware media key to the system, so a probe can measure whether the
// page's `navigator.mediaSession` handler is actually reached.
//
// Why this and not a synthetic DOM event: the question is whether the *OS*
// routes transport controls to an embedded WKWebView at all. A dispatched
// KeyboardEvent proves nothing about that path — it never leaves the page.
//
//   swift Scripts/audio-probe/press-media-key.swift [play|next|previous]

import Cocoa

let names = ["play": 16, "next": 17, "previous": 18] // NX_KEYTYPE_PLAY / _NEXT / _PREVIOUS
let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "play"
guard let keyCode = names[which] else {
    FileHandle.standardError.write(Data("unknown key: \(which)\n".utf8))
    exit(2)
}

func post(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = (keyCode << 16) | ((down ? 0xA : 0xB) << 8)
    guard let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        data1: data1,
        data2: -1
    ) else { return }
    event.cgEvent?.post(tap: .cghidEventTap)
}

post(down: true)
post(down: false)
print("posted \(which)")
