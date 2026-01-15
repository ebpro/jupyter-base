#!/usr/bin/env python3
"""Minimal prototype for checking upstream latest releases for tools.

Usage:
  python3 scripts/check-versions.py --versions versions/versions.yaml

This prototype demonstrates:
- loading a YAML versions file
- checking GitHub "latest release" for entries that expose a github source
- producing a JSON report in generated/version-checks/

Not production-ready: heuristic-only, limited error handling.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    import requests
    import yaml
    import semver
except Exception:
    print("Missing dependency: install 'pyyaml requests semver'", file=sys.stderr)
    sys.exit(2)


GITHUB_API = "https://api.github.com"


def load_versions(path: Path) -> dict:
    text = path.read_text()
    return yaml.safe_load(text)


def github_latest_release(owner_repo: str, token: str | None = None) -> str | None:
    url = f"{GITHUB_API}/repos/{owner_repo}/releases/latest"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        data = r.json()
        return data.get("tag_name")
    return None


def github_latest_release_non_prerelease(owner_repo: str, token: str | None = None) -> str | None:
    """Return the latest non-prerelease release tag when possible.

    Behaviour:
    - Query `/releases/latest`; if it is not a prerelease return its tag.
    - If it is a prerelease, paginate `/releases` and return the first release
      with `prerelease == false`.
    """
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"

    # try /releases/latest first
    url = f"{GITHUB_API}/repos/{owner_repo}/releases/latest"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        data = r.json()
        if not data.get("prerelease", False):
            return data.get("tag_name")

    # fallback: list releases and pick first non-prerelease
    page = 1
    while True:
        url = f"{GITHUB_API}/repos/{owner_repo}/releases"
        params = {"per_page": 100, "page": page}
        r = requests.get(url, headers=headers, params=params, timeout=15)
        if r.status_code != 200:
            break
        items = r.json() or []
        if not items:
            break
        for rel in items:
            if not rel.get("prerelease", False):
                return rel.get("tag_name")
        if len(items) < 100:
            break
        page += 1
    return None


def github_latest_tag(owner_repo: str, token: str | None = None, tag_regex: str | None = None) -> str | None:
    """Fallback: fetch repository tags (paginated) and return the most appropriate tag.

    Behaviour:
    - Paginate `/tags` with `per_page=100` until no results.
    - Try to extract semver-like parts from tag names and pick the highest semver.
    - If no semver-like tags are found, return the first tag returned by the API.
    """
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"

    names: list[str] = []
    page = 1
    while True:
        url = f"{GITHUB_API}/repos/{owner_repo}/tags"
        params = {"per_page": 100, "page": page}
        r = requests.get(url, headers=headers, params=params, timeout=15)
        if r.status_code != 200:
            break
        try:
            tags = r.json() or []
        except Exception:
            break
        if not tags:
            break
        for t in tags:
            n = t.get("name")
            if not n:
                continue
            if tag_regex:
                import re

                if not re.match(tag_regex, n):
                    continue
            names.append(n)
        # if fewer than requested, we've reached the last page
        if len(tags) < 100:
            break
        page += 1

    if not names:
        return None

    # Try to extract semver-like versions from tag names
    def extract_semver_from_tag(tag: str) -> str | None:
        import re

        m = re.search(r"(\d+(?:\.\d+){1,3})", tag)
        if not m:
            return None
        s = m.group(1)
        # if only two components like 0.58 -> pad to 0.58.0
        if s.count('.') == 1:
            s = s + '.0'
        return s

    semver_pairs: list[tuple[semver.VersionInfo, str]] = []
    for n in names:
        sv = extract_semver_from_tag(n)
        if not sv:
            continue
        try:
            v = semver.VersionInfo.parse(sv)
            semver_pairs.append((v, n))
        except Exception:
            continue

    if semver_pairs:
        semver_pairs.sort(key=lambda x: x[0], reverse=True)
        return semver_pairs[0][1]

    # fallback: return first tag seen
    return names[0]


def github_latest_release_full(owner_repo: str, token: str | None = None) -> dict | None:
    """Return full release JSON for latest release, or None."""
    url = f"{GITHUB_API}/repos/{owner_repo}/releases/latest"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    r = requests.get(url, headers=headers, timeout=15)
    if r.status_code == 200:
        return r.json()
    return None


def detect_arches_from_assets(release_json: dict) -> list[str]:
    """Heuristically detect available arches from release assets names.

    Returns subset of ['amd64','arm64'] discovered in asset filenames.
    """
    if not release_json:
        return []
    assets = release_json.get("assets", [])
    found: set[str] = set()
    for a in assets:
        name = (a.get("name") or "").lower()
        if any(tok in name for tok in ("arm64", "aarch64", "linux-arm64")):
            found.add("arm64")
        if any(tok in name for tok in ("amd64", "x86_64", "x64", "linux-amd64")):
            found.add("amd64")
    return sorted(found)


def parse_image_ref(image: str) -> tuple[str, str]:
    """Parse image reference into (registry, repository).

    Examples:
      ghcr.io/owner/repo -> (ghcr.io, owner/repo)
      node -> (registry-1.docker.io, library/node)
      owner/repo -> (registry-1.docker.io, owner/repo)
    """
    if "/" not in image or ("." not in image.split("/", 1)[0] and ":" not in image.split("/", 1)[0]):
        # docker hub short name
        repo = image if "/" in image else f"library/{image}"
        return ("registry-1.docker.io", repo)
    parts = image.split("/", 1)
    registry = parts[0]
    repo = parts[1]
    return (registry, repo)


def parse_www_auth(header: str) -> dict:
    """Parse WWW-Authenticate header for Bearer auth params."""
    # header example: Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/node:pull"
    out = {}
    if not header.lower().startswith("bearer "):
        return out
    rest = header[len("Bearer "):]
    for part in rest.split(','):
        if '=' in part:
            k, v = part.strip().split('=', 1)
            out[k] = v.strip('"')
    return out


def registry_get_manifest(registry: str, repo: str, tag: str = 'latest', session: requests.Session | None = None) -> tuple[int, dict | None, requests.Response | None]:
    """Fetch manifest for repo:tag, handling Bearer token auth if required.

    Returns (status_code, json_payload_or_none, response)
    """
    if session is None:
        session = requests.Session()
    url = f"https://{registry}/v2/{repo}/manifests/{tag}"
    accept = ",".join([
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.index.v1+json",
    ])
    headers = {"Accept": accept}
    r = session.get(url, headers=headers, timeout=15)
    if r.status_code == 401:
        www = r.headers.get('WWW-Authenticate', '')
        auth = parse_www_auth(www)
        realm = auth.get('realm')
        service = auth.get('service')
        scope = auth.get('scope')
        if realm:
            params = {}
            if service:
                params['service'] = service
            if scope:
                params['scope'] = scope
            token_resp = session.get(realm, params=params, timeout=15)
            if token_resp.status_code == 200:
                token = token_resp.json().get('token') or token_resp.json().get('access_token')
                if token:
                    headers['Authorization'] = f"Bearer {token}"
                    r = session.get(url, headers=headers, timeout=15)
    payload = None
    try:
        payload = r.json()
    except Exception:
        payload = None
    return (r.status_code, payload, r)


def detect_arches_from_manifest(registry: str, repo: str, tag: str = 'latest') -> list[str]:
    """Detect architectures from a docker manifest list (registry v2).

    Returns list like ['amd64','arm64'] or empty if unknown.
    """
    code, payload, resp = registry_get_manifest(registry, repo, tag)
    if code != 200 or not payload:
        return []
    # Manifest list contains 'manifests' with platform entries
    manifests = payload.get('manifests') or payload.get('manifests', [])
    found = set()
    if manifests:
        for m in manifests:
            plat = m.get('platform') or {}
            arch = (plat.get('architecture') or '').lower()
            if arch:
                if arch in ('arm64', 'aarch64'):
                    found.add('arm64')
                elif arch in ('amd64', 'x86_64'):
                    found.add('amd64')
                else:
                    found.add(arch)
    else:
        # Not a manifest list; some registries return single manifest - can't deduce multi-arch
        # Try Content-Type header check via resp
        ctype = resp.headers.get('Content-Type', '') if resp is not None else ''
        if 'manifest.list' in ctype or 'index' in ctype:
            # fallback - unknown
            return []
    return sorted(found)


def normalize_tag(tag: str | None) -> str | None:
    if not tag:
        return None
    # extract first semver-like fragment and normalize to semver-compatible string
    import re

    m = re.search(r"(\d+(?:\.\d+){1,3})", str(tag))
    if not m:
        return str(tag).lstrip("v")
    s = m.group(1)
    if s.count('.') == 1:
        s = s + '.0'
    return s.lstrip("v")


def compare_versions(current: str | None, latest: str | None) -> dict:
    result = {"current": current, "latest": latest, "upgradable": False, "reason": None}
    if not latest:
        result["reason"] = "no_latest_found"
        return result
    if not current:
        result["upgradable"] = True
        return result
    cur = normalize_tag(current)
    lat = normalize_tag(latest)
    try:
        curv = semver.VersionInfo.parse(cur)
        latv = semver.VersionInfo.parse(lat)
        result["upgradable"] = latv > curv
        result["reason"] = "semver_compare"
    except Exception:
        # fallback to simple string compare
        result["upgradable"] = cur != lat
        result["reason"] = "string_compare"
    return result


def run_check(versions_path: Path, out_dir: Path, github_token: str | None = None) -> dict:
    data = load_versions(versions_path)
    tools = data.get("tools", {})
    report = {"checked_at": datetime.utcnow().isoformat() + "Z", "tools": []}
    for name, info in tools.items():
        # support scalar or mapping
        if isinstance(info, str):
            current = info
            sources = []
        elif isinstance(info, dict):
            current = info.get("version")
            sources = info.get("sources", []) or []
        else:
            current = None
            sources = []

        # Allow per-feature hook: features/<name>/check_version.py
        hook_path = Path("features") / name / "check_version.py"
        if hook_path.exists():
            try:
                # run hook in isolated namespace; expect function `check_version(info, github_token)`
                import runpy

                ns = runpy.run_path(str(hook_path))
                if "check_version" in ns and callable(ns["check_version"]):
                    hook_res = ns["check_version"](info if info is not None else {}, github_token)
                    # normalize expected keys
                    hook_res.setdefault("name", name)
                    report["tools"].append(hook_res)
                    continue
            except Exception as e:
                report["tools"].append({"name": name, "error": f"hook_error: {e}", "upgradable": False})
                continue

        latest = None
        found_github = None
        available_arches: list[str] = []
        for s in sources:
            if isinstance(s, dict) and s.get("type") == "github":
                repo = s.get("repo")
                if repo:
                    found_github = repo
                    # Prefer GitHub latest release, fall back to tags when missing
                    latest = github_latest_release(repo, github_token)
                    rel = github_latest_release_full(repo, github_token)
                    if rel:
                        available_arches = detect_arches_from_assets(rel)
                    else:
                        # try tags fallback
                        tag = github_latest_tag(repo, github_token)
                        if tag:
                            latest = tag
                            # no release assets available for tag-only entries
                            available_arches = []
                    break

        result = compare_versions(current, latest)
        # If a newer version exists but assets are missing arches, mark for manual review
        result.update({"name": name, "github_repo": found_github, "available_arches": available_arches})
        if result.get("upgradable"):
            required = {"amd64", "arm64"}
            if not required.issubset(set(available_arches)):
                result["upgradable"] = False
                result["reason"] = "missing_arches"
                result["note"] = f"available_arches={available_arches}; require amd64+arm64 for auto-bump"

        report["tools"].append(result)

    # images section: check registry manifests for architecture support
    images = data.get("images", {})
    report["images"] = []
    session = requests.Session()
    for name, info in images.items():
        if isinstance(info, str):
            ref = info
        elif isinstance(info, dict):
            ref = info.get("ref")
        else:
            ref = None
        if not ref:
            continue
        parts = ref.rsplit(':', 1)
        tag = parts[1] if len(parts) == 2 else 'latest'
        image = parts[0]
        registry, repo = parse_image_ref(image)
        arches = detect_arches_from_manifest(registry, repo, tag)
        report["images"].append({"name": name, "ref": ref, "registry": registry, "repo": repo, "tag": tag, "arches": arches})

    out_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    out_path = out_dir / f"version-check-{ts}.json"
    out_path.write_text(json.dumps(report, indent=2))
    return {"report_path": str(out_path), "summary": report}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Minimal versions checker prototype")
    parser.add_argument("--versions", type=Path, default=Path("versions/versions.yaml"))
    parser.add_argument("--out", type=Path, default=Path("generated/version-checks"))
    parser.add_argument("--github-token", default=os.environ.get("GITHUB_TOKEN"))
    args = parser.parse_args(argv)

    if not args.versions.exists():
        print(f"Versions file not found: {args.versions}", file=sys.stderr)
        return 2

    res = run_check(args.versions, args.out, args.github_token)
    print(f"Report written: {res['report_path']}")
    # brief summary
    summary = res["summary"]["tools"]
    for t in summary:
        status = "UPGRADE" if t.get("upgradable") else "OK"
        print(f"{t['name']}: {status} (current={t.get('current')} latest={t.get('latest')})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
