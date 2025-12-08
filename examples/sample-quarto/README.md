Sample Quarto project

This minimal example shows a Quarto document that runs a Python "Hello, world" snippet.

Files:
- `index.qmd` — Quarto markdown file with a Python code cell.

How to render locally (if you have Quarto installed):

```bash
quarto render examples/sample-quarto/index.qmd -o examples/sample-quarto/_site
open examples/sample-quarto/_site/index.html
```

If you prefer not to install Quarto, you can view the `.qmd` file directly on GitHub or use a developer environment that includes Quarto.
