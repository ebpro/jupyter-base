from pathlib import Path
from solen.validators.features import FeatureValidator

if __name__ == '__main__':
    repo_root = Path.cwd()
    features_dir = repo_root / 'features'
    validator = FeatureValidator(features_dir)
    paths = sorted([p for p in features_dir.iterdir() if p.is_dir() and not p.name.startswith('.')])
    failed = []
    for p in paths:
        v = validator.validate_feature(p)
        if v.errors:
            failed.append((p.name, v))
            print('FEATURE:', p.name)
            for r in v.results:
                status = 'OK' if r.passed else 'X'
                print(f"  {status} {r.level.upper():6} - {r.message}")
            print()
    print('SUMMARY')
    print('Total features:', len(paths))
    print('Features with errors:', len(failed))
    print('List:', ','.join([f[0] for f in failed]))
