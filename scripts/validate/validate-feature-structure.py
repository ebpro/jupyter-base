#!/usr/bin/env python3
"""
Validate feature structure and metadata compliance.

Checks:
- feature.json exists and is valid JSON
- Required fields present and valid
- install.sh exists and is executable
- README.md exists (optional but recommended)
- Dependencies reference existing features
- Version follows semver
- Shell script basic validation
"""

import json
import sys
import os
import re
import stat
from pathlib import Path
from typing import Dict, List, Tuple, Set
from dataclasses import dataclass

@dataclass
class ValidationResult:
    """Single validation check result."""
    passed: bool
    level: str  # 'error', 'warning', 'info'
    message: str
    
@dataclass
class FeatureValidation:
    """Complete validation results for a feature."""
    feature_id: str
    path: Path
    results: List[ValidationResult]
    
    @property
    def errors(self) -> List[ValidationResult]:
        return [r for r in self.results if r.level == 'error' and not r.passed]
    
    @property
    def warnings(self) -> List[ValidationResult]:
        return [r for r in self.results if r.level == 'warning' and not r.passed]
    
    @property
    def passed(self) -> bool:
        return len(self.errors) == 0


class FeatureValidator:
    """Validates devcontainer feature structure."""
    
    REQUIRED_FIELDS = ['id', 'name', 'version']
    RECOMMENDED_FIELDS = ['description', 'documentationURL']
    VALID_CATEGORIES = ['language', 'tool', 'runtime', 'database', 'bundle', 'system', 'development']
    VALID_COMPLEXITIES = ['simple', 'moderate', 'complex']
    SEMVER_PATTERN = re.compile(r'^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$')
    
    def __init__(self, features_dir: Path):
        self.features_dir = features_dir
        self.all_feature_ids: Set[str] = set()
        self._collect_feature_ids()
    
    def _collect_feature_ids(self):
        """Collect all valid feature IDs for dependency validation."""
        if not self.features_dir.exists():
            return
        
        for feature_path in self.features_dir.iterdir():
            if not feature_path.is_dir():
                continue
            
            feature_json = feature_path / 'feature.json'
            if feature_json.exists():
                try:
                    with open(feature_json) as f:
                        data = json.load(f)
                        if 'id' in data:
                            self.all_feature_ids.add(data['id'])
                except Exception:
                    pass
    
    def validate_feature(self, feature_path: Path) -> FeatureValidation:
        """Run all validation checks on a feature."""
        results = []
        feature_id = feature_path.name
        
        # Check feature.json exists
        feature_json_path = feature_path / 'feature.json'
        if not feature_json_path.exists():
            results.append(ValidationResult(
                passed=False,
                level='error',
                message='feature.json not found'
            ))
            return FeatureValidation(feature_id, feature_path, results)
        
        # Load and validate JSON
        try:
            with open(feature_json_path) as f:
                feature_data = json.load(f)
            results.append(ValidationResult(
                passed=True,
                level='info',
                message='feature.json is valid JSON'
            ))
        except json.JSONDecodeError as e:
            results.append(ValidationResult(
                passed=False,
                level='error',
                message=f'feature.json is invalid JSON: {e}'
            ))
            return FeatureValidation(feature_id, feature_path, results)
        
        # Validate required fields
        results.extend(self._validate_required_fields(feature_data))
        
        # Validate recommended fields
        results.extend(self._validate_recommended_fields(feature_data))
        
        # Validate version format
        if 'version' in feature_data:
            results.append(self._validate_semver(feature_data['version']))
        
        # Validate custom metadata
        if 'customizations' in feature_data and 'solen' in feature_data['customizations']:
            results.extend(self._validate_custom_metadata(feature_data['customizations']['solen']))
        
        # Validate dependencies
        if 'dependsOn' in feature_data:
            results.extend(self._validate_dependencies(feature_data['dependsOn']))
        
        # Check install.sh
        results.extend(self._validate_install_script(feature_path))
        
        # Check README.md
        results.extend(self._validate_readme(feature_path))
        
        return FeatureValidation(feature_id, feature_path, results)
    
    def _validate_required_fields(self, data: Dict) -> List[ValidationResult]:
        """Check required fields are present and non-empty."""
        results = []
        for field in self.REQUIRED_FIELDS:
            if field not in data:
                results.append(ValidationResult(
                    passed=False,
                    level='error',
                    message=f"Required field '{field}' is missing"
                ))
            elif not data[field]:
                results.append(ValidationResult(
                    passed=False,
                    level='error',
                    message=f"Required field '{field}' is empty"
                ))
            else:
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Required field '{field}' present"
                ))
        return results
    
    def _validate_recommended_fields(self, data: Dict) -> List[ValidationResult]:
        """Check recommended fields."""
        results = []
        for field in self.RECOMMENDED_FIELDS:
            if field not in data or not data[field]:
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message=f"Recommended field '{field}' is missing or empty"
                ))
        return results
    
    def _validate_semver(self, version: str) -> ValidationResult:
        """Validate semantic version format."""
        if self.SEMVER_PATTERN.match(version):
            return ValidationResult(
                passed=True,
                level='info',
                message=f"Version '{version}' follows semver"
            )
        else:
            return ValidationResult(
                passed=False,
                level='warning',
                message=f"Version '{version}' does not follow semver (e.g., 1.0.0)"
            )
    
    def _validate_custom_metadata(self, solen_data: Dict) -> List[ValidationResult]:
        """Validate custom solen metadata."""
        results = []
        
        # Validate category
        if 'category' in solen_data:
            if solen_data['category'] in self.VALID_CATEGORIES:
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Category '{solen_data['category']}' is valid"
                ))
            else:
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message=f"Category '{solen_data['category']}' not in standard list: {', '.join(self.VALID_CATEGORIES)}"
                ))
        
        # Validate complexity
        if 'complexity' in solen_data:
            if solen_data['complexity'] in self.VALID_COMPLEXITIES:
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Complexity '{solen_data['complexity']}' is valid"
                ))
            else:
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message=f"Complexity '{solen_data['complexity']}' not in valid values: {', '.join(self.VALID_COMPLEXITIES)}"
                ))
        
        # Validate installTimeMinutes
        if 'installTimeMinutes' in solen_data:
            if isinstance(solen_data['installTimeMinutes'], (int, float)) and solen_data['installTimeMinutes'] > 0:
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message='installTimeMinutes is valid'
                ))
            else:
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message='installTimeMinutes should be a positive number'
                ))
        
        return results
    
    def _validate_dependencies(self, deps: List[str]) -> List[ValidationResult]:
        """Validate feature dependencies exist."""
        results = []
        for dep in deps:
            # Skip bundle references (they're text-based, not features)
            if dep.startswith('bundle-'):
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Dependency '{dep}' is a bundle (text-based, not validated)"
                ))
                continue
            
            # Skip library helpers (shared utilities, not features)
            if dep.startswith('_lib/'):
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Dependency '{dep}' is a library helper (not validated)"
                ))
                continue
            
            if dep in self.all_feature_ids:
                results.append(ValidationResult(
                    passed=True,
                    level='info',
                    message=f"Dependency '{dep}' exists"
                ))
            else:
                results.append(ValidationResult(
                    passed=False,
                    level='error',
                    message=f"Dependency '{dep}' not found in features directory"
                ))
        return results
    
    def _validate_install_script(self, feature_path: Path) -> List[ValidationResult]:
        """Validate install.sh exists and is executable."""
        results = []
        install_script = feature_path / 'install.sh'
        
        if not install_script.exists():
            results.append(ValidationResult(
                passed=False,
                level='error',
                message='install.sh not found'
            ))
            return results
        
        results.append(ValidationResult(
            passed=True,
            level='info',
            message='install.sh exists'
        ))
        
        # Check if executable
        if os.access(install_script, os.X_OK):
            results.append(ValidationResult(
                passed=True,
                level='info',
                message='install.sh is executable'
            ))
        else:
            results.append(ValidationResult(
                passed=False,
                level='error',
                message='install.sh is not executable (chmod +x install.sh)'
            ))
        
        # Basic shell script checks
        try:
            with open(install_script) as f:
                content = f.read()
            
            # Check shebang
            if not content.startswith('#!'):
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message='install.sh missing shebang (#!/bin/bash or #!/bin/sh)'
                ))
            
            # Check for set -e (fail on error)
            if 'set -e' not in content and 'set -eu' not in content:
                results.append(ValidationResult(
                    passed=False,
                    level='warning',
                    message='install.sh should contain "set -e" for error handling'
                ))
            
        except Exception as e:
            results.append(ValidationResult(
                passed=False,
                level='warning',
                message=f'Could not read install.sh: {e}'
            ))
        
        return results
    
    def _validate_readme(self, feature_path: Path) -> List[ValidationResult]:
        """Validate README.md exists and has required sections."""
        results = []
        readme_path = feature_path / 'README.md'
        
        if not readme_path.exists():
            results.append(ValidationResult(
                passed=False,
                level='warning',
                message='README.md not found (recommended for documentation)'
            ))
            return results
        
        results.append(ValidationResult(
            passed=True,
            level='info',
            message='README.md exists'
        ))
        
        # Check for recommended sections
        try:
            with open(readme_path) as f:
                content = f.read().lower()
            
            recommended_sections = ['description', 'usage', 'options']
            for section in recommended_sections:
                if section not in content:
                    results.append(ValidationResult(
                        passed=False,
                        level='warning',
                        message=f"README.md missing recommended section: '{section}'"
                    ))
        except Exception:
            pass
        
        return results


