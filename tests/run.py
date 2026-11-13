#!/usr/bin/env python3
"""Run process-control checks with a disposable process tree and isolated Dozor state."""
from pathlib import Path
import sys
import os
import signal
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
    subprocess.run(['clang', str(source / 'tests/fixture.c'), '-o', str(root / 'claude')], check=True, env=env)
    subprocess.run(['swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos13.0',
                    str(source / 'tests/main.swift'), str(source / 'tests/ServicesTests.swift'),
                    str(source / 'Telegram.swift'), str(source / 'ReleaseUpdates.swift'), str(root / 'Core.swift'), str(source / 'ProcessGuard.swift'),
                    str(source / 'Monitor.swift'), str(source / 'ProtectionStatus.swift'), str(source / 'FilterController.swift'), str(source / 'Filter/FlowPolicy.swift'), str(source / 'UI.swift'), '-o', str(root / 'verify'),
                    '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'Charts',
                    '-framework', 'Network', '-framework', 'SystemConfiguration'], check=True, env=env)
    subprocess.run(['clang', '-O2', '-Wall', '-Werror', '-DDOZOR_TEST_BUILD', str(source / 'GuardedLaunch.c'), '-o', str(root / 'dozor-run')], check=True, env=env)
    try:
        subprocess.run([str(root / 'verify')], check=True, env=env, timeout=45)
        subprocess.run([sys.executable, str(source / 'tests/network.py'), str(root / 'dozor-run'), str(root / 'verify')], check=True, env=env, timeout=40)
    finally:
        # Clean disposable fixtures even when a Swift assertion terminates the test runner.
        processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
        for line in processes.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1] == str(root / 'claude'):
                try:
                    os.kill(int(parts[0]), signal.SIGKILL)
                except ProcessLookupError:
                    pass
