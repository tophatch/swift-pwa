#!/usr/bin/env bash
#
# Drive a real Android app through a real OAuth 2.0 authorization-code flow.
#
# Why this is a third sibling to verify-oauth.sh / .ps1 rather than a flag on
# one of them: Android is the only platform where the *custom-scheme* receiver
# runs. The four desktop backends all use the loopback listener, so every check
# they carry leaves `SchemeRedirectReceiver` — and the whole
# ACTION_VIEW -> app.openURL -> `state` match chain behind it — untested on a
# device. It was cross-compile-verified only until this script existed.
#
# It needs no human. The consent page opens in the device's own browser, and the
# redirect is delivered by firing the intent the browser would have fired:
#
#   adb shell am start -a android.intent.action.VIEW -d '<scheme>:/oauth2redirect?code=..&state=..'
#
# which is the same Intent the OS routes from a real provider's 302 — same
# action, same category resolution, same MainActivity.handleOpenIntent path.
#
# The other side of the protocol is a real, separate process on the *host*
# (Scripts/oauth-probe/provider.py), reached from the device over `adb reverse`,
# so it checks what a provider checks: that the authorization request carries
# what RFC 6749 and RFC 7636 require, and that the verifier presented at the
# token endpoint hashes to the challenge sent at the start.
#
# Usage:
#   Scripts/verify-oauth-android.sh [--app-dir <dir>] [--keep] [--device <serial>]
#
# Written around the same trap as its siblings: a quiet device is not a passing
# test. The first check is a CONTROL — can this device open a browser at all —
# and the last is a negative control that MUST time out.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
DEVICE=""
SCHEME="swiftpwaoauthprobe"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
command -v adb >/dev/null || { echo "::error::adb not found (set ANDROID_HOME)"; exit 1; }

ADB=(adb)
[[ -n "$DEVICE" ]] && ADB=(adb -s "$DEVICE")
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "::error::no device (adb devices)"; exit 1; }

# --- The stand-in provider, on the host -------------------------------------
PROVIDER_LOG="$(mktemp)"
python3 "$REPO/Scripts/oauth-probe/provider.py" >"$PROVIDER_LOG" 2>&1 &
PROVIDER_PID=$!
disown "$PROVIDER_PID" 2>/dev/null || true
# Reap it from here, not from the fuller teardown below: an orphan that
# inherited this script's stdout holds the pipe open, so piping this script into
# `tail` would never return. (Cost a wedged run once already.)
trap 'kill "$PROVIDER_PID" 2>/dev/null; rm -f "$PROVIDER_LOG"' EXIT

PROVIDER_PORT=""
for _ in $(seq 1 60); do
    PROVIDER_PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$PROVIDER_LOG" 2>/dev/null | head -1)"
    [[ -n "$PROVIDER_PORT" ]] && break
    sleep 0.2
done
[[ -n "$PROVIDER_PORT" ]] || { echo "::error::the stand-in provider never started"; cat "$PROVIDER_LOG"; exit 1; }

# The device reaches the host's provider on its *own* 127.0.0.1 through this.
# Both halves need it: the browser loading the consent page, and the app's
# `net.request` doing the token exchange.
"${ADB[@]}" reverse "tcp:$PROVIDER_PORT" "tcp:$PROVIDER_PORT" >/dev/null || {
    echo "::error::adb reverse failed"; exit 1; }
PROVIDER="http://127.0.0.1:$PROVIDER_PORT"
echo "→ stand-in provider on $PROVIDER (reversed onto the device)"

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

# Declare the redirect scheme, and allow cleartext to the reversed provider.
# Both are what a real app would declare: `url_schemes` is how the OS learns to
# route the provider's redirect here at all, and Android blocks plain http by
# default (`usesCleartextTraffic=false`), scoped per host.
python3 - "$APP_DIR/pwa.json" "$SCHEME" <<'PY'
import json, sys
path, scheme = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
manifest.setdefault("url_schemes", [])
if scheme not in manifest["url_schemes"]:
    manifest["url_schemes"].append(scheme)
android = manifest.setdefault("android", {})
network = android.setdefault("network", {})
network.setdefault("cleartext_domains", [])
if "127.0.0.1" not in network["cleartext_domains"]:
    network["cleartext_domains"].append("127.0.0.1")
json.dump(manifest, open(path, "w"), indent=2)
print("    declared url_schemes + cleartext for 127.0.0.1")
PY

