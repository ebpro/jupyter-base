My Utils
========

This feature installs a small collection of helper scripts into the user's `~/bin` directory. The target user is taken from the `NB_USER` environment variable (defaults to `jovyan`).

Installed scripts:

- `display_files.sh` — list files (small helper)
- `get_src_dir.sh` — set `SRC_DIR` environment variables for materials
- `gihub-repos.sh` — (fetch & print repos list as markdown)
- `gitpull.sh` — clone or update a repository and print markdown info

Usage (during runtime / container):

```bash
# install manually from feature dir (example)
cd features/my-utils
./install.sh
```
