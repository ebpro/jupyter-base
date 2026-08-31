import requests
import re


def check_version(info: dict, github_token: str | None = None) -> dict:
    """Per-feature hook for tinytex.

    TinyTeX in this project uses a date-based internal version (YYYY.MM).
    Upstream releases use numeric tags (e.g. v0.58). This hook reports the
    upstream latest tag but marks the entry for manual review due to
    incompatible version schemes.
    """
    current = None
    if isinstance(info, dict):
        current = info.get("version")
    elif isinstance(info, str):
        current = info

    owner_repo = "yihui/tinytex"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if github_token:
        headers["Authorization"] = f"token {github_token}"

    latest = None
    try:
        r = requests.get(f"https://api.github.com/repos/{owner_repo}/releases/latest", headers=headers, timeout=15)
        if r.status_code == 200:
            latest = r.json().get("tag_name")
    except Exception:
        latest = None

    # fallback to tags
    if not latest:
        try:
            r = requests.get(f"https://api.github.com/repos/{owner_repo}/tags", headers=headers, params={"per_page": 100}, timeout=15)
            if r.status_code == 200:
                tags = r.json() or []
                for t in tags:
                    n = t.get("name")
                    if not n:
                        continue
                    # accept semver-like numeric tags
                    if re.search(r"\d+(?:\.\d+){1,3}", n):
                        latest = n
                        break
        except Exception:
            latest = None

    return {
        "name": "tinytex",
        "current": current,
        "latest": latest,
        "upgradable": False,
        "reason": "manual_version_scheme_mismatch",
        "note": f"upstream_tag={latest}",
    }
