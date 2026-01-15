from __future__ import annotations

from pathlib import Path
from typing import Optional
import os
import re
import requests
import semver

GITHUB_API = "https://api.github.com"


def infer_arches_from_assets(assets: list[dict]) -> list[str]:
    found = set()
    for a in assets:
        n = (a.get("name") or "").lower()
        if any(tok in n for tok in ("arm64", "aarch64", "linux-arm64")):
            found.add("arm64")
        if any(tok in n for tok in ("amd64", "x86_64", "x64", "linux-amd64")):
            found.add("amd64")
        if any(tok in n for tok in ("noarch", "all", "any")):
            found.add("noarch")
    return sorted(found)


def get_latest_stable_release(owner_repo: str, token: Optional[str]) -> tuple[Optional[str], list[str]]:
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    page = 1
    while True:
        url = f"{GITHUB_API}/repos/{owner_repo}/releases"
        r = requests.get(url, headers=headers, params={"per_page": 100, "page": page}, timeout=15)
        if r.status_code != 200:
            break
        items = r.json() or []
        if not items:
            break
        for rel in items:
            if not rel.get("prerelease") and rel.get("tag_name"):
                tag = rel.get("tag_name")
                arches = infer_arches_from_assets(rel.get("assets", []))
                return tag, arches
        if len(items) < 100:
            break
        page += 1
    return None, []


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
    # info may be string or dict
    if isinstance(info, str):
        current = info
        sources = []
    else:
        current = info.get("version")
        sources = info.get("sources", []) or []

    repo = None
    for s in sources:
        if isinstance(s, dict) and s.get("type") == "github" and s.get("repo"):
            repo = s.get("repo")
            break
    if not repo:
        repo = "docker/cli"

    latest, arches = get_latest_stable_release(repo, github_token)

    res = {"name": "docker", "current": current, "latest": latest, "available_arches": arches}

    if latest is None:
        res.update({"upgradable": False, "reason": "no_stable_found"})
        return res

    # compare
    try:
        curn = normalize(current)
        latn = normalize(latest)
        curv = semver.VersionInfo.parse(curn) if curn else None
        latv = semver.VersionInfo.parse(latn)
        up = (curv is None) or (latv > curv)
        res.update({"upgradable": up, "reason": "semver_compare", "normalized_current": curn, "normalized_latest": latn})
    except Exception:
        res.update({"upgradable": current != latest, "reason": "string_compare"})

    # require both arches for auto-bump
    if res.get("upgradable"):
        if not {"amd64", "arm64"}.issubset(set(arches)):
            res.update({"upgradable": False, "reason": "missing_arches", "note": f"available_arches={arches}; require amd64+arm64 for auto-bump"})

    return res
"""NOTE: moved to `features/docker-cli/check_version.py`.

This file was retained as a pointer to the canonical hook location to avoid
duplicate logic. The active hook is now under `features/docker-cli`.
"""

__all__ = []
