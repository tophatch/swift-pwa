#!/usr/bin/env bash
#
# Drive a real iOS device through a real OAuth 2.0 authorization-code flow.
#
# Why this is its own script rather than a flag on verify-oauth.sh: iOS is the
# only platform that uses `ASWebAuthenticationSession`, and it differs from the
# other four in every mechanical detail. The session presents the browser
# *itself*, catches the custom-scheme callback *itself* (the URL never touches
# the `app.openURL` channel), and reports a dismissal — none of which any other
# backend does. Until this existed the Apple path was compile-verified only,
# which in this repo has twice meant "never worked".
#
# Three constraints shape it:
#
#   1. **One `drive eval` per scenario.** `drive --target ios` owns the app's
#      lifecycle — each verb launches a fresh instance — so a multi-step probe
#      that sets state in one call and reads it in the next would read a new
#      process. Each check below is therefore a single self-contained
#      expression that runs a whole flow and returns its outcome.
#
#   2. **The provider has to be reachable over the LAN.** There is no
#      `adb reverse` for iOS, so the provider binds this host's LAN address and
#      the device dials it. The session's browser makes that request, not the
#      app, so the app's ATS doesn't apply to it.
#
#   3. **The far side has to really redirect.** On the other four platforms the
#      script delivers the redirect directly (curl to the loopback port, an
#      ACTION_VIEW intent). Here it must arrive through the session's own
#      navigation, so the provider answers `/authorize?auto_redirect=1` with a
#      302 — and the probe app registers the session as `ephemeral`, which is
#      what skips the "Do you want to allow…" prompt. That prompt, and
#      cancelling it, are the two cases in docs/manual-test-cases.md: no API
#      observes a system sheet, and `drive shot` captures the webview's
#      renderer, not the screen.
#
# Usage:
#   Scripts/verify-oauth-ios.sh [--app-dir <dir>] [--keep] [--team <id>] [--device <name>]
#
#   --team <id>  Apple Developer Team ID to sign with, or $SWIFT_PWA_IOS_TEAM.
#                A free personal team works; its profiles expire after 7 days,
#                so a run that fails at install usually just needs re-signing.
#   --device <n> Device name or UDID, or $SWIFT_PWA_IOS_DEVICE. Name it whenever
#                more than one device is *paired* — pairing is not cabling, and
#                the default picks the sole connected one, which on a Mac that
#                has ever paired a phone over Wi-Fi may be the wrong one. The
#                symptom is provisioning failing with "the target device wasn't
#                reachable to register".
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
# No baked-in id: a team id is an account identifier, not repo content.
TEAM="${SWIFT_PWA_IOS_TEAM:-}"
DEVICE="${SWIFT_PWA_IOS_DEVICE:-}"
SCHEME="swiftpwaoauthprobe"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }

# --- Is there a cabled device? ----------------------------------------------
# A charge-only USB-C cable presents as no cable at all, and a Wi-Fi-paired
# device installs and launches perfectly well but cannot be driven — the control
# socket is on the *device's* loopback and only usbmuxd's USB transport reaches
# it. Check before building anything.
# `grep -c`, not `grep -q`: under `set -o pipefail` a `-q` that matches closes
# the pipe, `ioreg` takes SIGPIPE, and the *pipeline* reports failure — so the
# check reads "no device" precisely when a device is present.
CABLED="$(ioreg -c IOUSBHostDevice -r -l 2>/dev/null | grep -ciE '"USB Product Name" = "(iPad|iPhone)"' || true)"
if [[ "${CABLED:-0}" -eq 0 ]]; then
    echo "::error::no cabled iPhone/iPad (a charge-only cable looks the same as none)"
    exit 1
fi

# --- The stand-in provider, on a LAN address the device can reach ------------
HOST_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
[[ -n "$HOST_IP" ]] || { echo "::error::couldn't find this host's LAN address"; exit 1; }

PROVIDER_LOG="$(mktemp)"
python3 "$REPO/Scripts/oauth-probe/provider.py" 0 0.0.0.0 >"$PROVIDER_LOG" 2>&1 &
PROVIDER_PID=$!
disown "$PROVIDER_PID" 2>/dev/null || true
# Reap from here, not from the fuller teardown below: an orphan that inherited
# this script's stdout holds the pipe open, so piping into `tail` never returns.
trap 'kill "$PROVIDER_PID" 2>/dev/null; rm -f "$PROVIDER_LOG"' EXIT

PROVIDER_PORT=""
for _ in $(seq 1 60); do
    PROVIDER_PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$PROVIDER_LOG" 2>/dev/null | head -1)"
    [[ -n "$PROVIDER_PORT" ]] && break
    sleep 0.2
done
[[ -n "$PROVIDER_PORT" ]] || { echo "::error::the stand-in provider never started"; cat "$PROVIDER_LOG"; exit 1; }
PROVIDER="http://$HOST_IP:$PROVIDER_PORT"
echo "→ stand-in provider on $PROVIDER (the device dials this over the LAN)"