# The whole adopter-facing line. `AndroidNetworkClient`, because Android's
# URLSession has no injectable CA trust store — the one thing that is still
# per-platform, exactly as it already is for net.*.
python3 - "$APP_DIR/Sources/$(basename "$APP_DIR")/App.swift" <<'PY'
import re, sys
path = sys.argv[1]
source = open(path).read()
if "AuthPlugin" not in source:
    patched = re.sub(
        r"\n(\s*)(_ = )?try ctx\.createWindow",
        r"\n\1ctx.use(AuthPlugin(networkClient: AndroidNetworkClient()))\n\n\1\2try ctx.createWindow",
        source, count=1)
    if patched == source:
        sys.exit("couldn't find where to register AuthPlugin in App.swift")
    open(path, "w").write(patched)
    print("    registered AuthPlugin")
PY

# The package id is derived from the app's *directory name*, not fixed — read it
# back rather than assuming, or `am start` targets an activity that doesn't
# exist and every check below SKIPs as "no browser on this device".
PKG="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('android',{}).get('package_id',''))" "$APP_DIR/pwa.json")"
[[ -n "$PKG" ]] || { echo "::error::pwa.json has no android.package_id"; exit 1; }

echo "→ building, installing and launching on the device (this takes a few minutes)"
DEPLOY=("$CLI" deploy --target android --android-abis arm64-v8a)
[[ -n "$DEVICE" ]] && DEPLOY+=(--device "$DEVICE")
DEPLOY_LOG="$(mktemp)"
(cd "$APP_DIR" && "${DEPLOY[@]}") >"$DEPLOY_LOG" 2>&1 || {
    echo "::error::deploy failed"; tail -25 "$DEPLOY_LOG"; rm -f "$DEPLOY_LOG"; exit 1; }
rm -f "$DEPLOY_LOG"

cleanup() {
    "${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1
    "${ADB[@]}" reverse --remove "tcp:$PROVIDER_PORT" >/dev/null 2>&1
    kill "$PROVIDER_PID" 2>/dev/null
    rm -f "$PROVIDER_LOG"
    [[ "$CLEANUP_APP" == 1 ]] && rm -rf "$(dirname "$APP_DIR")"
    return 0
}
trap cleanup EXIT

