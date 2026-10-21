#!/bin/bash
# Contract tests for prebuilt native verification; no real compiler, GUI, or builder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PYTHON'
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
case_filter = None
if len(sys.argv) > 2:
    if len(sys.argv) != 4 or sys.argv[2] != "--case-name" or not sys.argv[3]:
        sys.exit("Usage: test-native-verification.sh [--case-name label-substring]")
    case_filter = sys.argv[3]
runner = root / "Tests/Tools/verify-native.sh"
workflow = root / "Tests/Tools/verify-workflow.sh"
for source in (runner, workflow):
    if not source.is_file():
        print(f"FAIL required verification entry is missing: {source}")
        sys.exit(1)

recorder_stub = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["NATIVE_TEST_TRACE"], "a") as stream:
    stream.write(json.dumps({"event": "recorder", "argv": sys.argv[1:]}) + "\n")
sys.exit(int(os.environ.get("NATIVE_TEST_RECORDER_STATUS", "0")))
'''
compiler_stub = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["NATIVE_TEST_TRACE"], "a") as stream:
    stream.write(json.dumps({"event": "compile", "argv": args}) + "\n")
status = int(os.environ.get("NATIVE_TEST_COMPILE_STATUS", "0"))
if status: sys.exit(status)
output = pathlib.Path(args[args.index("-o") + 1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(os.environ["NATIVE_TEST_LIFECYCLE_STUB"] if output.name == "RunApp" else os.environ["NATIVE_TEST_RECORDER_STUB"])
output.chmod(0o755)
'''
tee_stub = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
text = sys.stdin.read()
if os.environ.get("NATIVE_TEST_FAIL_PID_LOG") == "1" and " pid=" in text:
    sys.stdout.write(text)
    sys.stdout.flush()
    if os.environ.get("NATIVE_TEST_IGNORE_TERM") == "1":
        # Only the stubborn-child variant waits for its handler to be installed.
        # The ordinary spawn-failure case derives ownership solely from stdout.
        deadline = time.monotonic() + 2
        ready = False
        while time.monotonic() < deadline:
            trace = pathlib.Path(os.environ["NATIVE_TEST_TRACE"])
            if trace.exists():
                records = [json.loads(line) for line in trace.read_text().splitlines()]
                ready = any(record.get("event") == "write" for record in records)
            if ready: break
            time.sleep(0.01)
        if ready:
            print("fixture-term-ignored-ready", flush=True)
        else:
            sys.exit(93)
    target = pathlib.Path(sys.argv[-1])
    if target.is_file(): target.unlink()
    target.mkdir(exist_ok=True)
    sys.exit(91)
sys.exit(subprocess.run(["/usr/bin/tee"] + sys.argv[1:], input=text, text=True).returncode)
'''
lifecycle_stub = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sqlite3, sys, time
time.sleep(float(os.environ.get("NATIVE_TEST_LIFECYCLE_DELAY_SECONDS", "0")))
args=sys.argv[1:]
trace=pathlib.Path(os.environ["NATIVE_TEST_TRACE"])
with trace.open("a") as stream: stream.write(json.dumps({"event":"lifecycle", "argv":args})+"\n")
state=trace.with_suffix(".running")
count=int(state.read_text()) if state.exists() else int(os.environ.get("NATIVE_TEST_INITIAL_RUNNING", "0"))
if os.environ.get("NATIVE_TEST_FOREIGN_APP") == "1": sys.exit(9)
if args[0] == "--inspect": print(json.dumps({"runningCount":count}))
elif args[0] == "--stop":
    state.write_text("0")
    if os.environ.get("NATIVE_TEST_AFTER_STOP_SNAPSHOT_OUTPUT_FAILURE") == "1":
        (trace.parent/"evidence output/production-after-stop.plist").mkdir()
    print("stopped count="+str(count))
elif args[0] == "--launch":
    if os.environ.get("NATIVE_TEST_RESTORE_FAILURE") == "1": sys.exit(8)
    root=pathlib.Path(os.environ["NATIVE_TEST_USER_DIRECTORY"])
    prefs=root/"Library/Preferences/app.mayfiles.QuickNote.plist"
    if os.environ.get("NATIVE_TEST_RESTORE_FRAME_CHANGE") == "1":
        values=plistlib.loads(prefs.read_bytes());values["NSWindow Frame QuickNoteWindow"]="120 100 420 360 0 0 1800 1130 "
        prefs.write_bytes(plistlib.dumps(values))
    if os.environ.get("NATIVE_TEST_RESTORE_COVERS_FIXTURE_CHANGE") == "1":
        prefs.write_bytes((trace.parent/"original-production.plist").read_bytes())
        with sqlite3.connect(root/"Library/Application Support/QuickNote/notes.sqlite") as c:c.execute("UPDATE content SET text='baseline'")
    state.write_text("1"); print("launched")
else: sys.exit(2)
'''

