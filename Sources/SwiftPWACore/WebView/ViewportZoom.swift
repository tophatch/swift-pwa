/// Makes a page's viewport tag stop the engine zooming it, where the engine
/// ignores the tag itself.
///
/// A page that sets `<meta name="viewport" content="…, user-scalable=no">` (or
/// `maximum-scale=1`) is asking not to be zoomed, and iOS, macOS and Android
/// leave it unzoomed. WebView2 doesn't: like desktop Chromium it ignores the
/// tag, so a touch or touchpad pinch magnifies the app's whole UI, fixed
/// chrome included, into a state nothing else in the app has (#304).
///
/// This is the page-side half of what the tag means, injected at document
/// start on a backend whose engine needs it. When the tag rules zoom out it
/// adds `touch-action: pan-x pan-y` to the root, which stops a touch pinch, and
/// cancels a Ctrl-`wheel`, which is how Chromium delivers a touchpad pinch. A
/// page without such a tag is left alone and pays nothing.
///
/// Not WebView2's `IsPinchZoomEnabled`, though that's the obvious switch.
/// Measured on WebView2: set after a page loads, it doesn't stop that page
/// zooming; set before, it does, but the page then receives none of the
/// pinch's events, so a page that gives a pinch its own meaning (font size,
/// a canvas zoom) loses the gesture. Here the events still reach the page,
/// which can cancel or handle them as on any other platform.
///
/// The tag is read once, when the document is parsed: a page that rewrites its
/// viewport tag later keeps the decision made for the first one. Top frame only,
/// as the tag of an embedded document doesn't govern the app's zoom.
public enum ViewportZoom {
    public static let script = #"""
    (() => {
      if (window.top !== window) return;
      // CSS Device Adaptation's reading of the tag: `user-scalable` of `no` or a
      // number below 1 forbids zoom, and so does a `maximum-scale` of 1 or less.
      const forbidsZoom = (content) => {
        const fields = {};
        for (const part of content.split(/[,;]/)) {
          const [key, value = ''] = part.split('=').map((s) => s.trim().toLowerCase());
          if (key) fields[key] = value;
        }
        const scalable = fields['user-scalable'];
        if (scalable === 'no') return true;
        if (scalable !== undefined && scalable !== 'yes' && Math.abs(parseFloat(scalable)) < 1) return true;
        return parseFloat(fields['maximum-scale']) <= 1;
      };
      const apply = () => {
        const tag = document.querySelector('meta[name="viewport" i]');
        if (!tag || !forbidsZoom(tag.content || '')) return;
        // A constructed sheet rather than a <style> element or the root's style
        // attribute: neither is the page's to find in its DOM.
        const sheet = new CSSStyleSheet();
        sheet.replaceSync('html { touch-action: pan-x pan-y; }');
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        addEventListener('wheel', (event) => { if (event.ctrlKey) event.preventDefault(); }, { passive: false });
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', apply, { once: true });
      } else {
        apply();
      }
    })();
    """#
}
