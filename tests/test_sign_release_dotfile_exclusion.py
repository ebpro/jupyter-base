"""Static + executable contract test for the `sign-release` job in ci-publish.yml.

Regression pin for the phantom ref the v1.3.41 tag run enumerated:
`ghcr.io/ebpro/solen:.gitkeep-v1.3.41` (32 refs, one of them this). `solen
list profiles` is a plain file listing of `generated/profiles`
(`solen-cli/solen/cli.py:62`), and `generated/profiles/.gitkeep` is the one
tracked file in that directory — so the profile/slug enumeration hands the
signing loop a dotfile entry that is not a profile.

The job is now KEYLESS (no key, no soft-skip), so the contract is pinned the
same way as before — by EXECUTING the job's own signing script over a stubbed
`solen` — but observed at the cosign boundary instead of at the old
"No cosign key present, skipping signing for <ref>" branch (that branch is
gone by design): stub `docker`/`sha256sum`/`cosign` record every digest ref
cosign is asked to sign, and the assertion is that the ref set is exactly the
real profiles (index + per-arch children), never the dotfile.
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


def _run_signing(profile_lines):
    """Runs the job's OWN signing script over stubbed tooling.

    `profile_lines` is the exact stdout of `solen list profiles` (one entry
    per line; may contain dotfile and blank lines). The stubs close the loop
    at the cosign boundary:

      * `docker` — echoes its LAST argument (the ref) as the "manifest
        bytes", so each ref flows into the (stub) digest verbatim;
      * `sha256sum` — wraps the input in `stub-digest-of-<input>`, keeping
        the ref recoverable out of the digest;
      * `cosign` — appends every non-flag argument (the digest ref) to
        `cosign-calls.log` and exits 0.

    Returns ``(cosign_refs, rc, stderr)`` where `cosign_refs` is the list of
    digest refs cosign was invoked with (filtered to this image).
    """
    script_src = _sign_script()
    with tempfile.TemporaryDirectory() as td:
        bin_dir = Path(td, "bin")
        bin_dir.mkdir()
        stubs = {
            "solen": (
                "#!/usr/bin/env bash\n"
                + "".join(f"printf '%s\\n' {shlex.quote(line)}\n" for line in profile_lines)
            ),
            "docker": "#!/usr/bin/env bash\nprintf '%s' \"${@: -1}\"\n",
            "sha256sum": (
                "#!/usr/bin/env bash\n"
                "input=\"$(cat)\"\n"
                "printf 'stub-digest-of-%s -\\n' \"$input\"\n"
            ),
            "cosign": (
                "#!/usr/bin/env bash\n"
                "for a in \"$@\"; do\n"
                "  case \"$a\" in\n"
                "    -*) ;;\n"
                "    *) printf '%s\\n' \"$a\" >> cosign-calls.log ;;\n"
                "  esac\n"
                "done\n"
            ),
        }
        for name, src in stubs.items():
            stub = bin_dir / name
            stub.write_text(src)
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
        log = Path(td) / "cosign-calls.log"
        all_calls = log.read_text().splitlines() if log.exists() else []
        cosign_refs = [
            ln for ln in all_calls if ln.startswith(f"{REPO}/{IMAGE_NAME}@")
        ]
    return cosign_refs, r.returncode, r.stderr


class TestSignReleaseRefEnumeration:
    def test_dotfile_and_blank_entries_are_excluded_from_signing_refs(self):
        # The profile source directory carries a tracked dotfile
        # (generated/profiles/.gitkeep); the v1.3.41 run enumerated it as
        # `ghcr.io/ebpro/solen:.gitkeep-v1.3.41`.
        refs, rc, stderr = _run_signing(["minimal", "", ".gitkeep", "quarto-full"])
        assert rc == 0, f"signing block died: rc={rc} {stderr!r}"
        assert not any(".gitkeep" in ref for ref in refs), (
            "a dotfile entry was enumerated as a signing ref — cosign would "
            f"be invoked for {REPO}/{IMAGE_NAME}:.gitkeep-{TAG} and fail the "
            "release"
        )
        assert refs == [
            f"{REPO}/{IMAGE_NAME}@sha256:stub-digest-of-{REPO}/{IMAGE_NAME}:{p}-{TAG}{suffix}"
            for p in ("minimal", "quarto-full")
            for suffix in ("", "-amd64", "-arm64")
        ], (
            f"expected exactly the two real profiles (dotfile and blank lines "
            f"excluded), each signed by digest for the index and both per-arch "
            f"children, got {refs!r}"
        )
