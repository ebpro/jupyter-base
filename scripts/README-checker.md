# Prototype: versions checker

 This folder contains a minimal prototype of a versions checker used to detect newer upstream releases.

 Files:

 - `check-versions.py`: prototype script. Requires `pyyaml`, `requests`, `semver`.
 - `requirements-checker.txt`: dependencies list for the prototype.
 - `../versions/versions.yaml`: example central manifest used by the script.

 Quick start:

 ```bash
 python3 -m pip install -r scripts/requirements-checker.txt
 python3 scripts/check-versions.py --versions versions/versions.yaml
 ```

 Notes:
 - This is a minimal prototype. It only checks GitHub `releases/latest` for listed github sources.
 - Per-feature hooks: place `features/<name>/check_version.py` with a `check_version(info, github_token)` function to override default behaviour for that tool/feature. The checker will run the hook and use its returned dict.
 - For production: add caching, rate-limit handling, more robust per-feature checkers, credentials for private registries, and CI integration.
