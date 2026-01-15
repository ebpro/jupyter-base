from __future__ import annotations

from typing import Optional
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
        repo = "moby/moby"

    latest, arches = get_latest_stable_release(repo, github_token)
    res = {"name": "docker-ce", "current": current, "latest": latest, "available_arches": arches}
    if latest is None:
        res.update({"upgradable": False, "reason": "no_stable_found"})
        return res

    try:
        curn = normalize(current)
        latn = normalize(latest)
        curv = semver.VersionInfo.parse(curn) if curn else None
        latv = semver.VersionInfo.parse(latn)
        up = (curv is None) or (latv > curv)
        res.update({"upgradable": up, "reason": "semver_compare", "normalized_current": curn, "normalized_latest": latn})
    except Exception:
        res.update({"upgradable": current != latest, "reason": "string_compare"})

    if res.get("upgradable"):
        if not {"amd64", "arm64"}.issubset(set(arches)):
            res.update({"upgradable": False, "reason": "missing_arches", "note": f"available_arches={arches}; require amd64+arm64 for auto-bump"})

    return res
import requests
import re
import semver


def _extract_semver(tag: str) -> str | None:
    m = re.search(r"v?(\d+(?:\.\d+){1,3})", tag)
    import requests
    import re
    import semver


    def _extract_semver(tag: str) -> str | None:
        m = re.search(r"v?(\d+(?:\.\d+){1,3})", tag)
        if not m:
            return None
        s = m.group(1)
        if s.count('.') == 1:
            s = s + '.0'
        return s


    def check_version(info: dict, github_token: str | None = None) -> dict:
        """Per-feature hook for docker-ce.

        The `moby/moby` repo contains many non-semver tags (e.g. xdocs-...).
        This hook filters tags to numeric semver-like names and picks the
        highest semver as the upstream latest.
        """
        current = None
        if isinstance(info, dict):
            current = info.get("version")
        elif isinstance(info, str):
            current = info

        owner_repo = None
        # try to obtain repo from provided sources
        if isinstance(info, dict):
            sources = info.get("sources", []) or []
            for s in sources:
                if isinstance(s, dict) and s.get("type") == "github" and s.get("repo"):
                    owner_repo = s.get("repo")
                    break
        if not owner_repo:
            owner_repo = "moby/moby"

        headers = {"Accept": "application/vnd.github.v3+json"}
        if github_token:
            headers["Authorization"] = f"token {github_token}"

        semver_pairs = []
        page = 1
        try:
            while True:
                r = requests.get(f"https://api.github.com/repos/{owner_repo}/tags", headers=headers, params={"per_page": 100, "page": page}, timeout=15)
                if r.status_code != 200:
                    break
                tags = r.json() or []
                if not tags:
                    break
                for t in tags:
                    n = t.get("name")
                    if not n:
                        continue
                    sv = _extract_semver(n)
                    if not sv:
                        continue
                    try:
                        v = semver.VersionInfo.parse(sv)
                        semver_pairs.append((v, n))
                    except Exception:
                        continue
                if len(tags) < 100:
                    break
                page += 1
        except Exception:
            pass

        latest = None
        if semver_pairs:
            semver_pairs.sort(key=lambda x: x[0], reverse=True)
            latest = semver_pairs[0][1]

        upgradable = False
        reason = None
        if latest:
            # compare with current
            try:
                cur = _extract_semver(str(current))
                if cur:
                    curv = semver.VersionInfo.parse(cur)
                    latv = semver.VersionInfo.parse(_extract_semver(latest))
                    upgradable = latv > curv
                    reason = "semver_compare"
            except Exception:
                upgradable = False
                reason = "compare_failed"
        else:
            reason = "no_semver_tags_found"

        return {
            "name": "docker-ce",
            "current": current,
            "latest": latest,
            "upgradable": upgradable,
            "reason": reason,
            "note": f"tracked_repo={owner_repo}",
        }
import requests
