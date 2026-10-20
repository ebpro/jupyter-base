"""Static contract tests for the `verify-published-arm64` job in ci-publish.yml.

The amd64 gate (`test_verify_published_contract.py`) proves what an x64 consumer
pulls. It proves nothing about the arm64 member of the folded index, and
`merge-index` is the one step that can get that wrong silently — an index whose
arm64 slot points at the amd64 child publishes green forever, because every
consumer that asks for arm64 quietly receives the other architecture.

These tests pin the standing gate's design contract, without docker or network:

  * the job exists, needs merge-index, runs on the ARM pool, and carries NO
    explicit `if:` (the implicit success() default, like verify-published);
  * it never uses bare `ebpro-org` — the arm runners also carry that label, so
    a bare label could route an arm64-proving job onto amd64 hardware;
  * it targets the FOLDED INDEX (unsuffixed base ref), never a per-arch child;
  * it asserts the resolved child architecture loudly;
  * it validates the runner's own hardware before trusting any result;
  * it asserts the baked contract's summary count rather than eyeballing it;
  * it carries the canary smoke's substance: in-container aarch64, a real
    quarto render to a non-empty artifact, and the hazard-marker sweep;
  * an empty selection fails loudly (no vacuous pass) and failures accumulate;
  * the cost cap is explicit, and every selected profile is evidenced by a real
    matrix entry (so the list cannot drift onto a profile that does not exist);
  * it is a leaf job: signing is never gated on it.
"""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"
MATRIX_DIR = ROOT / "profiles" / "matrix"

JOB = "verify-published-arm64"
ARM_POOL = "ebpro-org-arm"

# The documented representative subset. Order is coverage-per-minute, not
# alphabetical; see the env comment in the workflow for each entry's rationale.
EXPECTED_SMOKE_PROFILES = ["quarto-full", "lang-java-25", "db-postgres", "minimal"]


def _doc():
    # PyYAML parses the `on:` key as boolean True; only `jobs` is needed here.
    return yaml.safe_load(PUBLISH.read_text())


def _job(name):
    jobs = _doc()["jobs"]
    assert name in jobs, f"job {name!r} missing from ci-publish.yml"
    return jobs[name]


def _run_scripts(job):
    return [step["run"] for step in job["steps"] if step.get("run")]


def _verify_script():
    """The step that enumerates folded refs and docker-runs the checks."""
    for script in _run_scripts(_job(JOB)):
        if "run-postinstall-checks.sh" in script:
            return script
    raise AssertionError(f"no run step of {JOB} references run-postinstall-checks.sh")


def _matrix_profile_slugs():
    """Every 2-space `matrix:` key across the 8 matrices, as file:line evidence."""
    slugs = {}
    for f in sorted(MATRIX_DIR.glob("*.yaml")):
        for i, line in enumerate(f.read_text().splitlines(), 1):
            m = re.match(r"^  ([a-z0-9][a-z0-9._-]*):\s*(?:#.*)?$", line)
            if m:
                slugs.setdefault(m.group(1), f"{f.relative_to(ROOT)}:{i}")
    return slugs


class TestJobShape:
    def test_job_exists(self):
        assert JOB in _doc()["jobs"]

    def test_needs_merge_index_only(self):
        assert _job(JOB).get("needs") == ["merge-index"]

    def test_runs_on_arm_pool(self):
        assert _job(JOB)["runs-on"] == ARM_POOL

    def test_never_uses_bare_ebpro_org(self):
        # The arm runners carry the bare `ebpro-org` label too (see the
        # x64-pinning comment on verify-published): an arm-proving job scheduled
        # by that label could land on amd64 hardware and fail for the wrong
        # reason. The pool-specific label is the only acceptable form here.
        runs_on = _job(JOB)["runs-on"]
        labels = runs_on if isinstance(runs_on, list) else [runs_on]
        assert "ebpro-org" not in labels, f"{JOB} must not be schedulable on bare ebpro-org"
        assert "ebpro-org-large" not in labels

    def test_no_explicit_if_guard(self):
        # Mirrors verify-published: needs: [merge-index] + the implicit
        # success() default already prevent execution on a failed/absent fold.
        assert "if" not in _job(JOB), f"{JOB} must rely on the implicit success() default"

    def test_timeout_is_short_but_honest(self):
        # The archived canary measured 119 s for one image including a ~108 s
        # cold pull; the ARC kill deadline is ~80m37s. Anything >= 60 would
        # let a wedged pull hold a maxRunners:2 pool for most of an hour.
        t = _job(JOB).get("timeout-minutes")
        assert isinstance(t, int) and 10 <= t <= 30, f"timeout-minutes={t!r} is not sized to the measured work"

    def test_is_a_leaf_job(self):
        def needs_list(j):
            n = j.get("needs")
            if n is None:
                return []
            return [n] if isinstance(n, str) else list(n)

        consumers = [name for name, j in _doc()["jobs"].items() if JOB in needs_list(j)]
        assert consumers == [], f"{JOB} must stay a leaf job; needed by: {consumers}"


