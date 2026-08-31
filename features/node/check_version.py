from __future__ import annotations

from typing import Optional
import requests
import semver
import re


def get_node_index(token: Optional[str] = None):
    # Node publishes index.json with release metadata
    url = "https://nodejs.org/dist/index.json"
    r = requests.get(url, timeout=15)
    if r.status_code != 200:
        return []
    return r.json()


def infer_arches_from_files(files: list[str]) -> list[str]:
    found = set()
    for f in files:
        fn = f.lower()
        if any(tok in fn for tok in ("linux-x64", "x64", "x86_64")):
            found.add("amd64")
        if any(tok in fn for tok in ("linux-arm64", "arm64", "aarch64")):
            found.add("arm64")
        if any(tok in fn for tok in ("headers", "src")):
            found.add("noarch")
    return sorted(found)


def normalize(tag: Optional[str]) -> Optional[str]:
    if not tag:
        return None
    m = re.search(r"(\d+(?:\.\d+){1,3})", str(tag))
    if not m:
        return str(tag).lstrip("v")
    s = m.group(1)
    if s.count('.') == 1:
        s = s + '.0'
    return s.lstrip("v")


def check_version(info, github_token: Optional[str] = None) -> dict:
    if isinstance(info, str):
        current = info
    else:
        current = info.get("version")

    index = get_node_index(github_token)
    # find latest stable (ignore -rc)
    latest = None
    latest_files = []
    for entry in index:
        v = entry.get("version")
        if not v:
            continue
        if any(x in v.lower() for x in ("-rc", "-nightly", "-alpha", "-beta")):
            continue
        latest = v
        latest_files = entry.get("files", []) or []
        break

    res = {"name": "node", "current": current, "latest": latest, "available_arches": []}
    if not latest:
        res.update({"upgradable": False, "reason": "no_stable_found"})
        return res

    # infer arches from files list
    arches = infer_arches_from_files(latest_files)
    res["available_arches"] = arches

    # compare versions
    try:
        curn = normalize(current)
        latn = normalize(latest)
        curv = semver.VersionInfo.parse(curn)
        latv = semver.VersionInfo.parse(latn)
        res.update({"upgradable": latv > curv, "reason": "semver_compare", "normalized_current": curn, "normalized_latest": latn})
    except Exception:
        res.update({"upgradable": current != latest, "reason": "string_compare"})

    # require both arches
    if res.get("upgradable"):
        if not {"amd64", "arm64"}.issubset(set(arches)):
            res.update({"upgradable": False, "reason": "missing_arches", "note": f"available_arches={arches}; require amd64+arm64 for auto-bump"})

    return res

