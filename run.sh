#!/usr/bin/env bash

WORKDIR=$HOME/JUPYTER_WORK_DIR

echo brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD) 

docker run --rm -it \
	--user root \
	--name ${PWD##*/} \
	--volume $WORKDIR:/home/jovyan/work \
    --publish 8888:8888 \
    --env NB_UID=$UID \
    brunoe/${PWD##*/}:$(git rev-parse --abbrev-ref HEAD|tr '/' '-') $@ 
#	--env CHOWN_HOME_OPTS='-R'	--env CHOWN_HOME=yes \
	