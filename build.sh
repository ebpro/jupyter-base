#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
. ${DIR}/env.sh

docker build \
	--file Dockerfile \
	-t ${BASE}:$SHA \
	`[[ "$BRANCH" != "master" ]] && echo -t ${BASE}:$BRANCH` \
	`[[ "$BRANCH" == "master" ]] && echo -t ${BASE}:latest` \
	 .
