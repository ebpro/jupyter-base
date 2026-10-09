# PlantUML

**Installs:** graphviz, plantuml

**Purpose:** Installs Graphviz (`dot`) and PlantUML (`plantuml`) for diagram rendering from Quarto

## Description

Installs Graphviz (`dot`) and PlantUML (`plantuml`) so that Quarto documents can
render `plantuml` code blocks. Quarto invokes `plantuml`, which in turn uses
Graphviz's `dot` layout engine to produce the final diagram images.

## Dependencies

- `system-essentials`

## Usage

The feature is enabled automatically by the Quarto profiles through
`bundle-quarto-base` (all `quarto-*` profiles). No manual configuration is
required: once the image is built, `dot` and `plantuml` are available on `PATH`
and Quarto renders `plantuml` blocks out of the box.

## Options

None. The feature installs the default `graphviz` and `plantuml` packages with
no feature-specific options.