class TestRunnerHardwareGuard:
    def test_asserts_host_is_aarch64(self):
        steps = {s.get("name", ""): s.get("run", "") for s in _job(JOB)["steps"]}
        host = [r for n, r in steps.items() if "Host arch" in n]
        assert host, f"{JOB} must assert the RUNNER's own arch before trusting any result"
        assert "aarch64" in host[0] and "uname -m" in host[0]
        assert "::error::" in host[0], "a mislabelled pool must abort loudly, not silently"

    def test_host_guard_is_its_own_first_step(self):
        names = [s.get("name", "") for s in _job(JOB)["steps"]]
        assert "Host arch" in names[0], f"arch guard must run before checkout/docker: {names}"


class TestFoldedIndexIsTheTarget:
    def test_no_per_arch_child_suffix(self):
        # The whole point: consumers pull the index. Appending -arm64/-amd64
        # would validate a child and miss a mis-fold.
        s = _verify_script()
        assert "-amd64" not in s, "must not target the amd64 child"
        assert '"${T}-arm64"' not in s and '${T}-arm64' not in s, \
            "must validate the folded index, not the -arm64 child"

    def test_inspects_the_index_registry_side(self):
        s = _verify_script()
        assert "buildx imagetools inspect" in s
        assert "linux/arm64" in s and "linux/amd64" in s, \
            "fold integrity requires BOTH members to be advertised"

    def test_resolved_child_arch_is_asserted_loudly(self):
        s = _verify_script()
        assert re.search(r"docker image inspect.*\{\{\.Os\}\}/\{\{\.Architecture\}\}", s, re.DOTALL), \
            "must prove which child the manifest actually resolved to"
        assert "CRITICAL" in s, "a silently-wrong child is the defect class; it must scream"

    def test_pull_asks_for_arm64_explicitly(self):
        assert "docker pull --platform linux/arm64" in _verify_script()

    def test_execution_pins_the_platform(self):
        s = _verify_script()
        assert "--platform linux/arm64" in s and "docker run" in s


class TestContentContract:
    def test_baked_contract_is_executed(self):
        assert "run-postinstall-checks.sh" in _verify_script()

    def test_summary_count_is_asserted_not_eyeballed(self):
        s = _verify_script()
        assert "Solen post-install checks complete:" in s, \
            "a run that never reached its summary validated nothing"
        assert "passed=" in s and "total=" in s, "must compare passed to total"

    def test_in_container_arch_and_binary_floor(self):
        s = _verify_script()
        assert "in-container uname -m" in s
        for b in ("rsync", "jq", "cmake"):
            assert b in s, f"binary floor must still check {b}"

    def test_real_function_not_a_version_banner(self):
        s = _verify_script()
        assert "quarto render" in s, "the gate must exercise the flagship's real function"
        assert "test -s" in s, "a produced artifact must be proven NON-EMPTY"

    def test_hazard_markers_are_swept(self):
        s = _verify_script()
        for marker in ("An error occurred while executing", "FH_SDKMAN_INSTALL_FAILED",
                       "get\\.sdkman\\.io", "curl: \\(35\\)", "Killed",
                       "OutOfMemoryError", "Timeout"):
            assert marker in s, f"hazard sweep lost {marker!r} from the canary contract"
        assert re.search(r"\|\s*\\b137\\b", s), \
            "137 must be word-bounded or a byte count like 1137 false-positives"


