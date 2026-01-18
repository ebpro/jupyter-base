from pathlib import Path
import json
import pytest


FEATURES_DIR = Path("features")


def discover_features():
    for p in sorted(FEATURES_DIR.iterdir()):
        if not p.is_dir():
            continue
        if p.name.startswith("_"):
            continue
        feature_json = p / "feature.json"
        if feature_json.exists():
            yield p.name, feature_json, p / "install.sh"


@pytest.mark.parametrize("name,feature_json,install_sh", list(discover_features()))
def test_feature_has_postinstall_and_install_sh(name, feature_json, install_sh):
    """Each feature should declare a postInstallCheck and include an install.sh script."""
    data = json.loads(feature_json.read_text(encoding="utf-8"))
    assert (
        "postInstallCheck" in data and data["postInstallCheck"]
    ), f"Feature {name} missing non-empty postInstallCheck in {feature_json}"
    assert install_sh.exists(), f"Feature {name} missing install.sh at {install_sh}"
