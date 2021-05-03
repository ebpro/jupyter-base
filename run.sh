#!/usr/bin/env bash
docker run --rm \
	--name jupyterjava_${PWD##*/} \
	--volume $PWD/notebooks:/home/jovyan/work \
        --publish 8888:8888 \
        --env NB_UID=$UID \
	--env JUPYTER_ENABLE_LAB=yes \
        brunoe/jupyterjava:feature_dockerstack
#	--env NOTEBOOK_SRC_SUBDIR=${PWD##*/} \
#        --volume $PWD/src:/src \
#        --volume ~/.m2:/home/jovyan/.m2 \
#        --volume $PWD/codeserver:/codeserver \
	#--env CHOWN_HOME_OPTS='-R' --env CHOWN_HOME=yes \
