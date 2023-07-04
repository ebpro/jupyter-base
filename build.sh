#!/bin/bash
#docker build --progress=plain -t brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD|tr '/' '-') .
DOCKER_BUILDKIT=1 docker \
    build \
        --build-arg ENV \
        --progress=plain \
        --tag brunoe/${PWD##*/}:${ENV:+$ENV-}$(git rev-parse --abbrev-ref HEAD|tr '/' '-') \
        $@ \
        .
