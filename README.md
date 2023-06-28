# JupyterLab Base Image

**Test it on** [![Binder](https://mybinder.org/badge_logo.svg)](https://mybinder.org/v2/gh/ebpro/notebook-qs-base/develop)

A base image for the JupyterLab based on jupyter/base-notebook :
  
* ZSH
* TinyTeX
* Code Server Web IDE
* Jupyter Book and Quarto
* Web remote desktop

## Quickstart

```bash
docker run --rm --name jupyter-base-${PWD##*/} \
  --volume data-jupyter-workdir:/home/jovyan/work \ 
  --publish 8888:8888 \
  --env NB_UID=$UID \
  brunoe/jupyter-base:develop
```

Replace `data-jupyter-workdir` by `data-${PWD##*/}` by to have a seprate config for a project.

## Host files and UIDs

```bash
docker run --rm --name jupyter-base-${PWD##*/} \
  --user root \
  --volume data-jupyter-workdir:/home/jovyan/work \ 
  --volume $PWD:/home/jovyan/local \
  --publish 8888:8888 \
  --env NB_UID=$UID \
  brunoe/jupyter-base:develop
```

## With Docker support

```bash
docker run --rm --name jupyter-base-${PWD##*/} \
  --user root \
  --privileged=true \
  --volume $PWD:/home/jovyan/work/${PWD##*/} \
  --volume $PWD:/home/jovyan/local \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --publish 8888:8888 \
  --env NB_UID=$UID \
  brunoe/jupyter-base:develop
```
