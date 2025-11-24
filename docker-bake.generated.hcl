group "all" {
  targets = [
    "final-base",
    "final-codeserver",
    "final-data-science",
    "final-dev",
    "final-full",
    "final-k8s-dev",
    "final-minimal",
    "final-podman",
    "final-quarto-lecture",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
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
      "testuser/testimg:latest",
      "testuser/testimg:latest-sha",
    ]
  }

