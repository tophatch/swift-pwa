#!/usr/bin/env bash
#
# Drive a real app through a real OAuth 2.0 authorization-code flow.
#
# Why this exists: `auth.*` is three separate mechanisms wearing one command —
# a URL handed to the system browser, an HTTP listener on 127.0.0.1, and a
# custom-scheme callback off the app.openURL channel — and the unit suite can
# only reach the third of those that doesn't involve another process. CI
# compiles every backend and launches none, which is how `drive` and the agent
# check both turned out never to have worked on Windows.
#
# The other side of the protocol is a real, separate process
# (Scripts/oauth-probe/provider.py), not a test double. It checks what a
# provider checks: that the authorization request carries what RFC 6749 and
# RFC 7636 require, and that the verifier presented at the token endpoint
# actually hashes to the challenge sent at the start. A challenge can be
# well-formed and wrong, and only the far side notices.
#
# Usage:
#   Scripts/verify-oauth.sh [--app-dir <dir>] [--keep] [--only <name>]
#
#   --app-dir <dir>  where to build the probe app. Default: a temp dir.
#   --keep           don't delete the probe app afterwards (for iterating).
#   --only <name>    run one check: authorize | wrongstate | exchange | timeout
#   --require-browser  treat "no browser on this box" as a FAILURE rather than a
#                    SKIP. For CI, where a run that skips everything is worse
#                    than no run at all: it reports green having tested nothing,
#                    which is the exact failure the controls exist to prevent.
#
# Written around the trap every probe in this repo has paid for: a quiet
# environment is not a passing test. A box with no browser, or a locked screen,
# fails the browser leg in exactly the way a broken implementation would. So the
# first thing that runs is a CONTROL — `system.openURL` against the stand-in
# provider — and the run SKIPs rather than FAILs if even that can't land.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
ONLY=""
REQUIRE_BROWSER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --require-browser) REQUIRE_BROWSER=1; shift ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }
wanted() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      PLATFORM="windows" ;;
esac

# --- The stand-in provider --------------------------------------------------
PROVIDER_LOG="$(mktemp)"
python3 "$REPO/Scripts/oauth-probe/provider.py" >"$PROVIDER_LOG" 2>&1 &
PROVIDER_PID=$!
# Off the job table, so killing it at teardown doesn't print bash's own
# "Terminated: 15" line over the results.
disown "$PROVIDER_PID" 2>/dev/null || true
# Reap it from *here*, not from the full teardown installed later: every `exit 1`
# between this line and that one would otherwise leave the provider running, and
# an orphan that inherited this script's stdout holds the pipe open — so
# `Scripts/verify-oauth.sh | tail` never returns, long after the script itself
# has finished. (Same shape as the orphaned-Xvfb note in verify-driven-input.sh.)
trap 'kill "$PROVIDER_PID" 2>/dev/null; rm -f "$PROVIDER_LOG"' EXIT
PROVIDER_PORT=""
for _ in $(seq 1 60); do
    PROVIDER_PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$PROVIDER_LOG" 2>/dev/null | head -1)"
    [[ -n "$PROVIDER_PORT" ]] && break
    sleep 0.2
done
[[ -n "$PROVIDER_PORT" ]] || { echo "::error::the stand-in provider never started"; cat "$PROVIDER_LOG"; exit 1; }
PROVIDER="http://127.0.0.1:$PROVIDER_PORT"
echo "→ stand-in provider on $PROVIDER"

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

# `swift-pwa init` pins the app to the last *released* package, so an app
# scaffolded here would test the shipped backend and quietly ignore every local
# change.
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

# Register the plugin. This is the whole adopter-facing line, on every platform
# — if it ever needs an `#if os(…)` around it, that is itself the regression.
python3 - "$APP_DIR/Sources/$(basename "$APP_DIR")/App.swift" <<'PY'
import re, sys
path = sys.argv[1]
source = open(path).read()
if "AuthPlugin" not in source:
    patched = re.sub(
        r"\n(\s*)(_ = )?try ctx\.createWindow",
        r"\n\1ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))\n\n\1\2try ctx.createWindow",
        source, count=1)
    if patched == source:
        sys.exit("couldn't find where to register AuthPlugin in App.swift")
    open(path, "w").write(patched)
    print("    registered AuthPlugin")
PY

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | tail -20); exit 1; }

