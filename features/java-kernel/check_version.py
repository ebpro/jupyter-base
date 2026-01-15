"""Per-feature checker for `java-kernel`.

This hook reads `features/java-kernel/feature.json` defaults (ARTIFACTS_BASE_URL, KERNEL_VERSION,
ARTEFACT_URL) and checks upstream GitHub releases (if the artifacts URL points to GitHub) to
determine the latest stable kernel and whether an upgrade is available. It follows the
feature's installation method by respecting configured artifact URLs.

Contract: provide `check_version(info: dict, github_token: Optional[str]) -> dict`.
Returned dict must include keys: name, current, latest, upgradable, reason, available_arches (optional).
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

import requests


FEATURE_DIR = Path(__file__).resolve().parent


def load_feature_options() -> dict:
    f = FEATURE_DIR / "feature.json"
    if not f.exists():
        return {}
    return json.loads(f.read_text())


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


def check_version(info: dict, github_token: Optional[str] = None) -> dict:
    # info may be the versions.yaml entry (string or dict)
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    opts = load_feature_options().get("options", {})
    artifacts_base = opts.get("ARTIFACTS_BASE_URL", {}).get("default") if isinstance(opts.get("ARTIFACTS_BASE_URL"), dict) else None
    artefact_url = opts.get("ARTEFACT_URL", {}).get("default") if isinstance(opts.get("ARTEFACT_URL"), dict) else None
    kernel_version_default = opts.get("KERNEL_VERSION", {}).get("default") if isinstance(opts.get("KERNEL_VERSION"), dict) else None

    # Prefer explicit artefact URL if provided; otherwise use ARTIFACTS_BASE_URL
    target_url = artefact_url or artifacts_base
    latest = None
    available_arches = []
    reason = None

    if target_url and "github.com" in target_url:
        # try to extract owner/repo from URL
        # expected form: https://github.com/owner/repo/releases
        parts = target_url.split("github.com/")[-1].split("/")
        if len(parts) >= 2:
            owner_repo = "/".join(parts[0:2])
            rel = github_latest_release(owner_repo, github_token)
            if rel:
                latest = rel.get("tag_name")
                available_arches = detect_arches_from_assets(rel)
                reason = "github_latest"

    # If no latest found, fall back to default kernel version from feature.json
    if not latest and kernel_version_default:
        latest = kernel_version_default
        reason = reason or "default_from_feature"

    upgradable = False
    if latest and current:
        if str(latest).lstrip("v") != str(current).lstrip("v"):
            upgradable = True

    # If available_arches detected, require amd64+arm64 for auto-upgrade
    if upgradable and available_arches:
        if not {"amd64", "arm64"}.issubset(set(available_arches)):
            upgradable = False
            reason = "missing_arches"

    return {
        "name": "java-kernel",
        "current": current,
        "latest": latest,
        "upgradable": upgradable,
        "reason": reason,
        "available_arches": available_arches,
    }
