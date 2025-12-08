group "all" {
  targets = [
    "final-00-00-base",
    "final-00-01-minimal",
    "final-10-00-dev",
    "final-10-01-containers-tools",
    "final-10-02-podman",
    "final-20-00-data-science",
    "final-20-01-quarto-lecture",
    "final-20-02-quarto-lecture-full",
    "final-20-03-teaching-interactive",
    "final-30-00-k8s-dev",
    "final-30-01-k8s-sim",
    "final-40-00-codeserver",
    "final-40-01-jetbrains-gateway",
    "final-50-00-full",
  ]
}

target "final-00-00-base" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-00-00-base"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-00-01-minimal" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-00-01-minimal"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-10-00-dev" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-10-00-dev"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-10-01-containers-tools" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-10-01-containers-tools"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-10-02-podman" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-10-02-podman"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-20-00-data-science" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-20-00-data-science"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-20-01-quarto-lecture" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-20-01-quarto-lecture"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-20-02-quarto-lecture-full" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-20-02-quarto-lecture-full"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-20-03-teaching-interactive" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-20-03-teaching-interactive"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-30-00-k8s-dev" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-30-00-k8s-dev"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-30-01-k8s-sim" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-30-01-k8s-sim"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-40-00-codeserver" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-40-00-codeserver"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-40-01-jetbrains-gateway" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-40-01-jetbrains-gateway"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

target "final-50-00-full" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-50-00-full"
  platforms = [
    "linux/amd64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:latest",
    "ghcr.io/ebpro/solen:latest-sha",
  ]
}

