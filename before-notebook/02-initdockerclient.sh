#!/bin/bash

echo -e "\e[93m**** Chown docker user access ****\e[38;5;241m"

## Direct sock mount
if [[ -S /var/run/docker.sock ]]; then
	echo "Found /var/run/docker.sock"
	chown jovyan: /var/run/docker.sock

## Remote docker daemon (like DIND)	
elif [[ -f ${DOCKER_TLS_CERTDIR:-/certs}/client ]]; then
	echo "Found DOCKER_TLS_CERTDIR/client."
	mkdir -p /home/jovyan/.docker
	cp -v ${DOCKER_TLS_CERTDIR:-/certs}/client/{ca,cert,key}.pem /home/jovyan/.docker
	chown -R $NB_USER: /home/jovyan/.docker
else 
	echo "Neither /var/run/docker.sock nor DOCKER_TLS_CERTDIR found."
fi
