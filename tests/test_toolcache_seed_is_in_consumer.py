"""Regression guard: the /opt/toolcache seed lives INSIDE the consumer install RUN.

Root cause this pins (live evidence, ci-publish runs of bd1d66d vs 8da2bd8):
the standalone seeder `RUN --mount=type=cache,target=/opt/toolcache` had a
cache key that excluded features/, while the consumer install RUN's key
included it. On a features-only commit the seeder stayed CACHED (never ran;
cache-mount writes are excluded from exported layers anyway) while the
consumer executed against an empty mount — then the silent no-`else`
toolcache-miss path in download_direct egressed to origin and the legs died
on `curl: (28)`. Moving the seed into the install RUN makes a single cache
key cover both the seed source (the toolcache-stage bind) and every consumer (the
feature binds), so the divergence is structurally impossible.

Static template-text assertions only — no docker, no network. The idiom
follows tests/test_kotlin_kernel_contract.py (pin generated-file contracts
by exact text). The final test demonstrates non-vacuity by checking each
guard against the pre-fix template at c5af458 via `git show`.
"""

import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "solen-cli" / "solen" / "generators" / "dockerfile_template.j2"

PREFIX_REV = "c5af458"  # last commit with the standalone seeder RUN (hop 4)

MOUNT = "--mount=type=cache,target=/opt/toolcache"
SEED_IF = (
    'if [ -d /tmp/toolcache-stage ] '
    '&& [ -n "$(ls -A /tmp/toolcache-stage 2>/dev/null)" ]; then'
)
SEED_CP = "cp -a /tmp/toolcache-stage/. /opt/toolcache/"
HEREDOC_START = "bash -eux -o pipefail <<'SCRIPT'"


def _template() -> str:
    return TEMPLATE.read_text(encoding="utf-8")


def _prefix_template() -> str:
    """The template as of PREFIX_REV (before this fix)."""
    proc = subprocess.run(
        ["git", "show", f"{PREFIX_REV}:solen-cli/solen/generators/dockerfile_template.j2"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,  # return code is inspected below (skip when history is unavailable)
    )
    if proc.returncode != 0:
        pytest.skip(f"cannot read {PREFIX_REV} template via git show: {proc.stderr.strip()}")
    return proc.stdout


def _install_run_heredoc(text: str) -> str:
    """Body of the consumer install RUN: from its `bash -eux ... <<'SCRIPT'`
    opening line up to (exclusive of) the terminating SCRIPT line."""
    start = text.index(HEREDOC_START)
    end = text.index("\nSCRIPT", start)
    return text[start:end]


# ---------------------------------------------------------------------------
# (a) exactly one toolcache cache-mount in the whole template
# ---------------------------------------------------------------------------
def test_exactly_one_toolcache_cache_mount():
    """The seeder RUN and the consumer RUN shared one volume via byte-identical,
    id-less mount strings. With the seed moved inside the consumer, exactly one
    such mount must remain — a second one is the reintroduction of hop 4."""
    assert _template().count(MOUNT) == 1


# ---------------------------------------------------------------------------
# (b) the seed lives inside the install RUN heredoc
# ---------------------------------------------------------------------------
def test_seed_block_is_inside_the_install_run_heredoc():
    body = _install_run_heredoc(_template())
    assert SEED_IF in body, "seed `if` line must sit inside the consumer install RUN"
    assert SEED_CP in body, "seed cp must sit inside the consumer install RUN"


# ---------------------------------------------------------------------------
# (c) no standalone seeder RUN (regression guard against hop 4)
# ---------------------------------------------------------------------------
def test_no_standalone_toolcache_seeder_run():
    assert "RUN --mount=type=cache,target=/opt/toolcache" not in _template()


# ---------------------------------------------------------------------------
# (d) if-form, with the bash -eux rationale in an adjacent comment
# ---------------------------------------------------------------------------
def test_seed_uses_if_form_and_documents_the_bash_eux_reason():
    body = _install_run_heredoc(_template())
    assert SEED_IF in body
    # The abort-on-false short form must not replace the if-block.
    assert not re.search(r"\[\s*-d\s+/tmp/toolcache-stage\s*\]\s*&&\s*cp\b", body), (
        "`[ -d … ] && cp …` returns 1 under bash -eux when the test is false "
        "and would abort every local ./build.sh"
    )
    seed_line = body.index(SEED_IF)
    preamble = body[:seed_line]
    assert any(
        line.lstrip().startswith("#") and "bash -eux" in line
        for line in preamble.splitlines()
    ), "a comment naming the bash -eux reason for the if-form must sit with the seed"


# ---------------------------------------------------------------------------
# (e) clobbering cp -a, never cp -n
# ---------------------------------------------------------------------------
def test_seed_clobbers_with_cp_a_not_cp_n():
    body = _install_run_heredoc(_template())
    assert SEED_CP in body
    assert "cp -n" not in body, "skip-if-exists would replay stale bytes at the flat cache_archive path"


# ---------------------------------------------------------------------------
# non-vacuity: every guard above must FAIL against the pre-fix template
# ---------------------------------------------------------------------------
def test_guards_are_non_vacuous_against_the_prefix_template():
    old = _prefix_template()
    # (a) the old template carried the mount twice (seeder + consumer)...
    assert old.count(MOUNT) == 2
    # ...and both shared one id-less volume, which is exactly the hazard:
    # the mount strings are byte-identical.
    seeder_run = "RUN --mount=type=cache,target=/opt/toolcache"
    assert seeder_run in old
    assert seeder_run not in _template()  # (c) discriminates
    # (b) the old seed read the baked COPY path, not the toolcache-stage bind, and
    # the new bind-sourced seed lines are absent.
    assert SEED_IF not in old
    assert SEED_CP not in old
    # (d) no bash -eux rationale existed next to any seed.
    assert not any(
        line.lstrip().startswith("#") and "bash -eux" in line for line in old.splitlines()
    )
    # (e) the old cp targeted the baked path — the new /tmp/toolcache-stage cp line
    # is absent above (SEED_CP), so test (e)'s exact-text assertion discriminates.
    assert "cp -a /opt/solen/artefacts/toolcache/. /opt/toolcache/" in old