# --- Probe app --------------------------------------------------------------
CLEANUP_APP=0
if [[ -z "$APP_DIR" ]]; then
    APP_DIR="$(mktemp -d)/OAuthProbe"
    [[ "$KEEP" == 0 ]] && CLEANUP_APP=1
fi
CLI="$REPO/.build/debug/swift-pwa"

echo "→ building the CLI"
(cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
    echo "::error::couldn't build swift-pwa"; exit 1; }

if [[ ! -d "$APP_DIR" ]]; then
    echo "→ scaffolding a probe app in $APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    (cd "$(dirname "$APP_DIR")" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || {
        echo "::error::swift-pwa init failed"; exit 1; }
fi

python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
source = open(path).read()
patched = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', source)
if patched != source:
    open(path, "w").write(patched)
    print("    repointed Package.swift at the working tree")
PY

cp "$REPO/Scripts/oauth-probe/index.html" "$APP_DIR/web/index.html"

# The scheme has to be in `url_schemes` even though the session catches the
# callback rather than the OS routing it: `callbackURLScheme` is matched against
# what the app declares, and an undeclared one simply never returns.
python3 - "$APP_DIR/pwa.json" "$SCHEME" <<'PY'
import json, sys
path, scheme = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
manifest.setdefault("url_schemes", [])
if scheme not in manifest["url_schemes"]:
    manifest["url_schemes"].append(scheme)
json.dump(manifest, open(path, "w"), indent=2)
print("    declared url_schemes")
PY

# `ephemeral: true` is what makes this runnable without a human: a shared-cookie
# session asks "Do you want to allow…" first, and nothing can tap that. The
# non-ephemeral prompt is a manual case by design.
python3 - "$APP_DIR/Sources/$(basename "$APP_DIR")/App.swift" <<'PY'
import re, sys
path = sys.argv[1]
source = open(path).read()
if "AuthPlugin" not in source:
    registration = (
        "    ctx.use(AuthPlugin(\n"
        "        urlOpener: ctx.urlOpener,\n"
        "        events: ctx.events,\n"
        "        networkClient: URLSessionNetworkClient(),\n"
        "        presenter: SystemAuthorizationSession(ephemeral: true)\n"
        "    ))\n\n"
    )
    patched = re.sub(r"\n(\s*)(_ = )?try ctx\.createWindow",
                     "\n" + registration + r"\1\2try ctx.createWindow", source, count=1)
    if patched == source:
        sys.exit("couldn't find where to register AuthPlugin in App.swift")
    open(path, "w").write(patched)
    print("    registered AuthPlugin with an ephemeral session")
PY

cleanup() {
    kill "$PROVIDER_PID" 2>/dev/null
    rm -f "$PROVIDER_LOG"
    [[ "$CLEANUP_APP" == 1 ]] && rm -rf "$(dirname "$APP_DIR")"
    return 0
}
trap cleanup EXIT

DRIVE=("$CLI" drive)
DRIVE_OPTS=(--target ios --timeout 180)
[[ -n "$TEAM" ]] && DRIVE_OPTS+=(--team "$TEAM" --allow-provisioning-registration)
[[ -n "$DEVICE" ]] && DRIVE_OPTS+=(--device "$DEVICE")
evaljs() { (cd "$APP_DIR" && "${DRIVE[@]}" eval "$1" "${DRIVE_OPTS[@]}" 2>/dev/null); }
recorded() { curl -fsS "$PROVIDER/recorded" 2>/dev/null; }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

echo "→ building, signing, installing and driving on the cabled device"
echo "   (keep the device unlocked and the app on screen — iOS suspends a"
echo "    backgrounded app, and a verb sent to one waits rather than failing)"

# --- CONTROL: can we drive this device at all? ------------------------------
# Every check below is one launch, so a failure that is really "the app never
# came up" would otherwise be reported as a broken feature.
CONTROL="$(evaljs '1 + 1')"
if [[ "$CONTROL" != "2" ]]; then
    echo "::error::couldn't drive the device — 1 + 1 returned '$CONTROL'"
    echo "          (unlocked? trusted? a data cable, not charge-only? free-team profile still valid?)"
    exit 1
fi
echo "  CONTROL  the device is drivable over USB"

