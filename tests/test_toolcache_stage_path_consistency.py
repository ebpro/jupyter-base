"""Three-way staging-path consistency pin (Option A relocation).

Invariant: the ~150-250 MB/arch digest-pinned toolcache archives reach the
build ONLY through the read-only bind `source=toolcache-stage` and must NEVER
live inside the `COPY artefacts` tree (before this relocation, at 90e8db8, the
writer staged them under artefacts/toolcache/, so every published image baked
them into its base layer via `COPY artefacts /opt/solen/artefacts`).

The three path surfaces must agree:
  1. writer  — scripts/stage-toolcache.sh  default OUT and matrix() rows
               (`$OUT/$tool/$(basename url)`)
  2. bind    — dockerfile_template.j2      `--mount=type=bind,source=toolcache-stage,
               target=/tmp/toolcache-stage,readonly` + the in-consumer
               if-form seed `cp -a /tmp/toolcache-stage/. /opt/toolcache/`
  3. reader  — features/_lib/download-release/install.sh
               `"$TOOLCACHE_DIR/$tool/$(basename "$url")"` with
               TOOLCACHE_DIR=/opt/toolcache
Flat keys are byte-identical after the root swap: <stage>/<tool>/<base> maps
1:1 onto $TOOLCACHE_DIR/<tool>/<base>.

Non-vacuity: test_baseline_90e8db8_lacked_the_relocation asserts each pin
AGAINST the pre-relocation content via `git show 90e8db8:…`, and the file's
header docstring's RED demo is reproduced by running this module against a
90e8db8 worktree (the state-pinning tests fail there).
"""

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "stage-toolcache.sh"
TEMPLATE = REPO / "solen-cli" / "solen" / "generators" / "dockerfile_template.j2"
WORKFLOW = REPO / ".github" / "workflows" / "ci-publish.yml"
INSTALL = REPO / "features" / "_lib" / "download-release" / "install.sh"
DOCKERIGNORE = REPO / ".dockerignore"

BASELINE_REV = "90e8db8"  # last commit staging under artefacts/toolcache/

STAGE = "toolcache-stage"
BIND_MOUNT = f"--mount=type=bind,source={STAGE},target=/tmp/{STAGE},readonly"
SEED_IF = (
    f'if [ -d /tmp/{STAGE} ] && [ -n "$(ls -A /tmp/{STAGE} 2>/dev/null)" ]; then'
)
SEED_CP = f"cp -a /tmp/{STAGE}/. /opt/toolcache/"
MATRIX_PRINTF = (
    r"""printf '%s\t%s\t%s\t%s\t%s\t%s/%s/%s\n' """
    """"$tool" "$arch" "$ver" "$digest" "$url" "$OUT" "$tool" "$base\""""
)
CONSUMER_PROBE = '"$TOOLCACHE_DIR/$tool/$(basename "$url")"'


