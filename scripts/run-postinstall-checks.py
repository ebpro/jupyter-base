#!/usr/bin/env python3
"""
Run postInstallCheck commands for all features in an image

This script extracts postInstallCheck commands from feature.json files
and executes them in a running container to verify feature installations.

Usage:
  ./scripts/run-postinstall-checks.py IMAGE [OPTIONS]

Examples:
  # Check all features in an image
  ./scripts/run-postinstall-checks.py ghcr.io/ebpro/jupyter-base:dev

  # Check specific features only
  ./scripts/run-postinstall-checks.py jupyter:local --features node,python-base,gh-cli

  # Verbose output
  ./scripts/run-postinstall-checks.py jupyter:test --verbose
"""

import json
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import argparse

# Colors
GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

def log_pass(msg: str):
    print(f"{GREEN}✓{NC} {msg}")

def log_fail(msg: str):
    print(f"{RED}✗{NC} {msg}")

def log_warn(msg: str):
    print(f"{YELLOW}⚠{NC}  {msg}")

def log_info(msg: str):
    print(f"{BLUE}→{NC} {msg}")

def load_features(features_dir: Path) -> Dict[str, dict]:
    """Load all feature.json files and extract postInstallCheck info"""
    features = {}
    
    for feature_json in features_dir.glob("**/feature.json"):
        try:
            with open(feature_json) as f:
                data = json.load(f)
            
            feature_id = data.get('id')
            if not feature_id:
                log_warn(f"Feature at {feature_json.parent.name} has no 'id' field, skipping")
                continue
            
            post_install_check = data.get('postInstallCheck', {})
            if post_install_check:
                features[feature_id] = {
                    'name': data.get('name', feature_id),
                    'version': data.get('version', 'unknown'),
                    'command': post_install_check.get('command', ''),
                    'description': post_install_check.get('description', ''),
                    'path': feature_json
                }
        
        except Exception as e:
            log_warn(f"Error reading {feature_json}: {e}")
    
    return features

def run_check_in_container(
    image: str,
    command: str,
    user: str = 'jovyan',
    verbose: bool = False
) -> Tuple[bool, str]:
    """Execute a postInstallCheck command in a container"""
    try:
        # Use login shell to ensure environment is loaded
        docker_cmd = [
            'docker', 'run', '--rm',
            '-u', user,
            image,
            'bash', '-lc', command
        ]
        
        result = subprocess.run(
            docker_cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        success = result.returncode == 0
        output = result.stdout + result.stderr
        
        if verbose and output:
            print(f"  Output: {output.strip()}")
        
        return success, output
    
    except subprocess.TimeoutExpired:
        return False, "Command timed out after 30 seconds"
    except Exception as e:
        return False, str(e)

def detect_features_in_image(image: str) -> List[str]:
    """Detect which features are installed in an image by checking for markers"""
    try:
        result = subprocess.run(
            ['docker', 'run', '--rm', image, 'bash', '-c', 'ls /opt/.features 2>/dev/null || echo'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().split('\n')
        
    except Exception:
        pass
    
    return []

def main():
    parser = argparse.ArgumentParser(
        description='Run postInstallCheck commands for features in a container image',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Check all features in an image
  %(prog)s ghcr.io/ebpro/jupyter-base:dev

  # Check specific features only
  %(prog)s jupyter:local --features node,python-base,gh-cli

  # Verbose output with full command output
  %(prog)s jupyter:test --verbose

  # Check as root user
  %(prog)s jupyter:test --user root
        """
    )
    
    parser.add_argument(
        'image',
        help='Container image to test (e.g., ghcr.io/ebpro/jupyter-base:dev)'
    )
    
    parser.add_argument(
        '--features',
        help='Comma-separated list of features to check (default: all)'
    )
    
    parser.add_argument(
        '--user',
        default='jovyan',
        help='User to run commands as (default: jovyan)'
    )
    
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Show detailed output from checks'
    )
    
    parser.add_argument(
        '--detect',
        action='store_true',
        help='Detect installed features from image markers'
    )
    
    args = parser.parse_args()
    
    # Verify Docker is available
    try:
        subprocess.run(['docker', '--version'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        log_fail("Docker is not available. Please install Docker.")
        return 1
    
    # Verify image exists
    try:
        subprocess.run(
            ['docker', 'image', 'inspect', args.image],
            capture_output=True,
            check=True,
            timeout=10
        )
    except subprocess.CalledProcessError:
        log_fail(f"Image not found: {args.image}")
        log_info("Pull the image or build it first")
        return 1
    except subprocess.TimeoutExpired:
        log_fail("Timeout while inspecting image")
        return 1
    
    print("=" * 70)
    print(f"PostInstallCheck Runner")
    print("=" * 70)
    log_info(f"Image: {args.image}")
    log_info(f"User: {args.user}")
    print()
    
    # Detect installed features if requested
    if args.detect:
        log_info("Detecting installed features...")
        detected = detect_features_in_image(args.image)
        if detected:
            log_info(f"Found {len(detected)} feature markers:")
            for feat in detected:
                print(f"  - {feat}")
        else:
            log_warn("No feature markers found (image may not use markers)")
        print()
    
    # Load feature definitions
    script_dir = Path(__file__).parent
    root_dir = script_dir.parent
    features_dir = root_dir / '.devcontainer' / 'features'
    
    if not features_dir.exists():
        log_fail(f"Features directory not found: {features_dir}")
        return 1
    
    log_info("Loading feature definitions...")
    features = load_features(features_dir)
    
    if not features:
        log_fail("No features with postInstallCheck found")
        return 1
    
    log_info(f"Found {len(features)} features with postInstallCheck")
    print()
    
    # Filter features if specified
    if args.features:
        requested = set(f.strip() for f in args.features.split(','))
        features = {k: v for k, v in features.items() if k in requested}
        log_info(f"Testing {len(features)} requested features")
        print()
    
    # Run checks
    print("=" * 70)
    print("Running PostInstall Checks")
    print("=" * 70)
    print()
    
    passed = 0
    failed = 0
    skipped = 0
    
    for feature_id, info in sorted(features.items()):
        command = info['command']
        description = info['description'] or command
        
        if not command:
            log_warn(f"{feature_id}: No command defined")
            skipped += 1
            continue
        
        log_info(f"Testing: {feature_id}")
        if args.verbose:
            print(f"  Command: {command}")
            print(f"  Description: {description}")
        
        success, output = run_check_in_container(
            args.image,
            command,
            args.user,
            args.verbose
        )
        
        if success:
            log_pass(f"{feature_id}: {description}")
            passed += 1
        else:
            log_fail(f"{feature_id}: {description}")
            if not args.verbose and output:
                print(f"  Error: {output.strip()[:200]}")
            failed += 1
        
        print()
    
    # Summary
    print("=" * 70)
    print("Summary")
    print("=" * 70)
    print(f"Total features: {len(features)}")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print(f"Skipped: {skipped}")
    print("=" * 70)
    
    if failed == 0:
        print(f"{GREEN}✓ All postInstall checks passed!{NC}")
        return 0
    else:
        print(f"{RED}✗ {failed} checks failed{NC}")
        return 1

if __name__ == '__main__':
    sys.exit(main())
