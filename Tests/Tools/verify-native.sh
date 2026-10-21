#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./Tests/Tools/verify-native.sh --app /absolute/Quick\ Note.app --output /absolute/new-or-empty-dir
                               [--case workflow|localization] [--appearance native|standard]
                               [--timeout-seconds N] [--help]

Verify a prebuilt Quick Note bundle using the existing two-process workflow.
No build, signing or arbitrary normal-user application arguments are supported.
Localization uses isolated settings and normally stops/restores only a running
instance at the exact selected app path to release its Carbon shortcut.
Timeout defaults to 300 seconds (positive decimal, at most 86400).
Appearance defaults to native; standard uses the fixture's standard appearance.

The output contains manifest.json, stdout.log, stderr.log and workflow/ with
the two stage logs, phase commands/exit status, a fresh database and its oracle.
The manifest observes source/artifact state; it does not infer build origin.
USAGE
}
fail() { printf 'Quick Note verification: %s\n' "$*" >&2; exit 2; }

APP=""
OUTPUT=""
CASE="workflow"
TIMEOUT="300"
APPEARANCE="native"
HELP=0
SEEN=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            [[ "$HELP" == 0 ]] || fail 'Duplicate argument: --help'
            HELP=1; shift; continue ;;
        --app|--output|--case|--timeout-seconds|--appearance)
            FLAG="$1"
            for PREVIOUS in "${SEEN[@]+${SEEN[@]}}"; do
                [[ "$PREVIOUS" != "$FLAG" ]] || fail "Duplicate argument: $FLAG"
            done
            SEEN+=("$FLAG")
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value: $FLAG"
            case "$FLAG" in
                --app) APP="$2" ;;
                --output) OUTPUT="$2" ;;
                --case) CASE="$2" ;;
                --timeout-seconds) TIMEOUT="$2" ;;
                --appearance) APPEARANCE="$2" ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ "$CASE" == workflow || "$CASE" == localization ]] || fail "Unknown case: $CASE"
[[ "$APPEARANCE" == native || "$APPEARANCE" == standard ]] || fail 'Appearance must be native or standard.'
awk -v value="$TIMEOUT" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 && value <= 86400) }' || fail 'Timeout must be a positive decimal no greater than 86400.'
if [[ "$HELP" == 1 ]]; then usage; exit 0; fi
[[ "$APP" == /* && "$APP" == *.app && -d "$APP" ]] || fail '--app must be an absolute existing .app directory.'
[[ "$OUTPUT" == /* ]] || fail '--output must be an absolute new or empty directory.'
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    [[ -d "$OUTPUT" && -w "$OUTPUT" ]] || fail 'Output must be a writable directory.'
    shopt -s nullglob dotglob
    ENTRIES=("$OUTPUT"/*)
    [[ ${#ENTRIES[@]} -eq 0 ]] || fail 'Output is not empty; use a new run directory.'
else
    [[ -d "$(dirname "$OUTPUT")" && -w "$(dirname "$OUTPUT")" ]] || fail 'The output parent must already exist and be writable.'
fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" || fail 'App has no readable bundle identifier.'
[[ "$IDENTIFIER" == app.mayfiles.QuickNote ]] || fail "Wrong project app identifier: $IDENTIFIER"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT"
TOOL_DIR="$ROOT/.build/native-verification"
MODULE_CACHE="$ROOT/.build/VerificationEvidenceModuleCache"
OUTPUT_CANONICAL="$(/bin/zsh -c 'print -r -- "${1:A}"' -- "$OUTPUT")"
for CACHE in "$TOOL_DIR" "$MODULE_CACHE"; do
    CACHE_CANONICAL="$(/bin/zsh -c 'print -r -- "${1:A}"' -- "$CACHE")"
    if [[ "$OUTPUT_CANONICAL" == "$CACHE_CANONICAL" || "$OUTPUT_CANONICAL" == "$CACHE_CANONICAL"/* || "$CACHE_CANONICAL" == "$OUTPUT_CANONICAL"/* ]]; then
        fail 'Output must be separate from both recorder compiler output and module cache directories.'
    fi
done
mkdir -p "$TOOL_DIR" "$MODULE_CACHE"
swiftc -module-cache-path "$MODULE_CACHE" "$ROOT/scripts/lib/VerificationEvidence.swift" -o "$TOOL_DIR/VerificationEvidence"
WORKFLOW_ARGS=(--app "$APP" --output "$OUTPUT/workflow")
EVIDENCE_ARGS=()
if [[ "$CASE" == localization ]]; then
    WORKFLOW_ARGS+=(--case localization --report "$OUTPUT/localization-flow.json")
    EVIDENCE_ARGS=(--report "$OUTPUT/localization-flow.json" --success-field passed --termination-grace-seconds 60 --localization-cleanup true)
fi
if [[ "$APPEARANCE" == standard ]]; then WORKFLOW_ARGS+=(--appearance standard); fi
exec "$TOOL_DIR/VerificationEvidence" --project quick-note --repo "$ROOT" --app "$APP" --output "$OUTPUT" \
    --expected-bundle-id app.mayfiles.QuickNote --timeout-seconds "$TIMEOUT" "${EVIDENCE_ARGS[@]+${EVIDENCE_ARGS[@]}}" \
    -- /bin/zsh "$ROOT/Tests/Tools/verify-workflow.sh" "${WORKFLOW_ARGS[@]}"