def _git_show(rev: str, path: Path) -> str:
    rel = path.relative_to(REPO)
    proc = subprocess.run(
        ["git", "show", f"{rev}:{rel}"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,  # return code inspected below (skip when history unavailable)
    )
    if proc.returncode != 0:
        pytest.skip(f"cannot read {rev}:{rel} via git show: {proc.stderr.strip()}")
    return proc.stdout


# ---------------------------------------------------------------------------
# 1. writer
# ---------------------------------------------------------------------------
def test_writer_stages_outside_the_copyed_artefacts_tree():
    body = SCRIPT.read_text(encoding="utf-8")
    assert f'OUT="{STAGE}"' in body, "default staging dir must be the build-context sibling"
    # no reference anywhere in the writer may keep staging under artefacts/
    assert "artefacts/toolcache" not in body
    # matrix() rows carry the stage root (and --mode list output follows it)
    assert MATRIX_PRINTF in body


# ---------------------------------------------------------------------------
# 2. bind + in-consumer seed (structure preserved: if-form, cp -a, single hop)
# ---------------------------------------------------------------------------
def test_template_carries_a_second_bind_and_seeds_from_it():
    body = TEMPLATE.read_text(encoding="utf-8")
    assert BIND_MOUNT in body, "archives must arrive via a dedicated read-only bind"
    assert SEED_IF in body
    assert SEED_CP in body, "cp -a clobber semantics must be preserved"
    # the seed stays inside the consumer RUN (no standalone hop)
    assert "RUN --mount=type=cache,target=/opt/toolcache" not in body
    # the artefacts bind remains for its legitimate content, but no longer
    # carries any toolcache path
    assert "--mount=type=bind,source=artefacts,target=/tmp/artefacts,readonly" in body
    assert "/tmp/artefacts/toolcache" not in body


def test_copy_artefacts_cannot_carry_the_archives():
    body = TEMPLATE.read_text(encoding="utf-8")
    assert "COPY artefacts /opt/solen/artefacts" in body  # kept for real artefacts content
    assert f"COPY {STAGE}" not in body, "the staging tree must never be COPYed"
    # the CI writer agrees with the bind source
    wf = WORKFLOW.read_text(encoding="utf-8")
    assert f"--out {STAGE}" in wf
    assert "--out artefacts/toolcache" not in wf
    assert "find artefacts/toolcache" not in wf
    # and nothing is tracked under the old location
    proc = subprocess.run(
        ["git", "ls-files", "artefacts/toolcache"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0 and proc.stdout.strip() == ""


def test_stage_dir_exists_in_context_and_dockerignore_does_not_starve_the_bind():
    # BuildKit fails the RUN outright if a bind source is absent or excluded,
    # so the directory must be tracked (as an empty stub) and un-ignored.
    proc = subprocess.run(
        ["git", "ls-files", STAGE],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    assert f"{STAGE}/.gitkeep" in proc.stdout, (
        "the staging dir must exist in every fresh checkout/build context"
    )
    ignore = DOCKERIGNORE.read_text(encoding="utf-8")
    live = [ln.strip() for ln in ignore.splitlines() if ln.strip() and not ln.startswith("#")]
    assert not any("toolcache" in p or "artefacts" in p for p in live), (
        ".dockerignore must not exclude the bind source (would silently starve it)"
    )
    # staged archives are git-ignored but the stub is not
    ci = subprocess.run(
        ["git", "check-ignore", "-q", f"{STAGE}/helm/helm-v4.0.4-linux-amd64.tar.gz"],
        cwd=REPO,
        check=False,
    )
    assert ci.returncode == 0, "archive contents must never be committable"
    ck = subprocess.run(
        ["git", "check-ignore", "-q", f"{STAGE}/.gitkeep"],
        cwd=REPO,
        check=False,
    )
    assert ck.returncode != 0, ".gitkeep must stay tracked (bind source existence)"


# ---------------------------------------------------------------------------
# 3. reader / flat keys
# ---------------------------------------------------------------------------
def test_flat_keys_agree_after_the_root_swap():
    reader = INSTALL.read_text(encoding="utf-8")
    assert CONSUMER_PROBE in reader, (
        "download_direct probe shape must stay <TOOLCACHE_DIR>/<tool>/$(basename url)"
    )
    # writer row shape: $OUT/$tool/$base  ==  stage/<tool>/<basename url>
    assert '"$OUT" "$tool" "$base"' in SCRIPT.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# non-vacuity: the baseline (90e8db8) violates every relocation pin above
# ---------------------------------------------------------------------------
def test_baseline_90e8db8_lacked_the_relocation():
    old_script = _git_show(BASELINE_REV, SCRIPT)
    old_template = _git_show(BASELINE_REV, TEMPLATE)
    old_wf = _git_show(BASELINE_REV, WORKFLOW)
    # writer staged INTO the COPYed tree — the exact bloat this change removes
    assert 'OUT="artefacts/toolcache"' in old_script
    # no dedicated bind existed; the seed read the artefacts bind
    assert BIND_MOUNT not in old_template
    assert SEED_IF not in old_template
    assert SEED_CP not in old_template
    assert "/tmp/artefacts/toolcache" in old_template
    # CI legs passed the old --out
    assert "--out artefacts/toolcache" in old_wf
    assert f"--out {STAGE}" not in old_wf