class TestVacuousPassGuard:
    def test_empty_selection_fails_loudly(self):
        s = _verify_script()
        assert re.search(r"selected_refs\[@\]\}\[? -eq 0|ZERO multiarch images", s) or "ZERO" in s
        assert "::error::" in s and re.search(r"exit 1", s), "must exit non-zero, not warn"

    def test_guard_is_exercisable(self):
        # The guard's shell logic must be extractable so it can be run with an
        # empty selection (see test_empty_selection_exits_non_zero).
        assert "SMOKE_MAX_IMAGES" in _job(JOB)["env"]

    def test_failures_accumulate_instead_of_failing_fast(self):
        s = _verify_script()
        assert "set -uo pipefail" in s, "must not use `set -e`: one bad image ends the report"
        assert 'exit "$failed"' in s
        assert s.count("failed=1") >= 5, "every assertion above must accumulate, not abort"

    def _run_guard(self, candidates, cap="2"):
        """Runs the job's OWN selection/guard block (extracted verbatim, not
        retyped) against a synthetic candidate list."""
        import subprocess

        s = _verify_script()
        # PyYAML strips the block scalar's common indentation, so the script's
        # own top-level statements sit at column 0 here.
        guard = s[s.index("selected_refs=()"):s.index('echo ">> VALIDATING')]
        refs = " ".join(f'"{c}"' for c, _ in candidates)
        owners = " ".join(f'"{o}"' for _, o in candidates)
        harness = (
            "set -uo pipefail\n"
            "want=(quarto-full lang-java-25 minimal)\n"
            f"cand_refs=({refs})\n"
            f"cand_owners=({owners})\n"
            "all_slugs=(quarto-full dev lang-java-25 minimal)\n"
            f"SMOKE_MAX_IMAGES={cap}\n"
            + guard
            + '\necho "selected=${#selected_refs[@]} skipped=${#skipped_owners[@]}"\n'
        )
        return subprocess.run(["bash", "-c", harness], capture_output=True, text=True, check=False)

    def test_empty_selection_exits_non_zero(self):
        """Actually RUNS the guard with zero candidates. A guard that was never
        executed is an assumption, not a result."""
        r = self._run_guard([])
        assert r.returncode == 1, (
            f"vacuous-pass guard did NOT fail on an empty selection "
            f"(rc={r.returncode}, out={(r.stdout + r.stderr)!r}) — the gate can "
            "pass green while validating nothing"
        )
        assert "ZERO" in (r.stdout + r.stderr)

    def test_valid_input_proceeds_and_the_cap_binds(self):
        # The other half of the contract: it must not fail closed on real work,
        # and SMOKE_MAX_IMAGES must actually cap it (3 candidates, 2 wanted
        # within cap -> 2 selected, 1 reported skipped).
        r = self._run_guard([("ghcr.io/ebpro/solen:quarto-full-abc", "quarto-full"),
                             ("ghcr.io/ebpro/solen:dev-abc", "dev"),
                             ("ghcr.io/ebpro/solen:lang-java-25-abc", "lang-java-25")])
        assert r.returncode == 0, f"guard failed closed on valid input: {r.stdout!r}{r.stderr!r}"
        assert "selected=2 skipped=1" in r.stdout, f"cap/selection wrong: {r.stdout!r}"

    def test_subset_dispatch_without_representatives_falls_back(self):
        # A dispatch naming none of SMOKE_PROFILES must still validate something
        # (the dispatched profiles), never pass vacuously.
        r = self._run_guard([("ghcr.io/ebpro/solen:dev-abc", "dev")])
        assert r.returncode == 0, f"fallback path exited non-zero: {r.stderr!r}"
        assert "matched no owned tag" in r.stdout
        assert "selected=1" in r.stdout


class TestCostCap:
    def test_cap_is_explicit(self):
        env = _job(JOB)["env"]
        assert int(env["SMOKE_MAX_IMAGES"]) <= 5, \
            "on a minRunners:0 / maxRunners:2 arm pool the cap is the point of the design"

    def test_selection_is_the_documented_subset(self):
        env = _job(JOB)["env"]
        assert env["SMOKE_PROFILES"].split() == EXPECTED_SMOKE_PROFILES

    def test_every_selected_profile_is_evidenced_by_a_matrix_entry(self):
        # Guards against the list drifting onto a profile that no longer exists,
        # which would silently shrink the gate to fewer images than documented.
        slugs = _matrix_profile_slugs()
        for p in EXPECTED_SMOKE_PROFILES:
            assert p in slugs, f"{p} is validated but is not a matrix key ({sorted(slugs)[:5]}…)"

    def test_selection_covers_distinct_profile_classes(self):
        # flagship(quarto) / heavy JVM / services / bare base — one each.
        s = " ".join(_job(JOB)["env"]["SMOKE_PROFILES"].split())
        assert "quarto" in s and "java" in s and "db-" in s
        assert "minimal" in s, "the base floor must be validated, not only fat profiles"

    def test_subset_dispatch_falls_back_instead_of_passing_empty(self):
        s = _verify_script()
        assert "representative set matched no owned tag" in s, \
            "a dispatch of non-representative profiles must still be gated"
