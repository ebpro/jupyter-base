"""Per-feature checker for `scout` using GitHub Releases of docker/scout-cli."""
from __future__ import annotations

from typing import Optional
import requests


def github_latest_release(owner_repo: str, token: Optional[str] = None) -> dict | None:
    url = f"https://api.github.com/repos/{owner_repo}/releases/latest"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        return r.json()
    return None


def detect_arches_from_assets(release_json: dict) -> list[str]:
    assets = release_json.get("assets", []) if release_json else []
    found = set()
    for a in assets:
        name = (a.get("name") or "").lower()
        if "arm64" in name or "aarch64" in name:
            found.add("arm64")
        if "amd64" in name or "x86_64" in name or "x64" in name:
            found.add("amd64")
    return sorted(found)


def check_version(info: dict | str, github_token: Optional[str] = None) -> dict:
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    owner_repo = "docker/scout-cli"
    rel = github_latest_release(owner_repo, github_token)
    latest = None
    available_arches: list[str] = []
    reason = None
    if rel:
        latest = rel.get("tag_name")
        available_arches = detect_arches_from_assets(rel)
        reason = "github_latest"

    upgradable = False
    if latest and current and str(latest).lstrip("v") != str(current).lstrip("v"):
        upgradable = True

    if upgradable and available_arches and not {"amd64", "arm64"}.issubset(set(available_arches)):
        upgradable = False
        reason = "missing_arches"

    return {
        "name": "scout",
        "current": current,
        "latest": latest,
        "upgradable": upgradable,
        "reason": reason,
        "available_arches": available_arches,
    }
