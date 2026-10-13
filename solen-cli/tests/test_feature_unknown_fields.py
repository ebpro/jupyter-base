"""Tests for the feature.json unknown-field rejection in the validator.

Metadata keys that no toolchain component parses are silently ignored, which
hides design errors (the former ``caches`` declaration in zsh-config was never
read by anything and its cache mounts were hardcoded in the Dockerfile
template instead). The validator must now fail loudly on such keys while
accepting every key the real feature files legitimately use.
"""

import json
from pathlib import Path

import pytest

from solen.core.feature import FeatureMetadata
from solen.validators.features import FeatureValidator

REPO_ROOT = Path(__file__).resolve().parents[2]
FEATURES_DIR = REPO_ROOT / 'features'


def _make_feature(tmp_path: Path, data: dict) -> Path:
    """Create a feature directory with feature.json and an executable install.sh."""
    feature_path = tmp_path / data['id']
    feature_path.mkdir()
    (feature_path / 'feature.json').write_text(
        json.dumps(data, indent=2), encoding='utf-8'
    )
    install = feature_path / 'install.sh'
    install.write_text('#!/usr/bin/env bash\nset -euo pipefail\n', encoding='utf-8')
    install.chmod(0o755)
    return feature_path


def _valid_feature_data() -> dict:
    return {
        'id': 'demo-feature',
        'name': 'demo-feature',
        'version': '1.0.0',
        'description': 'A demo feature',
        'documentationURL': './features/demo-feature/README.md',
        'dependsOn': [],
        'options': {},
    }


def _real_feature_dirs() -> list[Path]:
    """Feature directories as enumerated by ``solen validate features``."""
    return [
        p for p in sorted(FEATURES_DIR.iterdir())
        if p.is_dir() and not p.name.startswith('.')
        and (p / 'feature.json').exists()
    ]


class TestUnknownFieldRejection:
    def test_unknown_key_is_rejected_naming_the_key(self, tmp_path):
        data = _valid_feature_data()
        data['caches'] = [{'id': 'cache_demo', 'path': '/home/jovyan/.demo'}]
        feature_path = _make_feature(tmp_path, data)

        validator = FeatureValidator(tmp_path)
        validation = validator.validate_feature(feature_path)

        assert not validation.passed
        messages = [r.message for r in validation.errors]
        assert any("'caches'" in m for m in messages), messages
        # Message names the offending file and the accepted set.
        offending = [m for m in messages if "'caches'" in m][0]
        assert 'feature.json' in offending
        assert 'dependsOn' in offending  # accepted fields are listed

    def test_allowed_keys_do_not_trigger_unknown_field_error(self, tmp_path):
        data = _valid_feature_data()
        data.update({
            'provides': ['demo'],
            'maintainer': {'name': 'A', 'email': 'a@example.com'},
            'platforms': ['linux/amd64'],
            'postInstallCheck': {'command': 'test -d /tmp/demo'},
            'vscode': {'extensions': []},
            'installsAfter': [],
            'licenseURL': 'https://example.com/license',
        })
        feature_path = _make_feature(tmp_path, data)

        validator = FeatureValidator(tmp_path)
        validation = validator.validate_feature(feature_path)

        assert not any(
            'Unknown field' in r.message for r in validation.errors
        ), [r.message for r in validation.errors]
        assert validation.passed

    @pytest.mark.parametrize(
        'feature_path',
        _real_feature_dirs(),
        ids=lambda p: p.name,
    )
    def test_all_real_feature_json_files_have_no_unknown_fields(self, feature_path):
        """Regression guard: the allowlist covers every key actually in use."""
        data = json.loads((feature_path / 'feature.json').read_text(encoding='utf-8'))
        unknown = set(data) - FeatureValidator.ALLOWED_FIELDS
        assert not unknown, f"{feature_path}: unknown fields {sorted(unknown)}"

    def test_zsh_config_no_longer_declares_caches(self):
        feature_json = FEATURES_DIR / 'zsh-config' / 'feature.json'
        data = json.loads(feature_json.read_text(encoding='utf-8'))
        assert 'caches' not in data


class TestParseBehaviorUnchanged:
    def test_feature_metadata_load_parses_valid_file(self, tmp_path):
        data = _valid_feature_data()
        data.update({
            'provides': ['demo'],
            'maintainer': {'name': 'A', 'email': 'a@example.com'},
            'platforms': ['linux/amd64', 'linux/arm64'],
        })
        feature_path = _make_feature(tmp_path, data)

        metadata = FeatureMetadata.load(feature_path)

        assert metadata.id == 'demo-feature'
        assert metadata.name == 'demo-feature'
        assert metadata.version == '1.0.0'
        assert metadata.description == 'A demo feature'
        assert metadata.depends_on == []
        assert metadata.provides == ['demo']
        assert metadata.options == {}
        assert metadata.maintainer == 'A (a@example.com)'
        assert metadata.platforms == ['linux/amd64', 'linux/arm64']

    def test_repo_feature_metadata_still_loads(self):
        """Core parsing of a real feature is unaffected by the validator change."""
        metadata = FeatureMetadata.load(FEATURES_DIR / 'zsh-config')
        assert metadata.id == 'zsh-config'
        assert 'container-user' in metadata.depends_on
