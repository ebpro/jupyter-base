---
description: A description of your rule
---
**Continue: Codebase Access Rule**

- **Purpose:** Allow the `Continue` extension to read repository files and answer chat questions about the project in the `#codebase` context, while enforcing privacy and safety constraints.

- **Scope:**
  - **Channels/tags:** `#codebase` (explicitly opt-in).
  - **Paths accessible (read-only):** repository source files, `features/`, `profiles/`, `generated/`, `scripts/`, `versions.json`, and any file not excluded by `.gitignore` or the rule's exclusions below.
  - **No write access:** The extension MUST NOT modify any files, create commits, or run destructive commands in the repository.

- **Allowed actions:**
  - Read and index project files to answer user questions (implementation may use grep, search, or language-model indexing).
  - Quote or reference file paths and short snippets (<= 10 lines) with file links in answers.
  - Explain code, suggest edits, and propose commands; all change suggestions must be provided as patch snippets or `git` commands the user must run manually.

- **Prohibitions & Safety:**
  - Do NOT disclose secrets, credentials, tokens, or private keys found in the repository (mask or refuse). If a secret is discovered, warn the user and recommend remediation.
  - Do NOT execute code, build steps, or external network calls on behalf of the user without explicit consent.
  - Do NOT access files outside the repository root.
  - Respect `.gitignore` and any `/.continue/exclude` patterns (if present).

- **Version resolution:** Features that depend on `versions.json` (for example `quarto`) may read `/versions.json` or `/Artefacts/versions.json` as available in the repo; prefer the canonical `versions.json` at repository root.

- **Answer formatting requirements:**
  - Always include a **Source** bullet for any factual claim derived from code, using relative file links and line ranges when referencing code (e.g., `features/quarto/install.sh`).
  - Use short code blocks for suggested edits and clearly label them as `patch` or `shell` examples.
  - If making multi-file suggestions, provide a short checklist of commands the user can run to apply changes.

- **Examples:**
  - "What version of Quarto does this repo pin?" → read `versions.json` and cite the path: `versions.json`.
  - "How is `quarto-cli` installed in the build?" → cite `features/quarto-cli/install.sh` with line snippet and explain.
  - "Suggest a small patch to make the feature source `scripts/lib/features.sh` canonical" → provide a unified diff and list commands to apply it (`git apply` / `git add` / `git commit`).

- **Revocation & audit:**
  - To revoke this rule, remove this file or add an explicit deny rule in `/.continue/exclude`.
  - All reads by the extension should be logged (if the extension supports auditing); recommend enabling audit logging when the extension is active.

- **Owner / Contact:**
  - Repository maintainers (use repository `CODEOWNERS` if present) are responsible for rule updates.
