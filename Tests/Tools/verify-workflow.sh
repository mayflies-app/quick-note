#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h:h}"
cd "$PROJECT_ROOT"
fail() { print -u2 -- "Quick Note workflow: $*"; exit 2; }
APP=""
WORKFLOW_DIR=""
APPEARANCE="native"
CASE="workflow"
CASE_SEEN=0
REPORT_PATH=""
REPORT_SEEN=0
APP_SEEN=0
OUTPUT_SEEN=0
APPEARANCE_SEEN=0
while (( $# > 0 )); do
    case "$1" in
        --app|--output|--appearance|--case|--report)
            FLAG="$1"
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "Missing value: $FLAG"
            if [[ "$FLAG" == --app ]]; then
                (( APP_SEEN == 0 )) || fail 'Duplicate --app'
                APP="$2"; APP_SEEN=1
            elif [[ "$FLAG" == --output ]]; then
                (( OUTPUT_SEEN == 0 )) || fail 'Duplicate --output'
                WORKFLOW_DIR="$2"; OUTPUT_SEEN=1
            elif [[ "$FLAG" == --report ]]; then
                (( REPORT_SEEN == 0 )) || fail 'Duplicate --report'
                REPORT_PATH="$2"; REPORT_SEEN=1
            elif [[ "$FLAG" == --case ]]; then
                (( CASE_SEEN == 0 )) || fail 'Duplicate --case'
                CASE="$2"; CASE_SEEN=1
            else
                (( APPEARANCE_SEEN == 0 )) || fail 'Duplicate --appearance'
                APPEARANCE="$2"; APPEARANCE_SEEN=1
            fi
            shift 2 ;;
        *) fail "Unknown argument: $1; prebuilt mode requires --app and --output." ;;
    esac