def print_validation_results(validation: FeatureValidation, verbose: bool = False):
    """Print validation results for a feature."""
    # Header
    status = '✅' if validation.passed else '❌'
    print(f"\n{status} {validation.feature_id}")
    print(f"   Path: {validation.path}")
    
    # Errors
    if validation.errors:
        print(f"\n   ❌ Errors ({len(validation.errors)}):")
        for result in validation.errors:
            print(f"      • {result.message}")
    
    # Warnings
    if validation.warnings:
        print(f"\n   ⚠️  Warnings ({len(validation.warnings)}):")
        for result in validation.warnings:
            print(f"      • {result.message}")
    
    # Verbose: show all checks
    if verbose and validation.passed:
        passed_checks = [r for r in validation.results if r.passed]
        if passed_checks:
            print(f"\n   ℹ️  Passed checks ({len(passed_checks)}):")
            for result in passed_checks[:5]:  # Limit to first 5
                print(f"      • {result.message}")
            if len(passed_checks) > 5:
                print(f"      • ... and {len(passed_checks) - 5} more")


def auto_fix_feature(feature_path: Path, validation: FeatureValidation) -> int:
    """Auto-fix common issues. Returns number of fixes applied."""
    fixed = 0
    
    # Fix non-executable install.sh
    install_script = feature_path / 'install.sh'
    if install_script.exists() and not os.access(install_script, os.X_OK):
        try:
            os.chmod(install_script, os.stat(install_script).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            fixed += 1
        except Exception:
            pass
    
    return fixed


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Validate devcontainer feature structure and metadata'
    )
    parser.add_argument(
        'features',
        nargs='*',
        help='Specific feature directories to validate (default: all features)'
    )
    parser.add_argument(
        '--features-dir',
        type=Path,
        default=Path('features'),
        help='Path to features directory (default: features)'
    )
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Show all validation checks, not just errors and warnings'
    )
    parser.add_argument(
        '--fail-on-warnings',
        action='store_true',
        help='Exit with error code if warnings are found'
    )
    parser.add_argument(
        '--fix',
        action='store_true',
        help='Auto-fix common issues (chmod +x install.sh)'
    )
    
    args = parser.parse_args()
    
    # Resolve features directory
    features_dir = args.features_dir
    if not features_dir.is_absolute():
        features_dir = Path.cwd() / features_dir
    
    if not features_dir.exists():
        print(f"❌ Features directory not found: {features_dir}", file=sys.stderr)
        return 1
    
    # Initialize validator
    validator = FeatureValidator(features_dir)
    
    # Determine which features to validate
    if args.features:
        feature_paths = [features_dir / f for f in args.features]
        # Validate paths exist
        for path in feature_paths:
            if not path.exists():
                print(f"❌ Feature not found: {path}", file=sys.stderr)
                return 1
    else:
        # Validate all features
        feature_paths = sorted([
            p for p in features_dir.iterdir() 
            if p.is_dir() and not p.name.startswith('.')
        ])
    
    if not feature_paths:
        print("⚠️  No features found to validate", file=sys.stderr)
        return 0
    
    print(f"🔍 Validating {len(feature_paths)} feature(s)...")
    
    # Validate each feature
    validations = []
    fixed_count = 0
    
    for feature_path in feature_paths:
        validation = validator.validate_feature(feature_path)
        validations.append(validation)
        
        # Auto-fix if requested
        if args.fix:
            fixed = auto_fix_feature(feature_path, validation)
            if fixed > 0:
                fixed_count += fixed
                print(f"   🔧 Auto-fixed {fixed} issue(s)")
                # Re-validate after fixes
                validation = validator.validate_feature(feature_path)
                validations[-1] = validation
        
        print_validation_results(validation, verbose=args.verbose)
    
    # Summary
    print("\n" + "="*60)
    total = len(validations)
    passed = sum(1 for v in validations if v.passed)
    failed = total - passed
    total_errors = sum(len(v.errors) for v in validations)
    total_warnings = sum(len(v.warnings) for v in validations)
    
    print(f"📊 Summary: {passed}/{total} features passed")
    if total_errors > 0:
        print(f"   ❌ {total_errors} error(s)")
    if total_warnings > 0:
        print(f"   ⚠️  {total_warnings} warning(s)")
    if args.fix and fixed_count > 0:
        print(f"   🔧 {fixed_count} issue(s) auto-fixed")
    
    # Determine exit code
    if failed > 0:
        return 1
    if args.fail_on_warnings and total_warnings > 0:
        return 1
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
