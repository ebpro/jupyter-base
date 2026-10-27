"""Static contract test: the `sign-release` job in ci-publish.yml is KEYLESS.

Before this change the job signed with provisioned cosign key material
(`secrets.COSIGN_PRIVATE_KEY` + `secrets.COSIGN_PASSWORD`) and SOFT-SKIPPED
the whole signing loop whenever the key was absent ("No cosign key present,
skipping signing for <ref>") — a v* tag release could go green with ZERO
signatures published ("vacuous green"), and no verify step existed at all.

The contract pinned here (static, over the parsed workflow YAML):

  (a) permissions — the JOB carries a job-level permissions block granting
      `id-token: write` (keyless OIDC token mint) AND `packages: write`
      (signature-manifest push to GHCR). Job-level permissions OVERRIDE the
      workflow-level block, so the grant must live on the job itself.
  (b) no key, no secrets — no COSIGN_PASSWORD / COSIGN_KEY /
      COSIGN_PRIVATE_KEY / "Prepare cosign key" / cosign.key anywhere in the
      job, and zero `secrets.` references: the default GITHUB_TOKEN (via the
      `github.token` expression) provides both the OIDC identity and the
      ghcr push.
  (c) digest-pinned keyless sign — `cosign sign --yes` against `@sha256:`
      refs (never tags, never key-based), covering the multi-arch index AND
      both per-arch children for every profile.
  (d) hard-failing verify — a `cosign verify` step pinned to
      `--certificate-oidc-issuer https://token.actions.githubusercontent.com`
      and `--certificate-identity-regexp`; no `|| true`, no
      `continue-on-error`, no step-level conditional skip anywhere in the job.
  (e) meaningful gate — the identity regexp provably MATCHES the real GHA
      keyless certificate identity
      `https://github.com/<owner>/<repo>/.github/workflows/<file>@<ref>` for
      this repo + this workflow on a v* tag, and REJECTS other repos, other
      workflows, and non-tag refs. A regex that never matches is a vacuous
      red; one that matches anything is a vacuous green.
"""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"

JOB = "sign-release"
SIGN_STEP = "Sign solen release indexes"
VERIFY_STEP = "Verify release signatures (hard gate)"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
REPO = "ebpro/jupyter-base"
WORKFLOW_FILE = "ci-publish.yml"


def _doc():
    # PyYAML parses the `on:` key as boolean True; only `jobs` is needed here.
    return yaml.safe_load(PUBLISH.read_text())


def _job():
    jobs = _doc()["jobs"]
    assert JOB in jobs, f"job {JOB!r} missing from ci-publish.yml"
    return jobs[JOB]


def _step(name):
    for step in _job()["steps"]:
        if step.get("name") == name and step.get("run"):
            return step["run"]
    raise AssertionError(f"step {name!r} with a run block missing from {JOB}")


def _job_dump():
    """The whole job re-serialized: every string value (run blocks, env,
    expressions) in one searchable blob."""
    return yaml.safe_dump(_job(), sort_keys=False)


def _exec_lines(run):
    """Executable lines of a run block (comments excluded) — the soft-skip
    and invocation assertions target real commands, not prose."""
    return [ln for ln in run.splitlines() if not ln.lstrip().startswith("#")]


# ---------------------------------------------------------------------------
# (a) keyless permissions
# ---------------------------------------------------------------------------

class TestKeylessPermissions:
    def test_job_level_permissions_grant_oidc_and_packages(self):
        perms = _job().get("permissions")
        assert isinstance(perms, dict), (
            "sign-release needs a JOB-LEVEL permissions block: job-level "
            "permissions override the workflow-level one, so the keyless "
            "grant must live on the job itself"
        )
        assert perms.get("id-token") == "write", (
            "id-token: write is required for the keyless OIDC token mint"
        )
        assert perms.get("packages") == "write", (
            "packages: write is required for GITHUB_TOKEN to push the "
            "signature manifests to GHCR"
        )


# ---------------------------------------------------------------------------
# (b) no key material, no secrets
# ---------------------------------------------------------------------------

class TestNoKeyNoSecrets:
    def test_no_cosign_key_material_anywhere_in_job(self):
        dump = _job_dump()
        for token in (
            "COSIGN_PASSWORD",
            "COSIGN_KEY",
            "COSIGN_PRIVATE_KEY",
            "Prepare cosign key",
            "cosign.key",
        ):
            assert token not in dump, (
                f"{token!r} must not survive in the keyless job"
            )

    def test_job_reads_zero_secrets(self):
        assert "secrets." not in _job_dump(), (
            "the keyless job must read NO secrets at all — the default "
            "GITHUB_TOKEN (github.token expression) provides both the OIDC "
            "identity and the ghcr push"
        )


# ---------------------------------------------------------------------------
# (c) digest-pinned keyless sign
# ---------------------------------------------------------------------------

