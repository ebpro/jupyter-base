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
  * the cap bounds DISTINCT PROFILES, never ref count: the bake publishes three
    digest-identical names per profile, and a cap applied to refs let one
    profile consume the whole budget and starve the flagship out of the gate
    (observed: `VALIDATING 4 ... db-postgres db-postgres db-postgres
    lang-java-25`, i.e. quarto-full and minimal never validated, quarto render
    never run) — TestOneRefPerProfile exercises that shape end to end;
  * the ref chosen for a profile is the IMMUTABLE one (`<slug>-<sha>`), so the
    gate never floats between enumeration and pull;
  * a wanted profile that is silently absent from the selection FAILS the job —
    the zero-selection guard only fires at zero, not at "fewer than intended";
  * it is a leaf job: signing is never gated on it.

Selection/guard and enumeration blocks are extracted from the workflow *verbatim*
and executed under bash against synthetic inputs, so these are behaviour tests,
not string greps. The synthetic candidate lists deliberately carry several refs
per owner: a harness that only ever fed one ref per profile could not express the
starvation defect above, which is how 30 green tests certified a broken gate.
"""

import re
import subprocess
import tempfile
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"
MATRIX_DIR = ROOT / "profiles" / "matrix"

JOB = "verify-published-arm64"
ARM_POOL = "ebpro-org-arm"

# The documented representative subset. Order is coverage-per-minute, not
# alphabetical; see the env comment in the workflow for each entry's rationale.
EXPECTED_SMOKE_PROFILES = ["quarto-full", "lang-java-25", "db-postgres", "minimal"]

REPO = "ghcr.io/ebpro/solen"

# Chosen, not incidental: a SHA beginning with 'f' sorts AFTER the floating
# `develop` tag, so a fixture built on it cannot be satisfied by alphabetical
# luck. A preference rule that only works when the SHA happens to sort first is
# not a preference rule.
PIN_SHA = "ffee123"


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


# --- executable harness -----------------------------------------------------
#
# Both helpers slice real workflow bash out of the step and run it. The anchors
# (`compute_slug() {`, `selected_refs=()`, `echo ">> VALIDATING`) are the block's
# own statements, so the extracted text is the job's text — nothing is retyped
# into Python and no assertion can drift away from what CI executes.

_ENUM_START = "compute_slug() {"
_SEL_START = "selected_refs=()"
_SEL_END = 'echo ">> VALIDATING'


def _owner_of(ref, slugs):
    """Constructs a candidate's owner for a synthetic fixture.

    This is only an input builder; the workflow's real longest-slug ownership
    matcher is pinned independently by TestRefEnumeration, which runs the bash
    and asserts it agrees with this rule.
    """
    tag = ref.split(":", 1)[1]
    best = ""
    for s in slugs:
        if (tag == s or tag.startswith(s + "-")) and len(s) > len(best):
            best = s
    return best


def _refs_for(slugs, sha=PIN_SHA):
    """The three base refs merge-index folds per profile on a develop push
    (`solen-cli/solen/generators/bake.py:172-183`,
    `solen-cli/solen/utils/git.py:99-107`), in `sort -u` order — the exact shape
    of the 93-entry list the selection block consumes.
    """
    refs = []
    for s in slugs:
        refs += [f"{REPO}:{s}-develop", f"{REPO}:{s}-develop-{sha}", f"{REPO}:{s}-{sha}"]
    return sorted(refs)


def _candidates_for(slugs, sha=PIN_SHA):
    return [(r, _owner_of(r, slugs)) for r in _refs_for(slugs, sha)]


def _bash_array(vals):
    return "(" + " ".join(str(v) for v in vals) + ")"


def _run_selection(candidates, cap="2", want=("quarto-full", "lang-java-25", "minimal"),
                   all_slugs=("quarto-full", "dev", "lang-java-25", "minimal"),
                   req_slugs=()):
    """Runs the job's OWN selection + guard block against a synthetic candidate
    list of (ref, owner) pairs. Several pairs may share an owner — that is the
    real bake shape and the one the old harness never expressed.
    """
    s = _verify_script()
    guard = s[s.index(_SEL_START):s.index(_SEL_END)]
    refs = " ".join(f'"{c}"' for c, _ in candidates)
    owners = " ".join(f'"{o}"' for _, o in candidates)
    harness = (
        "set -uo pipefail\n"
        f"want={_bash_array(want)}\n"
        f"cand_refs=({refs})\n"
        f"cand_owners=({owners})\n"
        f"all_slugs={_bash_array(all_slugs)}\n"
        f"req_slugs={_bash_array(req_slugs)}\n"
        f"SMOKE_MAX_IMAGES={cap}\n"
        + guard
        + '\necho "selected=${#selected_refs[@]} skipped=${#skipped_owners[@]}"\n'
        + 'for r in "${selected_refs[@]}"; do echo "REF $r"; done\n'
        + 'for o in "${selected_owners[@]}"; do echo "OWN $o"; done\n'
        + 'for o in "${skipped_owners[@]}"; do echo "SKIP $o"; done\n'
    )
    return subprocess.run(["bash", "-c", harness], capture_output=True, text=True, check=False)


def _lines(proc, tag):
    return [ln.split(" ", 1)[1] for ln in proc.stdout.splitlines() if ln.startswith(tag + " ")]


def _selected_refs(proc):
    return _lines(proc, "REF")


def _selected_owners(proc):
    # Read from the block's OWN selected_owners array, so the assertion is about
    # what the gate reports it validated — not a Python re-derivation from the
    # ref string.
    return _lines(proc, "OWN")


def _run_enumeration(slugs, refs, profile_list="", smoke_profiles=None):
    """Runs the job's OWN enumeration half (`sort -u`, the `*:*` header-comment
    skip and the ownership matcher) against a synthetic docker-bake.hcl, and
    returns the (ref, owner) candidates it produced.
    """
    if smoke_profiles is None:
        smoke_profiles = " ".join(EXPECTED_SMOKE_PROFILES)
    s = _verify_script()
    enum = s[s.index(_ENUM_START):s.index(_SEL_START)]
    with tempfile.TemporaryDirectory() as td:
        gen = Path(td, "generated")
        (gen / "profiles").mkdir(parents=True)
        for slug in slugs:
            (gen / "profiles" / slug).write_text("features: []\n")
        # The header comment is the source of the untagged `ghcr.io/ebpro/solen`
        # ref; include it so the `*:*` skip is genuinely exercised.
        bake = f"// image: {REPO}\n"
        for r in refs:
            bake += f'tag = ["{r}"]\n'
        (gen / "docker-bake.hcl").write_text(bake)
        script = (
            "set -uo pipefail\n"
            f"SMOKE_PROFILES='{smoke_profiles}'\n"
            f"PROFILE_LIST='{profile_list}'\n"
            + enum
            + '\nfor i in "${!cand_refs[@]}"; do echo "CAND ${cand_refs[$i]}|${cand_owners[$i]}"; done\n'
            + 'echo "SLUGS ${all_slugs[*]}"\n'
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                           check=False, cwd=td)
    assert r.returncode == 0, f"enumeration block died: rc={r.returncode} {r.stderr!r}"
    cands = []
    for ln in r.stdout.splitlines():
        if ln.startswith("CAND "):
            ref, owner = ln[5:].rsplit("|", 1)
            cands.append((ref, owner))
    return cands



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

    def _run_guard(self, candidates, cap="2", **kw):
        # Kept as the historical entry point; the shared harness now lives at
        # module level so the selection and enumeration classes use one seam.
        return _run_selection(candidates, cap=cap, **kw)

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
        # and SMOKE_MAX_IMAGES must cap DISTINCT PROFILES.
        #
        # The fixture used to be one ref per profile, which is not a shape the
        # bake ever produces — under it the buggy ref-count cap and a correct
        # profile-count cap agree, so the test certified the defect. Every
        # profile here carries its real triple of digest-identical refs, which is
        # what makes `skipped` and the distinct-owner count discriminate:
        # ref-capping burns the budget on one profile and reports the rest as
        # skipped, profile-capping spends one slot each.
        cands = _candidates_for(["dev", "lang-java-25", "minimal", "quarto-full"])
        assert len(cands) == 12, "fixture must carry the bake's 3-refs-per-profile shape"
        r = self._run_guard(cands, cap="2")
        assert r.returncode == 0, f"guard failed closed on valid input: {r.stdout!r}{r.stderr!r}"
        assert "selected=2 skipped=1" in r.stdout, (
            f"cap must bound distinct profiles, not refs: {r.stdout!r}"
        )
        owners = _selected_owners(r)
        assert len(owners) == len(set(owners)) == 2, (
            f"cap bound on refs, not profiles — selected owners {owners}"
        )
        assert set(owners) == {"quarto-full", "lang-java-25"}, (
            f"the documented order must be honoured slot by slot, got {owners}"
        )

    def test_subset_dispatch_without_representatives_falls_back(self):
        # A dispatch naming none of SMOKE_PROFILES must still validate something
        # (the dispatched profiles), never pass vacuously.
        r = self._run_guard([("ghcr.io/ebpro/solen:dev-abc", "dev")], req_slugs=["dev"])
        assert r.returncode == 0, f"fallback path exited non-zero: {r.stderr!r}"
        assert "matched no owned tag" in r.stdout
        assert "selected=1" in r.stdout


def _realized_smoke_selection():
    """Runs the job's own selection block over the FULL real profile set, with
    each profile carrying the three refs the bake actually publishes — i.e. the
    same 93-ref list CI feeds it, reconstructed offline.

    Returns (proc, distinct_owners). This is the "realized coverage" seam: the
    declaration `SMOKE_PROFILES: "…"` says what the gate intends; only running
    the block says what it validates.
    """
    env = _job(JOB)["env"]
    slugs = sorted(_matrix_profile_slugs())
    r = _run_selection(_candidates_for(slugs),
                       cap=env["SMOKE_MAX_IMAGES"],
                       want=tuple(EXPECTED_SMOKE_PROFILES),
                       all_slugs=tuple(slugs))
    return r, _selected_owners(r)


class TestCostCap:
    def test_cap_is_explicit(self):
        env = _job(JOB)["env"]
        assert int(env["SMOKE_MAX_IMAGES"]) <= 5, \
            "on a minRunners:0 / maxRunners:2 arm pool the cap is the point of the design"

    def test_selection_is_the_documented_subset(self):
        env = _job(JOB)["env"]
        assert env["SMOKE_PROFILES"].split() == EXPECTED_SMOKE_PROFILES
        # The declaration above is an intention. What the gate VALIDATES is what
        # its own block produces from the real 93-ref bake list, and that is the
        # assertion that used to be missing: with a ref-count cap the declared
        # four collapsed to {db-postgres, lang-java-25} and this test still
        # passed, because a string literal cannot contradict itself.
        r, owners = _realized_smoke_selection()
        assert r.returncode == 0, f"selection died on the real profile set: {r.stderr!r}"
        assert set(owners) == set(EXPECTED_SMOKE_PROFILES), (
            f"declared {EXPECTED_SMOKE_PROFILES} but realized {sorted(set(owners))} "
            f"— the gate validated {len(set(owners))} of {len(EXPECTED_SMOKE_PROFILES)} "
            "documented profiles"
        )
        assert len(owners) == len(set(owners)) == len(EXPECTED_SMOKE_PROFILES), (
            f"one slot per distinct profile expected, got {owners}"
        )

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
        # Same objection as above: a substring test on the env literal proves the
        # *comment*, not the gate. Assert the classes appear among the profiles
        # the block actually selected.
        _, owners = _realized_smoke_selection()
        realized = " ".join(owners)
        assert any(o.startswith("quarto") for o in owners), \
            f"flagship class absent from realized selection: {realized}"
        assert any("java" in o for o in owners), f"heavy-JVM class absent: {realized}"
        assert any(o.startswith("db-") for o in owners), f"services class absent: {realized}"
        assert "minimal" in owners, f"bare-base floor absent: {realized}"
        assert len(owners) == len(set(owners)), f"a profile occupied two slots: {owners}"

    def test_subset_dispatch_falls_back_instead_of_passing_empty(self):
        s = _verify_script()
        assert "representative set matched no owned tag" in s, \
            "a dispatch of non-representative profiles must still be gated"


class TestOneRefPerProfile:
    """The starvation defect class: the bake emits three digest-identical refs
    per profile, and the cap was applied to REFS, so the first profile
    alphabetically spent the whole budget. `db-postgres` took slots 1-3,
    `lang-java-25` slot 4, and `quarto-full`/`minimal` were skipped — which is
    not merely 2 fewer images: the probe is content-selected, so `quarto render`
    fires ONLY on quarto-full and the flagship's real function went unproven
    while the job reported green. One ref per distinct profile loses zero
    artifact coverage (all three names fold the same digest).
    """

    def test_triple_tags_of_one_profile_cannot_starve_the_rest_of_the_subset(self):
        # The production shape, reconstructed: db-postgres sorts first, so it is
        # the profile that ate the budget.
        want = EXPECTED_SMOKE_PROFILES
        cands = _candidates_for(sorted(want))
        r = _run_selection(cands, cap="4", want=tuple(want), all_slugs=tuple(sorted(want)))
        assert r.returncode == 0, (
            f"selection must succeed when the full subset is available: "
            f"rc={r.returncode} out={(r.stdout + r.stderr)!r}"
        )
        owners = _selected_owners(r)
        assert len(owners) == len(set(owners)) == 4, (
            f"cap consumed by duplicate folds of one profile: {owners}"
        )
        assert set(owners) == set(want), f"subset starved: realized {sorted(set(owners))}"
        # The defect's actual blast radius: the flagship must survive the cap.
        assert "quarto-full" in owners, \
            f"quarto-full dropped — the quarto render probe would never have run: {owners}"
        assert "selected=4 skipped=0" in r.stdout, r.stdout

    def test_the_immutable_sha_ref_is_selected_not_the_floating_tag(self):
        # Three-tier preference: <slug>-<sha> beats <slug>-<branch>-<sha> beats
        # <slug>-<branch>. PIN_SHA sorts after "develop", so this cannot pass by
        # alphabetical accident — a gate pointed at `quarto-full-develop` is
        # re-pointable between enumeration and pull (TOCTOU).
        slugs = EXPECTED_SMOKE_PROFILES
        cands = _candidates_for(slugs)
        r = _run_selection(cands, cap="4", want=tuple(slugs), all_slugs=tuple(sorted(slugs)))
        assert r.returncode == 0, r.stderr
        for ref in _selected_refs(r):
            tag = ref.split(":", 1)[1]
            assert tag.endswith(f"-{PIN_SHA}") and not tag.endswith(f"-develop-{PIN_SHA}"), (
                f"{ref} is not the bare commit-SHA ref of its profile"
            )

    @pytest.mark.parametrize("shape", [
        # (builder name, tag suffixes per profile, expected winner's suffix)
        pytest.param("develop", id="develop-push"),
        pytest.param("release", id="v-tag-push"),
        pytest.param("main", id="main-push"),
    ])
    def test_preference_resolves_to_the_sha_ref_on_every_trigger_shape(self, shape):
        # git.py:99-107 -> tag push yields (v1.2.3, v1.2.3-<sha>) plus the bare
        # <sha>; main yields (latest, main-<sha>); a branch yields
        # (<branch>, <branch>-<sha>). All three must resolve to the SHA ref.
        suffixes = {
            "develop": ["develop", f"develop-{PIN_SHA}", PIN_SHA],
            "release": ["v1.2.3", f"v1.2.3-{PIN_SHA}", PIN_SHA],
            "main": ["latest", f"main-{PIN_SHA}", PIN_SHA],
        }[shape]
        cands = []
        for s in EXPECTED_SMOKE_PROFILES:
            cands += [(f"{REPO}:{s}-{suf}", s) for suf in suffixes]
        r = _run_selection(cands, cap="4", want=tuple(EXPECTED_SMOKE_PROFILES),
                           all_slugs=tuple(sorted(EXPECTED_SMOKE_PROFILES)))
        assert r.returncode == 0, r.stderr
        for ref in _selected_refs(r):
            assert ref.endswith(f"-{PIN_SHA}"), (
                f"{shape}: {ref} is not the immutable <slug>-<sha> fold"
            )

    def test_missing_wanted_profile_fails_loudly_instead_of_shrinking_the_gate(self):
        # The hole the zero-selection guard leaves open: it fires at ZERO. Here
        # three of four wanted profiles are present, the bake simply has no
        # quarto-full ref, and the cap never binds — the old code reported a
        # green gate that had quietly lost the flagship.
        present = ["db-postgres", "lang-java-25", "minimal"]
        cands = _candidates_for(present)
        r = _run_selection(cands, cap="4", want=tuple(EXPECTED_SMOKE_PROFILES),
                           all_slugs=tuple(sorted(present + ["quarto-full"])))
        assert r.returncode == 1, (
            f"a wanted profile vanished from the selection and the gate passed "
            f"(rc={r.returncode}, out={r.stdout!r}) — coverage is silently reduced"
        )
        assert "quarto-full" in (r.stdout + r.stderr)
        assert "::error::" in r.stderr, "coverage loss must be an annotation, not a note"

    def test_profile_missing_from_the_bake_entirely_is_a_failure_not_a_skip(self):
        # Same class, unrestricted path: `minimal` is a generated profile and a
        # declared smoke profile, but produced no candidate ref at all.
        present = ["db-postgres", "lang-java-25", "quarto-full"]
        cands = _candidates_for(present)
        r = _run_selection(cands, cap="4", want=tuple(EXPECTED_SMOKE_PROFILES),
                           all_slugs=tuple(sorted(present + ["minimal"])))
        assert r.returncode == 1, (
            f"enumeration lost a wanted profile and the job still passed "
            f"(rc={r.returncode}, out={r.stdout!r})"
        )
        assert "minimal" in (r.stdout + r.stderr)

    def test_genuine_cap_pressure_is_not_reported_as_coverage_loss(self):
        # The guards must not fight the cap: when |want| > SMOKE_MAX_IMAGES the
        # shortfall IS the documented design, so the job proceeds and reports
        # what was skipped. Without this, the stricter guard would make the
        # declared configuration unrunnable.
        slugs = EXPECTED_SMOKE_PROFILES
        cands = _candidates_for(slugs)
        r = _run_selection(cands, cap="2", want=tuple(slugs), all_slugs=tuple(sorted(slugs)))
        assert r.returncode == 0, f"cap pressure must not fail the gate: {r.stdout!r}{r.stderr!r}"
        owners = _selected_owners(r)
        assert len(owners) == 2, owners
        assert "skipped=2" in r.stdout, r.stdout

    def test_fallback_path_also_picks_one_ref_per_profile(self):
        # The subset-dispatch fallback shared the same flaw; a dispatch of one
        # profile must cost ONE image, not its whole tag triple.
        cands = _candidates_for(["dev"])
        r = _run_selection(cands, cap="2", want=("quarto-full",),
                           all_slugs=("dev", "quarto-full"), req_slugs=["dev"])
        assert r.returncode == 0, r.stderr
        assert "matched no owned tag" in r.stdout
        assert "selected=1 skipped=0" in r.stdout, r.stdout

    def test_zero_selection_guard_is_still_the_zero_selection_guard(self):
        # The new coverage guards are siblings, not a replacement: the original
        # empty-selection failure must keep its own message and exit code.
        r = _run_selection([], cap="4")
        assert r.returncode == 1
        assert "ZERO" in (r.stdout + r.stderr)


class TestRefEnumeration:
    """The enumeration half (`sort -u`, the untagged header-comment ref, and the
    ownership matcher) had no executable test at all before this class — only a
    grep proving the `grep -oE` idiom was present. A matcher that mis-attributes
    a ref silently re-points the gate at a different image than it reports.
    """

    def test_header_comment_ref_is_skipped_and_duplicates_collapse(self):
        # The bake's generated header carries a bare `ghcr.io/ebpro/solen`
        # (no colon, no tag); it is not an image. Each profile is declared by
        # several targets that all repeat its three refs, so `sort -u` is what
        # keeps the list at one entry per ref.
        refs = [f"{REPO}:minimal-develop", f"{REPO}:minimal-develop",
                f"{REPO}:minimal-develop-{PIN_SHA}", f"{REPO}:minimal-{PIN_SHA}"]
        cands = _run_enumeration(["minimal"], refs)
        assert [c[0] for c in cands] == sorted(set(refs)), \
            f"header ref not skipped or duplicates not collapsed: {cands}"
        assert all(":" in r for r, _ in cands)
        assert {o for _, o in cands} == {"minimal"}

    def test_ownership_is_longest_slug_match_not_first_match(self):
        # `quarto` and `quarto-full` are both real generated profiles, and
        # `quarto` sorts first. A first-match matcher would attribute
        # quarto-full's refs to `quarto` — reporting one image while validating
        # another, and dropping the flagship from the subset entirely.
        slugs = ["quarto", "quarto-full"]
        refs = [f"{REPO}:quarto-{PIN_SHA}", f"{REPO}:quarto-develop",
                f"{REPO}:quarto-full-{PIN_SHA}", f"{REPO}:quarto-full-develop"]
        cands = _run_enumeration(slugs, refs)
        owners = dict(cands)
        assert owners[f"{REPO}:quarto-full-{PIN_SHA}"] == "quarto-full"
        assert owners[f"{REPO}:quarto-{PIN_SHA}"] == "quarto"

    def test_unowned_refs_are_dropped(self):
        # A ref no profile owns (a renamed profile still in the registry, say)
        # must not occupy a validation slot.
        cands = _run_enumeration(["minimal"], [f"{REPO}:minimal-{PIN_SHA}",
                                               f"{REPO}:gone-away-{PIN_SHA}"])
        assert [o for _, o in cands] == ["minimal"]

    def test_subset_dispatch_filters_by_ownership(self):
        cands = _run_enumeration(["db-postgres", "minimal"],
                                 _refs_for(["db-postgres", "minimal"]),
                                 profile_list="minimal")
        assert {o for _, o in cands} == {"minimal"}
        assert len(cands) == 3, f"expected the dispatch's own triple, got {cands}"

