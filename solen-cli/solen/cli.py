#!/usr/bin/env python3
"""Solen CLI - Main command-line interface."""

import json
import os
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import click

from solen import __version__


class NaturalOrderGroup(click.Group):
    """Click Group that preserves insertion order for commands (no alphabetical sort)."""

    def list_commands(self, ctx: click.Context) -> list[str]:
        return list(self.commands.keys())


@click.group(cls=NaturalOrderGroup)
@click.version_option(version=__version__)
@click.option('--repo-root', type=click.Path(exists=True, path_type=Path),
              default=Path.cwd(), help='Repository root directory')
@click.pass_context
def cli(ctx: click.Context, repo_root: Path) -> None:
    """Solen CLI - Manage container features, profiles, and artifacts."""
    ctx.ensure_object(dict)
    ctx.obj['repo_root'] = repo_root


# ============================================================================
# GENERATE commands
# ============================================================================

@cli.group(cls=NaturalOrderGroup)
def generate() -> None:
    """Generate profiles, Dockerfiles, and other artifacts."""
    pass


@cli.group(name='list')
def list_group() -> None:
    """List available artifacts and targets."""
    pass


@list_group.command(name='profiles')
@click.option('--dir', 'profiles_dir', type=click.Path(path_type=Path),
              default=Path('generated/profiles'), help='Directory with generated profiles')
@click.pass_context
def list_profiles(ctx: click.Context, profiles_dir: Path) -> None:
    """List generated profile files."""
    repo_root = ctx.obj['repo_root']
    dir_path = repo_root / profiles_dir if not profiles_dir.is_absolute() else profiles_dir
    if not dir_path.exists():
        click.echo(f"No generated profiles directory: {dir_path}", err=True)
        sys.exit(1)
    items = sorted([p.name for p in dir_path.iterdir() if p.is_file()])
    if not items:
        click.echo(f"No profiles found in {dir_path}")
        return
    for it in items:
        click.echo(it)


@cli.command(name='inspect-profile')
@click.argument('profile_name')
@click.option('--dir', 'profiles_dir', type=click.Path(path_type=Path),
              default=Path('generated/profiles'), help='Directory with generated profiles')