fixture_program = r'''import hashlib, json, os, pathlib, plistlib, signal, sqlite3, subprocess, sys, time
signal.signal(signal.SIGINT, signal.default_int_handler)
if os.environ.get("NATIVE_TEST_IGNORE_TERM") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
args = sys.argv[1:]
phase = "read" if "--read-back" in args else "write"
with open(os.environ["NATIVE_TEST_TRACE"], "a") as stream:
    stream.write(json.dumps({"event": phase, "argv": args, "pid": os.getpid()}) + "\n")
time.sleep(float(os.environ.get("NATIVE_TEST_DELAY_SECONDS", "0")))
database=args[args.index("--database") + 1]
folder = pathlib.Path(database).parent
if phase == "write" and os.environ.get("NATIVE_TEST_FIXTURE_PRODUCTION_CHANGE"):
    root=pathlib.Path(os.environ["NATIVE_TEST_USER_DIRECTORY"])
    if os.environ["NATIVE_TEST_FIXTURE_PRODUCTION_CHANGE"].startswith("preferences"):
        prefs=root/"Library/Preferences/app.mayfiles.QuickNote.plist"
        values=plistlib.loads(prefs.read_bytes());values["sentinel"]=0 if os.environ["NATIVE_TEST_FIXTURE_PRODUCTION_CHANGE"] == "preferences-type" else "fixture crossed production boundary";prefs.write_bytes(plistlib.dumps(values))
    elif os.environ["NATIVE_TEST_FIXTURE_PRODUCTION_CHANGE"] == "database":
        with sqlite3.connect(root/"Library/Application Support/QuickNote/notes.sqlite") as c:c.execute("UPDATE content SET text='fixture crossed production boundary'")
if phase == "write" and os.environ.get("NATIVE_TEST_WRITE_SUITE") == "1":
    suite="QuickNote.Verification.App."+hashlib.sha256(database.encode()).hexdigest()
    subprocess.run(["/usr/bin/defaults","write",suite,"language","en"],check=True)
if phase == "write":
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "expected.json").write_bytes(b'{"fixture":"original oracle"}\n')
    (folder / "notes.sqlite").write_bytes(b"fixture database")
    if os.environ.get("NATIVE_TEST_WRITE_SIDECARS") == "1":
        (folder / "notes.sqlite-wal").write_bytes(b"fixture WAL")
        (folder / "notes.sqlite-shm").write_bytes(b"fixture shared memory")
if os.environ.get("NATIVE_TEST_SKIP") == "1":
    print("SKIP: fixture physical input permission unavailable")
if os.environ.get("NATIVE_TEST_INCONCLUSIVE") == "1": print("INCONCLUSIVE: fixture desktop focus changed")
if os.environ.get("NATIVE_TEST_FALSE_PASS") == "1": print("FAIL: fixture has failure despite final marker")
print("PASS: fixture phase assertion")
if os.environ.get("NATIVE_TEST_" + phase.upper() + "_MARKER", "complete") == "complete":
    if "--settings-only" in args:
        print("PASS: Independent native settings checks; desktop focus coverage is reported separately")
    else: print("PASS: Single-note native application workflow")
sys.exit(int(os.environ.get("NATIVE_TEST_" + phase.upper() + "_STATUS", "0")))
'''
passed = failed = 0

