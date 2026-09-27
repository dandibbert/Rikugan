#!/usr/bin/env python3
"""Downloads real third-party extensions for the compatibility report (CI only).

Writes <out>/sources.json listing, per extension: key, name, version, source URL, file, sha256,
or downloadError. A failed download is recorded, never fatal: the compat suite then reports that
extension as "untested (download failed)" instead of guessing.

Sources:
  - GitHub releases (latest at run time; the resolved tag and asset are recorded):
      Dark Reader           darkreader/darkreader        asset *chrome-mv3*.zip
      uBlock Origin Lite    uBlockOrigin/uBOL-home       asset *chromium*.zip
      Violentmonkey         violentmonkey/violentmonkey  asset *webext*.zip (Chrome build)
  - Chrome Web Store CRX (current version, read from the manifest after download):
      Tampermonkey          dhdgffkkebhmkfjojejmpbldmpobfkfo
      Immersive Translate   bpoadfkcbjbfhfodiogcnhhhpibjhbnh
"""
import hashlib
import io
import json
import os
import re
import sys
import urllib.request
import zipfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "compat"
GITHUB = [
    ("darkreader", "Dark Reader", "darkreader/darkreader", r"chrome-mv3.*\.zip$|mv3.*chrome.*\.zip$"),
    ("ubol", "uBlock Origin Lite", "uBlockOrigin/uBOL-home", r"chromium.*\.zip$"),
    ("violentmonkey", "Violentmonkey", "violentmonkey/violentmonkey", r"webext.*\.zip$"),
]
CWS = [
    ("tampermonkey", "Tampermonkey", "dhdgffkkebhmkfjojejmpbldmpobfkfo"),
    ("immersive-translate", "Immersive Translate", "bpoadfkcbjbfhfodiogcnhhhpibjhbnh"),
]
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"


def get(url, accept=None):
    headers = {"User-Agent": UA}
    if accept:
        headers["Accept"] = accept
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        headers["Authorization"] = "Bearer " + token
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
        return r.read()


def manifest_version(package):
    data = package
    if data[:4] == b"Cr24":  # CRX3: magic, version, header length, header, zip
        header_len = int.from_bytes(data[8:12], "little")
        data = data[12 + header_len:]
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        name = next(n for n in z.namelist() if n.endswith("manifest.json") and n.count("/") <= 1)
        manifest = json.loads(z.read(name).decode("utf-8-sig"))
        return manifest.get("version"), manifest.get("manifest_version")


def save(key, data, ext):
    name = f"{key}.{ext}"
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)
    return name, hashlib.sha256(data).hexdigest()


def main():
    os.makedirs(OUT, exist_ok=True)
    sources = []
    for key, name, repo, pattern in GITHUB:
        entry = {"key": key, "name": name}
        try:
            release = json.loads(get(f"https://api.github.com/repos/{repo}/releases/latest", "application/vnd.github+json"))
            asset = next((a for a in release["assets"] if re.search(pattern, a["name"], re.I)), None)
            if asset is None:
                raise RuntimeError(f"no asset matching {pattern} in {release['tag_name']}: " + ", ".join(a["name"] for a in release["assets"]))
            data = get(asset["browser_download_url"])
            entry["file"], entry["sha256"] = save(key, data, "zip")
            version, mv = manifest_version(data)
            entry.update(version=version or release["tag_name"], source=asset["browser_download_url"], tag=release["tag_name"], manifestVersion=mv)
        except Exception as e:  # recorded, not fatal
            entry["downloadError"] = f"{type(e).__name__}: {e}"
        sources.append(entry)
        print(key, entry.get("version"), entry.get("downloadError", "ok"))
    for key, name, ext_id in CWS:
        url = ("https://clients2.google.com/service/update2/crx?response=redirect&prodversion=138.0.0.0"
               f"&acceptformat=crx2,crx3&x=id%3D{ext_id}%26installsource%3Dondemand%26uc")
        entry = {"key": key, "name": name, "source": f"https://chromewebstore.google.com/detail/{ext_id}"}
        try:
            data = get(url)
            if data[:4] != b"Cr24":
                raise RuntimeError(f"not a CRX ({len(data)} bytes)")
            entry["file"], entry["sha256"] = save(key, data, "crx")
            version, mv = manifest_version(data)
            entry.update(version=version, manifestVersion=mv)
        except Exception as e:
            entry["downloadError"] = f"{type(e).__name__}: {e}"
        sources.append(entry)
        print(key, entry.get("version"), entry.get("downloadError", "ok"))
    with open(os.path.join(OUT, "sources.json"), "w") as f:
        json.dump(sources, f, indent=2)


if __name__ == "__main__":
    main()
