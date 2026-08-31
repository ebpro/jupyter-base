"""Per-feature checker for `kubectl`.

Uses GitHub releases/tags for `kubernetes/kubernetes` and inspects release
assets for arch presence (e.g., linux-amd64, linux-arm64).
"""
from __future__ import annotations

from typing import Optional
import requests
import semver


GITHUB_API = "https://api.github.com"


def github_latest_release_full(owner_repo: str, token: Optional[str] = None) -> dict | None:
    url = f"{GITHUB_API}/repos/{owner_repo}/releases/latest"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        return r.json()
    return None


def detect_arches_from_assets(release_json: dict) -> list[str]:
    if not release_json:
        return []
    assets = release_json.get("assets", [])
    found = set()
    for a in assets:
        name = (a.get("name") or "").lower()
        if any(tok in name for tok in ("linux-arm64", "arm64", "aarch64")):
            found.add("arm64")
        if any(tok in name for tok in ("linux-amd64", "amd64", "x86_64")):
            found.add("amd64")
    return sorted(found)


def check_version(info: dict | str, github_token: Optional[str] = None) -> dict:
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    owner_repo = "kubernetes/kubernetes"
    rel = github_latest_release_full(owner_repo, github_token)
    latest = rel.get("tag_name") if rel else None
    available_arches = detect_arches_from_assets(rel)

    upgradable = False
    reason = None
    if latest and current:
        try:
            curv = semver.VersionInfo.parse(str(current).lstrip("v"))
            latv = semver.VersionInfo.parse(str(latest).lstrip("v"))
            upgradable = latv > curv
            reason = "semver_compare"
        except Exception:
            if latest.lstrip("v") != str(current).lstrip("v"):
                upgradable = True
                reason = "string_compare"

    # require amd64+arm64 for auto-bump
    if upgradable and available_arches and not {"amd64", "arm64"}.issubset(set(available_arches)):
        upgradable = False
        reason = "missing_arches"

    return {
        "name": "kubernetes-client",
        "current": current,
        "latest": latest,
        "upgradable": upgradable,
        "reason": reason,
        "available_arches": available_arches,
    }