def require(condition, message):
    if not condition:
        raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix="quicknote native verification ") as temporary:
    work = Path(temporary).resolve()
    tools = work / "mock tools"
    tools.mkdir()
    compiler = tools / "swiftc"
    compiler.write_text(compiler_stub)
    compiler.chmod(0o755)
    tee = tools / "tee"
    tee.write_text(tee_stub)
    tee.chmod(0o755)
    for name in ("swift", "xcrun", "open", "osascript", "pkill", "killall", "pgrep", "security", "codesign"):
        stub = tools / name
        stub.write_text("#!/bin/bash\nprintf 'Unexpected real-tool route: %s\\n' " + name + " >&2\nexit 98\n")
        stub.chmod(0o755)
    cwd = work / "foreign cwd"
    cwd.mkdir()

    def run_case(label, entry, make_args, validate, overrides=None, status=0, setup=None, requested_signal=None, inject_log_failure=False, cleanup_timeout=2):
        global passed, failed
        if case_filter is not None and case_filter not in label:
            return
        project = work / (f"case {passed + failed + 1:02d} " + label)
        (project / "Tests/Tools").mkdir(parents=True)
        (project / "scripts/lib").mkdir(parents=True)
        shutil.copy2(runner, project / "Tests/Tools/verify-native.sh")
        copied_workflow=project / "Tests/Tools/verify-workflow.sh"
        shutil.copy2(workflow,copied_workflow)
        # Mock the input directory in the isolated snapshot subprocess only.
        # Do not alter HOME or the account used by CFPreferences suite cleanup.
        snapshot_boundary="<<'SNAPSHOT'\n"
        mock_home=r'''import os
from pathlib import Path
Path.home=classmethod(lambda cls: Path(os.environ['NATIVE_TEST_USER_DIRECTORY']))
if os.environ.get("NATIVE_TEST_PARTIAL_SNAPSHOT_JSON") == "1":
    original_write_text=Path.write_text
    def interrupted_snapshot_write(path,data,*args,**kwargs):
        if path.name == "production-after-stop.json":
            original_write_text(path,'{"preferencesFileExists":')
            raise OSError("Controlled partial snapshot output")
        return original_write_text(path,data,*args,**kwargs)
    Path.write_text=interrupted_snapshot_write
'''
        copied_workflow.write_text(copied_workflow.read_text().replace(snapshot_boundary,snapshot_boundary+mock_home,1))
        (project / "scripts/lib/VerificationEvidence.swift").write_text("// Recorder compiler fixture input.\n")
        (project / "scripts/lib/RunApp.swift").write_text("// Lifecycle compiler fixture input.\n")
        builder = project / "scripts/app.py"
        builder.write_text("#!/bin/bash\nprintf 'builder\\n' >> \"$NATIVE_TEST_TRACE\"\nexit 99\n")
        builder.chmod(0o755)
        app = project / "prebuilt app/Fixture QuickNote.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "app.mayfiles.QuickNote", "CFBundleExecutable": "QuickNote",
                          "CFBundlePackageType": "APPL", "CFBundleName": "Fixture Quick Note"}, stream)
        binary = macos / "QuickNote"
        binary.write_text('#!/bin/bash\nexec python3 "$(dirname "$0")/fixture-native.py" "$@"\n')
        binary.chmod(0o755)
        (macos / "fixture-native.py").write_text(fixture_program)
        output = project / "evidence output"
        if setup:
            setup(project, app, output)
        trace = project / "trace.jsonl"
        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith("QUICKNOTE_") or name.startswith("NATIVE_TEST_"):
                del env[name]
        env.update({"NATIVE_TEST_USER_DIRECTORY":str(project/"fixture user"), "PATH": str(tools) + os.pathsep + env["PATH"], "NATIVE_TEST_TRACE": str(trace),
                    "NATIVE_TEST_RECORDER_STUB": recorder_stub, "NATIVE_TEST_LIFECYCLE_STUB": lifecycle_stub})
        env.update(overrides or {})
        command = ["/bin/bash", str(project / "Tests/Tools/verify-native.sh")] if entry == "runner" else ["/bin/zsh", str(project / "Tests/Tools/verify-workflow.sh")]
        signal_problem = None
        cleanup_elapsed = None
        if requested_signal is None and not inject_log_failure:
            result = subprocess.run(command + make_args(project, app, output), cwd=cwd, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        else:
            # The control process and shell/fixture are test-owned PIDs. Never
            # discover or signal an application by name or bundle identifier.
            control = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            process = subprocess.Popen(command + make_args(project, app, output), cwd=cwd, env=env, text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            owned_pid = None
            def alive(pid):
                try:
                    os.kill(pid, 0)
                    return True
                except ProcessLookupError:
                    return False
            try:
                if inject_log_failure:
                    text, _ = process.communicate(timeout=2)
                    match = re.search(r"phase=write pid=([0-9]+)", text)
                    owned_pid = int(match.group(1)) if match else None
                    result = subprocess.CompletedProcess(command, process.returncode, text)
                    control_alive = control.poll() is None
                    owned_alive = owned_pid is not None and alive(owned_pid)
                    print(f"OBSERVE {label}: scriptExit={process.returncode} ownedPid={owned_pid} ownedAlive={owned_alive} controlAlive={control_alive}")
                    if owned_pid is None:
                        signal_problem = "spawned owned PID missing from actual phase stdout"
                    elif owned_alive:
                        signal_problem = "owned fixture PID remained alive after phase-log failure"
                    if not control_alive:
                        signal_problem = "unrelated control PID was terminated"
                else:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if trace.exists():
                            records = [json.loads(line) for line in trace.read_text().splitlines()]
                            owned_pid = next((record["pid"] for record in records if record["event"] == "write"), None)
                        if owned_pid is not None or process.poll() is not None:
                            break
                        time.sleep(0.02)
                    if owned_pid is None:
                        signal_problem = "fixture did not start before signal scenario deadline"
                    else:
                        cleanup_started = time.monotonic()
                        os.kill(process.pid, requested_signal)
                    text, _ = process.communicate(timeout=cleanup_timeout)
                    if owned_pid is not None:
                        cleanup_elapsed = time.monotonic() - cleanup_started
                    result = subprocess.CompletedProcess(command, process.returncode, text)
                    if owned_pid is not None:
                        deadline = time.monotonic() + 3
                        while alive(owned_pid) and time.monotonic() < deadline:
                            time.sleep(0.02)
                        if alive(owned_pid):
                            signal_problem = "owned fixture PID remained alive after script signal cleanup"
                    if control.poll() is not None:
                        signal_problem = "unrelated control PID was terminated"
            except subprocess.TimeoutExpired:
                signal_problem = "workflow script did not finish signal cleanup"
                process.kill()
                text, _ = process.communicate()
                if inject_log_failure and owned_pid is None:
                    match = re.search(r"phase=write pid=([0-9]+)", text)
                    owned_pid = int(match.group(1)) if match else None
                result = subprocess.CompletedProcess(command, process.returncode, text)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if owned_pid is not None and alive(owned_pid):
                    os.kill(owned_pid, signal.SIGKILL)
                control.terminate()
                control.wait()
        lines = trace.read_text().splitlines() if trace.exists() else []
        events = []
        for line in lines:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                events.append({"event": line, "argv": []})
        try:
            require(signal_problem is None, signal_problem or "")
            require(result.returncode != 0 if status == "failure" else result.returncode == status,
                    f"unexpected exit status {result.returncode}; expected {status}")
            validate(project, app, output, events, result.stdout)
        except AssertionError as error:
            failed += 1
            print(f"FAIL {label}: {error}")
            print("  observed events: " + json.dumps(events, ensure_ascii=False))
            print("  output: " + result.stdout.replace("\n", "\n  output: ").rstrip())
        else:
            passed += 1
            detail = f" (signal cleanup {cleanup_elapsed:.3f}s; control alive)" if cleanup_elapsed is not None else ""
            print(f"PASS {label}{detail}")
            if "appearance" in label and events:
                print("  observed argv: " + json.dumps(events, ensure_ascii=False))
                phase_log = output / "phases.log"
                if phase_log.is_file():
                    for line in phase_log.read_text().splitlines():
                        if " argv=" in line:
                            print("  phase evidence: " + line)

    def standard_args(project, app, output):
        return ["--app", str(app), "--output", str(output)]

    def no_native(project, app, output, events, text):
        require(not events, "invalid request called compiler, builder, recorder or native fixture")
        require(not (project / ".build").exists(), "invalid request created compiler output/cache")
        if output.exists():
            names = {item.name for item in output.iterdir()}
            require(not names or (names == {"sentinel"} and (output / "sentinel").read_text() == "preserve"),
                    "invalid request modified output")

    def runner_success(project, app, output, events, text, timeout="300", appearance="native"):
        require([event["event"] for event in events] == ["compile", "recorder"], "runner did not compile then execute recorder only")
        args = events[0]["argv"]
        require(str(project / "scripts/lib/VerificationEvidence.swift") in args, "runner compiled wrong recorder source")
        for flag, path in (("-o", project / ".build/native-verification/VerificationEvidence"),
                           ("-module-cache-path", project / ".build/VerificationEvidenceModuleCache")):
            require(flag in args and args[args.index(flag) + 1] == str(path), f"wrong compiler {flag} path")
        expected = ["--project", "quick-note", "--repo", str(project), "--app", str(app),
                    "--output", str(output), "--expected-bundle-id", "app.mayfiles.QuickNote", "--timeout-seconds", timeout,
                    "--", "/bin/zsh", str(project / "Tests/Tools/verify-workflow.sh"), "--app", str(app),
                    "--output", str(output / "workflow")]
        if appearance == "standard":
            expected += ["--appearance", "standard"]
        require(events[1]["argv"] == expected, "recorder argv did not preserve frozen prebuilt workflow contract")
        require("--report" not in events[1]["argv"], "oracle incorrectly presented as machine report")

    def help_case(project, app, output, events, text):
        no_native(project, app, output, events, text)
        require("--app" in text and "--output" in text, "help missing required prebuilt input flags")

    run_case("runner help no native calls", "runner", lambda *items: ["--help"], help_case)
    for label, extra in (("runner unknown flag", ["--normal"]), ("runner free app args", ["--", "--database", "user.sqlite"]),
                         ("runner appearance invalid rejected", ["--appearance", "dark"]), ("runner unknown case", ["--case", "appearance"]),
                         ("runner duplicate app", ["--app", "/duplicate.app"]), ("runner duplicate output", ["--output", "/duplicate-output"]),
                         ("runner duplicate case", ["--case", "workflow", "--case", "workflow"]),
                         ("runner duplicate timeout", ["--timeout-seconds", "2", "--timeout-seconds", "3"])):
        run_case(label, "runner", lambda p, a, o, flags=extra: standard_args(p, a, o) + flags, no_native, status="failure")
    for label, args in (("runner missing app", lambda p, a, o: ["--output", str(o)]),
                        ("runner missing output", lambda p, a, o: ["--app", str(a)]),
                        ("runner relative app", lambda p, a, o: ["--app", "relative.app", "--output", str(o)]),
                        ("runner relative output", lambda p, a, o: ["--app", str(a), "--output", "relative-output"]),
                        ("runner missing app path", lambda p, a, o: ["--app", str(p / "Missing.app"), "--output", str(o)]),
                        ("runner app flag missing value", lambda p, a, o: ["--app"]),
                        ("runner output flag missing value", lambda p, a, o: ["--app", str(a), "--output"]),
                        ("runner case flag missing value", lambda p, a, o: standard_args(p, a, o) + ["--case"]),
                        ("runner timeout flag missing value", lambda p, a, o: standard_args(p, a, o) + ["--timeout-seconds"])):
        run_case(label, "runner", args, no_native, status="failure")
    for timeout in ("0", "-1", "nan", "inf", "86401", "abc", ""):
        run_case("runner invalid timeout " + (timeout or "empty"), "runner",
                 lambda p, a, o, value=timeout: standard_args(p, a, o) + ["--timeout-seconds", value], no_native, status="failure")
    def wrong_id(project, app, output):
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "fixture.other.app", "CFBundleExecutable": "QuickNote"}, stream)
    def old_output(project, app, output):
        output.mkdir()
        (output / "sentinel").write_text("preserve")
    run_case("runner wrong bundle ID rejected", "runner", standard_args, no_native, status="failure", setup=wrong_id)
    run_case("runner nonempty output rejected", "runner", standard_args, no_native, status="failure", setup=old_output)
    run_case("runner default workflow exact argv", "runner", standard_args, runner_success)
    run_case("runner explicit workflow exact argv", "runner", lambda p, a, o: standard_args(p, a, o) + ["--case", "workflow"], runner_success)
    run_case("runner empty output allowed", "runner", standard_args, runner_success, setup=lambda p, a, o: o.mkdir())
    run_case("runner positive finite timeout accepted", "runner", lambda p, a, o: standard_args(p, a, o) + ["--timeout-seconds", "2.5"],
             lambda *items: runner_success(*items, timeout="2.5"))
    run_case("runner timeout upper bound accepted", "runner", lambda p, a, o: standard_args(p, a, o) + ["--timeout-seconds", "86400"],
             lambda *items: runner_success(*items, timeout="86400"))
    run_case("runner recorder failure propagated", "runner", standard_args, runner_success,
             {"NATIVE_TEST_RECORDER_STATUS": "29"}, status="failure")
    run_case("runner compile failure prevents recorder", "runner", standard_args,
             lambda p, a, o, events, text: require([e["event"] for e in events] == ["compile"], "compiler failure invoked recorder"),
             {"NATIVE_TEST_COMPILE_STATUS": "28"}, status="failure")

    def localization_runner(project, app, output, events, text):
        require([e["event"] for e in events] == ["compile", "recorder"], "localization wrapper performed unexpected work")
        args=events[1]["argv"]
        require(args[args.index("--report")+1] == str(output/"localization-flow.json"), "localization success report missing")
        require(args[args.index("--success-field")+1] == "passed", "localization did not require passed report")
        require(args[args.index("--termination-grace-seconds")+1] == "60", "restoration grace missing")
        require(args[args.index("--localization-cleanup")+1] == "true", "shared localization cleanup missing")
        require(args[-4:] == ["--case", "localization", "--report", str(output/"localization-flow.json")], "localization case not forwarded")
    run_case("localization runner routes native settings and cleanup report", "runner",
             lambda p,a,o:standard_args(p,a,o)+["--case","localization"],localization_runner)

    def localization_phases(project, app, output, events, text, wanted_phases=("write","read"), originally_running=True, success=True):
        lifecycle=[e for e in events if e["event"] == "lifecycle"]
        phases=[e for e in events if e["event"] in ("write","read")]
        require([e["event"] for e in phases] == list(wanted_phases), "wrong localization phase order")
        for phase in phases:
            require("--settings-only" in phase["argv"], "localization used broad workflow")
            require(phase["argv"][-2:] == ["--database",str(output/"notes.sqlite")], "normal database could be used")
        require(lifecycle[0]["argv"] == ["--inspect",str(app)], "lifecycle not inspected before action")
        actions=[e["argv"][0] for e in lifecycle]
        require(("--stop" in actions) == originally_running, "normal stop ignored original state")
        require(("--launch" in actions) == originally_running, "normal restore ignored original state")
        for event in lifecycle:
            require(event["argv"][1] == str(app), "lifecycle operated on different app")
        report=json.loads((output/"localization-flow.json").read_text())
        require(report["passed"] == success, "cleanup report passed state incorrect")
        require(report["isolatedPreferencesRemoved"], "isolated prefs not cleaned")
        require(report["originalRunningStateRestored"], "original app not restored")
        require(report["isolatedDataRemoved"], "isolated database cleanup not established")
        require(report["ownedFixturesStopped"], "owned fixture process exit not established")
        require(report["productionDataAndPreferencesUnchanged"], "production data preservation not established")
        for name in ("notes.sqlite", "notes.sqlite-wal", "notes.sqlite-shm"):
            require(not (output/name).exists(), "isolated data remained: "+name)
        before=json.loads((output/"production-before.json").read_text())
        require(before == json.loads((output/"production-after.json").read_text()), "production snapshots differ")
    localization_args=lambda p,a,o:standard_args(p,a,o)+["--case","localization"]
    run_case("localization normal exact app stop and restore", "workflow", localization_args,localization_phases,
             {"NATIVE_TEST_INITIAL_RUNNING":"1"})
    run_case("localization originally stopped app stays stopped", "workflow",localization_args,
             lambda *args:localization_phases(*args,originally_running=False))
    def missing_production_preferences(project, app, output, events, text):
        localization_phases(project,app,output,events,text,originally_running=False)
        before=json.loads((output/"production-before.json").read_text())
        require(before.get("preferencesFileExists") is False, "missing preference file not recorded")
        require(before["preferencesSHA256"] is None, "missing preference file hashed as an existing empty domain")
        require(not (project/"fixture user/Library/Preferences/app.mayfiles.QuickNote.plist").exists(), "snapshot created a missing preference file")
        for stage in ("before","after-stop","after-fixture","after"):
            require(not (output/("production-"+stage+".plist")).exists(), "absent preferences produced synthetic raw data")
            require(not (output/("production-"+stage+".sql")).exists(), "absent database produced a synthetic SQL dump")
    run_case("localization observes absent production preferences without creating them", "workflow",localization_args,
             missing_production_preferences)
    typed_preferences={"data":b"\x00\xff\x01", "language":"简体中文", "array":["text",3,True], "nested":{"enabled":True,"ratio":1.5}}
    def typed_preference_setup(project, app, output):
        path=project/"fixture user/Library/Preferences/app.mayfiles.QuickNote.plist"
        path.parent.mkdir(parents=True)
        path.write_bytes(plistlib.dumps(typed_preferences,fmt=plistlib.FMT_BINARY))
    def typed_production_preferences(project, app, output, events, text):
        localization_phases(project,app,output,events,text,originally_running=False)
        before=json.loads((output/"production-before.json").read_text())
        require(before.get("preferencesFileExists") is True, "existing preference file not recorded")
        for phase in ("before","after"):
            require(plistlib.loads((output/("production-"+phase+".plist")).read_bytes())==typed_preferences, "production snapshot lost preference value types")
        require(plistlib.loads((project/"fixture user/Library/Preferences/app.mayfiles.QuickNote.plist").read_bytes())==typed_preferences, "snapshot changed production preference values")
    run_case("localization preserves raw typed production preferences", "workflow",localization_args,
             typed_production_preferences,setup=typed_preference_setup)
    def production_state_setup(project,app,output,sentinel="baseline"):
        import sqlite3
        root=project/"fixture user"
        prefs=root/"Library/Preferences/app.mayfiles.QuickNote.plist";prefs.parent.mkdir(parents=True)
        original=plistlib.dumps({"sentinel":sentinel,"NSWindow Frame QuickNoteWindow":"100 100 420 360 0 0 1800 1130 "})
        prefs.write_bytes(original);(project/"original-production.plist").write_bytes(original)
        database=root/"Library/Application Support/QuickNote/notes.sqlite";database.parent.mkdir(parents=True)
        with sqlite3.connect(database) as c:c.execute("CREATE TABLE content(text TEXT)");c.execute("INSERT INTO content VALUES('baseline')")
    def phase_preservation(project,app,output,events,text,fixture_changed=False,database_changed=False):
        report=json.loads((output/"localization-flow.json").read_text())
        require(report["passed"] is False,"phase change was incorrectly accepted")
        require(report["fixtureProductionUnchanged"] is (not fixture_changed),"fixture mutation attribution incorrect")
        require(report["productionDataAndPreferencesUnchanged"] is fixture_changed,"full comparison hid restore-only change or rejected fully restored baseline")
        phases=report["productionStateChanges"]
        require(phases["fixtureExecution"]["databaseLogicalChanged"] is database_changed,"database phase change missing")
        if fixture_changed and not database_changed:require(phases["fixtureExecution"]["changedPreferenceKeys"]==["sentinel"],"fixture preference mutation missing")
        if not fixture_changed:require(phases["normalRestore"]["changedPreferenceKeys"]==["NSWindow Frame QuickNoteWindow"],"normal restoration mutation not separated")
        for stage in ("before","after-stop","after-fixture","after"):
            require((output/("production-"+stage+".json")).is_file(),"phase snapshot missing")
            require((output/("production-"+stage+".sql")).is_file(),"private logical SQL dump missing")
            require((output/("production-"+stage+".sql")).stat().st_mode & 0o777 == 0o600,"private SQL dump permissions incorrect")
            import hashlib
            snapshot=json.loads((output/("production-"+stage+".json")).read_text())
            require(hashlib.sha256((output/("production-"+stage+".sql")).read_bytes()).hexdigest()==snapshot["databaseLogicalSHA256"],"logical SQL dump does not match its snapshot hash")
            require((output/("production-"+stage+".plist")).stat().st_mode & 0o777 == 0o600,"private preference dump permissions incorrect")
    run_case("localization distinguishes normal restore frame changes", "workflow",localization_args,phase_preservation,
             {"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_RESTORE_FRAME_CHANGE":"1"},status="failure",setup=production_state_setup)
    for kind in ("preferences","database","preferences-type"):
        run_case("localization rejects covered fixture production "+kind+" mutation", "workflow",localization_args,
                 lambda *args,kind=kind:phase_preservation(*args,fixture_changed=True,database_changed=kind=="database"),
                 {"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_FIXTURE_PRODUCTION_CHANGE":kind,"NATIVE_TEST_RESTORE_COVERS_FIXTURE_CHANGE":"1"},status="failure",setup=lambda *args,kind=kind:production_state_setup(*args,sentinel=False if kind=="preferences-type" else "baseline"))
    def snapshot_failure_restores_running(project,app,output,events,text):
        lifecycle=[e for e in events if e["event"] == "lifecycle"]
        require([e["argv"][0] for e in lifecycle].count("--launch")==1,"snapshot error skipped normal app restoration")
        require((output/"localization-flow.json").is_file(),"cleanup restored app but lost failure report")
        report=json.loads((output/"localization-flow.json").read_text())
        require(report["passed"] is False and report["originalRunningStateRestored"] is True,"snapshot failure restoration not reported")
        require(not [e for e in events if e["event"] in ("write","read")],"fixture launched after failed boundary snapshot")
    run_case("localization snapshot error after stop restores original running app", "workflow",localization_args,
             snapshot_failure_restores_running,{"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_AFTER_STOP_SNAPSHOT_OUTPUT_FAILURE":"1"},status="failure",setup=production_state_setup)
    def partial_snapshot_restores_and_reports(project,app,output,events,text):
        snapshot_failure_restores_running(project,app,output,events,text)
        report=json.loads((output/"localization-flow.json").read_text())
        require(report["fixtureProductionUnchanged"] is False,"partial snapshot was accepted as unchanged")
        for phase in ("normalStop","fixtureExecution"):
            observed=report["productionStateChanges"][phase]
            require(observed["observed"] is False and observed["error"]=="JSONDecodeError","partial snapshot did not retain safe error classification")
    run_case("localization partial snapshot JSON still restores and reports failure", "workflow",localization_args,
             partial_snapshot_restores_and_reports,{"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_PARTIAL_SNAPSHOT_JSON":"1"},status="failure",setup=production_state_setup)
    run_case("localization removes exact isolated SQLite sidecars after success", "workflow",localization_args,
             lambda *args:localization_phases(*args,originally_running=False), {"NATIVE_TEST_WRITE_SIDECARS":"1"})
    run_case("localization removes exact isolated SQLite sidecars after failure", "workflow",localization_args,
             lambda *args:localization_phases(*args,wanted_phases=("write",),originally_running=False,success=False),
             {"NATIVE_TEST_WRITE_SIDECARS":"1","NATIVE_TEST_WRITE_STATUS":"7"},status="failure")
    for label, override in (("SKIP",{"NATIVE_TEST_SKIP":"1"}), ("INCONCLUSIVE",{"NATIVE_TEST_INCONCLUSIVE":"1"}),
                            ("FAIL despite final PASS",{"NATIVE_TEST_FALSE_PASS":"1"}), ("nonzero",{"NATIVE_TEST_WRITE_STATUS":"7"}),
                            ("missing PASS",{"NATIVE_TEST_WRITE_MARKER":"none"})):
        run_case("localization rejects "+label+" and restores", "workflow",localization_args,
                 lambda *args:localization_phases(*args,wanted_phases=("write",),success=False),
                 dict(override,NATIVE_TEST_INITIAL_RUNNING="1"),status="failure")
    def persistent_cleanup(project,app,output,events,text):
        localization_phases(project,app,output,events,text,wanted_phases=("write",),success=False)
        import hashlib
        suite="QuickNote.Verification.App."+hashlib.sha256(str(output/"notes.sqlite").encode()).hexdigest()
        owned=Path.home()/"Library/Preferences"/(suite+".plist")
        require(not owned.exists() and not owned.is_symlink(), "failed fixture's real isolated preference file leaked")
        observed=json.loads((output/"preferences-after-cleanup.json").read_text())
        require(observed["suite"] == suite and observed["path"] == str(owned) and observed["preferencesFileAbsent"], "exact preference file cleanup not recorded")
    run_case("localization failed fixture removes actual isolated preference values", "workflow",localization_args,persistent_cleanup,
             {"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_WRITE_SUITE":"1","NATIVE_TEST_WRITE_STATUS":"7"},status="failure")

    def restore_failure(project,app,output,events,text):
        report=json.loads((output/"localization-flow.json").read_text())
        require(not report["passed"] and not report["originalRunningStateRestored"], "failed restore was reported as passing")
        require(report["isolatedPreferencesRemoved"], "restore failure skipped isolated preference cleanup")
    run_case("localization failed normal relaunch fails report", "workflow",localization_args,restore_failure,
             {"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_RESTORE_FAILURE":"1"},status="failure")
    for signal_name, requested, status in (("TERM", signal.SIGTERM, 143), ("INT", signal.SIGINT, 130)):
        run_case("localization "+signal_name+" cleans fixture and restores original app", "workflow",localization_args,
                 lambda *args:localization_phases(*args,wanted_phases=("write",),success=False),
                 # Localization also restores production snapshots and the original running state.
                 # Exercise that bounded cleanup with a deliberately slower lifecycle service.
                 {"NATIVE_TEST_INITIAL_RUNNING":"1","NATIVE_TEST_DELAY_SECONDS":"60",
                  "NATIVE_TEST_LIFECYCLE_DELAY_SECONDS":"0.4"},status=status,requested_signal=requested,cleanup_timeout=10)

    def foreign_app(project,app,output,events,text):
        require([e["argv"][0] for e in events if e["event"] == "lifecycle"] == ["--inspect"], "foreign same-ID app was acted on")
        require(not any(e["event"] in ("write","read") for e in events), "foreign app refusal still launched fixture")
    run_case("localization foreign same-ID app rejected before mutation", "workflow",localization_args,foreign_app,
             {"NATIVE_TEST_FOREIGN_APP":"1"},status="failure")

    def workflow_phases(project, app, output, events, text, phases=("write", "read"), appearance="native"):
        require([event["event"] for event in events] == list(phases), "wrong workflow phase order or unexpected builder")
        for event in events:
            args = ["--verify-workflow"] + (["--standard-appearance"] if appearance == "standard" else [])
            args += (["--read-back"] if event["event"] == "read" else []) + ["--database", str(output / "notes.sqlite")]
            require(event["argv"] == args, "native phase did not use exact isolated database argv")
        require((output / "expected.json").read_bytes() == b'{"fixture":"original oracle"}\n', "workflow modified or lost original expected.json oracle")
        require((output / "write.log").is_file(), "write log not retained")
        require((output / "phases.log").is_file(), "phase argv/exit evidence not retained")
        evidence = (output / "phases.log").read_text()
        for event in events:
            phase = "write" if event["event"] == "write" else "read-back"
            require("phase=" + phase in evidence, "phase identity evidence missing")
            require("pid=" + str(event["pid"]) in evidence, "owned phase PID evidence missing")
            require("exit=" in evidence, "phase exit evidence missing")
            for value in [str(app / "Contents/MacOS/QuickNote"), str(output / "notes.sqlite")]:
                escaped = subprocess.check_output(["/bin/zsh", "-c", 'printf "%q" "$1"', "fixture", value], text=True)
                require(escaped in evidence, "phase actual shell-escaped argv evidence missing")
            actual_argv = [str(app / "Contents/MacOS/QuickNote")] + event["argv"]
            escaped_argv = subprocess.check_output(["/bin/zsh", "-c", 'printf "%q " "$@"', "fixture"] + actual_argv, text=True)
            require("phase=" + phase + " argv=" + escaped_argv in evidence.splitlines(),
                    "phase log did not preserve the complete actual fixture argv")
        if "read" in phases:
            require((output / "relaunch.log").is_file(), "read-back log not retained")
        else:
            require(not (output / "relaunch.log").exists(), "failed write started read-back phase")

    run_case("workflow prebuilt write and read complete", "workflow", standard_args, workflow_phases)
    run_case("workflow prebuilt empty output allowed", "workflow", standard_args, workflow_phases, setup=lambda p, a, o: o.mkdir())
    def skip_phases(*items):
        workflow_phases(*items)
        output = items[2]
        for phase_log in ("write.log", "relaunch.log"):
            require("SKIP: fixture physical input permission unavailable" in (output / phase_log).read_text(), "SKIP permission evidence lost")
    run_case("workflow permission SKIP evidence retained", "workflow", standard_args, skip_phases, {"NATIVE_TEST_SKIP": "1"})
    for label, overrides, phases in (("workflow write nonzero fails before read", {"NATIVE_TEST_WRITE_STATUS": "31"}, ("write",)),
                                    ("workflow write missing final PASS fails before read", {"NATIVE_TEST_WRITE_MARKER": "none"}, ("write",)),
                                    ("workflow read nonzero fails", {"NATIVE_TEST_READ_STATUS": "32"}, ("write", "read")),
                                    ("workflow read missing final PASS fails", {"NATIVE_TEST_READ_MARKER": "none"}, ("write", "read"))):
        run_case(label, "workflow", standard_args, lambda *items, wanted=phases: workflow_phases(*items, phases=wanted), overrides, status="failure")
    for label, flags in (("workflow free args rejected", ["--", "--database", "user.sqlite"]),
                         ("workflow unknown flag rejected", ["--normal"]),
                         ("workflow duplicate app rejected", ["--app", "/duplicate.app"]),
                         ("workflow duplicate output rejected", ["--output", "/duplicate-output"])):
        run_case(label, "workflow", lambda p, a, o, extra=flags: standard_args(p, a, o) + extra, no_native, status="failure")
    run_case("workflow wrong ID rejected before native", "workflow", standard_args, no_native, status="failure", setup=wrong_id)
    run_case("workflow old output rejected before native", "workflow", standard_args, no_native, status="failure", setup=old_output)

    # Appearance is a fixture presentation choice, not arbitrary app arguments.
    # Observe both the recorder's workflow command and real fake-App phase argv.
    for appearance in ("native", "standard"):
        run_case("runner appearance " + appearance + " exact argv", "runner",
                 lambda p, a, o, value=appearance: standard_args(p, a, o) + ["--appearance", value],
                 lambda *items, value=appearance: runner_success(*items, appearance=value))
        run_case("workflow appearance " + appearance + " both phases exact argv", "workflow",
                 lambda p, a, o, value=appearance: standard_args(p, a, o) + ["--appearance", value],
                 lambda *items, value=appearance: workflow_phases(*items, appearance=value))
    for entry in ("runner", "workflow"):
        for label, flags in (("duplicate rejected", ["--appearance", "native", "--appearance", "standard"]),
                             ("missing value rejected", ["--appearance"]),
                             ("empty value rejected", ["--appearance", ""]),
                             ("option as value rejected", ["--appearance", "--output", "/unused"])):
            run_case(entry + " appearance " + label, entry,
                     lambda p, a, o, extra=flags: standard_args(p, a, o) + extra,
                     no_native, status="failure")
    run_case("workflow appearance invalid rejected", "workflow",
             lambda p, a, o: standard_args(p, a, o) + ["--appearance", "dark"], no_native, status="failure")

    def signal_cleanup(project, app, output, events, text):
        require([event["event"] for event in events] == ["write"], "signal scenario started wrong phases")
        require((output / "write.log").is_file(), "interrupted phase log lost")
        evidence = (output / "phases.log").read_text()
        require("pid=" + str(events[0]["pid"]) in evidence, "signal cleanup lacks owned PID evidence")
        require("signal" in evidence.lower(), "signal cleanup evidence missing")
        require(not (output / "relaunch.log").exists(), "signal scenario launched read-back")

    run_case("workflow TERM cleans owned PID only", "workflow", standard_args, signal_cleanup,
             {"NATIVE_TEST_DELAY_SECONDS": "60"}, status=143, requested_signal=signal.SIGTERM)
    run_case("workflow INT cleans owned PID only", "workflow", standard_args, signal_cleanup,
             {"NATIVE_TEST_DELAY_SECONDS": "60"}, status=130, requested_signal=signal.SIGINT)
    run_case("workflow stubborn owned PID cleanup bounded", "workflow", standard_args, signal_cleanup,
             {"NATIVE_TEST_DELAY_SECONDS": "60", "NATIVE_TEST_IGNORE_TERM": "1"}, status=143, requested_signal=signal.SIGTERM)


    def cache_snapshot(project):
        cache = project / ".build"
        if not cache.exists():
            return []
        return sorted((str(item.relative_to(cache)), "dir" if item.is_dir() else "file") for item in cache.rglob("*"))

    def cache_setup(cache_name, relation, alias):
        def setup(project, app, output):
            cache = project / ".build" / cache_name
            actual = project / ".build" if relation == "ancestor" else cache
            actual.mkdir(parents=True)
            chosen = actual
            if alias:
                chosen = project / "canonical cache alias"
                chosen.symlink_to(actual, target_is_directory=True)
            if relation == "inside":
                chosen = chosen / "nested evidence"
            (project / "chosen-output.txt").write_text(str(chosen))
            (project / "cache-before.json").write_text(json.dumps(cache_snapshot(project)))
        return setup

    def overlap_args(project, app, output):
        return ["--app", str(app), "--output", (project / "chosen-output.txt").read_text()]

    def overlap_rejected(project, app, output, events, text):
        require(not events, "overlapping output reached compiler/recorder before rejection")
        initial = json.loads((project / "cache-before.json").read_text())
        require([list(item) for item in cache_snapshot(project)] == initial, "overlap rejection mutated compiler/cache output")

    for cache_name in ("native-verification", "VerificationEvidenceModuleCache"):
        for relation in ("equal", "inside", "ancestor"):
            for alias in (False, True):
                label = f"regression cache overlap {cache_name} {relation}" + (" canonical alias" if alias else "")
                run_case(label, "runner", overlap_args, overlap_rejected, status="failure",
                         setup=cache_setup(cache_name, relation, alias))
    run_case("regression independent empty output control", "runner", standard_args, runner_success,
             setup=lambda p, a, o: o.mkdir())
    run_case("regression duplicate help rejected", "runner", lambda *items: ["--help", "--help"], no_native, status="failure")
    run_case("regression spawned phase log failure cleans owned PID", "workflow", standard_args,
             lambda p, a, o, events, text: require(not (o / "relaunch.log").exists(), "phase log failure launched read-back"),
             {"NATIVE_TEST_DELAY_SECONDS": "60", "NATIVE_TEST_FAIL_PID_LOG": "1"}, status="failure", inject_log_failure=True)
    def stubborn_log_cleanup(project, app, output, events, text):
        require("fixture-term-ignored-ready" in text, "fixture TERM-ignore handler was not installed before log failure")
        require(not (output / "relaunch.log").exists(), "phase log failure launched read-back")
    run_case("regression stubborn spawned phase log failure cleans owned PID", "workflow", standard_args,
             stubborn_log_cleanup,
             {"NATIVE_TEST_DELAY_SECONDS": "60", "NATIVE_TEST_FAIL_PID_LOG": "1", "NATIVE_TEST_IGNORE_TERM": "1"},
             status="failure", inject_log_failure=True)

print(f"{passed} passed, {failed} failed; fake compiler/recorder/App only, spaced project paths, foreign cwd")
if passed + failed == 0:
    sys.exit("No test case matched --case-name")
sys.exit(1 if failed else 0)
PYTHON
