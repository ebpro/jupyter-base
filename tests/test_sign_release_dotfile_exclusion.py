"""Static + executable contract test for the `sign-release` job in ci-publish.yml.

Regression pin for the phantom ref the v1.3.41 tag run enumerated:
`ghcr.io/ebpro/solen:.gitkeep-v1.3.41` (32 refs, one of them this). `solen
list profiles` is a plain file listing of `generated/profiles`
(`solen-cli/solen/cli.py:62`), and `generated/profiles/.gitkeep` is the one
tracked file in that directory — so the profile/slug enumeration hands the
signing loop a dotfile entry that is not a profile. Today the job soft-skips
every ref (no `COSIGN_PRIVATE_KEY` provisioned), but once the key exists,
cosign would attempt the nonexistent `.gitkeep-<tag>` ref and fail the
release.

The contract pinned here: the ref-enumeration block must exclude entries
starting with `.` (and blank lines) from the slug list. As in the
verify-published contract tests, the block is the workflow's real text
(sliced, never retyped) and is EXECUTED over a stubbed `solen` whose output
contains a dotfile line and a blank line — the exclusion is asserted by
behaviour, not by pattern-matching the step's text.
"""

import os
import shlex
import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"

JOB = "sign-release"
STEP = "Sign solen release indexes"

# The job's own env (ci-publish.yml: `REPO: ghcr.io/${{ github.repository_owner }}`,
# `IMAGE_NAME: solen`) on the ref the phantom was observed on.
REPO = "ghcr.io/ebpro"
IMAGE_NAME = "solen"
TAG = "v1.3.41"


def _doc():
    # PyYAML parses the `on:` key as boolean True; only `jobs` is needed here.
    return yaml.safe_load(PUBLISH.read_text())


def _job(name):
    jobs = _doc()["jobs"]
    assert name in jobs, f"job {name!r} missing from ci-publish.yml"
    return jobs[name]


def _sign_script():
    """The step that enumerates the release refs and calls cosign on each."""
    for step in _job(JOB)["steps"]:
        if step.get("name") == STEP and step.get("run"):
            return step["run"]
    raise AssertionError(f"step {STEP!r} with a run block missing from {JOB}")


def _run_enumeration(profile_lines):
    """Runs the job's OWN ref-enumeration block over a stubbed `solen`.

    `profile_lines` is the exact stdout of `solen list profiles` (one entry
    per line; may contain dotfile and blank lines). The block runs in a temp
    cwd with NO cosign.key, so the soft-skip branch is taken and every
    enumerated ref is printed as
    `No cosign key present, skipping signing for <ref>` — that printed set is
    exactly the set cosign would attempt once COSIGN_PRIVATE_KEY is
    provisioned. Returns ``(stdout_lines, rc, stderr)``.
    """
    script_src = _sign_script()
    with tempfile.TemporaryDirectory() as td:
        bin_dir = Path(td, "bin")
        bin_dir.mkdir()
        stub = bin_dir / "solen"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            + "".join(f"printf '%s\\n' {shlex.quote(line)}\n" for line in profile_lines)
        )
        stub.chmod(0o755)
        r = subprocess.run(
            ["bash", "-c", script_src],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "REPO": REPO,
                "IMAGE_NAME": IMAGE_NAME,
                "GITHUB_REF": f"refs/tags/{TAG}",
                "HOME": td,
            },
        )
    return r.stdout.splitlines(), r.returncode, r.stderr


class TestSignReleaseRefEnumeration:
    def test_dotfile_and_blank_entries_are_excluded_from_signing_refs(self):
        # The profile source directory carries a tracked dotfile
        # (generated/profiles/.gitkeep); the v1.3.41 run enumerated it as
        # `ghcr.io/ebpro/solen:.gitkeep-v1.3.41`.
        lines, rc, stderr = _run_enumeration(["minimal", "", ".gitkeep", "quarto-full"])
        assert rc == 0, f"enumeration block died: rc={rc} {stderr!r}"
        refs = [
            ln.rsplit(" ", 1)[1]
            for ln in lines
            if ln.startswith("No cosign key present, skipping signing for ")
        ]
        assert f"{REPO}/{IMAGE_NAME}:.gitkeep-{TAG}" not in refs, (
            "a dotfile entry was enumerated as a signing ref — once "
            "COSIGN_PRIVATE_KEY is provisioned, cosign would attempt the "
            f"nonexistent {REPO}/{IMAGE_NAME}:.gitkeep-{TAG} and fail the release"
        )
        assert refs == [
            f"{REPO}/{IMAGE_NAME}:minimal-{TAG}",
            f"{REPO}/{IMAGE_NAME}:quarto-full-{TAG}",
        ], (
            f"expected exactly the two real profiles (dotfile and blank lines "
            f"excluded), got {refs!r}"
        )
