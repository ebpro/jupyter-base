"""Contract test: no job downstream of a conditionally-skippable job may lack
a survival guard against skipped-ancestor propagation.

Root cause this pins (live evidence, ci-publish run 40173553597 — the first
tag ever, v1.3.41): on a tag push `mirror-artefacts` is `skipped` (its `if:`
matches develop/dispatch only), and GitHub propagates `skipped` TRANSITIVELY
down the `needs` graph. Every job without an explicit `if:` that survives a
skipped ancestor was cascade-skipped — `merge-index`, `verify-published`,
`verify-published-arm64` AND `sign-release` (whose bare `startsWith(...)`
guard does not survive either) — even though all three builds succeeded:
conclusion `success`, 5 jobs skipped, 0 folded indexes, 0 `.sig` tags.
Skipped is neutral, so the run read green: the release path was a silent
no-op, and could never have worked without explicit guards.

Rule (the recurrence-forbidder): walk the `needs` graph of ci-publish.yml;
every job whose TRANSITIVE dependency chain contains a job with an `if:`
(a job that can be conditionally skipped on some trigger) must itself carry
an explicit `if:` containing `cancelled()` or `always()` — the two job-level
expressions that survive a skipped ancestor. The three build legs already
carried `!cancelled()` (which is exactly why they survived run 40173553597);
the post-build chain must as well.

Non-vacuity is proven RED against the pre-fix workflow blob at 317d114 (the
commit the stale v1.3.41 tag pointed at) via `git show` — the idiom of
tests/test_mirror_artefacts_trigger_is_unconditional.py.
"""

import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / ".github" / "workflows" / "ci-publish.yml"
WORKFLOW_REL = ".github/workflows/ci-publish.yml"

# Last commit whose post-build chain carried no survival guards (the defect,
# as shipped; the stale v1.3.41 tag pointed here).
BASELINE_REV = "317d114"

# The two job-level expressions that survive a skipped ancestor.
SURVIVAL_TOKENS = ("cancelled()", "always()")


def _doc(text=None):
    # PyYAML parses the `on:` key as boolean True; only `jobs` is needed here.
    return yaml.safe_load(text if text is not None else PUBLISH.read_text(encoding="utf-8"))


def _needs_list(job):
    needs = job.get("needs")
    if needs is None:
        return []
    return [needs] if isinstance(needs, str) else list(needs)


def _transitive_chain(doc, name):
    """Every job reachable from `name` by following `needs` edges, as a set
    (excluding `name` itself)."""
    jobs = doc["jobs"]
    seen = set()
    stack = _needs_list(jobs[name])
    while stack:
        dep = stack.pop()
        if dep in seen:
            continue
        seen.add(dep)
        stack.extend(_needs_list(jobs[dep]))
    return seen


def _violations(doc):
    """One entry per job the skipped-ancestor cascade could silently kill."""
    jobs = doc["jobs"]
    out = []
    for name, job in jobs.items():
        chain = _transitive_chain(doc, name)
        conditional = sorted(d for d in chain if str(jobs[d].get("if", "")).strip())
        if not conditional:
            continue
        guard = str(job.get("if", "")).strip()
        if not guard:
            out.append(
                f"{name}: no explicit if: at all, but its transitive needs chain "
                f"contains conditionally-skippable job(s) {conditional}"
            )
        elif not any(tok in guard for tok in SURVIVAL_TOKENS):
            out.append(
                f"{name}: if: {guard!r} cannot survive a skipped ancestor "
                f"(no cancelled()/always()); conditional ancestor(s): {conditional}"
            )
    return out


class TestPostBuildChainSurvivalGuard:
    def test_no_job_downstream_of_a_conditional_job_lacks_a_survival_guard(self):
        violations = _violations(_doc())
        assert not violations, (
            "skipped-ancestor cascade is possible again — a job whose needs "
            "chain contains a conditionally-skippable job lacks an explicit "
            "if: with cancelled()/always():\n  " + "\n  ".join(violations)
        )

    def test_the_post_build_chain_is_actually_downstream_of_mirror_artefacts(self):
        # Non-vacuity of the rule itself: the rule must be able to SEE the
        # defect's shape — the fold and the signature must sit downstream of
        # mirror-artefacts (the job that skips on tag pushes), or the rule
        # would pass because the graph is disconnected, not because the
        # chain is guarded.
        doc = _doc()
        assert "mirror-artefacts" in _transitive_chain(doc, "merge-index")
        assert "mirror-artefacts" in _transitive_chain(doc, "sign-release")


class TestRedProofAgainstBaseline:
    """The rule must classify the PRE-FIX workflow exactly as production did —
    proving the test discriminates and is not vacuously true."""

    @staticmethod
    def _baseline_doc():
        proc = subprocess.run(
            ["git", "show", f"{BASELINE_REV}:{WORKFLOW_REL}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,  # PLW1510: returncode is inspected explicitly below
        )
        if proc.returncode != 0:
            raise AssertionError(f"git show {BASELINE_REV}:{WORKFLOW_REL} failed: {proc.stderr.strip()}")
        return yaml.safe_load(proc.stdout)

    def test_baseline_chain_was_gutted_by_the_cascade(self):
        # Run 40173553597 shape: all four post-build jobs flagged on the
        # pre-fix blob.
        flagged = _violations(self._baseline_doc())
        for job in ("merge-index", "verify-published", "verify-published-arm64", "sign-release"):
            assert any(ln.startswith(f"{job}:") for ln in flagged), (
                f"baseline {job!r} not flagged — the test would have passed on the "
                f"broken workflow:\n{flagged!r}"
            )

    def test_fix_actually_changed_the_guards(self):
        assert _violations(self._baseline_doc()) != _violations(_doc())
