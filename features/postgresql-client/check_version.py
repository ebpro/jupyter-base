"""Stub per-feature checker for `postgresql`.

PostgreSQL releases are tracked on https://www.postgresql.org/. Implement
this hook to query the official download/release pages or use vendor metadata
to extract the latest minor/major release versions.
"""
from __future__ import annotations

from typing import Optional


def check_version(info: dict | str, github_token: Optional[str] = None) -> dict:
    current = None
    if isinstance(info, str):
        current = info
    elif isinstance(info, dict):
        current = info.get("version")

    return {
        "name": "postgresql-client",
        "current": current,
        "latest": current,
        "upgradable": False,
        "reason": "stub_official_site",
        "available_arches": [],
    }
