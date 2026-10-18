/// Tells the Android host how many close watchers the page has open, so Back
/// can go to the page while it holds one (#294).
///
/// A close watcher is the web's way for a page to take a "close request":
/// `CloseWatcher`, a modal `<dialog>`, an auto popover. In Chrome on Android,
/// Back is a close request and closes the newest one before it walks history.
/// A WebView leaves Back to its app, so without this a page with nothing in
/// its history couldn't keep Back at all, and an app that reopened on a
/// screen with no entry behind it closed instead of going "up".
///
/// The host has to know *before* Back is pressed: predictive back asks whether
/// the app wants the gesture as it starts, and a callback enabled the whole
/// time would cost an app at its root the system's back-to-home animation. So
/// the page reports its count as it changes, and the host enables its Back
/// callback while the count, or the history, is non-zero. Back is then
/// delivered to the page as Escape, which is a close request in Chromium,
/// so the watcher closes the way it would on desktop: `cancel`, then `close`.
///
/// Staged next to bridge.js and injected the same way, top frame only.
enum AndroidBackWatchers {
    static let assetPath = "swift_pwa/back-watchers.js"

    static let script = #"""
    (() => {
      if (window.top !== window || !window.__SwiftPWA__back) return;
      const open = new Set();
      let reported = -1;
      const report = () => {
        if (open.size === reported) return;
        reported = open.size;
        window.__SwiftPWA__back.postMessage(String(open.size));
      };
      if (window.CloseWatcher) {
        const Native = window.CloseWatcher;
        window.CloseWatcher = class CloseWatcher extends Native {
          constructor(options) {
            super(options);
            open.add(this);
            this.addEventListener('close', () => { open.delete(this); report(); });
            report();
          }
          destroy() {
            super.destroy();
            open.delete(this);
            report();
          }
        };
      }
      // A modal dialog and an auto popover are close watchers too. `toggle`
      // doesn't bubble, so it's caught on the way down.
      addEventListener('toggle', (event) => {
        const element = event.target;
        const watches = (element instanceof HTMLDialogElement && element.matches(':modal'))
          || (element instanceof HTMLElement && element.popover === 'auto');
        if (event.newState === 'open' && watches) open.add(element);
        else open.delete(element);
        report();
      }, true);
      // A new document starts with none, whatever the last one left open.
      report();
    })();
    """#
}
