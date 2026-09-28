#!/usr/bin/env python3
"""Downloads real third-party extensions for the compatibility report (CI only).

Writes <out>/sources.json listing, per extension: key, name, version, source URL, file, sha256,
or downloadError. A failed download is recorded, never fatal: the compat suite then reports that
extension as "untested (download failed)" instead of guessing.

Sources:
  - GitHub releases (latest at run time; the resolved tag and asset are recorded):
      Dark Reader           darkreader/darkreader        asset *chrome-mv3*.zip
      uBlock Origin Lite    uBlockOrigin/uBOL-home       asset *chromium*.zip
      Violentmonkey         violentmonkey/violentmonkey  asset Violentmonkey-mv3-*.zip (MV3 Chrome build;
                            the *webext* asset is the MV2 build)
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
import urllib.error
import urllib.request
import zipfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "compat"
GITHUB = [
    ("darkreader", "Dark Reader", "darkreader/darkreader", r"chrome-mv3.*\.zip$|mv3.*chrome.*\.zip$"),
    ("ubol", "uBlock Origin Lite", "uBlockOrigin/uBOL-home", r"chromium.*\.zip$"),
    ("violentmonkey", "Violentmonkey", "violentmonkey/violentmonkey", r"^Violentmonkey-mv3-.*\.zip$"),
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
    edge = edge_download_probe()
    print("edge download probe:", json.dumps(edge))
    with open(os.path.join(OUT, "edge-download-probe.json"), "w") as f:
        json.dump(edge, f, indent=2)
    probe = violentmonkey_mv3_probe()
    print("violentmonkey MV3 probe:", json.dumps(probe))
    with open(os.path.join(OUT, "sources.json"), "w") as f:
        json.dump(sources, f, indent=2)
    with open(os.path.join(OUT, "violentmonkey-mv3-probe.json"), "w") as f:
        json.dump(probe, f, indent=2)


def edge_download_probe():
    """Where does the Edge Add-ons package endpoint redirect to, and does the HTTPS form of that
    URL serve the same package? (The app upgrades the redirect to HTTPS before falling back.)"""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    url = ("https://edge.microsoft.com/extensionwebstorebase/v1/crx?response=redirect&prodversion=138.0.0.0"
           "&x=id%3Deeagobfjdenkkddmbclomhiblgggliao%26installsource%3Dondemand%26uc")
    result = {}
    try:
        opener = urllib.request.build_opener(NoRedirect)
        try:
            opener.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60)
            result["redirect"] = None
        except urllib.error.HTTPError as e:
            result["status"] = e.code
            result["redirect"] = e.headers.get("Location")
        target = result.get("redirect") or ""
        result["redirectScheme"] = target.split(":", 1)[0] if target else None
        if target.startswith("http://"):
            https = "https://" + target[len("http://"):]
            try:
                data = get(https)
                result["httpsUpgrade"] = {"ok": data[:4] == b"Cr24", "bytes": len(data)}
            except Exception as e:
                result["httpsUpgrade"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    except Exception as e:
        result["error"] = f"{type(e).__name__}: {e}"
    return result


def violentmonkey_mv3_probe():
    """Evidence for "does an MV3 Violentmonkey build exist for Chrome/Edge?": reads the manifest of
    the Chrome Web Store / Edge Add-ons packages and of every zip asset in the last 15 GitHub
    releases (prereleases included). Rikugan does not add MV2 support; this only records facts."""
    found = []
    stores = [("chrome-web-store", "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=138.0.0.0"
               "&acceptformat=crx2,crx3&x=id%3Djinjaccalgkegednnccohejagnlnfdag%26installsource%3Dondemand%26uc"),
              ("edge-addons", "https://edge.microsoft.com/extensionwebstorebase/v1/crx?response=redirect&prodversion=138.0.0.0"
               "&x=id%3Deeagobfjdenkkddmbclomhiblgggliao%26installsource%3Dondemand%26uc")]
    for label, url in stores:
        try:
            data = get(url)
            version, mv = manifest_version(data)
            found.append({"source": label, "version": version, "manifestVersion": mv})
        except Exception as e:
            found.append({"source": label, "error": f"{type(e).__name__}: {e}"})
    try:
        releases = json.loads(get("https://api.github.com/repos/violentmonkey/violentmonkey/releases?per_page=15", "application/vnd.github+json"))
        downloads = 0
        for release in releases:
            for asset in release.get("assets", []):
                if not asset["name"].lower().endswith(".zip") or asset.get("size", 0) > 8_000_000 or downloads >= 12:
                    continue
                downloads += 1
                try:
                    version, mv = manifest_version(get(asset["browser_download_url"]))
                    found.append({"source": "github", "tag": release["tag_name"], "prerelease": release.get("prerelease"),
                                  "asset": asset["name"], "version": version, "manifestVersion": mv})
                except Exception as e:
                    found.append({"source": "github", "tag": release["tag_name"], "asset": asset["name"], "error": f"{type(e).__name__}: {e}"})
    except Exception as e:
        found.append({"source": "github", "error": f"{type(e).__name__}: {e}"})
    mv3 = [f for f in found if f.get("manifestVersion") == 3]
    return {"mv3BuildFound": bool(mv3), "mv3": mv3, "checked": found}


if __name__ == "__main__":
    main()
