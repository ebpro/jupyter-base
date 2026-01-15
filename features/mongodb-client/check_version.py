"""Per-feature checker for `mongodb`.

This uses GitHub tags/releases for `mongodb/mongo` as a best-effort source, but
marks the result for manual review if no artifact arch info is available.
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
    return tags[0].get("name")


def check_version(info: dict | str, github_token: Optional[str] = None) -> dict:
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    owner_repo = "mongodb/mongo"
    latest = github_latest_tag(owner_repo, github_token)

    upgradable = False
    reason = None
    if latest and current:
        if latest.lstrip("v") != str(current).lstrip("v"):
            upgradable = True
            reason = "tag_compare"

    # conservative: require manual review for mongodb because images/binaries handled separately
    if upgradable:
        upgradable = False
        reason = "requires_manual_review"

    return {
        "name": "mongodb-client",
        "current": current,
        "latest": latest,
        "upgradable": upgradable,
        "reason": reason,
        "available_arches": [],
    }
