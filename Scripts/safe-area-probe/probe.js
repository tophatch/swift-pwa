// Logs a document's safe-area insets through the probe app's `probe.log`
// command, on load, on every change, and once it has settled (#282).
//
// The first document replaces itself with the second after a delay that steps
// through the sweep across launches, so one install covers every delay.
// A delay of "none" never navigates: that launch is the control, and a
// document that never navigated has to end up with insets.
const DELAYS = [0, 10];
// How the first document leaves, crossed with every delay:
//   replace — `location.replace` to a trivial second document;
//   push    — `location.href`, a new history entry;
//   heavy   — to a second document whose <head> runs for 150ms before it ends;
//   stall   — the app's main thread is held for 100ms as the navigation starts,
//             the way a busy launch holds the scheme handler that serves it;
//   metas   — to a second document carrying theme-color and the
//             apple-mobile-web-app metas (status bar black-translucent);
//   styles  — to a second document behind five render-blocking stylesheets,
//             which hold its first paint without holding its scripts.
//   tall    — the first document is taller than the screen (a 2000px body)
//             and leaves on a bridge reply, the moment the reporting app's
//             launch resume did: this is what sticks (#282);
//   short   — the same without the tall body, which doesn't.
// `reply` in place of a delay: navigate when an invoke sent from the script
// itself answers, then a zero timeout — 6–15ms into the document's life.
const VARIANTS = ["replace"];
const PLAN = [["none", "none"], ["tall", "reply"], ["tall", "reply"], ["short", "reply"],
    ...VARIANTS.flatMap((v) => DELAYS.map((d) => [v, d]))];
const SETTLE_MS = 2000;

const probe = document.getElementById("probe");
const doc = document.body.dataset.doc;
const params = new URLSearchParams(location.search);
const launch = params.get("launch") || Math.random().toString(36).slice(2, 8);
let delay = params.get("delay");
let variant = params.get("variant");
if (doc === "first") {
    const n = Number(localStorage.getItem("safeAreaLaunch") || 0);
    localStorage.setItem("safeAreaLaunch", String(n + 1));
    [variant, delay] = PLAN[n % PLAN.length].map(String);
}

function insets() {
    const s = getComputedStyle(probe);
    return [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft]
        .map((v) => Math.round(parseFloat(v)))
        .join(",");
}

function log(event) {
    const line = [launch, doc, `${variant}:${delay}`, Math.round(performance.now()), event,
        insets(), `${innerWidth}x${innerHeight}`, `${screen.width}x${screen.height}`].join(" ");
    __SWIFT_PWA__.invoke("probe.log", { line }).catch(() => {});
}

new ResizeObserver(() => log("change")).observe(probe, { box: "border-box" });
addEventListener("resize", () => log("resize"));
document.addEventListener("visibilitychange", () => log(document.visibilityState));

function leave() {
    const page = { heavy: "second-heavy.html", metas: "second-metas.html", styles: "second-styles.html" }[variant] ?? "second.html";
    const url = `${page}?launch=${launch}&variant=${variant}&delay=${delay}`;
    if (variant === "push") location.href = url;
    else location.replace(url);
    if (variant === "stall") __SWIFT_PWA__.invoke("probe.stall", { ms: 100 }).catch(() => {});
}

if (doc === "first" && delay === "reply") {
    if (variant === "tall") {
        const filler = document.createElement("div");
        filler.style.height = "2000px";
        document.body.append(filler);
    }
    __SWIFT_PWA__.invoke("app.name", {}).then(() => setTimeout(leave, 0));
}

addEventListener("load", () => {
    log("load");
    if (doc === "first" && delay === "reply") {
        // Already on its way, from the script above.
    } else if (doc === "first" && delay !== "none") {
        setTimeout(leave, Number(delay));
    } else {
        setTimeout(() => log("final"), SETTLE_MS);
    }
});