@click.pass_context
def inspect_profile(ctx: click.Context, profile_name: str, profiles_dir: Path) -> None:
    """Show resolved contents (features/options/services) of a generated profile file."""
    repo_root = ctx.obj['repo_root']
    dir_path = repo_root / profiles_dir if not profiles_dir.is_absolute() else profiles_dir
    # allow passing full path
    candidate = Path(profile_name)
    if candidate.is_absolute() or '/' in profile_name:
        profile_path = candidate
    else:
        profile_path = dir_path / profile_name

    if not profile_path.exists():
        click.echo(f"Profile not found: {profile_path}", err=True)
        sys.exit(1)

    features = []
    options = {}
    services = []
    parent = None
    comment = None

    with open(profile_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                if line.startswith('#') and not comment:
                    comment = line.lstrip('#').strip()
                continue
            if line.startswith('@'):
                # @parent:..., @options:..., @services:...
                if line.startswith('@parent:'):
                    parent = line.split(':', 1)[1]
                elif line.startswith('@options:'):
                    kv = line.split(':', 1)[1]
                    for part in kv.split(';'):
                        if '=' in part:
                            k, v = part.split('=', 1)
                            options[k] = v
                elif line.startswith('@services:'):
                    services.append(line.split(':', 1)[1])
                continue
            # regular feature line
            features.append(line)

    if comment:
        click.echo(f"# {comment}")
    if parent:
        click.echo(f"Parent: {parent}")
    click.echo("\nFeatures:")
    for f in features:
        click.echo(f"- {f}")
    if options:
        click.echo("\nOptions:")
        for k, v in options.items():
            click.echo(f"- {k}: {v}")
    if services:
        click.echo("\nServices:")
        for s in services:
            click.echo(f"- {s}")


@generate.command()
@click.option('--matrix', type=click.Path(exists=True, path_type=Path),
              required=True, help='Path to matrix YAML file or directory')
@click.option('--out', type=click.Path(path_type=Path),
              default=Path('generated/profiles'), help='Output directory')
@click.option('--prefix', default='', help='Filename prefix for generated profiles')
@click.option('--chain', is_flag=True, help='Also generate Dockerfile and docker-bake.hcl after profiles')
@click.pass_context
def profiles(ctx: click.Context, matrix: Path, out: Path, prefix: str, chain: bool) -> None:
    """Generate profile files from YAML matrix definitions."""
    from solen.generators.profiles import (
        generate_profiles,
        validate_matrix_features,
    )

    repo_root = ctx.obj['repo_root']
    matrix_path = repo_root / matrix if not matrix.is_absolute() else matrix
    out_dir = repo_root / out if not out.is_absolute() else out

    total = 0
    # Allow passing a directory containing multiple matrix YAMLs
    paths = []
    if matrix_path.is_dir():
        for p in sorted(matrix_path.glob('*.yaml')) + sorted(matrix_path.glob('*.yml')):
            paths.append(p)
    else:
        paths = [matrix_path]

    for p in paths:
        try:
            missing = validate_matrix_features(p, repo_root)
            if missing:
                click.echo(f"⚠️  Matrix {p} references missing features: {', '.join(missing)}", err=True)
        except Exception as e:
            click.echo(f"⚠️  Could not validate matrix {p}: {e}", err=True)

        count = generate_profiles(p, out_dir, prefix)
        total += count
        click.echo(f"✅ Generated {count} profile(s) from {p}")

    click.echo(f"✅ Generated {total} profile(s) in {out_dir}")

    if chain:
        # Chain to Dockerfile and bake generation (multi-profile)
        try:
            from solen.generators.bake import generate_bake
            from solen.generators.dockerfile_gen import generate_multi_profile_dockerfile

            dockerfile_out = repo_root / 'generated' / 'Dockerfile'
            bake_out = repo_root / 'generated' / 'docker-bake.hcl'

            profiles = generate_multi_profile_dockerfile(repo_root, dockerfile_out)
            click.echo(f"✅ Generated Dockerfile with {len(profiles)} profiles: {dockerfile_out}")
            count = generate_bake(repo_root, bake_out)
            click.echo(f"✅ Generated docker-bake.hcl with {count} profile(s): {bake_out}")
        except Exception as e:
            click.echo(f"❌ Chain generation failed: {e}", err=True)
            sys.exit(1)


@generate.command()
@click.option('--profile', help='Profile name to generate Dockerfile for')
@click.option('--all', 'all_profiles', is_flag=True, help='Generate Dockerfile with all profiles')
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/Dockerfile'), help='Output Dockerfile path')
@click.option('--verbose', is_flag=True, help='Show verbose output')
@click.pass_context
def dockerfile(ctx: click.Context, profile: str | None, all_profiles: bool, output: Path, verbose: bool) -> None:
    """Generate Dockerfile for a profile or all profiles."""
    from solen.generators.dockerfile_gen import (
        generate_multi_profile_dockerfile,
        generate_single_profile_dockerfile,
    )

    if not profile and not all_profiles:
        click.echo("❌ Error: Must specify either --profile or --all", err=True)
        sys.exit(1)

    if profile and all_profiles:
        click.echo("❌ Error: Cannot use both --profile and --all", err=True)
        sys.exit(1)

    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output

    try:
        if all_profiles:
            profiles = generate_multi_profile_dockerfile(repo_root, output_path)
            click.echo(f"✅ Generated Dockerfile with {len(profiles)} profiles: {output_path}")
            click.echo(f"Profiles: {', '.join(profiles)}")
            # Write a short machine-readable log to generated/ for CI/debugging
            try:
                gen_dir = (repo_root / 'generated')
                gen_dir.mkdir(parents=True, exist_ok=True)
                log = {
                    'timestamp': datetime.utcnow().isoformat() + 'Z',
                    'action': 'generate dockerfile',
                    'output': str(output_path),
                    'profiles': profiles,
                }
                with open(gen_dir / 'last-generate.json', 'w', encoding='utf-8') as lf:
                    json.dump(log, lf, indent=2)
                click.echo(f"Wrote log: {gen_dir / 'last-generate.json'}")
            except Exception:
                # non-fatal
                pass
        else:
            generate_single_profile_dockerfile(repo_root, profile, output_path)
            click.echo(f"✅ Generated Dockerfile for {profile}: {output_path}")
            try:
                # log single-profile generation as well
                gen_dir = (repo_root / 'generated')
                gen_dir.mkdir(parents=True, exist_ok=True)
                log = {
                    'timestamp': datetime.utcnow().isoformat() + 'Z',
                    'action': 'generate dockerfile',
                    'output': str(output_path),
                    'profile': profile,
                }
                with open(gen_dir / 'last-generate.json', 'w', encoding='utf-8') as lf:
                    json.dump(log, lf, indent=2)
                click.echo(f"Wrote log: {gen_dir / 'last-generate.json'}")
            except Exception:
                pass
    except Exception as e:
        if verbose:
            import traceback
            click.echo(traceback.format_exc(), err=True)
        else:
            click.echo(f"❌ Error: {e}", err=True)
        sys.exit(1)


@generate.command()
@click.option('--profile', help='Profile name to generate devcontainer config for')
@click.option('--all', 'all_profiles', is_flag=True, help='Generate for all known profiles')
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/devcontainer'), help='Output directory')
@click.pass_context
def devcontainer(ctx: click.Context, profile: str | None, all_profiles: bool, output: Path) -> None:
    """Generate devcontainer.json (and docker-compose.yml) for profile(s)."""
    from solen.generators.devcontainer import generate_devcontainer, list_generated_profiles

    if bool(profile) == all_profiles:
        click.echo("❌ Error: specify exactly one of --profile or --all", err=True)
        sys.exit(1)

    repo_root = ctx.obj['repo_root']
    out_dir = repo_root / output if not output.is_absolute() else output

    if all_profiles:
        names = list_generated_profiles(repo_root)
        if not names:
            click.echo("❌ No profiles found (run `solen generate profiles` first)", err=True)
            sys.exit(1)
    else:
        names = [profile]

    for name in names:
        try:
            path = generate_devcontainer(repo_root, name, out_dir)
            click.echo(f"✅ Generated: {path}")
        except FileNotFoundError as e:
            click.echo(f"❌ {e}", err=True)
            sys.exit(1)
    click.echo(f"✅ Generated devcontainer config for {len(names)} profile(s) in {out_dir}")


@generate.command()
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/docker-bake.hcl'), help='Output path')
@click.pass_context
def bake(ctx: click.Context, output: Path) -> None:
    """Generate docker-bake.hcl for all profiles."""
    from solen.generators.bake import generate_bake

    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output

    count = generate_bake(repo_root, output_path)
    click.echo(f"✅ Generated docker-bake.hcl with {count} profile(s): {output_path}")





# ============================================================================
# VALIDATE commands
# ============================================================================

@cli.group()
def validate() -> None:
    """Validate features and configuration."""
    pass


@validate.command()
@click.option('--fix', is_flag=True, help='Auto-fix issues (e.g., permissions)')
@click.option('--verbose', is_flag=True, help='Also print warning details')
@click.pass_context
def features(ctx: click.Context, fix: bool, verbose: bool) -> None:
    """Validate all features against schema."""
    from solen.validators.features import FeatureValidator, validate_features

    repo_root = ctx.obj['repo_root']
    features_dir = repo_root / 'features'

    passed, total, errors, warnings = validate_features(features_dir, auto_fix=fix)

    if passed == total:
        click.echo(f"✅ All {total} features passed validation")
        if warnings:
            click.echo(f"⚠️  {warnings} warning(s)")
        sys.exit(0)

    # Surface per-feature error detail so failures are actionable in CI.
    validator = FeatureValidator(features_dir)
    for path in sorted(p for p in features_dir.iterdir()
                       if p.is_dir() and not p.name.startswith('.')):
        fv = validator.validate_feature(path)
        for r in fv.errors:
            click.echo(f"   ✗ {fv.feature_id}: {r.message}", err=True)
        if verbose:
            for r in fv.warnings:
                click.echo(f"   ⚠ {fv.feature_id}: {r.message}", err=True)

    click.echo(f"❌ {total - passed}/{total} features failed validation", err=True)
    click.echo(f"   {errors} error(s), {warnings} warning(s)", err=True)
    sys.exit(1)


@validate.command(name='propagate-versions')
@click.option('--versions', type=click.Path(exists=True, path_type=Path),
              default=Path('versions/versions.yaml'), help='Source of truth (versions/versions.yaml)')
@click.option('--write', is_flag=True, help='Write updates to feature.json files')
@click.option('--verbose', is_flag=True, help='Print full JSON report')
@click.pass_context
def propagate_versions_cmd(ctx: click.Context, versions: Path, write: bool, verbose: bool) -> None:
    """Propagate central version values into feature `options.version.default`."""
    repo_root = ctx.obj['repo_root']
    versions_path = repo_root / versions if not versions.is_absolute() else versions
    try:
        from solen.core.versions import propagate_versions
    except Exception as e:
        click.echo(f"❌ Could not import propagation helper: {e}", err=True)
        sys.exit(1)

    rpt = propagate_versions(repo_root, versions_path, write=write)
    if verbose:
        click.echo(json.dumps(rpt, indent=2, ensure_ascii=False))
    else:
        updates = rpt.get('updates', [])
        written = [u for u in updates if u.get('written')]
        changed = [u for u in updates if u.get('old') != u.get('new')]
        click.echo(f"Checked {len(updates)} features; candidates={len(changed)}; written={len(written)}")
        if not write and len(changed) > 0:
            click.echo("Run with --write to apply changes", err=True)
    sys.exit(0)


# ============================================================================
# ANALYZE commands
# ============================================================================

@cli.group()
def analyze() -> None:
    """Analyze features and dependencies."""
    pass


@analyze.command(name='features')
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/feature-matrix.md'), help='Output matrix file')
@click.pass_context
def analyze_features_cmd(ctx: click.Context, output: Path) -> None:
    """Analyze features and generate dependency matrix."""
    from solen.generators.readme import analyze_features

    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output

    count = analyze_features(repo_root, output_path)
    click.echo(f"✅ Analyzed {count} features")
    click.echo(f"✅ Generated matrix: {output_path}")


def main() -> None:
    """Entry point for CLI."""
    cli(obj={})


# ==========================================================================
# BUILD (end-to-end)
# ==========================================================================


@cli.command()
@click.option('--target', help='Bake target to build (e.g., final-20-01-quarto-lecture-java-lts)')
@click.option('--profile', help='Profile name to build (alias for --target final-<profile>)')
@click.option('--platforms', default='', help='Comma-separated platforms for buildx (default: platforms from the bake file)')
@click.option('--no-cache', is_flag=True, help='Pass no-cache to buildx bake')
@click.option('--load', is_flag=True, help='Pass --load to buildx bake')
@click.option('--push', is_flag=True, help='Pass --push to buildx bake')
@click.option('--progress', default='plain', help='Buildx progress mode (default: plain)')
@click.option('--all', 'all_targets', is_flag=True, help='Build all targets from generated bake file')
@click.option('--yes', is_flag=True, help='Skip confirmation when using --all')
@click.option('--filter', 'filter_targets', default=None, help='Comma-separated subset of targets to build when using --all')
@click.pass_context
def build(ctx: click.Context, target: str, profile: str, platforms: str, no_cache: bool, load: bool, push: bool, progress: str, all_targets: bool, yes: bool, filter_targets: str) -> None:
    """End-to-end generate + bake build for a profile/target.

    This command runs: generate dockerfile (all), generate bake, then invokes
    `docker buildx bake` for the requested target while injecting build args
    such as `QUARTO_VERSION` from `versions.json`.
    """
    repo_root = ctx.obj['repo_root']

    # Determine bake target (unless building all targets)
    if all_targets:
        # confirm potentially expensive operation
        if not yes:
            if not click.confirm('⚠️  You are about to build ALL targets defined in the generated bake file. Continue?'):
                click.echo('Aborted by user')
                sys.exit(0)
        bake_target = None
    else:
        if profile and not target:
            target = f"final-{profile}"
        if not target:
            click.echo('❌ Error: must specify --target or --profile (or use --all)', err=True)
            sys.exit(1)
        bake_target = target

    # Generate multi-profile Dockerfile and bake file
    click.echo('🔧 Generating Dockerfile and docker-bake.hcl...')
    from solen.generators.bake import generate_bake
    from solen.generators.dockerfile_gen import generate_multi_profile_dockerfile

    dockerfile_out = repo_root / 'generated' / 'Dockerfile'
    bake_out = repo_root / 'generated' / 'docker-bake.hcl'

    profiles = generate_multi_profile_dockerfile(repo_root, dockerfile_out)
    click.echo(f"✅ Generated Dockerfile with {len(profiles)} profiles: {dockerfile_out}")
    generate_bake(repo_root, bake_out)
    click.echo(f"✅ Generated docker-bake.hcl: {bake_out}")

    # Build the docker buildx bake command
    bake_cmd = ['docker', 'buildx', 'bake', '--file', str(bake_out)]
    if bake_target:
        bake_cmd.append(bake_target)
    else:
        # when building all, allow restricting to a filtered list of targets
        if filter_targets:
            sel = [t.strip() for t in filter_targets.split(',') if t.strip()]
            bake_cmd.extend(sel)

    # Platforms
    plat_list = [p.strip() for p in platforms.split(',') if p.strip()]
    if plat_list:
        bake_cmd.extend(['--set', f"*.platform={','.join(plat_list)}"])

    # no-cache
    if no_cache:
        bake_cmd.extend(['--set', "*.no-cache=true"])

    # load
    if load:
        bake_cmd.append('--load')

    # push
    if push:
        bake_cmd.append('--push')

    # progress
    if progress:
        bake_cmd.extend(['--progress', progress])

    click.echo('🔨 Running buildx bake...')

    # Execute the command and stream output
    try:
        click.echo(' '.join(shlex.quote(x) for x in bake_cmd))
        proc = subprocess.run(bake_cmd, cwd=str(repo_root), check=False)
        if proc.returncode != 0:
            click.echo(f'❌ buildx bake failed (exit {proc.returncode})', err=True)
            sys.exit(proc.returncode)
        else:
            click.echo('✅ Build completed')
    except FileNotFoundError:
        click.echo('❌ docker or docker buildx not found in PATH', err=True)
        sys.exit(1)


# ---------------------
# Versions commands
# ---------------------


@cli.group()
def versions() -> None:
    """Version management commands."""
    pass


@versions.command()
@click.option('--versions', type=click.Path(exists=True, path_type=Path), default=Path('versions/versions.yaml'))
@click.option('--out', type=click.Path(path_type=Path), default=Path('generated/version-checks'))
@click.option('--github-token', default=None, help='GitHub token for API requests')
@click.pass_context
def check(ctx: click.Context, versions: Path, out: Path, github_token: str | None) -> None:
    """Check upstream versions for tools defined in the versions manifest."""
    from solen.core.versions import run_check

    repo_root = ctx.obj['repo_root']
    versions_path = repo_root / versions if not versions.is_absolute() else versions
    out_dir = repo_root / out if not out.is_absolute() else out

    # prefer explicit flag, then env var; warn if no token (unauthenticated requests may be rate-limited)
    token = github_token or os.environ.get("GITHUB_TOKEN")
    if not token:
        click.echo("⚠️  No GitHub token provided — unauthenticated API requests may be rate-limited", err=True)

    res = run_check(repo_root, versions_path, out_dir, token)
    click.echo(f"✅ Report written: {res['report_path']}")


@versions.command()
@click.option('--source', type=click.Path(exists=True, path_type=Path),
              default=Path('versions/versions.yaml'), help='Source of truth (versions/versions.yaml)')
@click.option('--target', type=click.Path(path_type=Path),
              default=Path('versions.json'), help='Generated flat manifest (versions.json)')
@click.option('--check', is_flag=True, help='Fail if target is out of date, without writing')
@click.pass_context
def sync(ctx: click.Context, source: Path, target: Path, check: bool) -> None:
    """Generate the flat versions.json manifest from versions/versions.yaml."""
    from solen.core.versions import sync_versions, versions_up_to_date

    repo_root = ctx.obj['repo_root']
    source_path = repo_root / source if not source.is_absolute() else source
    target_path = repo_root / target if not target.is_absolute() else target

    if check:
        if versions_up_to_date(source_path, target_path):
            click.echo(f"✅ {target_path} is up to date with {source_path}")
            return
        click.echo(f"❌ {target_path} is out of date — run `solen versions sync`", err=True)
        sys.exit(1)

    try:
        res = sync_versions(source_path, target_path)
    except ValueError as e:
        click.echo(f"❌ {e}", err=True)
        sys.exit(1)
    click.echo(f"✅ Wrote {res['path']} ({res['tools']} tools, base={res['base']})")


if __name__ == '__main__':
    main()
