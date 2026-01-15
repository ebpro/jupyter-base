"""Per-feature checker for `typescript`.

Uses GitHub tags/releases to determine the latest TypeScript version and marks
the tool as architecture-independent (`noarch`).
"""
from __future__ import annotations

from typing import Optional
import requests
import semver


GITHUB_API = "https://api.github.com"


def github_latest_tag(owner_repo: str, token: Optional[str] = None) -> str | None:
    url = f"{GITHUB_API}/repos/{owner_repo}/tags"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code != 200:
        return None
    try:
        tags = r.json() or []
    except Exception:
        return None
    if not tags:
        return None
    names = [t.get("name") for t in tags if t.get("name")]
    semvers = []
    for n in names:
        try:
            semv = semver.VersionInfo.parse(n.lstrip("v"))
            semvers.append((semv, n))
        except Exception:
            continue
    if semvers:
        semvers.sort(key=lambda x: x[0], reverse=True)
        return semvers[0][1]
    return names[0]


def check_version(info: dict | str, github_token: Optional[str] = None) -> dict:
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    owner_repo = "microsoft/TypeScript"
    latest = github_latest_tag(owner_repo, github_token)
    upgradable = False
    reason = None
    if latest and current:
        if latest.lstrip("v") != str(current).lstrip("v"):
            upgradable = True
            reason = "tag_compare"

    return {
        "name": "typescript",
        "current": current,
        "latest": latest,
        "upgradable": upgradable,
        "reason": reason,
        "available_arches": ["noarch"],
    }