CDP=("$REPO/Scripts/android-cdp-eval.py" "$PKG")
[[ -n "$DEVICE" ]] && CDP=("$REPO/Scripts/android-cdp-eval.py" -s "$DEVICE" "$PKG")
evaljs() { "${CDP[@]}" "$1" 2>/dev/null; }
recorded() { curl -fsS "$PROVIDER/recorded" 2>/dev/null; }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
# Bring the app back to the front — the consent browser covers it, and a
# backgrounded WebView still answers CDP but the next intent needs the activity.
front() { "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1; }

echo "→ driving $PKG on the device"

# --- CONTROL: can this device open a browser at all? ------------------------
evaljs "__SWIFT_PWA__.invoke('system.openURL', { url: '$PROVIDER/control' })" >/dev/null
BROWSER=0
for _ in $(seq 1 180); do
    [[ "$(recorded | jqp 'd["control"]')" != "0" ]] && { BROWSER=1; break; }
    sleep 0.25
done
if [[ "$BROWSER" == 1 ]]; then
    echo "  CONTROL  the device's URL handler opened a URL from this app"
else
    echo "  CONTROL  no browser reachable on this device — the flow will be SKIPped, not failed"
fi
front

# --- authorize --------------------------------------------------------------
AUTH_STATE=""; REDIRECT_URI=""
if [[ "$BROWSER" == 0 ]]; then
    skip authorize "no browser on this device"
else
    evaljs "__probe.authorize({authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',scopes:['read'],redirect:{scheme:'$SCHEME'},timeoutMs:120000})" >/dev/null

    for _ in $(seq 1 180); do
        AUTH_STATE="$(recorded | jqp 'd["authorize"][-1]["state"] if d["authorize"] else ""')"
        [[ -n "$AUTH_STATE" ]] && break
        sleep 0.25
    done

    if [[ -z "$AUTH_STATE" ]]; then
        fail authorize "the consent page never reached the provider (but the control did, so this is real)"
    else
        SENT="$(recorded)"
        REDIRECT_URI="$(jqp 'd["authorize"][-1].get("redirect_uri","")' <<<"$SENT")"
        METHOD="$(jqp 'd["authorize"][-1].get("code_challenge_method","")' <<<"$SENT")"
        CHALLENGE="$(jqp 'd["authorize"][-1].get("code_challenge","")' <<<"$SENT")"

        [[ "$METHOD" == "S256" && -n "$CHALLENGE" && -n "$AUTH_STATE" ]] \
            && pass "the authorization request carries state and an S256 challenge" \
            || fail "the authorization request carries state and an S256 challenge" \
                    "state=$AUTH_STATE method=$METHOD challenge=$CHALLENGE"

        # The point of this platform: the redirect is a scheme, not loopback.
        [[ "$REDIRECT_URI" == "$SCHEME:"* ]] \
            && pass "the redirect URI is the app's custom scheme ($REDIRECT_URI)" \
            || fail "the redirect URI is the app's custom scheme" "$REDIRECT_URI"
    fi
fi

# --- wrong state ------------------------------------------------------------
if [[ -n "$AUTH_STATE" ]]; then
    front
    "${ADB[@]}" shell am start -a android.intent.action.VIEW \
        -d "'$SCHEME:/oauth2redirect?code=attacker&state=not-the-one'" >/dev/null 2>&1
    sleep 2
    # Double-decoded on purpose: `snapshot()` returns a JSON *string*, so CDP
    # hands back a JSON-encoded string containing JSON. A single `json.loads`
    # yields text, and indexing text by "running" throws — which reads as a
    # failure while the flow is in fact exactly where it should be.
    STILL="$(evaljs '__probe.snapshot()' | python3 -c 'import json,sys;print(json.loads(json.loads(sys.stdin.read().strip()))["running"])' 2>/dev/null)"
    [[ "$STILL" == "True" ]] \
        && pass "a deep link with the wrong state is ignored and the flow keeps waiting" \
        || fail "a deep link with the wrong state is ignored and the flow keeps waiting" "running=$STILL"
fi

# --- the real redirect ------------------------------------------------------
GRANT_CODE="probe-code-$RANDOM"
VERIFIER=""
if [[ -n "$AUTH_STATE" ]]; then
    front
    # Exactly the Intent the OS fires when a provider's 302 lands on a scheme
    # this app declared in `url_schemes`.
    "${ADB[@]}" shell am start -a android.intent.action.VIEW \
        -d "'$SCHEME:/oauth2redirect?code=$GRANT_CODE&state=$AUTH_STATE'" >/dev/null 2>&1

    SNAP=""
    for _ in $(seq 1 40); do
        SNAP="$(evaljs '__probe.snapshot()')"
        [[ "$SNAP" == *"$GRANT_CODE"* ]] && break
        sleep 0.5
    done
    if [[ "$SNAP" == *"$GRANT_CODE"* ]]; then
        pass "the page received the authorization code through the app.openURL channel"
        VERIFIER="$(python3 -c "
import json,sys
try:
    print((json.loads(json.loads(sys.stdin.read().strip())).get('result') or {}).get('codeVerifier',''))
except Exception:
    print('')
" <<<"$SNAP" 2>/dev/null)"
    else
        fail "the page received the authorization code" "$SNAP"
    fi
fi

# --- exchange ---------------------------------------------------------------
if [[ -n "$VERIFIER" ]]; then
    OUT="$(evaljs "__probe.exchange({tokenEndpoint:'$PROVIDER/token',clientId:'probe-client',code:'$GRANT_CODE',codeVerifier:'$VERIFIER',redirectUri:'$REDIRECT_URI'})")"
    # The provider recomputes SHA256(verifier) against the challenge the app
    # sent at the start, so this passing means PKCE round-tripped for real
    # between a device and a separate host process.
    [[ "$OUT" == *"verified-access-token"* ]] \
        && pass "the token exchange round-tripped, PKCE verified by the provider" \
        || fail "the token exchange round-tripped" "$OUT"
fi

# --- timeout (the negative control) -----------------------------------------
if [[ "$BROWSER" == 1 ]]; then
    front
    evaljs "__probe.authorize({authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',redirect:{scheme:'$SCHEME'},timeoutMs:2000})" >/dev/null
    sleep 5
    front
    OUT="$(evaljs '__probe.snapshot()')"
    [[ "$OUT" == *"E_AUTH_TIMEOUT"* ]] \
        && pass "a flow nothing redirects to times out with E_AUTH_TIMEOUT" \
        || fail "a flow nothing redirects to times out" "$OUT"
fi

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" == 0 ]] || exit 1