class TestDigestPinnedKeylessSign:
    def test_sign_is_keyless_and_digest_pinned(self):
        exec_text = "\n".join(_exec_lines(_step(SIGN_STEP)))
        assert "--key" not in exec_text, "no key-based signing may remain"
        m = re.search(r"^\s*cosign sign[^\n]*", exec_text, re.M)
        assert m, "the sign step must invoke cosign sign"
        assert "--yes" in m.group(0), (
            "cosign sign must be non-interactive (--yes)"
        )
        assert "@sha256:" in m.group(0), (
            "cosign sign must target a digest ref, never a tag — signing by "
            "tag could bind a different manifest than the released one"
        )

    def test_sign_covers_index_and_both_per_arch_children(self):
        run = _step(SIGN_STEP)
        for tag in ('"${sign_tag}"', '"${sign_tag}-amd64"', '"${sign_tag}-arm64"'):
            assert tag in run, f"the signing loop must cover {tag}"


# ---------------------------------------------------------------------------
# (d) hard-failing verify
# ---------------------------------------------------------------------------

class TestHardFailingVerify:
    def test_verify_pins_oidc_issuer_and_identity_regexp(self):
        run = _step(VERIFY_STEP)
        assert "cosign verify" in run
        assert f"--certificate-oidc-issuer {OIDC_ISSUER}" in run, (
            "verify must pin the GHA Fulcio issuer"
        )
        assert "--certificate-identity-regexp" in run, (
            "verify must pin the signer identity regexp — without it cosign "
            "accepts ANY keyless signature"
        )

    def test_no_soft_skip_anywhere_in_job(self):
        for step in _job()["steps"]:
            name = step.get("name")
            assert not step.get("continue-on-error"), (
                f"step {name!r} must not be continue-on-error"
            )
            assert not step.get("if"), (
                f"step {name!r} must not be conditionally skipped — the only "
                "gate is the job-level v* tag gate"
            )
            run = step.get("run") or ""
            assert "|| true" not in run, (
                f"step {name!r} swallows a failure (|| true)"
            )
        dump = _job_dump()
        assert "skipping signing" not in dump
        assert "No cosign key" not in dump


# ---------------------------------------------------------------------------
# (e) the identity regexp is a meaningful gate
# ---------------------------------------------------------------------------

def _identity_regexp():
    """The verify step's identity regexp, materialized for this repo.

    The workflow interpolates `${GITHUB_REPOSITORY}` at runtime; here we
    substitute the literal repo so the pattern can be exercised with Python's
    re (the pattern is plain RE2, so the semantics match cosign's Go re2).
    """
    run = _step(VERIFY_STEP)
    m = re.search(r'identity_regexp="([^"]*)"', run)
    assert m, "the verify step must define identity_regexp"
    raw = m.group(1).replace("${GITHUB_REPOSITORY}", REPO)
    # Bash double-quote unescape — the only escape the pattern uses: \\ -> \
    return raw.replace("\\\\", "\\")


class TestIdentityRegexpIsMeaningful:
    # The documented GHA keyless certificate identity for THIS workflow on
    # the v1.3.41 tag (cosign docs:
    # https://github.com/<owner>/<repo>/.github/workflows/<file>@<ref>).
    REAL_IDENTITY = (
        f"https://github.com/{REPO}/.github/workflows/{WORKFLOW_FILE}"
        "@refs/tags/v1.3.41"
    )

    def test_regexp_matches_the_real_gha_keyless_identity(self):
        pattern = _identity_regexp()
        assert re.match(pattern, self.REAL_IDENTITY), (
            f"the verify gate would reject EVERY legitimate signature: "
            f"pattern {pattern!r} does not match the real GHA identity "
            f"{self.REAL_IDENTITY!r} — a vacuous red"
        )

    def test_regexp_rejects_other_repos_workflows_and_non_tag_refs(self):
        pattern = _identity_regexp()
        for bad in (
            # another repo's run of the same workflow
            f"https://github.com/evil/{REPO.split('/')[1]}/.github/workflows/{WORKFLOW_FILE}@refs/tags/v1.3.41",
            # this repo, a different workflow
            f"https://github.com/{REPO}/.github/workflows/ci-build.yml@refs/tags/v1.3.41",
            # this repo + workflow, a branch ref (not a release tag)
            f"https://github.com/{REPO}/.github/workflows/{WORKFLOW_FILE}@refs/heads/develop",
            # the shape the pre-review design proposed — NOT the real GHA
            # certificate identity; matching it would mean the gate was
            # written against a format that never occurs
            f"https://github.com/{REPO}/refs/tags/v1.3.41",
        ):
            assert not re.match(pattern, bad), (
                f"the verify gate is vacuous: {bad!r} would pass {pattern!r}"
            )
