#!/bin/bash
#docker build --progress=plain -t brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD|tr '/' '-') .
DOCKER_BUILDKIT=1 docker build -t brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD|tr '/' '-') $@ .
