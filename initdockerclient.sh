#/bin/bash

## Direct sock mount
if [[ -S /var/run/docker.sock ]]; then
	chown jovyan: /var/run/docker.sock

## Remote docker daemon (like DIND)	
elif [[ -f ${DOCKER_TLS_CERTDIR:-/certs}/client ]]; then
	mkdir -p /home/jovyan/.docker
	cp -v ${DOCKER_TLS_CERTDIR:-/certs}/client/{ca,cert,key}.pem /home/jovyan/.docker
	chown -R $NB_USER: /home/jovyan/.docker
fi
