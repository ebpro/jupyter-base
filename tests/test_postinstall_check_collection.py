from pathlib import Path

from solen.core.feature import collect_post_install_checks


def test_collect_post_install_checks_returns_java_kernel_command():
    repo_root = Path(__file__).resolve().parents[1]
    checks = collect_post_install_checks(repo_root / 'features', ['java-kernel'])

    assert checks
    assert checks[0]['id'] == 'java-kernel'
    assert 'jupyter kernelspec list' in checks[0]['command']


def test_collect_post_install_checks_skips_missing_feature():
    repo_root = Path(__file__).resolve().parents[1]
    checks = collect_post_install_checks(repo_root / 'features', ['does-not-exist'])

    assert checks == []
