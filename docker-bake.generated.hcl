group "all" {
  targets = [
    "final-base",
    "final-codeserver",
    "final-containers-tools",
    "final-data-science",
    "final-dev",
    "final-full",
    "final-jetbrains-gateway",
    "final-k8s-dev",
    "final-k8s-sim",
    "final-minimal",
    "final-podman",
    "final-quarto-lecture",
    "final-quarto-lecture-full",
    "final-teaching-interactive",
  ]
}

targets = {
  "final-base" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-base"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-codeserver" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-codeserver"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-containers-tools" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-containers-tools"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-data-science" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-data-science"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-dev" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-dev"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-full" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-full"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-jetbrains-gateway" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-jetbrains-gateway"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-k8s-dev" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-k8s-dev"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-k8s-sim" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-k8s-sim"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-minimal" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-minimal"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-podman" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-podman"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-quarto-lecture" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-quarto-lecture"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-quarto-lecture-full" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-quarto-lecture-full"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

  "final-teaching-interactive" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-teaching-interactive"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ebpro/jupyter-base:latest",
      "ebpro/jupyter-base:latest-sha",
    ]
  }

