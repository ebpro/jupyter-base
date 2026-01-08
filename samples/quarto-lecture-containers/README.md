# Quarto Lecture Containers Sample

This sample demonstrates the `quarto-lecture-containers` profile, which provides a complete environment for creating Quarto-based lecture materials with container demonstrations.

## Features Included

- **Quarto**: Full installation with PDF, HTML, and reveal.js support
- **Java 25**: Latest JDK for Java examples
- **Docker-in-Docker**: Run container examples within the environment
- **PostgreSQL**: Client and server (sidecar) for database examples
- **Python**: Full data science stack (NumPy, Pandas, Matplotlib, etc.)
- **Jupyter**: Interactive notebook support

## Quick Start

### Using Docker

```bash
# Pull the image
docker pull ghcr.io/ebpro/solen:quarto-lecture-containers-develop

# Run the container with volume mount
docker run -it --rm \
  -v "$(pwd)":/home/jovyan/work \
  -p 8888:8888 \
  ghcr.io/ebpro/solen:quarto-lecture-containers-develop
```

### Using VS Code Dev Containers

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. Open this directory in VS Code
3. Click "Reopen in Container" when prompted (or use Command Palette: "Dev Containers: Reopen in Container")
4. Wait for the container to start and services to be ready
5. Start working! All services (PostgreSQL, Docker-in-Docker) are automatically available

The devcontainer includes:
- Main workspace with Quarto, Java, Python, and all tools
- PostgreSQL database (accessible at `postgres:5432`)
- Docker-in-Docker for running container examples
- Pre-configured VS Code extensions (Quarto, Python, Java, Docker)

## Sample Project Structure

```
.
├── README.md                          # This file
├── lecture.qmd                        # Main Quarto document
├── examples/
│   ├── java-example.java             # Java code example
│   └── docker-example.dockerfile      # Dockerfile example
├── data/
│   └── sample.csv                     # Sample dataset
└── _quarto.yml                        # Quarto configuration
```

## Rendering the Document

### HTML Output

```bash
quarto render lecture.qmd --to html
```

### PDF Output

```bash
quarto render lecture.qmd --to pdf
```

### Reveal.js Presentation

```bash
quarto render lecture.qmd --to revealjs
```

### Preview with Live Reload

```bash
quarto preview lecture.qmd
```

## Working with Services

### PostgreSQL

The PostgreSQL server is available as a sidecar service:

```bash
# Connect to PostgreSQL
psql -h postgres -U jovyan -d demo

# Run SQL from command line
psql -h postgres -U jovyan -d demo -c "SELECT version();"
```

### Docker-in-Docker

Build and run containers from within the environment:

```bash
# Build a container
docker build -t my-app examples/

# Run containers
docker run --rm my-app

# List running containers
docker ps
```

## Using Jupyter Notebooks

Start JupyterLab:

```bash
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser
```

Then open the URL shown in your browser.

## Customization

### Adding Dependencies

Python packages:
```bash
pip install --user package-name
```

System packages (requires sudo):
```bash
sudo apt-get update && sudo apt-get install -y package-name
```

### Quarto Extensions

```bash
quarto add extension-name
```

## Tips

1. **Save your work**: Always mount a volume to `/home/jovyan/work` to persist your files
2. **Port forwarding**: Use `-p` to expose additional ports (e.g., for web servers)
3. **Environment variables**: Set with `-e VAR=value` when running docker
4. **Resource limits**: Adjust with `--memory` and `--cpus` flags

## Troubleshooting

### Docker-in-Docker not working

Ensure you're running with `--privileged` flag or appropriate capabilities:

```bash
docker run -it --rm --privileged \
  -v "$(pwd)":/home/jovyan/work \
  ghcr.io/ebpro/solen:quarto-lecture-containers-develop
```

### PostgreSQL connection refused

Verify the postgres service is running:
```bash
docker compose ps postgres
```

### Quarto render fails

Check TeX installation:
```bash
quarto check
```

## License

This sample is part of the Solen project. See the main repository for license information.
