from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
import re
from typing import Optional

import requests
import yaml
import semver


GITHUB_API = "https://api.github.com"


def load_versions(path: Path) -> dict:
    text = path.read_text()
    return yaml.safe_load(text)


def github_latest_release_non_prerelease(owner_repo: str, token: Optional[str] = None) -> Optional[str]:
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


def is_prerelease_tag(tag: Optional[str]) -> bool:
    if not tag:
        return False
    t = str(tag).lower()
    return bool(re.search(r"[-._]?(?:rc|alpha|beta|preview|pre|prerelease)[.\-\d]*", t))


def github_latest_tag(owner_repo: str, token: Optional[str] = None, tag_regex: Optional[str] = None, ignore_prereleases: bool = True) -> Optional[str]:
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
        tags = r.json() or []
        if not tags:
            break
        for t in tags:
            n = t.get("name")
            if not n:
                continue
            if tag_regex and not re.match(tag_regex, n):
                continue
            if ignore_prereleases and is_prerelease_tag(n):
                # skip prerelease tags when requested
                continue
            names.append(n)
        if len(tags) < 100:
            break
        page += 1

    if not names:
        # no stable tags found (after optional filtering)
        return None

    # extract semver-like fragments
    def extract_semver_from_tag(tag: str) -> Optional[str]:
        m = re.search(r"(\d+(?:\.\d+){1,3})", tag)
        if not m:
            return None
        s = m.group(1)
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

    return names[0]


def detect_arches_from_assets(release_json: dict) -> list[str]:
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


def normalize_tag(tag: Optional[str]) -> Optional[str]:
    if not tag:
        return None
    s_tag = str(tag)
    # detect semver-like numeric fragment
    m = re.search(r"(\d+(?:\.\d+){1,3})", s_tag)
    if m:
        s = m.group(1)
        if s.count('.') == 1:
            s = s + '.0'
        return s.lstrip("v")
    # fallback: strip leading 'v' if present and return the remainder
    return s_tag.lstrip("v")


def is_prerelease_tag(tag: Optional[str]) -> bool:
    if not tag:
        return False
    t = str(tag).lower()
    # common prerelease identifiers
    return bool(re.search(r"[-._]?(?:rc|alpha|beta|preview|pre|prerelease)[.\-\d]*", t))


def compare_versions(current: Optional[str], latest: Optional[str]) -> dict:
    result = {
        "current": current,
        "latest": latest,
        "upgradable": False,
        "reason": None,
        "normalized_current": None,
        "normalized_latest": None,
        "latest_is_prerelease": False,
    }

    if not latest:
        result["reason"] = "no_latest_found"
        return result

    # preserve raw latest and detect prerelease
    result["latest_is_prerelease"] = is_prerelease_tag(latest)

    # normalize values
    cur_norm = normalize_tag(current) if current else None
    lat_norm = normalize_tag(latest)
    result["normalized_current"] = cur_norm
    result["normalized_latest"] = lat_norm

    # If latest looks like a prerelease, don't auto-bump by default
    if result["latest_is_prerelease"]:
        result["reason"] = "latest_is_prerelease"
        result["upgradable"] = False
        return result

    if not current:
        result["upgradable"] = True
        result["reason"] = "no_current_version"
        return result

    # Try semver compare when possible
    try:
        curv = semver.VersionInfo.parse(cur_norm)
        latv = semver.VersionInfo.parse(lat_norm)
        result["upgradable"] = latv > curv
        result["reason"] = "semver_compare"
        return result
    except Exception:
        # not semver-comparable
        pass

    # If normalization didn't produce a numeric-semver, require manual review
    if not re.search(r"\d+\.\d+", str(lat_norm)):
        result["reason"] = "requires_manual_review"
        result["upgradable"] = False
        return result

    # fallback string compare
    result["upgradable"] = cur_norm != lat_norm
    result["reason"] = "string_compare"
    return result


def run_check(repo_root: Path, versions_path: Path, out_dir: Path, github_token: Optional[str] = None) -> dict:
    data = load_versions(versions_path)
    tools = data.get("tools", {})
    report = {"checked_at": datetime.utcnow().isoformat() + "Z", "tools": []}

    for name, info in tools.items():
        if isinstance(info, str):
            current = info
            sources = []
        elif isinstance(info, dict):
            current = info.get("version")
            sources = info.get("sources", []) or []
        else:
            current = None
            sources = []

        # per-feature hook in repo_root/features/<name>/check_version.py
        hook_path = repo_root / 'features' / name / 'check_version.py'
        if hook_path.exists():
            try:
                import runpy

                ns = runpy.run_path(str(hook_path))
                if "check_version" in ns and callable(ns["check_version"]):
                    hook_res = ns["check_version"](info if info is not None else {}, github_token)
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
                    latest = github_latest_release_non_prerelease(repo, github_token)
                    # try full release for assets
                    try:
                        url = f"{GITHUB_API}/repos/{repo}/releases/latest"
                        headers = {"Accept": "application/vnd.github.v3+json"}
                        if github_token:
                            headers["Authorization"] = f"token {github_token}"
                        r = requests.get(url, headers=headers, timeout=15)
                        rel = r.json() if r.status_code == 200 else None
                    except Exception:
                        rel = None
                    if rel:
                        available_arches = detect_arches_from_assets(rel)
                    else:
                        tag = github_latest_tag(repo, github_token)
                        if tag:
                            latest = tag
                            available_arches = []
                    break

        result = compare_versions(current, latest)
        result.update({"name": name, "github_repo": found_github, "available_arches": available_arches})
        # If latest is a prerelease tag, try to find a stable tag; otherwise skip
        if latest and is_prerelease_tag(latest):
            try:
                stable_tag = github_latest_tag(found_github, github_token, ignore_prereleases=True) if found_github else None
            except Exception:
                stable_tag = None
            if stable_tag:
                # replace latest with the stable tag we found
                result = compare_versions(current, stable_tag)
                result.update({"name": name, "github_repo": found_github, "available_arches": available_arches})
            else:
                # no stable found; mark as no latest found to force manual review
                result = {"current": current, "latest": None, "upgradable": False, "reason": "no_stable_found", "name": name, "github_repo": found_github, "available_arches": available_arches}
        if result.get("upgradable"):
            required = {"amd64", "arm64"}
            if not required.issubset(set(available_arches)):
                result["upgradable"] = False
                result["reason"] = "missing_arches"
                result["note"] = f"available_arches={available_arches}; require amd64+arm64 for auto-bump"

        report["tools"].append(result)

    out_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    out_path = out_dir / f"version-check-{ts}.json"
    out_path.write_text(json.dumps(report, indent=2))
    return {"report_path": str(out_path), "summary": report}