# Second control: can a session present at all on this device, right now?
#
# `ASWebAuthenticationSession` refuses an anchor whose scene isn't
# **foreground-active**, and reports it as "error 3" naming nothing. A device
# whose screen has gone to sleep during the build is exactly that state — and
# `document.visibilityState` still answers "visible" there, so the obvious
# control measures the wrong thing. (It did, for a whole round of runs.)
#
# So probe the real precondition: start a session nothing will redirect to, with
# a short timeout. `E_AUTH_TIMEOUT` means it presented and waited — the thing
# every check below depends on. `active=0` in the anchor diagnostic means the
# scene isn't active, which is an environment to fix rather than a feature to
# fail.
PROBE="$(evaljs "(async()=>{try{await __SWIFT_PWA__.invoke('auth.authorize',{authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',redirect:{scheme:'$SCHEME'},timeoutMs:4000});return 'resolved';}catch(e){return (e.code||'')+' :: '+(e.message||'');}})()")"
if [[ "$PROBE" == *"active=0"* ]]; then
    echo "  CONTROL  the app's scene isn't foreground-active — $PROBE"
    skip "the whole flow" "wake and unlock the device, keep the app on screen, then re-run"
    echo
    echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if [[ "$PROBE" != *"E_AUTH_TIMEOUT"* ]]; then
    fail "a session nothing redirects to times out with E_AUTH_TIMEOUT" "$PROBE"
else
    pass "a session nothing redirects to times out with E_AUTH_TIMEOUT"
fi
echo "  CONTROL  ASWebAuthenticationSession presents on this device"

# --- The whole flow, in one launch ------------------------------------------
# Every `drive eval` returns the page's value as a JSON *string*, so anything it
# built is JSON inside JSON and arrives backslash-escaped. Decode twice and
# assert on values; matching patterns against the escaped text reads as a
# failure while the flow is in fact perfect. (It did, on three platforms.)
decode() { python3 -c 'import json,sys; print(json.loads(json.loads(sys.stdin.read().strip())))' 2>/dev/null; }
field() { python3 -c "
import json,sys
d = json.loads(json.loads(sys.stdin.read().strip()))
for key in '$1'.split('.'):
    d = (d or {}).get(key) if isinstance(d, dict) else None
print('' if d is None else d)
" 2>/dev/null; }

FLOW="$(evaljs "(async()=>{try{const g=await __SWIFT_PWA__.invoke('auth.authorize',{authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',scopes:['read'],redirect:{scheme:'$SCHEME'},extraParams:{auto_redirect:'1'},timeoutMs:90000});return JSON.stringify({ok:true,g});}catch(e){return JSON.stringify({ok:false,code:e.code||'',message:e.message||String(e)});}})()")"

GRANT_CODE="$(field 'g.code' <<<"$FLOW")"
VERIFIER="$(field 'g.codeVerifier' <<<"$FLOW")"
REDIRECT_URI="$(field 'g.redirectUri' <<<"$FLOW")"

if [[ -n "$GRANT_CODE" ]]; then
    pass "ASWebAuthenticationSession presented, and the callback came back through it"
else
    fail "ASWebAuthenticationSession presented, and the callback came back through it" "$(decode <<<"$FLOW")"
fi

# What the provider saw — the same RFC checks the other scripts make, but proving
# it for a request built on the device.
SENT="$(recorded)"
METHOD="$(jqp 'd["authorize"][-1].get("code_challenge_method","") if d["authorize"] else ""' <<<"$SENT")"
CHALLENGE="$(jqp 'd["authorize"][-1].get("code_challenge","") if d["authorize"] else ""' <<<"$SENT")"
[[ "$METHOD" == "S256" && -n "$CHALLENGE" ]] \
    && pass "the authorization request carries an S256 challenge" \
    || fail "the authorization request carries an S256 challenge" "method=$METHOD challenge=$CHALLENGE"

# The verifier has to come back, or the exchange the app must do next is
# impossible — and it has to be the one that was actually hashed.
[[ -n "$VERIFIER" ]] \
    && pass "the verifier comes back with the code" \
    || fail "the verifier comes back with the code" "codeVerifier was empty"

[[ "$REDIRECT_URI" == "$SCHEME:"* ]] \
    && pass "the redirect URI is the app's custom scheme ($REDIRECT_URI)" \
    || fail "the redirect URI is the app's custom scheme" "$REDIRECT_URI"

# --- The callback must NOT leak onto app.openURL -----------------------------
# The session routes it straight back, which is the security property worth
# having: nothing else listening on that channel can see an authorization code.
# Asserted in the same launch that receives it — and the code arriving at all is
# the control, so an empty `leaked` can't be mistaken for a flow that never ran.
LEAK="$(evaljs "(async()=>{let seen=null;__SWIFT_PWA__.on('app.openURL',p=>{seen=p});const g=await __SWIFT_PWA__.invoke('auth.authorize',{authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',redirect:{scheme:'$SCHEME'},extraParams:{auto_redirect:'1'},timeoutMs:90000});await new Promise(r=>setTimeout(r,750));return JSON.stringify({code:g.code,leaked:seen});})()")"
LEAK_CODE="$(field 'code' <<<"$LEAK")"
LEAKED="$(field 'leaked' <<<"$LEAK")"
if [[ -z "$LEAK_CODE" ]]; then
    fail "the callback never reaches the app.openURL channel" "the flow didn't complete: $(decode <<<"$LEAK")"
elif [[ -z "$LEAKED" ]]; then
    pass "the callback never reaches the app.openURL channel"
else
    fail "the callback never reaches the app.openURL channel" "leaked=$LEAKED"
fi

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
echo "  (the cookie-sharing prompt and cancel-by-dismissal stay manual — see docs/manual-test-cases.md)"
[[ "$FAIL" == 0 ]] || exit 1
