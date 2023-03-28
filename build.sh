#!/bin/bash
docker build --progress=plain -t brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD) .