def propagate_versions(repo_root: Path, versions_path: Path, write: bool = False) -> dict:
    """Propagate versions from a central `versions.json` into feature `feature.json` files.

    For each feature under `repo_root/features`, if the feature exposes
    `options.version.default`, try to map a tool key from `versions.json` and
    update the default value. Returns a report with changes.
    """
    data = load_versions(versions_path)
    tools = data.get("tools", {}) or {}

    features_dir = repo_root / 'features'
    report = {"checked_at": datetime.utcnow().isoformat() + 'Z', "updates": []}

    if not features_dir.exists():
        return {"error": "features directory not found", "report": report}

    def candidate_keys(feature_name: str, feature_id: Optional[str]) -> list[str]:
        keys = []
        if feature_id:
            keys.append(feature_id)
            keys.append(feature_id.replace('-', ''))
        keys.append(feature_name)
        keys.append(feature_name.replace('-', ''))
        return [k.lower() for k in keys if k]

    # helper to find best match in versions.tools
    def find_tool_key(feature_name: str, feature_id: Optional[str]) -> Optional[str]:
        cands = candidate_keys(feature_name, feature_id)
        tools_keys = list(tools.keys())
        # exact matches first
        for c in cands:
            for tk in tools_keys:
                if tk.lower() == c:
                    return tk
        # substring / normalized match
        norm_map = {tk.lower().replace('-', ''): tk for tk in tools_keys}
        for c in cands:
            nc = c.replace('-', '')
            if nc in norm_map:
                return norm_map[nc]
        # fallback: check if any tool key is contained in id/name
        for tk in tools_keys:
            if tk.lower() in (feature_name.lower() or ''):
                return tk
            if feature_id and tk.lower() in (feature_id.lower() or ''):
                return tk
        return None

    for feat_dir in sorted([p for p in features_dir.iterdir() if p.is_dir()]):
        feature_json = feat_dir / 'feature.json'
        if not feature_json.exists():
            continue
        try:
            j = json.loads(feature_json.read_text(encoding='utf-8'))
        except Exception:
            report['updates'].append({"feature": feat_dir.name, "error": "invalid_json"})
            continue

        feature_id = j.get('id')
        # look for options.version.default
        opts = j.get('options') or {}
        ver_opt = opts.get('version') if isinstance(opts, dict) else None
        if not ver_opt or not isinstance(ver_opt, dict):
            # nothing to propagate for this feature
            continue

        current_default = ver_opt.get('default')
        tool_key = find_tool_key(feat_dir.name, feature_id)
        if not tool_key:
            report['updates'].append({"feature": feat_dir.name, "matched": None})
            continue

        tool_val = tools.get(tool_key)
        # support both string entries and dict entries in versions.json
        if isinstance(tool_val, dict):
            new_default = tool_val.get('version') or tool_val.get('value')
        else:
            new_default = tool_val

        # nothing to do if no value found
        if new_default is None:
            report['updates'].append({"feature": feat_dir.name, "matched": tool_key, "new": None})
            continue

        if str(current_default) != str(new_default):
            # apply update
            if write:
                # modify and persist
                j.setdefault('options', {})
                j['options'].setdefault('version', {})
                j['options']['version']['default'] = new_default
                try:
                    feature_json.write_text(json.dumps(j, indent=2, ensure_ascii=False), encoding='utf-8')
                    report['updates'].append({"feature": feat_dir.name, "matched": tool_key, "old": current_default, "new": new_default, "written": True})
                except Exception as e:
                    report['updates'].append({"feature": feat_dir.name, "matched": tool_key, "old": current_default, "new": new_default, "written": False, "error": str(e)})
            else:
                report['updates'].append({"feature": feat_dir.name, "matched": tool_key, "old": current_default, "new": new_default, "written": False})
        else:
            report['updates'].append({"feature": feat_dir.name, "matched": tool_key, "old": current_default, "new": new_default, "written": False, "note": "no_change"})

    return report
