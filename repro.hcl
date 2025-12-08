targets = {
  "final-00-00-base" = {
    context = "."
    dockerfile = "Dockerfile.generated"
    target = "final-00-00-base"
    platforms = [
      "linux/amd64",
      "linux/arm64",
    ]
    tags = [
      "ghcr.io/ebpro/solen:repro-test",
    ]
  }
}
