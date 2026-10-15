# poppler-utils

**Installs:** poppler-utils

**Purpose:** Provides the Poppler PDF command-line tools (`pdftotext`, `pdftoppm`, `pdfinfo`, ...)

## Description

Installs the Ubuntu `poppler-utils` package, which provides the Poppler CLI
suite for working with PDF files from a shell.

This is a **test-parity / availability** dependency that is carried in a
published artifact. It is **not** a Quarto runtime dependency.

- **Test parity (primary).** Quarto's own PDF-text verification tests are
  *optional*: when `pdftotext` is absent they skip gracefully instead of
  failing, so the assertion silently stops running. Installing `poppler-utils`
  keeps that test path executing. Upstream `quarto-cli` PR #13939 documents
  exactly this as an optional test-only dependency, worded
  `"pdftotext (poppler)"`.
- **Availability (secondary).** `pdftoppm`, `pdfinfo`, `pdfseparate`,
  `pdfunite`, `pdffonts` and friends are generally useful to users of the
  lecture image (screenshotting slides, inspecting generated PDFs, extracting
  text in notebook cells).

Quarto itself vendors every binary it runs — `DENO`, `DENO_DOM`, `PANDOC`,
`DARTSASS`, `ESBUILD`, `TYPST`, `TYPST_GATHER`, `VERAPDF` — and its PDF preview
renders with vendored `pdf.js`. Quarto's installable-tool list is
`tinytex`, `chromium`/`chrome-headless-shell` and `verapdf`. None of these are
Poppler, and nothing in this feature is needed for `quarto render` to work.

### Scope limit — `poppler-data` is intentionally absent

The installer uses `--no-install-recommends`, which keeps the recommended
`poppler-data` package out of the image. `poppler-data` is roughly 40 MB of
glyph/metrics tables for CJK and unusual font encodings. Consequence:

- Latin/Helvetica-based PDFs (the overwhelmingly common lecture case, and the
  fixture the post-install check ships with) work.
- PDFs using CJK or unusual encodings may extract garbled or empty text with
  `pdftotext`, or rasterise with missing glyphs via `pdftoppm`.

If a profile ever needs that coverage, add `poppler-data` explicitly rather
than relaxing `--no-install-recommends` globally.

### Deliberately excluded from `base.required`

`poppler-utils` is attached to the `quarto-full` profile only. It is *not* in
`inputs/apt-packages/base` (`base`, `base.required`, `base.optional`), because
a test-only, optional dependency must not be hard-asserted by every profile —
a `base.required` miss exits `1` on every build, which is precisely the
coupling the recent apt-package work removed.

## Usage

Enable the feature in a profile matrix entry:

```yaml
matrix:
  my-profile:
    features:
      - poppler-utils
```

Then from the tool it is a normal CLI command:

```bash
pdftotext input.pdf -            # text to stdout
pdftoppm -png -singlefile input.pdf out   # out.png
pdfinfo input.pdf
```

Prefer the absolute paths (`/usr/bin/pdftotext`) in automation — see
*Post-install check* below for why.

### Post-install check

`feature.json → postInstallCheck.command` does more than test for file
existence. It:

1. decodes an embedded one-page PDF fixture (base64, synthesised at check time
   into a `mktemp -d` workdir, removed by an `EXIT` trap),
2. rasterises it with `pdftoppm -png -singlefile` and validates the PNG magic
   bytes,
3. extracts the marker `POPCHECK7X` from the same fixture with `pdftotext`.

The check calls **`/usr/bin/pdftoppm` and `/usr/bin/pdftotext` by absolute
path on purpose.** The generated image prepends `~/miniforge3/bin`,
`~/.linuxbrew/bin` and the TinyTeX bin directories ahead of `${PATH}`
(`solen-cli/solen/generators/dockerfile_template.j2:112-115`). A
`command -v pdftotext`-style probe could therefore certify a **conda-forge
`poppler`** build instead of the apt package this feature actually installed —
a green check hiding a red install. The absolute paths remove that ambiguity,
and `provides` records the same absolute paths.

Two verification traps found while calibrating this check, recorded so they are
not reintroduced:

- `--version` is unusable as a liveness probe: 6 of the 13 `poppler-utils`
  binaries print `I/O Error: Couldn't open file '--version'` on a *healthy*
  install.
- `dpkg-query` is unusable as a verdict on Ubuntu 24.04: it returned `rc=0` for
  the not-installed *virtual* name `libpng16-16` while printing
  `unknown ok not-installed`. The check therefore tests executability and
  behaviour, not package-manager state.

## Options

None. This feature takes no options and pins no version; it installs whatever
`poppler-utils` the noble apt pocket provides (verified: `24.02.0-1ubuntu9.10`,
13 binaries, on both amd64 and arm64). Real marginal cost on `quarto-full` is
11 new packages, ~7.2 MiB installed, ~2.4 MB download (`libpoppler134` is 3.5
MiB of that).

## Dependencies

- `system-essentials`

## Provided binaries

Only the two binaries the check certifies are declared in `provides`:

- `/usr/bin/pdftoppm`
- `/usr/bin/pdftotext`

The remaining Poppler CLI tools (`pdfinfo`, `pdfseparate`, `pdfunite`,
`pdffonts`, `pdfimages`, ...) are installed but deliberately not asserted.
