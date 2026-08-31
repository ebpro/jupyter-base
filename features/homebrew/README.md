Homebrew (Linux) feature
=========================

Installs Homebrew (Linuxbrew) into the `NB_USER` home prefix (default `jovyan`).

Notes
-----
- Installer runs as the non-root `NB_USER` to avoid permission issues.
- The feature writes `/etc/profile.d/homebrew.sh` so interactive shells pick up `brew` on PATH.
- Use `HOMEBREW_NO_ANALYTICS=1` and `NONINTERACTIVE=1` in CI if you want non-interactive behaviour.

Testing
-------

```bash
# run as root inside build context
NB_USER=jovyan ./install.sh
su - jovyan -c 'command -v brew && brew --version'
```
