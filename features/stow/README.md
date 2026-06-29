GNU Stow feature
=================

Installs GNU Stow (used for managing dotfiles and symlink trees).

Usage
-----

The feature installs `stow` via `apt` when available. If `apt` is not present and Homebrew is available, it falls back to `brew install stow`.

To test locally:

```bash
sudo ./install.sh
command -v stow && stow --version
```
