#!/usr/bin/env python3
"""Solen CLI - Main command-line interface."""

import sys
from pathlib import Path
from typing import Optional

import click

from solen import __version__


@click.group()
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

@cli.group()
def generate() -> None:
    """Generate profiles, Dockerfiles, and other artifacts."""
    pass


@generate.command()
@click.option('--matrix', type=click.Path(exists=True, path_type=Path), 
              required=True, help='Path to matrix YAML file')
@click.option('--out', type=click.Path(path_type=Path), 
              default=Path('generated/profiles'), help='Output directory')
@click.option('--prefix', default='', help='Filename prefix for generated profiles')
@click.pass_context
def profiles(ctx: click.Context, matrix: Path, out: Path, prefix: str) -> None:
    """Generate profile files from YAML matrix definitions."""
    from solen.generators.profiles import generate_profiles
    
    repo_root = ctx.obj['repo_root']
    matrix_path = repo_root / matrix if not matrix.is_absolute() else matrix
    out_dir = repo_root / out if not out.is_absolute() else out
    
    count = generate_profiles(matrix_path, out_dir, prefix)
    click.echo(f"✅ Generated {count} profile(s) in {out_dir}")


@generate.command()
@click.option('--profile', help='Profile name to generate Dockerfile for')
@click.option('--all', 'all_profiles', is_flag=True, help='Generate Dockerfile with all profiles')
@click.option('--output', type=click.Path(path_type=Path), 
              default=Path('generated/Dockerfile'), help='Output Dockerfile path')
@click.pass_context
def dockerfile(ctx: click.Context, profile: Optional[str], all_profiles: bool, output: Path) -> None:
    """Generate Dockerfile for a profile or all profiles."""
    from solen.generators.dockerfile import (
        generate_single_profile_dockerfile,
        generate_multi_profile_dockerfile,
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
        else:
            generate_single_profile_dockerfile(repo_root, profile, output_path)
            click.echo(f"✅ Generated Dockerfile for {profile}: {output_path}")
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        sys.exit(1)


@generate.command()
@click.option('--profile', required=True, help='Profile name')
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/devcontainer.json'), help='Output path')
@click.pass_context
def devcontainer(ctx: click.Context, profile: str, output: Path) -> None:
    """Generate devcontainer.json for a profile."""
    from solen.generators.devcontainer import generate_devcontainer
    
    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output
    
    generate_devcontainer(repo_root, profile, output_path)
    click.echo(f"✅ Generated devcontainer.json: {output_path}")


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


@generate.command()
@click.option('--force', is_flag=True, help='Overwrite existing READMEs')
@click.option('--matrix', type=click.Path(path_type=Path),
              help='Also generate feature matrix file')
@click.pass_context
def readmes(ctx: click.Context, force: bool, matrix: Optional[Path]) -> None:
    """Generate README.md files for all features."""
    from solen.generators.readme import generate_readmes
    
    repo_root = ctx.obj['repo_root']
    matrix_path = repo_root / matrix if matrix and not matrix.is_absolute() else matrix
    
    count = generate_readmes(repo_root, force=force, matrix_path=matrix_path)
    click.echo(f"✅ Generated {count} README(s)")
    if matrix_path:
        click.echo(f"✅ Generated feature matrix: {matrix_path}")


# ============================================================================
# VALIDATE commands
# ============================================================================

@cli.group()
def validate() -> None:
    """Validate features and configuration."""
    pass


@validate.command()
@click.option('--fix', is_flag=True, help='Auto-fix issues (e.g., permissions)')
@click.pass_context
def features(ctx: click.Context, fix: bool) -> None:
    """Validate all features against schema."""
    from solen.validators.features import validate_features
    
    repo_root = ctx.obj['repo_root']
    features_dir = repo_root / 'features'
    
    passed, total, errors, warnings = validate_features(features_dir, auto_fix=fix)
    
    if passed == total:
        click.echo(f"✅ All {total} features passed validation")
        if warnings:
            click.echo(f"⚠️  {warnings} warning(s)")
        sys.exit(0)
    else:
        click.echo(f"❌ {total - passed}/{total} features failed validation", err=True)
        click.echo(f"   {errors} error(s), {warnings} warning(s)", err=True)
        sys.exit(1)


# ============================================================================
# ANALYZE commands
# ============================================================================

@cli.group()
def analyze() -> None:
    """Analyze features and dependencies."""
    pass


@analyze.command()
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/feature-matrix.md'), help='Output matrix file')
@click.pass_context
def features(ctx: click.Context, output: Path) -> None:
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


if __name__ == '__main__':
    main()
