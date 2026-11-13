#!/usr/bin/env python3
"""Package an already tested macOS app and pin the Homebrew update to its SHA-256."""
import os
import hashlib
import plistlib
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
    raise SystemExit("Expected a stable version such as 0.1 or 0.1.1")
app = Path(os.environ.get("DOZOR_BUILD_DIR", root)) / "Dozor.app"
extension = app / "Contents/Library/SystemExtensions/local.dozor.filter.systemextension"
for bundle in (app, extension):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream)["CFBundleShortVersionString"] != version:
            raise SystemExit("Rebuild the app after changing VERSION")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
dist = root / "dist"
dist.mkdir(exist_ok=True)
archive = dist / f"Dozor-{version}-macOS-arm64.zip"
subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(app), str(archive)], check=True)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(dist / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
template = (root / "scripts/dozor.rb.in").read_text()
(root / "Casks/dozor.rb").write_text(template.replace("@VERSION@",version).replace("@SHA256@",digest))
print(f"{archive.name}  {digest}")
