#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
echo $DIR
. ${DIR}/env.sh

BASE=${REGISTRY}/${IMAGE_NAME}
BRANCH=`git rev-parse --abbrev-ref HEAD`

echo Branche:$BRANCH
docker push ${BASE} --all-tags

#docker push ${BASE}:`git log -1 --pretty=%h`
#docker push ${BASE}:`git rev-parse --abbrev-ref HEAD`
#[[ "$BRANCH" == "master" ]] && docker push -t "${BASE}:latest"
