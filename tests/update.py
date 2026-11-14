"""Exercise the installer with disposable bundles and a unique Launch Services ID."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

verify = Path(sys.argv[1])
source = Path(__file__).resolve().parents[1]


def run(*args, **options):
    return subprocess.run(args, check=True, **options)


with tempfile.TemporaryDirectory(prefix="dozor-installer-test-") as temp:
    root = Path(temp).resolve()
    fixture_id = "org.dozor.fixture.x" + uuid.uuid4().hex
    marker = root / "launched"
    program = root / "fixture.c"
    program.write_text('#include <stdio.h>\nint main(void) {FILE *f=fopen(' +
                       json.dumps(str(marker)) + ',"w"); if (!f) return 1; fputs(BUILD,f); return fclose(f);}')
    helper = root / "helper"
    run("swiftc", str(source / "Updater/main.swift"), "-o", helper)

    def bundle(parent, identifier, version):
        app = parent / "Dozor.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        run("clang", program, '-DBUILD="' + version + '"', "-o", macos / "Dozor")
        shutil.copy2(helper, macos / "dozor-update")
        info = dict(CFBundleIdentifier=identifier, CFBundleExecutable="Dozor", CFBundlePackageType="APPL",
                    CFBundleVersion=version, CFBundleShortVersionString=version, LSBackgroundOnly=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run("codesign", "--force", "-s", "-", app)
        return app

    app = bundle(root / "installed", fixture_id, "0.4.0")
    new = bundle(root / "package", "local.dozor", "0.4.1")
    archive = root / "download.zip"
    metadata = root / "release.json"

    def package():
        archive.unlink(missing_ok=True)
        run("ditto", "-c", "-k", "--keepParent", new, archive)
        return dict(name="Dozor-0.4.1-macOS-arm64.zip", size=archive.stat().st_size,
                    digest="sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest())

    def stage(assets, ok):
        metadata.write_text(json.dumps(dict(tag_name="v0.4.1", draft=False, prerelease=False, assets=assets)))
        result = subprocess.run([verify, "update-stage", metadata, archive, app], capture_output=True, text=True)
        assert result.returncode == (0 if ok else 1), result.stderr
        if ok:
            path = Path(result.stdout.strip())
            assert path.parent.parent == app.parent and path.name == app.name
            shutil.rmtree(path.parent)
        assert not list(app.parent.glob(".dozor-update-*"))

    asset = package()
    stage([asset], True)
    stage([], False)
    stage([asset, asset], False)
    stage([dict(asset, digest="sha256:" + "0"*64)], False)
    stage([dict(asset, size=asset["size"]+1)], False)
    resources = new / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    (resources / "unsealed").write_text("modified after signing")
    stage([package()], False)
    for identifier, version in [("org.dozor.wrong", "0.4.1"), ("local.dozor", "0.4.0")]:
        shutil.rmtree(new)
        new = bundle(root / "package", identifier, version)
        stage([package()], False)
    print("PASS: updater checks asset identity, size, SHA-256, bundle identity, version and signature", flush=True)

    # Use an unrelated bundle ID for the actual launch. Never open the installed Dozor.
    staged = bundle(app.parent / ".dozor-update-fixture", fixture_id, "0.4.1")
    run(verify, "update-handoff", staged, app, timeout=10)
    for _ in range(200):
        if marker.exists() and marker.read_text() == "0.4.1" and not staged.parent.exists():
            break
        time.sleep(.1)
    else:
        raise RuntimeError("updated fixture did not launch or backup was not cleaned up")
    print("PASS: real update helper swaps bundles and launches the new fixture at the installed path")
