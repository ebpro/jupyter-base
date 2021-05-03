#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
. ${DIR}/env.sh

docker run --rm \
	--name ${PWD##*/} \
	--volume $PWD/notebooks:/home/jovyan/work \
        --publish 8888:8888 \
        --env NB_UID=$UID \
	--env JUPYTER_ENABLE_LAB=yes \
        ${BASE}:$SHA 
	#--env CHOWN_HOME_OPTS='-R' --env CHOWN_HOME=yes \
