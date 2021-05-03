#!/bin/bash
REGISTRY=brunoe
IMAGE_NAME=${PWD##*/}

CURRENT=`pwd`
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $DIR
BASE=${REGISTRY}/${IMAGE_NAME}
BRANCH=`git rev-parse --abbrev-ref HEAD|tr '/' '_' `
SHA=`git log -1 --pretty=%h`
cd $CURRENT
