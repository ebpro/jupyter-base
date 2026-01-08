# Profile Samples

This directory contains minimal working examples for each Solen profile. Each sample demonstrates the key features and typical use cases for its respective profile.

## Available Samples

### [`quarto-lecture-containers/`](quarto-lecture-containers/)

**Profile**: `quarto-lecture-containers`

A complete teaching environment for creating lecture materials about containers and databases using Quarto.

**Features demonstrated**:
- Quarto document rendering (HTML, PDF, reveal.js)
- Docker-in-Docker for container demonstrations
- PostgreSQL database operations
- Java 25 examples
- Python data analysis and visualization

**Quick start**:
```bash
cd quarto-lecture-containers
docker run -it --rm -v "$(pwd)":/home/jovyan/work \
  ghcr.io/ebpro/solen:quarto-lecture-containers-develop
```

## Using These Samples

### Local Development

Each sample can be used directly with the corresponding container image:

```bash
# Navigate to the sample directory
cd samples/quarto-lecture-containers

# Run with volume mount
docker run -it --rm \
  -v "$(pwd)":/home/jovyan/work \
  -w /home/jovyan/work \
  ghcr.io/ebpro/solen:quarto-lecture-containers-develop \
  bash
```

### VS Code Dev Containers

Most samples include a `.devcontainer/` configuration. To use:

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. Open the sample directory in VS Code
3. Click "Reopen in Container" when prompted

### Testing a Sample

Each sample includes instructions in its README.md for:
- Building/rendering output
- Running demonstrations
- Connecting to services
- Common troubleshooting

## Sample Structure

Each sample follows a consistent structure:

```
sample-name/
├── README.md              # Sample-specific documentation
├── _quarto.yml           # Configuration (if Quarto-based)
├── main-document.qmd     # Main content
├── examples/             # Code examples
│   └── ...
├── data/                 # Sample datasets
│   └── ...
├── .gitignore           # Ignore build artifacts
└── docker-compose.yml   # Optional compose file
```

## Contributing Samples

When adding a new sample:

1. Create a directory named after the profile (e.g., `minimal/`, `python-db/`)
2. Include a comprehensive README.md with:
   - Profile name and description
   - Features demonstrated
   - Quick start instructions
   - Usage examples
   - Troubleshooting tips
3. Keep it minimal but complete - focus on one clear use case
4. Test the sample with the actual container image
5. Include any necessary data files or configuration

## Profile Coverage

- ✅ `quarto-lecture-containers` - Complete
- ⬜ `minimal` - TODO
- ⬜ `data-science` - TODO
- ⬜ `python-db` - TODO
- ⬜ `java-jdk25` - TODO
- ⬜ `k8s-dev` - TODO
- ⬜ `ml-teaching` - TODO
- ⬜ `web-dev` - TODO

## Additional Resources

- [Main Solen Documentation](../README.md)
- [Profile System Guide](../PROFILE_SYSTEM.md)
- [Build Instructions](../DEVELOPER.md)

---

**Note**: These samples are designed for teaching and demonstration purposes. For production use, review security settings and customize as needed.
