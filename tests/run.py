#!/usr/bin/env python3
"""Run process-control checks with a disposable process tree and isolated Dozor state."""
from pathlib import Path
import sys
import os
import signal
import ctypes
import subprocess
import tempfile

source = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='dozor-checks-') as temporary:
    root = Path(temporary)
    (root / 'state').mkdir()
    core = (source / 'Core.swift').read_text()
    a = core.index('let supportDir: URL = {')
    b = core.index('let configURL', a)
    core = core[:a] + 'let supportDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOZOR_TEST_STATE"]!)\n' + core[b:]
    (root / 'Core.swift').write_text(core)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / 'module-cache'), DOZOR_TEST_STATE=str(root / 'state'))
    subprocess.run(['clang', str(source / 'tests/fixture.c'), '-o', str(root / 'dozor-test-worker')], check=True, env=env)
    subprocess.run(['swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos13.0',
                    str(source / 'tests/main.swift'), str(source / 'tests/ServicesTests.swift'), str(source / 'tests/RouteGuardTests.swift'), str(source / 'tests/ProfileTests.swift'), str(source / 'tests/DecisionHistoryTests.swift'), str(source / 'DecisionHistory.swift'),
                    str(source / 'Telegram.swift'), str(source / 'ReleaseUpdates.swift'), str(source / 'AppUpdate.swift'), str(root / 'Core.swift'), str(source / 'ProcessGuard.swift'),
                    str(source / 'IncyTunnel.swift'), str(source / 'Monitor.swift'), str(source / 'Watchdog.swift'), str(source / 'ProtectionStatus.swift'), str(source / 'FilterController.swift'), str(source / 'Filter/FlowPolicy.swift'), str(source / 'UI.swift'), '-o', str(root / 'verify'),
                    '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'Charts',
                    '-framework', 'Network', '-framework', 'SystemConfiguration'], check=True, env=env)
    subprocess.run(['clang', '-O2', '-Wall', '-Werror', '-DDOZOR_TEST_BUILD', str(source / 'GuardedLaunch.c'), '-o', str(root / 'dozor-run')], check=True, env=env)
    verifier = subprocess.Popen([str(root / 'verify')], env=env, start_new_session=True)
    try:
        if verifier.wait(timeout=60) != 0:
            raise RuntimeError(f"fixture verifier exited with {verifier.returncode}")
    finally:
        # Foundation may give fixture children their own process group. Never
        # walk the host table: validate only PIDs reported in this test directory.
        if verifier.poll() is None:
            verifier.kill()
        verifier.wait()
        fixture_path = os.fsencode((root/'dozor-test-worker').resolve())
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        for record in (root/'state').glob('*/level*.pid'):
            try:
                pid = int(record.read_text())
                path = ctypes.create_string_buffer(4096)
                if pid > 1 and libc.proc_pidpath(pid, path, len(path)) > 0 and os.path.realpath(path.value) == fixture_path:
                    os.kill(pid, signal.SIGKILL)
            except (ValueError, ProcessLookupError):
                pass
    subprocess.run([sys.executable, str(source / 'tests/network.py'), str(root / 'dozor-run'), str(root / 'verify')], check=True, env=env, timeout=40)

    subprocess.run([sys.executable, str(source / "tests/watchdog.py")], check=True, env=env, timeout=90)

    subprocess.run([sys.executable, str(source / "tests/update.py"), str(root / "verify")], check=True, env=env, timeout=90)
