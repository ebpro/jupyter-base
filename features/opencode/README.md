# opencode

**Purpose:** Installs the OpenCode AI coding agent and deploys the private `ebpro/opencode-config` repository.

## Description

Installs [OpenCode](https://opencode.ai) as a global npm package (`opencode-ai`) and —
when `SSH_PRIVATE_KEY` is provided at build time — clones the private
`git@github.com:ebpro/opencode-config.git` repository into the dev user's
`~/.config/opencode/`.

The binary is installed system-wide (available to all users). The configuration is
deployed for the dev user (`jovyan` by default) with correct ownership.

The feature is idempotent and safe to run more than once per image build.

## Dependencies

- `node` (provides `node` + `npm`)

## Required environment variables

The bundled configuration is **credential-agnostic**: it references the LLM
credentials through environment variables. These values are provided by the caller
at container start and are **never** baked into the image.

| Variable          | Purpose                                          |
|-------------------|--------------------------------------------------|
| `VLLM_API_KEY`    | API key for the vLLM-backed LLM endpoint          |
| `LIS_LAB_API_KEY` | API key for the LIS Lab LLM endpoint              |

> The exact names and roles are defined by the `ebpro/opencode-config` repository;
> the values above are the documented credential contract.

## Usage

Enable the feature in your `devcontainer.json` (see the manual base template at
`devcontainer/template/devcontainer.json`):

```json
{
  "features": {
    "ghcr.io/ebpro/solen/opencode:1.0.0": {}
  }
}
```

To deploy the private configuration, provide a deploy key with read access to
`ebpro/opencode-config` at build time:

```bash
SSH_PRIVATE_KEY="$(cat ~/.ssh/deploy_opencode)" ./build.sh my-profile
```

At runtime, start the container with the LLM credentials:

```bash
docker run -e VLLM_API_KEY=... -e LIS_LAB_API_KEY=... <image>
```

Inside the container:

```bash
opencode --version
opencode
```

## Options

| Option    | Type   | Default   | Description                                       |
|-----------|--------|-----------|---------------------------------------------------|
| `version` | string | `1.18.29` | `opencode-ai` npm package version to install       |

## Notes

- Without `SSH_PRIVATE_KEY`, only the binary is installed; `~/.config/opencode/` is
  created but left empty.
- `SSH_PRIVATE_KEY` is written to a temporary file (mode `600`), used only for the
  clone, and removed before the build layer is committed (via an `EXIT` trap).
- The clone is scoped to `github.com` with `StrictHostKeyChecking no` and
  `UserKnownHostsFile /dev/null` so it is fully non-interactive in CI.
