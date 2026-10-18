"""Contract test: mirror-artefacts must NOT be gated on a checksums range-diff.

Root cause this pins (live evidence, ci-publish runs): the old gate
`needs.changes.outputs.checksums == 'true' || mirror_force` asked "did THIS
commit range touch checksums.json?" — a one-time trigger that a replaced
pending run can lose forever:

  * runs 39120654609-family seeding pushes b514de1 (39127999375),
    77b3272 (39128743942) and bb2a2dc (39128767925) were ALL cancelled with
    zero jobs (a PENDING run in this group is replaced by the next push even
    though cancel-in-progress: false protects RUNNING ones);
  * run 39120654609 (9225c0d) completed with `Mirror toolcache archives to
    Harbor` = skipped — the gate closed, observed directly;
  * run 39129344307 (90e8db8) diffs bb2a2dc..90e8db8, which contains no
    checksums.json change, so the mirror skipped again and 6 of 18 blobs
    stayed unpushed with NO future develop range able to seed them.

Policy now pinned: the job runs unconditionally on every push to develop
(mode_push is idempotent — `already published; skipping` — so unconditional
is cheap and self-healing), on every workflow_dispatch, and via the
mirror_force override door. It must never read needs.changes again. The
advisory semantics stay: the push step keeps continue-on-error: true and the
build legs keep their `needs: [changes, mirror-artefacts]` + !cancelled()
ordering edge unchanged.

The predicate is evaluated through a minimal GitHub-expression subset
(dotted context refs, ==, !=, &&, ||, !, parentheses) so the assertions
discriminate behaviour, not strings. Non-vacuity is proven RED against the
pre-change workflow blob at 90e8db8 via `git show` (the idiom of
tests/test_toolcache_seed_is_in_consumer.py).
"""

import re
import subprocess
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
PUBLISH = REPO / ".github" / "workflows" / "ci-publish.yml"
WORKFLOW_REL = ".github/workflows/ci-publish.yml"

# Last commit with the range-diff-gated mirror job (the defect, as shipped).
BASELINE_REV = "90e8db8"

JOB = "mirror-artefacts"
LEGS = ("build-amd64-standard", "build-amd64-heavy", "build-arm64")


def _doc(text=None):
    # PyYAML parses the `on:` key as boolean True; tests below handle that.
    return yaml.safe_load(text if text is not None else PUBLISH.read_text(encoding="utf-8"))


def _job(doc, name):
    assert name in doc["jobs"], f"job {name!r} missing from ci-publish.yml"
    return doc["jobs"][name]


def _predicate(doc):
    pred = _job(doc, JOB).get("if")
    assert isinstance(pred, str) and pred.strip(), f"{JOB} must carry an explicit if:"
    return pred


class _Ctx(dict):
    """Strict context: an unmodelled ref in the predicate fails the test
    loudly instead of silently evaluating to null (which could mask a new
    hidden dependency on another signal)."""

    def __missing__(self, key):
        raise AssertionError(
            f"mirror predicate reads unmodelled context {key!r}; "
            "either the gate gained a dependency (update the policy) or the "
            "test scenario table is incomplete"
        )


def _env(event="push", ref="refs/heads/develop", checksums="false", mirror_force="false"):
    return _Ctx(
        {
            "github.event_name": event,
            "github.ref": ref,
            # The very signal that must NOT be able to close the gate on a
            # develop push any more; provided so a regression to `needs`-based
            # gating is evaluated rather than KeyError-crashed.
            "needs.changes.outputs.checksums": checksums,
            "github.event.inputs.mirror_force": mirror_force,
        }
    )


def _eval(predicate, env):
    """Evaluate a GitHub Actions expression subset in `env`."""
    assert "__" not in predicate, "dunder in predicate — refusing to eval"
    expr = predicate.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    expr = re.sub(
        r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+",
        lambda m: f'CTX["{m.group(0)}"]',
        expr,
    )
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    return bool(eval(expr, {"__builtins__": {}}, {"CTX": env}))


