// Logs a document's safe-area insets through the probe app's `probe.log`
// command, on load, on every change, and once it has settled (#282).
//
// The first document replaces itself with the second after a delay that steps
// through the sweep across launches, so one install covers every delay.
// A delay of "none" never navigates: that launch is the control, and a
// document that never navigated has to end up with insets.
const DELAYS = [0, 10, 30, 50];
// How the first document leaves, crossed with every delay:
//   replace — `location.replace` to a trivial second document;
//   push    — `location.href`, a new history entry;
//   heavy   — to a second document whose <head> runs for 150ms before it ends;
//   stall   — the app's main thread is held for 100ms as the navigation starts,
//             the way a busy launch holds the scheme handler that serves it.
const VARIANTS = ["replace", "push", "heavy", "stall"];
const PLAN = [["none", "none"], ...VARIANTS.flatMap((v) => DELAYS.map((d) => [v, d]))];
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

addEventListener("load", () => {
    log("load");
    if (doc === "first" && delay !== "none") {
        setTimeout(() => {
            const page = variant === "heavy" ? "second-heavy.html" : "second.html";
            const url = `${page}?launch=${launch}&variant=${variant}&delay=${delay}`;
            if (variant === "push") location.href = url;
            else location.replace(url);
            if (variant === "stall") __SWIFT_PWA__.invoke("probe.stall", { ms: 100 }).catch(() => {});
        }, Number(delay));
    } else {
        setTimeout(() => log("final"), SETTLE_MS);
    }
});
