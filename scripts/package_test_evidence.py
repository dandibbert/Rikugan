"""Package actual CI results and runnable fixtures, even when tests failed."""
from pathlib import Path
import hashlib
import json
import os
import zipfile

root = Path(__file__).resolve().parents[1]
dist = root / "dist"
dist.mkdir(exist_ok=True)
manifest = {
    "commit": os.environ.get("GITHUB_SHA", "local"),
    "runID": os.environ.get("GITHUB_RUN_ID", "local"),
    "testOutcome": os.environ.get("TEST_OUTCOME", "not-run"),
    "deviceSigning": "unsigned",
    "realDeviceTested": False,
}
with zipfile.ZipFile(dist / "tests.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("manifest.json", json.dumps(manifest, indent=2, sort_keys=True))
    for name in ["TestResults.xcresult", "Tests", "UITests", "TestDiagnostics", "Examples"]:
        for path in sorted((root / name).rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(root))
    for path in sorted((root / "scripts").glob("test_*.cjs")):
        archive.write(path, path.relative_to(root))
    for name in ["build-device.log", "test.log", "webkit-runtime.log", "scripts/fixture_server.py", "project.yml"]:
        path = root / name
        if path.is_file():
            archive.write(path, name)
    fixture = Path("/tmp/rikugan-fixture.log")
    if fixture.is_file():
        archive.write(fixture, "fixture-server.log")

def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

assets = sorted(dist.glob("*.ipa")) + [dist / "tests.zip"]
(dist / "SHA256SUMS.txt").write_text("".join(f"{digest(path)}  {path.name}\n" for path in assets))
print(json.dumps(manifest, indent=2))
