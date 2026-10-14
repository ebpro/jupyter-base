"""Static contract tests for the `verify-published` job in ci-publish.yml.

Item 3 of the publish-hardening set: the publish path must assert the
CONTENT of what it publishes, not just its existence. These tests pin the
design contract of the new job without docker or network:

  * the job exists, depends on merge-index, and runs on the amd64 pool;
  * it executes the already-baked /opt/solen/run-postinstall-checks.sh on
    the published -amd64 tags;
  * its independent binary floor stays a strict subset of the executables
    declared in inputs/apt-packages/base.required (Item 2 corroboration);
  * the rejected design (setting RUN_POSTINSTALL_CHECKS at publish build
    time — it invalidates the cached install layer) can never sneak back
    in: the string must not appear in ci-publish.yml at all;
  * an empty tag enumeration fails loudly (no vacuous pass);
  * failures accumulate instead of failing fast;
  * nothing depends on verify-published — signing is never gated on it.
"""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"
BASE_REQUIRED = ROOT / "inputs" / "apt-packages" / "base.required"

JOB = "verify-published"


def _doc():
    # PyYAML parses the `on:` key as boolean True; only `jobs` is needed here.
    return yaml.safe_load(PUBLISH.read_text())


def _job(name):
    jobs = _doc()["jobs"]
    assert name in jobs, f"job {name!r} missing from ci-publish.yml"
    return jobs[name]


def _run_scripts(job):
    return [step["run"] for step in job["steps"] if step.get("run")]


def _main_verify_script():
    """The step that enumerates tags and docker-runs the checks."""
    for script in _run_scripts(_job(JOB)):
        if "run-postinstall-checks.sh" in script:
            return script
    raise AssertionError(f"no run step of {JOB} references run-postinstall-checks.sh")


class TestJobShape:
    def test_job_exists(self):
        assert JOB in _doc()["jobs"]

    def test_needs_merge_index(self):
        needs = _job(JOB).get("needs") or []
        if isinstance(needs, str):
            needs = [needs]
        assert "merge-index" in needs

    def test_runs_on_amd64_pool(self):
        # Must be the amd64 pool with an explicit x64 label: the arm pool's
        # runners also carry `ebpro-org`, and bare `ebpro-org` could route
        # this job to a host that cannot docker-run -amd64 images.
        runs_on = _job(JOB)["runs-on"]
        assert isinstance(runs_on, list), f"runs-on must pin arch via labels, got {runs_on!r}"
        assert "ebpro-org" in runs_on
        assert "x64" in runs_on
        assert "arm64" not in runs_on

    def test_ghcr_login_present(self):
        # Pulling private-ish GHCR tags requires the login step.
        uses = [step.get("uses", "") for step in _job(JOB)["steps"]]
        assert any("docker/login-action" in u for u in uses)

    def test_bake_generated_for_enumeration(self):
        runs = " ".join(_run_scripts(_job(JOB)))
        assert "solen generate bake" in runs
        assert "--no-build-tag" in runs


class TestContentVerification:
    def test_baked_check_script_executed(self):
        assert "/opt/solen/run-postinstall-checks.sh" in _main_verify_script()

    def test_docker_run_entrypoint_idiom(self):
        script = _main_verify_script()
        assert re.search(
            r"docker run --rm --pull always --entrypoint /opt/solen/run-postinstall-checks\.sh",
            script,
        ), "check script must run via docker run --rm --entrypoint on each tag"

    def test_amd64_suffix_appended(self):
        # Tags are the folded base refs plus the -amd64 member suffix,
        # mirroring merge-index's fold sources.
        assert re.search(r'tags\+=\("\$\{T\}-amd64"\)', _main_verify_script())

    def test_tag_enumeration_reuses_merge_index_idiom(self):
        assert "grep -oE 'ghcr.io/[^\"]+'" in _main_verify_script()

    def test_binary_floor_uses_bash_entrypoint(self):
        script = _main_verify_script()
        assert re.search(r"docker run .*--entrypoint bash", script)

    def test_binary_floor_subset_of_base_required(self):
        script = _main_verify_script()
        m = re.search(r"for b in ([A-Za-z0-9._ -]+); do command -v", script)
        assert m, "binary floor loop `for b in ...; do command -v` not found"
        floor = set(m.group(1).split())
        assert floor, "binary floor must not be empty"
        required = {
            line.strip()
            for line in BASE_REQUIRED.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        }
        assert floor <= required, (
            f"binary floor {sorted(floor - required)} contradicts inputs/apt-packages/base.required"
        )


class TestRejectedDesignLockedOut:
    def test_run_postinstall_checks_never_appears_in_publish(self):
        # Setting RUN_POSTINSTALL_CHECKS at publish build time promotes the
        # ARG to ENV in the install RUN layer, invalidating the heavy job's
        # cache (~60-min cold rebuild) or yielding false assurance. The
        # content check must run against the published artifact instead.
        assert "RUN_POSTINSTALL_CHECKS" not in PUBLISH.read_text(), (
            "RUN_POSTINSTALL_CHECKS must never appear in ci-publish.yml"
        )


class TestNoVacuousPass:
    def test_empty_tag_list_fails_loudly(self):
        script = _main_verify_script()
        m = re.search(r'\$\{#tags\[@\]\}"?\s*-eq\s*0\s*\]; then(.{0,400}?)fi', script, re.DOTALL)
        assert m, "guard against an empty tag enumeration is missing"
        assert "exit 1" in m.group(1), "empty-tag guard must exit non-zero"

    def test_failures_accumulate_not_fail_fast(self):
        script = _main_verify_script()
        assert "failed=1" in script
        assert re.search(r'exit "\$failed"', script), (
            'job must exit with the accumulated status (`exit "$failed"`), '
            "so every tag is tested but one bad tag still fails the job"
        )


class TestGraphIsolation:
    def test_no_job_depends_on_verify_published(self):
        # Leaf job: signing must not be blocked by a verification-harness
        # hiccup, and nothing else may be gated on it.
        for name, job in _doc()["jobs"].items():
            needs = job.get("needs") or []
            if isinstance(needs, str):
                needs = [needs]
            assert JOB not in needs, f"{name} must not need {JOB}"

    def test_sign_release_needs_unchanged(self):
        needs = _doc()["jobs"]["sign-release"].get("needs")
        assert needs == ["merge-index"]

    def test_merge_index_needs_unchanged(self):
        needs = set(_doc()["jobs"]["merge-index"].get("needs"))
        assert needs == {"build-amd64-heavy", "build-amd64-standard", "build-arm64"}

    def test_build_jobs_not_renamed(self):
        jobs = _doc()["jobs"]
        for name in ("build-amd64-standard", "build-amd64-heavy", "build-arm64", "merge-index"):
            assert name in jobs