# maxdepth 5: the swiftbuild engine puts it at .build/out/Products/Debug/<name>,
# two levels deeper than the legacy .build/<triple>/debug/<name> layout.
BINARY="$(find "$APP_DIR/.build" -maxdepth 5 -name "$(basename "$APP_DIR")" -type f -perm -u+x | head -1)"
[[ -x "$BINARY" ]] || { echo "::error::couldn't find the built probe binary"; exit 1; }

LOG="$(mktemp)"
LAUNCH=("$BINARY")
if [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" ]]; then
    LAUNCH=(xvfb-run -a "$BINARY")
fi
SETSID=()
command -v setsid >/dev/null 2>&1 && SETSID=(setsid)

${SETSID[@]+"${SETSID[@]}"} env SWIFT_PWA_WEB_ROOT="$APP_DIR/web" SWIFT_PWA_DRIVE=0 "${LAUNCH[@]}" >"$LOG" 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true

cleanup() {
    kill -- -"$APP_PID" 2>/dev/null || kill "$APP_PID" 2>/dev/null
    kill "$PROVIDER_PID" 2>/dev/null
    rm -f "$LOG" "$PROVIDER_LOG"
    [[ "$CLEANUP_APP" == 1 ]] && rm -rf "$(dirname "$APP_DIR")"
    return 0
}
trap cleanup EXIT

PORT=""; TOKEN=""
for _ in $(seq 1 120); do
    line="$(grep -m1 'driver listening' "$LOG" 2>/dev/null)"
    if [[ -n "$line" ]]; then
        PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' <<<"$line")"
        TOKEN="$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' <<<"$line")"
        break
    fi
    kill -0 "$APP_PID" 2>/dev/null || { echo "::error::the probe app exited:"; cat "$LOG"; exit 1; }
    sleep 0.5
done
[[ -n "$PORT" && -n "$TOKEN" ]] || { echo "::error::the app never printed its driver port"; cat "$LOG"; exit 1; }

# stdout only. `drive` warns on stderr whenever the target window isn't on
# screen — true for every backgrounded run, which is the normal case here — and
# folding that into stdout interleaves it with the results.
drive() { "$CLI" drive "$@" --attach "$PORT" --token "$TOKEN" 2>/dev/null; }
evaljs() { drive eval "$1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))' 2>/dev/null; }
recorded() { curl -fsS "$PROVIDER/recorded"; }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

echo "→ driving $(basename "$BINARY") on $PLATFORM (port $PORT)"

# --- CONTROL: can this box open a browser at all? ---------------------------
# Without this, a headless machine reports the browser leg as a broken feature.
drive eval "__probe.openControl('$PROVIDER/control')" >/dev/null 2>&1
BROWSER=0
# Generous, because this is a *cold* browser start on a machine that may have
# none running — 45s on a headless Linux box under Xvfb, where Chrome's first
# launch is slow enough that a 10s wait reports "no browser here" on a box that
# has two of them installed. Getting this wrong turns the control into the very
# thing it exists to prevent: a SKIP that looks like an environment limit.
for _ in $(seq 1 180); do
    [[ "$(recorded | jqp 'd["control"]')" != "0" ]] && { BROWSER=1; break; }
    sleep 0.25
done
if [[ "$BROWSER" == 1 ]]; then
    echo "  CONTROL  the system URL handler opened a URL from this app"
elif [[ "$REQUIRE_BROWSER" == 1 ]]; then
    fail "the system URL handler opened a URL from this app" \
        "--require-browser: this box has no reachable browser, so nothing below could be tested"
else
    echo "  CONTROL  no browser on this box — the browser leg will be SKIPped, not failed"
fi

# --- authorize --------------------------------------------------------------
AUTH_REDIRECT=""; AUTH_STATE=""
if wanted authorize || wanted wrongstate || wanted exchange; then
    if [[ "$BROWSER" == 0 ]]; then
        skip authorize "no system browser here"
    else
        drive eval "__probe.authorize({authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',scopes:['read'],redirect:'loopback',timeoutMs:60000})" >/dev/null 2>&1

        for _ in $(seq 1 180); do
            AUTH_REDIRECT="$(recorded | jqp 'd["authorize"][-1]["redirect_uri"] if d["authorize"] else ""')"
            [[ -n "$AUTH_REDIRECT" ]] && break
            sleep 0.25
        done

        if [[ -z "$AUTH_REDIRECT" ]]; then
            fail authorize "the consent page never reached the provider (but the control did, so this is real)"
        else
            SENT="$(recorded)"
            AUTH_STATE="$(jqp 'd["authorize"][-1]["state"]' <<<"$SENT")"
            METHOD="$(jqp 'd["authorize"][-1].get("code_challenge_method","")' <<<"$SENT")"
            CHALLENGE="$(jqp 'd["authorize"][-1].get("code_challenge","")' <<<"$SENT")"
            RESPONSE_TYPE="$(jqp 'd["authorize"][-1].get("response_type","")' <<<"$SENT")"

            [[ "$RESPONSE_TYPE" == "code" && -n "$AUTH_STATE" && "$METHOD" == "S256" && -n "$CHALLENGE" ]] \
                && pass "the authorization request carries code/state/S256 challenge" \
                || fail "the authorization request carries code/state/S256 challenge" \
                        "response_type=$RESPONSE_TYPE state=$AUTH_STATE method=$METHOD challenge=$CHALLENGE"

            [[ "$AUTH_REDIRECT" == http://127.0.0.1:* ]] \
                && pass "the redirect URI is an OS-assigned loopback port ($AUTH_REDIRECT)" \
                || fail "the redirect URI is loopback" "$AUTH_REDIRECT"
        fi
    fi
fi

# --- wrong state ------------------------------------------------------------
if wanted wrongstate && [[ -n "$AUTH_REDIRECT" ]]; then
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "$AUTH_REDIRECT?code=attacker&state=not-the-one")"
    STILL="$(evaljs '__probe.snapshot()' | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["running"])' 2>/dev/null)"
    [[ "$CODE" == "400" && "$STILL" == "True" ]] \
        && pass "a callback with the wrong state is refused and the flow keeps waiting" \
        || fail "a callback with the wrong state is refused and the flow keeps waiting" "http=$CODE running=$STILL"
fi

# --- the real redirect ------------------------------------------------------
GRANT_CODE="probe-code-$RANDOM"
if [[ -n "$AUTH_REDIRECT" ]] && (wanted authorize || wanted exchange); then
    curl -fsS "$AUTH_REDIRECT?code=$GRANT_CODE&state=$AUTH_STATE" >/dev/null 2>&1
    RESULT=""
    for _ in $(seq 1 40); do
        RESULT="$(drive eval '__probe.snapshot()' | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()))' 2>/dev/null)"
        [[ "$RESULT" == *"$GRANT_CODE"* ]] && break
        sleep 0.25
    done
    VERIFIER="$(python3 -c "
import json,sys
try:
    snap = json.loads('''$RESULT'''.replace(chr(39), chr(34)))
    print((snap.get('result') or {}).get('codeVerifier',''))
except Exception:
    print('')
" 2>/dev/null)"
    [[ "$RESULT" == *"$GRANT_CODE"* ]] \
        && pass "the page received the authorization code through the loopback receiver" \
        || fail "the page received the authorization code" "$RESULT"
fi

# --- exchange ---------------------------------------------------------------
if wanted exchange && [[ -n "$AUTH_REDIRECT" && -n "${VERIFIER:-}" ]]; then
    OUT="$(drive eval "__probe.exchange({tokenEndpoint:'$PROVIDER/token',clientId:'probe-client',code:'$GRANT_CODE',codeVerifier:'$VERIFIER',redirectUri:'$AUTH_REDIRECT'})")"
    # The provider recomputes SHA256(verifier) and compares it to the challenge
    # the app sent at the start, so this passing means PKCE round-tripped for
    # real across two processes.
    [[ "$OUT" == *"verified-access-token"* ]] \
        && pass "the token exchange round-tripped, PKCE verified by the provider" \
        || fail "the token exchange round-tripped" "$OUT"
fi

# --- timeout (the negative control) -----------------------------------------
# A run where nothing redirects MUST fail. Without it, every check above is
# equally consistent with a flow that resolves whatever it is handed.
if wanted timeout && [[ "$BROWSER" == 1 ]]; then
    drive eval "__probe.authorize({authorizationEndpoint:'$PROVIDER/authorize',clientId:'probe-client',redirect:'loopback',timeoutMs:1500})" >/dev/null 2>&1
    sleep 3
    OUT="$(drive eval '__probe.snapshot()')"
    [[ "$OUT" == *"E_AUTH_TIMEOUT"* ]] \
        && pass "a flow nothing redirects to times out with E_AUTH_TIMEOUT" \
        || fail "a flow nothing redirects to times out" "$OUT"
fi

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" == 0 ]] || exit 1
