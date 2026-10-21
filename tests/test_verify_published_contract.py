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
   * an unowned bake ref is never dropped silently: it is logged as
     SKIPPED-UNOWNED, and on an unrestricted run a generated profile that owns
     no ref at all fails the job (coverage guard, twin of the vacuous-pass
     guard);
   * failures accumulate instead of failing fast;
  * the selection verifies ONE tag per profile — the bake's three
    digest-identical names per profile are the same artifact, so iterating all
    of them bought no coverage and tripled the pulls and the imagefs churn on
    the disk-constrained amd64 node — and that tag is the immutable
    `<slug>-<sha>` member, never the floating one;
  * nothing depends on verify-published — signing is never gated on it.

Tag selection is asserted by EXECUTING the job's own bash over a synthetic
docker-bake.hcl, not by pattern-matching the step's text.
"""

import re
import subprocess
import tempfile
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


# --- executable harness -----------------------------------------------------
#
# The job's own bash is sliced out of the step and RUN against a synthetic bake,
# so the selection is asserted by behaviour rather than by grep. The anchors are
# the block's own statements, which keeps the same slice valid before and after
# a change to it — that is what makes the red-then-green evidence honest.
_ENUM_START = "compute_slug() {"
_TAGS_END = "# Vacuous-pass guard: zero enumerated tags"

REPO = "ghcr.io/ebpro/solen"

# Not incidental: a hex SHA can never sort after `v1.2.3` or `latest`, but it
# CAN sort after `develop` ('f' > 'd'). Pinning a SHA that loses alphabetically
# means a selection that picks the immutable ref is proving a rule, not
# inheriting `sort -u`'s ordering.
PIN_SHA = "ffee123"


def _refs_for(slugs, sha=PIN_SHA):
    """The three base refs merge-index folds per profile on a develop push
    (`solen-cli/solen/generators/bake.py:172-183`,
    `solen-cli/solen/utils/git.py:99-107`), in `sort -u` order. 31 profiles ×
    3 = the 93-entry list this job actually iterates today.
    """
    refs = []
    for s in slugs:
        refs += [f"{REPO}:{s}-develop", f"{REPO}:{s}-develop-{sha}", f"{REPO}:{s}-{sha}"]
    return sorted(refs)


def _run_selection(refs, slugs, profile_list=""):
    """Runs the job's OWN enumeration + tag-selection block over a synthetic
    generated/docker-bake.hcl and returns ``(tags, stdout_lines, rc, stderr)``.

    The block is the workflow's real text (sliced, never retyped) and runs
    under the step's own ``set -uo pipefail``. Callers decide what a non-zero
    returncode means; the wrapper below keeps the historical "must succeed"
    contract for the plain selection tests.
    """
    script_src = _main_verify_script()
    block = script_src[script_src.index(_ENUM_START):script_src.index(_TAGS_END)]
    with tempfile.TemporaryDirectory() as td:
        gen = Path(td, "generated")
        (gen / "profiles").mkdir(parents=True)
        for slug in slugs:
            (gen / "profiles" / slug).write_text("features: []\n")
        # The generated header comment contributes the untagged `ghcr.io/…`
        # ref; including it keeps the `*:*` skip genuinely exercised.
        bake = f"// image: {REPO}\n"
        for r in refs:
            bake += f'tag = ["{r}"]\n'
        (gen / "docker-bake.hcl").write_text(bake)
        script = (
            "set -uo pipefail\n"
            f"PROFILE_LIST='{profile_list}'\n"
            + block
            + '\nfor t in "${tags[@]}"; do echo "TAG $t"; done\n'
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                           check=False, cwd=td)
    tags = [ln[4:] for ln in r.stdout.splitlines() if ln.startswith("TAG ")]
    return tags, r.stdout.splitlines(), r.returncode, r.stderr


def _run_tag_selection(refs, slugs, profile_list=""):
    """Historical contract: the selection block must succeed; returns `tags`."""
    tags, _lines, rc, stderr = _run_selection(refs, slugs, profile_list)
    assert rc == 0, f"selection block died: rc={rc} {stderr!r}"
    return tags


# A realistic 31-profile set — the count `generated/profiles` holds today. Pinned
# literally rather than read from generated/, because that directory is
# build-time output and absent from a fresh CI checkout.
PROFILE_SLUGS = [
    "codeserver", "containers-tools", "data-science", "db-mongo", "db-multi",
    "db-mysql", "db-postgres", "db-redis", "dev", "full", "jetbrains-gateway",
    "k8s-dev", "k8s-sim", "lang-java-21", "lang-java-25", "lang-java-8",
    "lang-java-db-jdk25", "lang-java-ea", "lang-java-graal", "lang-java-latest",
    "lang-java-sdk", "lang-kotlin", "lang-web-dev", "minimal", "python-db",
    "quarto", "quarto-containers", "quarto-db-pg", "quarto-full",
    "quarto-java-25", "quarto-java-ea",
]


class TestTagSelection:
    """Selection behaviour, executed rather than pattern-matched.

    This job has no cost cap, so it cannot drop a profile and is immune to the
    starvation defect that `verify-published-arm64` suffered. What it was not
    immune to is paying for the same digest three times: the bake's three
    digest-identical names per profile all became verification targets, which is
    ~93 pulls and ~93 imagefs writes on the disk-constrained amd64 node — the
    fleet's actual bottleneck — for zero extra artifact coverage.
    """

    def test_bake_shape_fixture_is_the_real_three_refs_per_profile(self):
        refs = _refs_for(PROFILE_SLUGS)
        assert len(PROFILE_SLUGS) == 31
        assert len(refs) == 93, "fixture must be the 93-ref list CI iterates"

    def test_one_tag_per_profile_not_one_per_bake_ref(self):
        tags = _run_tag_selection(_refs_for(PROFILE_SLUGS), PROFILE_SLUGS)
        profiles = [t.rsplit(":", 1)[1][: -len("-amd64")] for t in tags]
        assert len(tags) == len(PROFILE_SLUGS), (
            f"expected one tag per profile ({len(PROFILE_SLUGS)}), got {len(tags)}: "
            "verifying the same digest three times triples the pulls and the "
            "imagefs churn on a disk-constrained node"
        )
        assert len(set(profiles)) == len(profiles), f"a profile was verified twice: {profiles}"

    def test_the_immutable_sha_ref_is_the_one_verified(self):
        # Dedup that picks `<slug>-develop-amd64` would trade cost for a
        # re-pointable tag; the fold must be the commit-SHA name.
        tags = _run_tag_selection(_refs_for(PROFILE_SLUGS), PROFILE_SLUGS)
        for t in tags:
            assert t.endswith(f"-{PIN_SHA}-amd64"), f"{t} is not the -<sha> amd64 member"

    def test_subset_dispatch_still_filters_by_ownership(self):
        # Manual subset dispatch must verify the dispatched profile only — and
        # still only once.
        tags = _run_tag_selection(_refs_for(PROFILE_SLUGS), PROFILE_SLUGS, profile_list="minimal")
        assert tags == [f"{REPO}:minimal-{PIN_SHA}-amd64"], tags

    def test_untagged_header_ref_and_unowned_refs_are_not_verified(self):
        refs = _refs_for(["minimal"]) + [f"{REPO}:gone-away-{PIN_SHA}"]
        tags, lines, rc, _stderr = _run_selection(refs, ["minimal"])
        assert rc == 0, "selection block must not die on an unowned ref"
        assert all(":" in t for t in tags), f"untagged header ref leaked in: {tags}"
        assert not any("gone-away" in t for t in tags), "an unowned ref took a verification slot"
        # And the skip must be VISIBLE, not silent: the unowned ref must show
        # up in the log as SKIPPED-UNOWNED, or its absence would be
        # indistinguishable from a broken enumeration.
        skipped = [ln for ln in lines if "SKIPPED-UNOWNED" in ln]
        assert any(f"{REPO}:gone-away-{PIN_SHA}" in ln for ln in skipped), (
            "the unowned ref was dropped without a SKIPPED-UNOWNED trace — "
            f"silent skip; log lines: {lines!r}"
        )

    def test_real_bake_output_has_no_unowned_refs(self):
        # The real bake shape (three digest-identical refs per generated
        # profile) must be fully owned by the workflow's own ownership
        # matcher: if the generator ever emits a ref no profile owns, this is
        # the first line that says so instead of the ref vanishing from the
        # sweep.
        tags, lines, rc, _stderr = _run_selection(_refs_for(PROFILE_SLUGS), PROFILE_SLUGS)
        assert rc == 0
        assert len(tags) == len(PROFILE_SLUGS), f"expected 31 tags, got {len(tags)}"
        unowned = [ln for ln in lines if "SKIPPED-UNOWNED" in ln]
        assert not unowned, f"bake refs with no owning profile: {unowned}"

    def test_prefix_colliding_profiles_keep_their_own_refs(self):
        # `quarto` and `quarto-full` are both real profiles and `quarto` sorts
        # first; first-match ownership would verify quarto-full's image while
        # reporting `quarto`, and lose quarto from the sweep entirely.
        slugs = ["quarto", "quarto-full"]
        tags = _run_tag_selection(_refs_for(slugs), slugs)
        assert sorted(t.split(":")[1] for t in tags) == [
            f"quarto-{PIN_SHA}-amd64",
            f"quarto-full-{PIN_SHA}-amd64",
        ], tags



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