done
[[ "$CASE" == workflow || "$CASE" == localization ]] || fail "Unknown case: $CASE"
[[ "$APPEARANCE" == native || "$APPEARANCE" == standard ]] || fail 'Appearance must be native or standard.'
APP_APPEARANCE_ARGS=()
if [[ "$APPEARANCE" == standard ]]; then APP_APPEARANCE_ARGS=(--standard-appearance); fi
[[ "$APP" == /* && "$APP" == *.app && -d "$APP" ]] || fail '--app must be an absolute existing .app directory.'
[[ "$WORKFLOW_DIR" == /* ]] || fail '--output must be an absolute new or empty directory.'
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" || fail 'App has no readable bundle identifier.'
[[ "$IDENTIFIER" == app.mayfiles.QuickNote ]] || fail "Wrong project app identifier: $IDENTIFIER"
APP_BINARY="$APP/Contents/MacOS/QuickNote"
[[ -f "$APP_BINARY" && -x "$APP_BINARY" ]] || fail 'QuickNote executable is missing or not executable.'
APP="${APP:A}"
APP_BINARY="$APP/Contents/MacOS/QuickNote"
WORKFLOW_DIR="${WORKFLOW_DIR:A}"
[[ "$WORKFLOW_DIR" != "$APP" && "$WORKFLOW_DIR" != "$APP"/* && "$WORKFLOW_DIR" != "$PROJECT_ROOT/.git" && "$WORKFLOW_DIR" != "$PROJECT_ROOT/.git"/* ]] || fail 'Output must be separate from the app and Git metadata.'
if [[ -e "$WORKFLOW_DIR" || -L "$WORKFLOW_DIR" ]]; then
    [[ -d "$WORKFLOW_DIR" && -w "$WORKFLOW_DIR" ]] || fail 'Output must be a writable directory.'
    ENTRIES=("$WORKFLOW_DIR"/*(DN))
    (( ${#ENTRIES[@]} == 0 )) || fail 'Output is not empty; use a fresh workflow directory.'
else
    [[ -d "${WORKFLOW_DIR:h}" && -w "${WORKFLOW_DIR:h}" ]] || fail 'The output parent must already exist and be writable.'
    mkdir "$WORKFLOW_DIR"
fi

if [[ "$CASE" == localization ]]; then
    if [[ -z "$REPORT_PATH" ]]; then REPORT_PATH="$WORKFLOW_DIR/localization-flow.json"; fi
    [[ "$REPORT_PATH" == /* && ! -e "$REPORT_PATH" && ! -L "$REPORT_PATH" ]] || fail 'Report must be an absolute fresh file.'
    REPORT_PATH="${REPORT_PATH:A}"
    [[ "$REPORT_PATH" == "$WORKFLOW_DIR/localization-flow.json" || "$REPORT_PATH" == "${WORKFLOW_DIR:h}/localization-flow.json" ]] || fail 'Report must be the workflow report or its native runner parent report.'
else
    [[ -z "$REPORT_PATH" ]] || fail '--report is only supported for localization.'
fi

ACTIVE_FIXTURE_PID=""
ACTIVE_PHASE=""
ACTIVE_LOG=""
RESTORE_RUNNING=0
RESTORATION_PASSED=1
INITIAL_RUNNING=0
PREFERENCES_CLEANED=1
VERIFICATION_SUITE=""
SHARED_SUITE=0
LIFECYCLE_HELPER=""
INITIAL_OBSERVED=0
DATA_CLEANED=1
FIXTURES_STOPPED=1
PRESERVATION_PASSED=0
FIXTURE_PRESERVATION_PASSED=0
OWNED_FIXTURE_PIDS=()
production_snapshot() {
    python3 - "$1" <<'SNAPSHOT'
import hashlib, json, os, plistlib, sqlite3, sys
from pathlib import Path
from urllib.parse import quote
# Protect the persisted preference file, including its absence. The defaults
# export observer can materialize an empty domain; opening its precise plist is
# read-only and preserves Data, dates and other property-list types exactly.
preference_file=Path.home()/"Library/Preferences/app.mayfiles.QuickNote.plist"
try:
    preference_bytes=preference_file.read_bytes()
except FileNotFoundError:
    if preference_file.is_symlink():
        raise RuntimeError("Production preference file is a dangling symlink")
    preference_exists=False
    prefhash=None
else:
    preference_exists=True
    values=plistlib.loads(preference_bytes)
    raw=Path(sys.argv[1]).with_suffix(".plist")
    with os.fdopen(os.open(raw,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),"wb") as output:
        output.write(preference_bytes)
    prefhash=hashlib.sha256(plistlib.dumps(values,fmt=plistlib.FMT_BINARY,sort_keys=True)).hexdigest()
database=Path.home()/"Library/Application Support/QuickNote/notes.sqlite"
exists=database.exists()
logicalhash=None
if exists:
    # A read-only SQLite transaction includes committed WAL pages. Never use
    # immutable=1 or file hashes, which can miss or misclassify WAL contents.
    with sqlite3.connect("file:"+quote(str(database))+"?mode=ro",uri=True,timeout=5) as connection:
        connection.execute("BEGIN")
        logical="\n".join(connection.iterdump())
        logical_bytes=logical.encode()
        logicalhash=hashlib.sha256(logical_bytes).hexdigest()
        dump=Path(sys.argv[1]).with_suffix(".sql")
        with os.fdopen(os.open(dump,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),"wb") as output:
            output.write(logical_bytes)
Path(sys.argv[1]).write_text(json.dumps({"preferencesFileExists":preference_exists,"preferencesSHA256":prefhash,"databaseExists":exists,"databaseLogicalSHA256":logicalhash},indent=2)+"\n")
SNAPSHOT
}
cleanup_fixture() {
    local signal="$1" script_status="$2" fixture_status=0
    trap - EXIT
    trap '' TERM INT
    # Logging may be the reason for this exit; cleanup must still reclaim the child.
    set +e
    if [[ -n "$ACTIVE_FIXTURE_PID" ]]; then
        printf 'phase=%s signal=%s ownedPid=%s\n' "$ACTIVE_PHASE" "$signal" "$ACTIVE_FIXTURE_PID" >> "$WORKFLOW_DIR/phases.log" || true
        if kill -0 "$ACTIVE_FIXTURE_PID" 2>/dev/null; then
            kill -TERM "$ACTIVE_FIXTURE_PID" 2>/dev/null || true
            # End only this owned isolated fixture; leave time for normal app restoration.
            local attempt
            for attempt in {1..10}; do
                kill -0 "$ACTIVE_FIXTURE_PID" 2>/dev/null || break
                /bin/sleep 0.1
            done
            if kill -0 "$ACTIVE_FIXTURE_PID" 2>/dev/null; then
                kill -KILL "$ACTIVE_FIXTURE_PID" 2>/dev/null || true
            fi
        fi
        wait "$ACTIVE_FIXTURE_PID"
        fixture_status=$?
        if [[ -f "$ACTIVE_LOG" ]]; then cat "$ACTIVE_LOG" || true; fi
        printf 'phase=%s cleanupExit=%s ownedPid=%s\n' "$ACTIVE_PHASE" "$fixture_status" "$ACTIVE_FIXTURE_PID" >> "$WORKFLOW_DIR/phases.log" || true
        ACTIVE_FIXTURE_PID=""
    fi
    if [[ "$CASE" == localization ]]; then
        if [[ -n "$VERIFICATION_SUITE" && "$SHARED_SUITE" == 0 ]]; then
            local deletion_message deletion_status=0
            deletion_message="$(/usr/bin/defaults delete "$VERIFICATION_SUITE" 2>&1)" || deletion_status=$?
            # Reading a removed suite through defaults export may recreate an
            # empty plist. Observe only the exact owned file after deletion.
            if ! python3 - "$VERIFICATION_SUITE" "$WORKFLOW_DIR/preferences-after-cleanup.json" "$deletion_status" "$deletion_message" <<'PREFERENCES'
import json, os, plistlib, stat, sys
from pathlib import Path
path=Path.home()/"Library/Preferences"/(sys.argv[1]+".plist")
deleted=int(sys.argv[3]) == 0
missing=int(sys.argv[3]) == 1 and sys.argv[4] == "Error: Domain '"+sys.argv[1]+"' not found.\nDefaults have not been changed."
assert deleted or missing, "Isolated preference deletion API failed"
try:
    metadata=os.lstat(path)
    assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid(), "Isolated preference residue is not an owned regular file"
    with path.open("rb") as stream:
        assert plistlib.load(stream) == {}, "Preference values survived deletion API"
    # The precise suite belongs to this fresh run and its fixture has exited.
    # A cleared domain can leave an empty plist; remove only that exact residue.
    assert os.lstat(path).st_ino == metadata.st_ino, "Isolated preference file changed during cleanup"
    path.unlink()
    os.lstat(path)
    absent=False
except FileNotFoundError:
    absent=True
Path(sys.argv[2]).write_text(json.dumps({"suite":sys.argv[1],"path":str(path),"preferencesFileAbsent":absent,"deletionAPISucceeded":deleted or missing},indent=2)+"\n")
assert absent, "Owned isolated preference plist remained after deletion"
PREFERENCES
            then
                PREFERENCES_CLEANED=0
                print -u2 -- "FAIL: Could not establish isolated preference file cleanup"
            fi
        fi
        local owned_pid
        for owned_pid in "${OWNED_FIXTURE_PIDS[@]}"; do
            if kill -0 "$owned_pid" 2>/dev/null; then FIXTURES_STOPPED=0; fi
        done
        if (( FIXTURES_STOPPED )); then
            # Only these exact files under our fresh workflow directory are data.
            # Keep logs, expected-value oracles and screenshots for diagnosis.
            /bin/rm -f -- "$WORKFLOW_DIR/notes.sqlite" "$WORKFLOW_DIR/notes.sqlite-wal" "$WORKFLOW_DIR/notes.sqlite-shm" || DATA_CLEANED=0
            local database_file
            for database_file in "$WORKFLOW_DIR/notes.sqlite" "$WORKFLOW_DIR/notes.sqlite-wal" "$WORKFLOW_DIR/notes.sqlite-shm"; do
                [[ ! -e "$database_file" && ! -L "$database_file" ]] || DATA_CLEANED=0
            done
        else
            DATA_CLEANED=0
        fi
        # Capture the full production state after every owned fixture has exited,
        # before the ordinary app is relaunched. Restoration cannot mask a
        # fixture's temporary mutation by returning the final hash to baseline.
        if (( FIXTURES_STOPPED )) && [[ -f "$WORKFLOW_DIR/production-after-stop.json" ]] && production_snapshot "$WORKFLOW_DIR/production-after-fixture.json"; then
            if cmp -s "$WORKFLOW_DIR/production-after-stop.json" "$WORKFLOW_DIR/production-after-fixture.json"; then FIXTURE_PRESERVATION_PASSED=1; fi
        fi
        if (( RESTORE_RUNNING )); then
            # Normal launch only; the fixture child above is the only PID we signal.
            "$LIFECYCLE_HELPER" --inspect "$APP" > "$WORKFLOW_DIR/running-after-fixture.json" 2> "$WORKFLOW_DIR/restore.stderr.log"
            local inspect_status=$? current_running=0
            if (( inspect_status == 0 )); then
                current_running="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runningCount"])' "$WORKFLOW_DIR/running-after-fixture.json")"
                if [[ "$current_running" == 0 ]]; then
                    "$LIFECYCLE_HELPER" --launch "$APP" --verify > "$WORKFLOW_DIR/restore.stdout.log" 2>> "$WORKFLOW_DIR/restore.stderr.log"
                    (( $? == 0 )) || RESTORATION_PASSED=0
                fi
            else
                RESTORATION_PASSED=0
            fi
            "$LIFECYCLE_HELPER" --inspect "$APP" > "$WORKFLOW_DIR/running-restored.json" 2>> "$WORKFLOW_DIR/restore.stderr.log"
            if (( $? != 0 )) || ! python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["runningCount"] > 0' "$WORKFLOW_DIR/running-restored.json"; then
                RESTORATION_PASSED=0
            fi
        fi
        if (( INITIAL_OBSERVED )); then
            "$LIFECYCLE_HELPER" --inspect "$APP" > "$WORKFLOW_DIR/running-final.json" 2>> "$WORKFLOW_DIR/restore.stderr.log"
            if (( $? != 0 )) || ! python3 -c 'import json,sys; assert bool(json.load(open(sys.argv[1]))["runningCount"]) == bool(int(sys.argv[2]))' "$WORKFLOW_DIR/running-final.json" "$INITIAL_RUNNING"; then
                RESTORATION_PASSED=0
            fi
        else
            RESTORATION_PASSED=0
        fi
        if [[ -f "$WORKFLOW_DIR/production-before.json" ]] && production_snapshot "$WORKFLOW_DIR/production-after.json"; then
            if cmp -s "$WORKFLOW_DIR/production-before.json" "$WORKFLOW_DIR/production-after.json"; then PRESERVATION_PASSED=1; fi
        fi
        (( PREFERENCES_CLEANED && RESTORATION_PASSED && DATA_CLEANED && FIXTURES_STOPPED && PRESERVATION_PASSED && FIXTURE_PRESERVATION_PASSED )) || script_status=1
        python3 - "$WORKFLOW_DIR" "$REPORT_PATH" "$script_status" "$INITIAL_RUNNING" "$PREFERENCES_CLEANED" "$RESTORATION_PASSED" "$DATA_CLEANED" "$FIXTURES_STOPPED" "$PRESERVATION_PASSED" "$SHARED_SUITE" "$VERIFICATION_SUITE" "$FIXTURE_PRESERVATION_PASSED" <<'REPORT'
import json, plistlib
from pathlib import Path
import sys
folder=Path(sys.argv[1])
logs={name:(folder/name).read_text(errors="replace") if (folder/name).is_file() else "" for name in ("write.log","relaunch.log")}
report={"passed":int(sys.argv[3]) == 0, "initialRunningCount":int(sys.argv[4]),
        "originalRunningStateRestored":sys.argv[6] == "1",
        "isolatedDataRemoved":sys.argv[7] == "1", "ownedFixturesStopped":sys.argv[8] == "1",
        "productionDataAndPreferencesUnchanged":sys.argv[9] == "1",
        "fixtureProductionUnchanged":sys.argv[12] == "1",
        "checksByPhase":{name:sum(line.startswith("PASS: ") for line in text.splitlines()) for name,text in logs.items()},
        "scope":"Prebuilt native bilingual Settings and custom shortcut checks with isolated data and preferences; production preservation is checked across normal-app lifecycle boundaries."}
def phase_changes(before,after):
    first=folder/("production-"+before+".json")
    last=folder/("production-"+after+".json")
    if not first.is_file() or not last.is_file():
        return {"observed":False,"before":str(first),"after":str(last)}
    try:
        initial=json.loads(first.read_text());final=json.loads(last.read_text())
        def values(path,state):
            return plistlib.loads(path.with_suffix(".plist").read_bytes()) if state["preferencesFileExists"] else {}
        initial_values=values(first,initial);final_values=values(last,final)
        keys=sorted(key for key in set(initial_values)|set(final_values)
                    if (key in initial_values)!=(key in final_values)
                    or plistlib.dumps({key:initial_values[key]},fmt=plistlib.FMT_BINARY,sort_keys=True)
                    != plistlib.dumps({key:final_values[key]},fmt=plistlib.FMT_BINARY,sort_keys=True))
        return {"observed":True,"before":str(first),"after":str(last),"unchanged":initial==final,
                "changedPreferenceKeys":keys,
                "preferenceFilePresenceChanged":initial["preferencesFileExists"]!=final["preferencesFileExists"],
                "databasePresenceChanged":initial["databaseExists"]!=final["databaseExists"],
                "databaseLogicalChanged":initial["databaseLogicalSHA256"]!=final["databaseLogicalSHA256"]}
    except (OSError,ValueError,KeyError,TypeError,plistlib.InvalidFileException) as error:
        return {"observed":False,"before":str(first),"after":str(last),"error":type(error).__name__}
report["productionStateChanges"]={"normalStop":phase_changes("before","after-stop"),
    "fixtureExecution":phase_changes("after-stop","after-fixture"),"normalRestore":phase_changes("after-fixture","after")}
report["productionSnapshotScope"]="Full persisted preferences and transaction-consistent SQLite at four lifecycle boundaries. Phase differences locate an observed change interval; they do not identify its writer. No preference keys are excluded. Raw plist and SQL dumps have owner-only permissions."
if sys.argv[10] == "1":
    report.update(ownedSuiteInUse=True, isolatedPreferencesSuite=sys.argv[11], preferenceCleanupOwner="VerificationEvidence")
else:
    report["isolatedPreferencesRemoved"]=sys.argv[5] == "1"
Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+"\n")
REPORT
        (( $? == 0 )) || script_status=1
    fi
    exit "$script_status"
}
trap 'cleanup_fixture EXIT $?' EXIT
trap 'cleanup_fixture TERM 143' TERM
trap 'cleanup_fixture INT 130' INT

if [[ "$CASE" == localization ]]; then
    # The path is fresh, canonical and test-owned; this is the exact suite used by
    # AppPreferences, not the normal app preference domain.
    if [[ -n "${MACOS_LOCALIZATION_TEST_SUITE:-}" ]]; then
        SHARED_SUITE=1
        VERIFICATION_SUITE="$(python3 - "$WORKFLOW_DIR" <<'SUITE'
import hashlib, os, sys
from pathlib import Path
folder=Path(sys.argv[1]).resolve()
output=folder.parent
expected="app.mayfiles.QuickNote.localization-test."+hashlib.sha256(str(output).encode()).hexdigest()
assert os.environ["MACOS_LOCALIZATION_TEST_SUITE"] == expected, "Unexpected localization preference suite"
assert Path(os.environ["MACOS_LOCALIZATION_TEST_DIRECTORY"]).resolve() == output/"fixture-data", "Unexpected localization fixture directory"
print(expected)
SUITE
)"
    else
        VERIFICATION_SUITE="$(python3 -c 'import hashlib,sys; print("QuickNote.Verification.App."+hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$WORKFLOW_DIR/notes.sqlite")"
    fi
    LIFECYCLE_CACHE="$PROJECT_ROOT/.build/native-verification"
    MODULE_CACHE="$PROJECT_ROOT/.build/VerificationEvidenceModuleCache"
    mkdir -p "$LIFECYCLE_CACHE" "$MODULE_CACHE"
    LIFECYCLE_HELPER="$LIFECYCLE_CACHE/RunApp"
    swiftc -module-cache-path "$MODULE_CACHE" "$PROJECT_ROOT/scripts/lib/RunApp.swift" -o "$LIFECYCLE_HELPER"
    "$LIFECYCLE_HELPER" --inspect "$APP" > "$WORKFLOW_DIR/running-before.json"
    INITIAL_RUNNING="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runningCount"])' "$WORKFLOW_DIR/running-before.json")"
    INITIAL_OBSERVED=1
    production_snapshot "$WORKFLOW_DIR/production-before.json" || exit $?
    if (( INITIAL_RUNNING > 0 )); then
        RESTORE_RUNNING=1
        "$LIFECYCLE_HELPER" --stop "$APP" > "$WORKFLOW_DIR/stop.stdout.log" 2> "$WORKFLOW_DIR/stop.stderr.log"
    fi
    production_snapshot "$WORKFLOW_DIR/production-after-stop.json" || exit $?
fi

run_phase() {
    local phase="$1" log="$2"
    shift 2
    {
        printf 'phase=%s argv=' "$phase"
        printf '%q ' "$@"
        printf '\n'
    } | tee -a "$WORKFLOW_DIR/phases.log" || exit $?
    ACTIVE_PHASE="$phase"
    ACTIVE_LOG="$log"
    "$@" > "$log" 2>&1 &
    ACTIVE_FIXTURE_PID=$!
    OWNED_FIXTURE_PIDS+=("$ACTIVE_FIXTURE_PID")
    # zsh skips a global EXIT trap for ERR_EXIT inside a function. Explicit exit
    # keeps this post-spawn logging failure on the owned-child cleanup path.
    printf 'phase=%s pid=%s\n' "$phase" "$ACTIVE_FIXTURE_PID" | tee -a "$WORKFLOW_DIR/phases.log" || exit $?
    set +e
    wait "$ACTIVE_FIXTURE_PID"
    local phase_status=$?
    set -e
    ACTIVE_FIXTURE_PID=""
    cat "$log" || exit $?
    printf 'phase=%s exit=%s\n' "$phase" "$phase_status" | tee -a "$WORKFLOW_DIR/phases.log" || exit $?
    (( phase_status == 0 )) || exit "$phase_status"
    local expected_marker='PASS: Single-note native application workflow'
    if [[ "$CASE" == localization ]]; then
        expected_marker='PASS: Independent native settings checks; desktop focus coverage is reported separately'
        if /usr/bin/grep -Eq '^(FAIL|SKIP|INCONCLUSIVE):' "$log"; then
            print -u2 -- "FAIL: $phase contains failed, skipped or inconclusive native checks"
            exit 1
        fi
    fi
    if ! /usr/bin/grep -Fxq "$expected_marker" "$log"; then
        print -u2 -- "FAIL: $phase exited without the final native workflow PASS marker"
        exit 1
    fi
}
CASE_ARGS=()
if [[ "$CASE" == localization ]]; then CASE_ARGS=(--settings-only); fi
run_phase write "$WORKFLOW_DIR/write.log" "$APP_BINARY" --verify-workflow "${CASE_ARGS[@]}" "${APP_APPEARANCE_ARGS[@]}" --database "$WORKFLOW_DIR/notes.sqlite"
run_phase read-back "$WORKFLOW_DIR/relaunch.log" "$APP_BINARY" --verify-workflow "${CASE_ARGS[@]}" "${APP_APPEARANCE_ARGS[@]}" --read-back --database "$WORKFLOW_DIR/notes.sqlite"
print "Evidence: $WORKFLOW_DIR"