class TestTriggerPolicy:
    def test_predicate_never_reads_changes_output(self):
        # Structural half of the fix: the dependency is gone from the text.
        assert "needs.changes" not in _predicate(_doc())

    def test_job_has_no_needs(self):
        # develop-path triggering must not wait on (or be gated by) `changes`.
        assert "needs" not in _job(_doc(), JOB)

    def test_develop_push_ignores_checksums_signal(self):
        pred = _predicate(_doc())
        for checksums in ("true", "false"):
            for mirror_force in ("true", "false", ""):
                assert _eval(pred, _env(checksums=checksums, mirror_force=mirror_force)) is True, (
                    f"develop push must mirror unconditionally (checksums={checksums!r}, mirror_force={mirror_force!r})"
                )

    def test_later_unrelated_run_heals_a_checksums_only_change(self):
        # The exact run-39129344307 scenario: range bb2a2dc..HEAD contains NO
        # checksums.json change (checksums=false), yet the mirror must run so
        # the six orphaned blobs get seeded by a later, unrelated push.
        assert _eval(_predicate(_doc()), _env(checksums="false")) is True

    def test_dispatch_runs_even_without_mirror_force(self):
        assert _eval(_predicate(_doc()), _env(event="workflow_dispatch", mirror_force="false")) is True

    def test_mirror_force_door_still_opens_on_other_refs(self):
        # mirror_force remains an explicit override for re-verification on
        # refs outside the develop-push path.
        pred = _predicate(_doc())
        assert _eval(pred, _env(event="workflow_dispatch", ref="refs/heads/feature-x", mirror_force="true")) is True

    def test_tag_push_deliberately_not_mirrored(self):
        # Boundary pin: v* tags are cut on the develop tip whose push already
        # mirrored the same checksums.json; the release path must not start
        # depending on the mirror again.
        assert _eval(_predicate(_doc()), _env(ref="refs/tags/v1.2.3", checksums="true")) is False

    def test_workflow_has_no_pull_request_trigger(self):
        doc = _doc()
        on = doc.get("on", doc.get(True))  # YAML 1.1 parses `on` as True
        assert "pull_request" not in on, "PR behaviour claim in the comments must be re-checked"


class TestAdvisorySemanticsIntact:
    def test_push_step_stays_continue_on_error(self):
        steps = _job(_doc(), JOB)["steps"]
        push = [s for s in steps if "Push toolcache mirror" in s.get("name", "")]
        assert len(push) == 1, "exactly one push step expected"
        assert push[0].get("continue-on-error") is True

    def test_legs_keep_the_ordering_edge_unchanged(self):
        doc = _doc()
        for leg in LEGS:
            job = _job(doc, leg)
            needs = job.get("needs")
            needs = [needs] if isinstance(needs, str) else list(needs or [])
            assert "changes" in needs and JOB in needs, f"{leg} lost its needs ordering edge"
            assert "!cancelled()" in str(job.get("if", "")), f"{leg} lost !cancelled() guard"


class TestRedProofAgainstBaseline:
    """The evaluator must classify the OLD predicate exactly as production did
    — proving these tests discriminate and are not vacuously true."""

    @staticmethod
    def _baseline_doc():
        proc = subprocess.run(
            ["git", "show", f"{BASELINE_REV}:{WORKFLOW_REL}"],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=False,  # PLW1510: returncode is inspected explicitly below
        )
        if proc.returncode != 0:
            raise AssertionError(f"git show {BASELINE_REV}:{WORKFLOW_REL} failed: {proc.stderr.strip()}")
        return yaml.safe_load(proc.stdout)

    def test_baseline_gate_reproduces_the_skipped_runs(self):
        old = _predicate(self._baseline_doc())
        assert "needs.changes.outputs.checksums" in old  # sanity: the defect's shape
        # 39120654609 / 39129344307 class: develop push, range without a
        # checksums change -> the mirror SKIPPED.
        assert _eval(old, _env(checksums="false")) is False
        # The seeding ranges (b514de1..): the gate DID open — which is why
        # RED below is about lost runs, not about a dead gate.
        assert _eval(old, _env(checksums="true")) is True

    def test_baseline_lost_the_seeding_event_when_runs_were_cancelled(self):
        # A cancelled-with-zero-jobs run (39127999375/39128743942/39128767925)
        # never evaluated the gate at all; the NEXT completed run diffs a
        # range with no checksums change -> False forever under the old
        # predicate. Pin that the old shape cannot self-heal...
        old = _predicate(self._baseline_doc())
        assert _eval(old, _env(checksums="false")) is False
        # ...while the new shape does.
        assert _eval(_predicate(_doc()), _env(checksums="false")) is True

    def test_predicate_actually_changed(self):
        assert _predicate(_doc()) != _predicate(self._baseline_doc())
