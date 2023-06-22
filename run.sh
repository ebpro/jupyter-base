#!/usr/bin/env bash

WORKDIR=$HOME/JUPYTER_WORK
IMAGE_REPO=brunoe
TAG=docker.io/${IMAGE_REPO}/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD|tr '/' '-') 

docker run --rm -it \
    --user root \
    --name ${PWD##*/} \
    --volume JUPYTER_WORKDIR:/home/jovyan/work \
    --publish 8888:8888 \
    --env NB_UID=$UID \
    ${TAG} $@
