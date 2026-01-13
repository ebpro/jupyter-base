"""Feature structure validation."""

from __future__ import annotations

import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any


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
    results: list[ValidationResult]
    
    @property
    def errors(self) -> list[ValidationResult]:
        return [r for r in self.results if r.level == 'error' and not r.passed]
    
    @property
    def warnings(self) -> list[ValidationResult]:
        return [r for r in self.results if r.level == 'warning' and not r.passed]
    
    @property
    def passed(self) -> bool:
        return len(self.errors) == 0


class FeatureValidator:
    """Validates devcontainer feature structure."""
    
    REQUIRED_FIELDS = ['id', 'name', 'version']
    RECOMMENDED_FIELDS = ['description', 'documentationURL']
    VALID_CATEGORIES = [
        'language', 'tool', 'runtime', 'database', 'bundle', 'system', 'development'
    ]
    VALID_COMPLEXITIES = ['simple', 'moderate', 'complex']
    SEMVER_PATTERN = re.compile(r'^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$')
    
    def __init__(self, features_dir: Path):
        self.features_dir = features_dir
        self.all_feature_ids: set[str] = set()
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
                    with open(feature_json, encoding='utf-8') as f:
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
            with open(feature_json_path, encoding='utf-8') as f:
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
    
    def _validate_required_fields(self, data: dict[str, Any]) -> list[ValidationResult]:
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
    
    def _validate_recommended_fields(self, data: dict[str, Any]) -> list[ValidationResult]:
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
    
    def _validate_custom_metadata(self, solen_data: dict[str, Any]) -> list[ValidationResult]:
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
    
    def _validate_dependencies(self, deps: list[str]) -> list[ValidationResult]:
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
    
    def _validate_install_script(self, feature_path: Path) -> list[ValidationResult]:
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
            with open(install_script, encoding='utf-8') as f:
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
    
    def _validate_readme(self, feature_path: Path) -> list[ValidationResult]:
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
            with open(readme_path, encoding='utf-8') as f:
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


def auto_fix_feature(feature_path: Path, validation: FeatureValidation) -> int:
    """Auto-fix common issues. Returns number of fixes applied."""
    fixed = 0
    
    # Fix non-executable install.sh
    install_script = feature_path / 'install.sh'
    if install_script.exists() and not os.access(install_script, os.X_OK):
        try:
            os.chmod(
                install_script, 
                os.stat(install_script).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            )
            fixed += 1
        except Exception:
            pass
    
    return fixed


def validate_features(
    features_dir: Path,
    feature_ids: list[str] | None = None,
    verbose: bool = False,
    auto_fix: bool = False,
    fail_on_warnings: bool = False
) -> tuple[int, int, int, int]:
    """Validate features and return (passed, total, errors, warnings).
    
    Args:
        features_dir: Path to features directory
        feature_ids: Optional list of specific feature IDs to validate
        verbose: Show all validation checks
        auto_fix: Auto-fix common issues
        fail_on_warnings: Treat warnings as failures
        
    Returns:
        Tuple of (passed_count, total_count, total_errors, total_warnings)
    """
    # Initialize validator
    validator = FeatureValidator(features_dir)
    
    # Determine which features to validate
    if feature_ids:
        feature_paths = [features_dir / fid for fid in feature_ids]
        # Validate paths exist
        for path in feature_paths:
            if not path.exists():
                raise FileNotFoundError(f"Feature not found: {path}")
    else:
        # Validate all features
        feature_paths = sorted([
            p for p in features_dir.iterdir() 
            if p.is_dir() and not p.name.startswith('.')
        ])
    
    if not feature_paths:
        return (0, 0, 0, 0)
    
    # Validate each feature
    validations = []
    
    for feature_path in feature_paths:
        validation = validator.validate_feature(feature_path)
        
        # Auto-fix if requested
        if auto_fix:
            fixed = auto_fix_feature(feature_path, validation)
            if fixed > 0:
                # Re-validate after fixes
                validation = validator.validate_feature(feature_path)
        
        validations.append(validation)
    
    # Calculate summary
    total = len(validations)
    passed = sum(1 for v in validations if v.passed)
    if fail_on_warnings:
        passed = sum(1 for v in validations if v.passed and not v.warnings)
    
    total_errors = sum(len(v.errors) for v in validations)
    total_warnings = sum(len(v.warnings) for v in validations)
    
    return (passed, total, total_errors, total_warnings)
