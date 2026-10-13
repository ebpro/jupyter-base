"""Regression guards for the manual devcontainer template.

The manual base template at ``devcontainer/template/devcontainer.json`` is
copied by users (see ``devcontainer/README.md``). It must stay valid JSON and
must not reference unpublished OCI feature images. Solen features (including
``opencode``) are baked into profiles via ``profiles/matrix/*.yaml`` at build
time; the only published devcontainer-facing artifacts are the profile images
themselves (``ghcr.io/ebpro/solen:<profile>-<tag>``), not per-feature
``ghcr.io/ebpro/solen/<feature>`` images.
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = REPO_ROOT / "devcontainer" / "template" / "devcontainer.json"
OPENCODE_README = REPO_ROOT / "features" / "opencode" / "README.md"


def test_template_is_valid_json():
    """The manual template must always parse as JSON (users cp it verbatim)."""
    json.loads(TEMPLATE.read_text(encoding="utf-8"))


def test_template_features_is_empty_dict():
    """Generated devcontainers emit ``"features": {}`` (devcontainer.py); the
    manual template must match — no dangling feature references."""
    config = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    assert config["features"] == {}


def test_no_unpublished_feature_image_references():
    """Neither the template nor the opencode README may point users at a
    ``ghcr.io/ebpro/solen/<feature>`` image that was never published.
    (Needle is assembled at runtime so the literal does not appear in this
    file and repo-wide scans for the dangling reference stay zero-hit.)"""
    needle = "solen/" + "opencode"
    for path in (TEMPLATE, OPENCODE_README):
        assert needle not in path.read_text(encoding="utf-8"), (
            f"{path} references the non-existent opencode feature image"
        )
