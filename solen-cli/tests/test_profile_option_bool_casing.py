"""Regression tests for boolean option casing in generated profile files.

Matrix-declared booleans (``@options:`` in ``profiles/matrix/*.yaml``) flow
through :func:`solen.generators.profiles.render_options` into the
``@options:KEY=VALUE`` profile line, are parsed back by
:func:`solen.core.profile.parse_profile`, and finally reach the Dockerfile
as ``ENV KEY="VALUE"``.

Historic defect: ``f"{v}"`` stringified Python ``bool`` values as
``True``/``False``, while every installer gates with lowercase comparisons
(``[ "$X" = "true" ]``) and the feature-default path
(``solen.core.feature.collect_feature_options``) already normalises to
lowercase. The fix renders booleans as ``true``/``false`` -- and MUST NOT
touch any other type, because option values include case-significant
version strings such as ``KERNEL_VERSION=v1.4.6-pr12``.
"""

from pathlib import Path

from solen.core.profile import parse_profile
from solen.generators.profiles import (
    generate_profile_file,
    render_option_value,
    render_options,
)


class TestRenderOptionValue:
    """Type-dispatched rendering of a single option value."""

    def test_bool_true_renders_lowercase(self):
        assert render_option_value(True) == 'true'

    def test_bool_false_renders_lowercase(self):
        assert render_option_value(False) == 'false'

    def test_int_one_is_not_treated_as_bool(self):
        # ``bool`` is an ``int`` subclass; the reverse must not leak either:
        # plain ints keep their exact ``str()`` rendering.
        assert render_option_value(1) == '1'
        assert render_option_value(0) == '0'

    def test_non_bool_types_render_exactly_as_before(self):
        cases = {
            'v1.4.6-pr12': 'v1.4.6-pr12',          # case-significant version
            'EA': 'EA',                            # case-significant token
            'https://GitHub.com/Org/Repo': 'https://GitHub.com/Org/Repo',
            25: '25',
            3.7: '3.7',
            None: 'None',
            True: 'true',                          # only bools are normalised
            False: 'false',
        }
        for value, expected in cases.items():
            assert render_option_value(value) == expected


class TestRenderOptions:
    """The flat option dict renderer used for ``@options:`` lines."""

    def test_bool_options_render_lowercase(self):
        rendered = render_options(
            {'INSTALL_KOTLIN': True, 'INSTALL_KOTLIN_KERNEL': False}
        )
        assert rendered == 'INSTALL_KOTLIN=true;INSTALL_KOTLIN_KERNEL=false'
        assert 'True' not in rendered
        assert 'False' not in rendered

    def test_mixed_types_preserve_exact_non_bool_rendering(self):
        # Regression guard against a future "just lowercase everything"
        # change: every non-bool value must survive byte-identically.
        opts = {
            'INSTALL_NOTEBOOK_EXTENSIONS': True,
            'KERNEL_VERSION': 'v1.4.6-pr12',
            'JDK_VERSION': 'EA',
            'ARTIFACTS_BASE_URL': 'https://github.com/ebpro/IJava/releases',
            'JAVA_MAJOR': 25,
        }
        assert render_options(opts) == (
            'INSTALL_NOTEBOOK_EXTENSIONS=true;'
            'KERNEL_VERSION=v1.4.6-pr12;'
            'JDK_VERSION=EA;'
            'ARTIFACTS_BASE_URL=https://github.com/ebpro/IJava/releases;'
            'JAVA_MAJOR=25'
        )


class TestProfileFileEndToEnd:
    """Booleans lowercase through the real profile-generation pipeline."""

    def test_generated_profile_options_line_is_lowercase(self, tmp_path: Path):
        spec = {
            'base': 'test-profile',
            'features': [],
            'labels': {
                'variant': {
                    'options': {
                        'INSTALL_KOTLIN': True,
                        'INSTALL_KOTLIN_KERNEL': False,
                        'KERNEL_VERSION': 'v1.4.6-pr12',
                    },
                },
            },
        }
        created = generate_profile_file(spec, tmp_path / 'profiles')
        assert len(created) == 1
        text = Path(created[0]).read_text(encoding='utf-8')

        option_lines = [
            line for line in text.splitlines() if line.startswith('@options:')
        ]
        assert option_lines == [
            '@options:INSTALL_KOTLIN=true;INSTALL_KOTLIN_KERNEL=false;'
            'KERNEL_VERSION=v1.4.6-pr12'
        ]

        # Downstream parser sees the lowercase string, which is what the
        # Dockerfile template and installer gates consume.
        data = parse_profile(Path(created[0]), Path(created[0]).parent)
        assert data.options['INSTALL_KOTLIN'] == 'true'
        assert data.options['INSTALL_KOTLIN_KERNEL'] == 'false'
        assert data.options['KERNEL_VERSION'] == 'v1.4.6-pr12'
