#!/usr/bin/env python3
"""Build a temporary executable backed by the real singleton/watchdog code; it only writes test markers."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import time

src = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="dozor-watchdog-") as tmp:
    d = Path(tmp)
    app = d / "Fixture.app" / "Contents"
    bins = app / "MacOS"
    bins.mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Dozor", "CFBundleIdentifier": "invalid.dozor.fixture"}))
    (d / "main.swift").write_text("""
import Foundation
import Darwin
let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_STATE"]!)
guard let owner = MonitorInstance(directory: dir, arguments: Array(CommandLine.arguments.dropFirst())) else { exit(0) }
let w = CrashWatchdog()
let executable = URL(fileURLWithPath: CommandLine.arguments[0])
try w.configure(enabled: true, instance: owner, executable: executable)
let marker = dir.appendingPathComponent("run-" + String(owner.attempt))
try String(getpid()).write(to: marker, atomically: true, encoding: .utf8)
while true {
    let mode = try? String(contentsOf: dir.appendingPathComponent("action"), encoding: .utf8)
    if mode == "crash" { raise(SIGKILL) }
    if mode == "off" { try w.configure(enabled: false, instance: owner, executable: executable); _exit(93) }
    if mode == "clean" { w.disarm(owner); exit(0) }
    usleep(10_000)
}
""")
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=os.environ.get("CLANG_MODULE_CACHE_PATH", str(d/"cache")))
    # No lookup or fallback to an installed application.
    target = bins / "Dozor"
    subprocess.run(["swiftc", str(src/"Watchdog/main.swift"), "-o", str(bins/"dozor-watchdog")], env=env, check=True)
    subprocess.run(["swiftc", str(src/"Watchdog.swift"), str(d/"main.swift"), "-o", str(target)], env=env, check=True)
    def run_case(name):
        state = d / name
        state.mkdir()
        runenv = dict(env, FIXTURE_STATE=str(state))
        proc = subprocess.Popen([str(target)], env=runenv)
        def wait(attempt):
            marker = state / f"run-{attempt}"
            limit = time.monotonic()+12
            while time.monotonic()<limit:
                if marker.exists(): return
                if attempt==0 and proc.poll() is not None: raise RuntimeError("did not start")
                time.sleep(.02)
            raise RuntimeError(f"{name}: attempt {attempt} missing")
        try:
            wait(0)
            (state/"action").write_text(name if name in ["clean","off"] else "crash")
            proc.wait(timeout=5)
            if name=="crash":
                for attempt in range(1,4): wait(attempt)
                time.sleep(4.5)
                assert len(list(state.glob("run-*")))==4
            elif name=="replace":
                # Same path but new inode: old helper must leave this update alone.
                import shutil
                replacement=bins/"replacement"
                shutil.copy2(target,replacement)
                replacement.replace(target)
                time.sleep(1.6)
                assert not (state/"run-1").exists()
            elif name=="manual":
                (state/"action").unlink()
                manual=subprocess.Popen([str(target)],env=runenv)
                try:
                    # Let the first recovery timer fire. A simultaneous second open exits.
                    time.sleep(1.6)
                    duplicate=subprocess.run([str(target)],env=runenv,timeout=2)
                    assert duplicate.returncode==0 and manual.poll() is None and not (state/"run-1").exists()
                finally:
                    (state/"action").write_text("clean")
                    manual.wait(timeout=5)
            else:
                time.sleep(1.6)
                assert not (state/"run-1").exists()
            print("PASS: watchdog fixture " + name, flush=True)
        finally:
            (state/"action").write_text("clean")
            if proc.poll() is None: proc.wait(timeout=3)
    for name in ["clean", "off", "crash", "manual", "replace"]: run_case(name)
