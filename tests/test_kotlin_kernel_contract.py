"""Static cross-artifact contract tests for the kotlin-jupyter kernel.

The kernel installation spans four artefacts that must not drift apart:

  profiles/matrix/languages.yaml   -> turns the gate on for lang-kotlin
  checksums.json                   -> pins version + wheel URL + sha256 (SoT)
  features/kotlin/feature.json     -> exposes KOTLIN_KERNEL_VERSION / _WHEEL_URL,
                                      single postInstallCheck asserting the spec
  features/kotlin/install.sh       -> resolves the pin, enforces the digest
  features/kotlin/README.md        -> states the accepted truths plainly

The digests and metadata here were verified live against the PyPI JSON API
(pypi.org/pypi/kotlin-jupyter-kernel/json) on 2026-10-13; these tests are the
drift guard, not the discovery mechanism. Pure file inspection: no network,
no subprocess beyond plain reads.
"""

import json
import re
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
CHECKSUMS = REPO / "checksums.json"
FEATURE_JSON = REPO / "features" / "kotlin" / "feature.json"
INSTALL_SH = REPO / "features" / "kotlin" / "install.sh"
README = REPO / "features" / "kotlin" / "README.md"
MATRIX = REPO / "profiles" / "matrix" / "languages.yaml"
TEMPLATE = REPO / "solen-cli" / "solen" / "generators" / "dockerfile_template.j2"

# Live-verified against PyPI on 2026-10-13 (files.pythonhosted.org,
# kotlin_jupyter_kernel-0.19.0.944-py3-none-any.whl). The wheel is
# py3-none-any, so amd64 and arm64 digests are identical by construction.
PINNED_VERSION = "0.19.0.944"
PINNED_SHA256 = "dc654a426a28e6621aeb0bd7772d268a9a877aabae4a17b73383752a416281a3"
PINNED_WHEEL = f"kotlin_jupyter_kernel-{PINNED_VERSION}-py3-none-any.whl"


def _checksums_entry() -> dict:
    return json.loads(CHECKSUMS.read_text(encoding="utf-8"))["tools"]["kotlin-jupyter"]


