// A launcher that is the frontmost app, launches a swift-pwa app, and reports
// whether the child ever took the front (#283).
//
// The launcher has to be frontmost itself: AppKit only hands the front to a
// launching child when its parent holds it, so a launcher that isn't frontmost
// passes against the broken build too. That is the case a suite started from an
// editor's terminal is in, and the case #208's own measurement missed.
//
// Usage: launcher <app-binary> <seconds> <background: 0|1>
// Prints one line: `launcher_frontmost=<bool> child_frontmost=<bool>
// child_frontmost_at=<seconds|-> child_window=<bool>` and exits 0, or exits 3
// when the launcher can't become frontmost (a locked screen, no session).
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let seconds = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: launcher <app-binary> <seconds> <background: 0|1>\n".utf8))
    exit(2)
}
let binary = arguments[1]
let background = arguments[3] == "1"

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class Probe: NSObject, NSApplicationDelegate {
    let binary: String
    let seconds: Double
    let background: Bool
    var window: NSWindow?
    var child: Process?
    var childFrontmostAt: Double?
    var childWindow = false
    var started = Date()

    init(binary: String, seconds: Double, background: Bool) {
        self.binary = binary
        self.seconds = seconds
        self.background = background
    }

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "background-focus launcher"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        waitUntilFrontmost(deadline: Date().addingTimeInterval(5))
    }

    /// The control: until the launcher is frontmost, a child that never takes
    /// the front proves nothing.
    func waitUntilFrontmost(deadline: Date) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            launchChild()
            return
        }
        guard Date() < deadline else {
            print("launcher_frontmost=false")
            exit(3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitUntilFrontmost(deadline: deadline) }
    }

    func launchChild() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        var env = ProcessInfo.processInfo.environment
        env["SWIFT_PWA_DRIVE_BACKGROUND"] = background ? "1" : nil
        child.environment = env
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            FileHandle.standardError.write(Data("couldn't launch \(binary): \(error)\n".utf8))
            exit(4)
        }
        self.child = child
        started = Date()
        poll()
    }

    /// `frontmostApplication` is only current while a run loop turns, which is
    /// why this is a timer on the main queue rather than a loop.
    func poll() {
        guard let child else { return }
        let elapsed = Date().timeIntervalSince(started)
        if childFrontmostAt == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
        {
            childFrontmostAt = elapsed
        }
        // The second control: a child that never put a window up can't have
        // taken the front for it either. Off-screen windows count — a parked
        // one is the whole point — so this lists every window, not only the
        // on-screen ones.
        if !childWindow, let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            childWindow = list.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == child.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0
                    && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
            }
        }
        guard elapsed < seconds, child.isRunning else {
            child.terminate()
            let at = childFrontmostAt.map { String(format: "%.2f", $0) } ?? "-"
            print(
                "launcher_frontmost=true child_frontmost=\(childFrontmostAt != nil) child_frontmost_at=\(at) child_window=\(childWindow)"
            )
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.poll() }
    }
}

let probe = Probe(binary: binary, seconds: seconds, background: background)
app.delegate = probe
app.run()