def _feature() -> dict:
    return json.loads(FEATURE_JSON.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# matrix gate
# ---------------------------------------------------------------------------
def test_matrix_enables_kotlin_kernel_for_lang_kotlin():
    matrix = yaml.safe_load(MATRIX.read_text(encoding="utf-8"))
    options = matrix["matrix"]["lang-kotlin"]["options"]
    assert options.get("INSTALL_KOTLIN_KERNEL") is True, (
        "lang-kotlin must enable the kernel now that install.sh really "
        f"installs it (found: {options.get('INSTALL_KOTLIN_KERNEL')!r})"
    )
    assert options.get("INSTALL_KOTLIN") is True


def test_matrix_comment_no_longer_describes_the_placeholder():
    """The de086cb comment called the gate a metadata lie; after the kernel
    installer landed it must not keep asserting the placeholder state."""
    text = MATRIX.read_text(encoding="utf-8")
    stale = ("registers no kernel", "only echoes a placeholder", "metadata\n       # lie")
    for phrase in stale:
        assert phrase not in text, f"stale placeholder claim in matrix: {phrase!r}"


# ---------------------------------------------------------------------------
# checksums.json pin (SoT) and its drift guards
# ---------------------------------------------------------------------------
def test_pinned_version_is_consistent_across_artefacts():
    entry = _checksums_entry()
    assert entry["pinned_version"] == PINNED_VERSION
    assert entry["archive_format"] == "whl"

    feature_default = _feature()["options"]["KOTLIN_KERNEL_VERSION"]["default"]
    assert feature_default == PINNED_VERSION, "feature.json default drifted from the pin"

    m = re.search(
        r'^KOTLIN_KERNEL_VERSION_DEFAULT="([^"]+)"$', INSTALL_SH.read_text(), re.MULTILINE
    )
    assert m and m.group(1) == PINNED_VERSION, "install.sh fallback drifted from the pin"


def test_digest_drift_guard():
    entry = _checksums_entry()
    per_version = entry["checksums"][PINNED_VERSION]
    assert per_version["amd64"] == PINNED_SHA256, "amd64 digest drifted from PyPI"
    assert per_version["arm64"] == PINNED_SHA256, "arm64 digest drifted from PyPI"
    assert per_version["amd64"] == per_version["arm64"], "pure-Python wheel: digests must match"
    assert re.fullmatch(r"[0-9a-f]{64}", PINNED_SHA256)

    url = entry["archive_url_template"]
    assert url.startswith("https://files.pythonhosted.org/packages/")
    assert url.endswith(PINNED_WHEEL), "wheel URL must embed the pinned version's filename"


def test_checksums_notes_record_the_accepted_truths():
    notes = _checksums_entry()["notes"]
    for fact in (
        "2.4.0-dev-6891",                      # bundled dev-build compiler
        "Development Status :: 4 - Beta",      # PyPI maturity classifier
        "NO GitHub Releases",                  # why the URL is content-hashed
        "--no-deps",                           # upstream installation semantics
        "run_kotlin_kernel {connection_file}", # verified kernel.json argv
    ):
        assert fact in notes, f"notes no longer record: {fact!r}"


# ---------------------------------------------------------------------------
# feature.json
# ---------------------------------------------------------------------------
def test_kernel_options_are_uppercase_and_documented():
    options = _feature()["options"]
    kernel_version = options["KOTLIN_KERNEL_VERSION"]
    wheel_url = options["KOTLIN_KERNEL_WHEEL_URL"]
    assert kernel_version["type"] == wheel_url["type"] == "string"
    assert wheel_url["default"] == ""  # empty -> resolved from checksums.json
    # The names must NOT imply they govern the language level.
    assert "NOT the notebook Kotlin language level" in kernel_version["description"]
    assert "KOTLIN_VERSION" in kernel_version["description"]
    # Uppercase distinct names: they must not collide with the parked flat
    # `version` option pattern.
    assert "version" not in options and "kotlin_kernel_version" not in options


def test_single_post_install_check_asserts_the_kernelspec():
    feature = _feature()
    pic = feature["postInstallCheck"]
    # solen's collect_post_install_checks accepts exactly ONE dict per feature.
    assert isinstance(pic, dict)
    command = pic["command"]
    assert 'get_kernel_spec("kotlin")' in command, "must resolve the plain 'kotlin' spec"
    assert "kotlinc -version" in command, "compiler check must be preserved"
    assert "INSTALL_KOTLIN_KERNEL" in command and "${v,,}" in command, (
        "kernel assertions must be gated on the lowercased option value"
    )
    # Payload completeness mirrors the installer's own assertions.
    assert "jar_args.json" in command and "mainJar" in command
    assert "run_kotlin_kernel" in command


# ---------------------------------------------------------------------------
# installer wiring
# ---------------------------------------------------------------------------
def test_installer_prefers_shared_helper_and_knows_the_baked_checksums_path():
    """The COPY in the Dockerfile template lands the central pin at
    /opt/solen/artefacts/checksums.json; the installer must (a) try the shared
    fh_resolve_checksum first and (b) include that exact path in its
    self-contained fallback, because scripts/lib/features.sh's
    fh_verify_from_checksums searches only /tmp and $PWD (and $PWD at
    feature-install time is /home/jovyan, which misses the central file)."""
    template = TEMPLATE.read_text(encoding="utf-8")
    baked = "/opt/solen/artefacts/checksums.json"
    assert f"COPY checksums.json {baked}" in template

    source = INSTALL_SH.read_text(encoding="utf-8")
    assert "fh_resolve_checksum" in source, "shared helper must be tried first"
    assert baked in source, "fallback must search the baked central location"


def test_installer_uses_the_shared_interpreter_convention():
    """Kernelspec registration must go through the notebook stack's own
    interpreter, same convention as features/java-kernel and
    features/jupyter-kernels."""
    source = INSTALL_SH.read_text(encoding="utf-8")
    # Stepwise but equivalent to ${CONDA_DIR:-${HOME_DIR:-/home/$NB_USER}/miniforge3}/bin/python
    assert 'home_dir="${HOME_DIR:-/home/${nb_user}}"' in source
    assert 'conda_dir="${CONDA_DIR:-${home_dir}/miniforge3}"' in source
    assert 'python_exec="${conda_dir}/bin/python"' in source
    assert "--no-index --no-deps" in source
    assert "refusing to fall back" in source
    assert "share/jupyter/kernels/kotlin" in source


# ---------------------------------------------------------------------------
# README truthfulness (I6)
# ---------------------------------------------------------------------------
def test_readme_states_the_accepted_truths():
    text = README.read_text(encoding="utf-8")
    for fact in (
        "2.4.0-dev-6891",                       # bundled dev-build compiler
        "Development Status :: 4 - Beta",       # PyPI maturity
        "KOTLIN_VERSION",                       # what does NOT govern the language level
        "80 MB",                                # build-time download size
        "checksums.json",                       # verification source
        "fix-kernelspec-location",              # explicitly not used
        "add-kernel",                           # explicitly not used
        "KOTLIN_JUPYTER_JAVA_EXECUTABLE",       # JVM precedence, real env names
        "KOTLIN_JUPYTER_JAVA_HOME",
        "JAVA_HOME",
        "run_kotlin_kernel",
    ):
        assert fact in text, f"README no longer states: {fact!r}"


def test_readme_keeps_validator_recommended_sections():
    """solen validate: README should contain description/usage/options sections."""
    text = README.read_text(encoding="utf-8").lower()
    for section in ("description", "usage", "options"):
        assert section in text, f"README missing recommended section: {section}"
