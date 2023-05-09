# THE BASE IMAGE
ARG LAB_BASE=jupyter/minimal-notebook:lab-3.6.3
# minimal or empty 
ARG ENV

# GENERAL
ARG WORK_DIR=$HOME/work
ARG NOTEBOOKS_DIR=$WORK_DIR/notebooks
ARG MATERIALS_DIR=$WORK_DIR/materials

# DOCKER
#ARG DOCKER_CLI_VERSION="23.0.1"
#ARG DOCKER_COMPOSE_VERSION="2.17.0"
#ARG DOCKER_BUILDX_VERSION="0.10.4"
#ARG DOCKER_CONFIG="/usr/local/lib/docker/cli-plugins"
ARG DOCKER_CONFIG="/home/jovyan/.docker/cli-plugins"
# CODE SERVER
ARG CODESERVER_DIR=/opt/codeserver
ARG CODESERVEREXT_DIR=${CODESERVER_DIR}/extensions
ARG CODE_WORKINGDIR=/home/jovyan/work
ARG CODESERVERDATA_DIR=${CODE_WORKINGDIR}/.config/codeserver/data
ARG CODE_SERVER_CONFIG=${CODE_WORKINGDIR}/.config/code-server/config.yaml

# PYTHON
ARG PIP_CACHE_DIR=${WORK_DIR}/var/cache/buildkit/pip/
ARG CONDA_PKG_DIR=/opt/conda/pkgs/

#######################
# BASE BUILDER        #
#######################
FROM ubuntu AS builder_base
RUN  apt-get update \
  && apt-get install -y curl git wget zsh \
  && rm -rf /var/lib/apt/lists/*

###############
# ZSH         #
###############
FROM builder_base AS builder_zsh
RUN useradd -ms /bin/bash jovyan
USER jovyan
WORKDIR /home/jovyan

ADD zsh/initzsh.sh /tmp/initzsh.sh
RUN echo -e "\e[93m**** Configure a nice zsh environment ****\e[38;5;241m" && \
        git clone --recursive https://github.com/sorin-ionescu/prezto.git "$HOME/.zprezto" && \
        zsh -c /tmp/initzsh.sh && \
        sed -i -e "s/zstyle ':prezto:module:prompt' theme 'sorin'/zstyle ':prezto:module:prompt' theme 'powerlevel10k'/" $HOME/.zpreztorc && \
        echo "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> $HOME/.zshrc && \
        echo "PATH=/opt/bin:$PATH" >> $HOME/.zshrc
RUN wget -O ~/.zprezto/modules/completion/external/src/_docker https://raw.githubusercontent.com/docker/cli/master/contrib/completion/zsh/_docker
ENV PATH=/opt/bin:$PATH

#######################
# PYTHON_DEPENDENCIES #
#######################
FROM ${LAB_BASE} AS builder_pythondependencies
# PIP and conda packages to install
COPY Artefacts/environment.yml /tmp
COPY Artefacts/requirements.txt /tmp
USER root
# Installs python packages
RUN --mount=type=cache,target=/home/jovyan/work/var/cache/buildkit/pip/,sharing=locked  \
    --mount=type=cache,target=/opt/conda/pkgs/,sharing=locked  \
        echo -e "\e[93m***** Install Python packages ****\e[38;5;241m" && \
        pip install -r /tmp/requirements.txt && \
        mamba env update -p ${CONDA_DIR} -f /tmp/environment.yml && \
        echo -e "\e[93m**** Install ZSH Kernel for Jupyter ****\e[38;5;241m" && \
            python3 -m zsh_jupyter_kernel.install --sys-prefix 

###############
# CODE SERVER #
###############
FROM builder_base AS builder_codeserver_minimal

FROM builder_base AS builder_codeserver_default
ARG CODESERVER_DIR
ARG CODESERVEREXT_DIR
ARG CODE_WORKINGDIR
ARG CODESERVERDATA_DIR
ENV CODESERVER_DIR=${CODESERVER_DIR}
ENV CODESERVEREXT_DIR=${CODESERVEREXT_DIR}
ENV CODE_WORKINGDIR=${CODE_WORKINGDIR}
ENV CODESERVERDATA_DIR=${CODESERVERDATA_DIR}
# Codeserver extensions to install
COPY Artefacts/codeserver_extensions /tmp/
RUN echo -e "\e[93m**** Installs Code Server Web ****\e[38;5;241m" && \
                curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/opt --method=standalone && \
                mkdir -p ${CODESERVERDATA_DIR} &&\
                mkdir -p ${CODESERVEREXT_DIR} && \
                PATH=/opt/bin:$PATH code-server \
                	--user-data-dir $CODESERVERDATA_DIR\
                	--extensions-dir $CODESERVEREXT_DIR \
                    $(cat /tmp/codeserver_extensions|sed 's/./--install-extension &/')

FROM builder_codeserver_${ENV:-default} AS builder_codeserver

############
## DOCKER ##
############

FROM builder_base AS builder_docker_minimal

FROM builder_base AS builder_docker_default
# Installs only the docker client and docker compose
# easly used by mounting docker socket 
#    docker run -v /var/run/docker.sock:/var/run/docker.socker
# container must be start as root to change socket owner ship before privilege drop
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM}
ENV BUILDPLATFORM=${BUILDPLATFORM}

#ARG DOCKER_CLI_VERSION
#ARG DOCKER_COMPOSE_VERSION
#ARG DOCKER_BUILDX_VERSION
ARG DOCKER_CONFIG
ENV DOCKER_CONFIG=${DOCKER_CONFIG}
ARG BIN_DIR
ENV BIN_DIR=/usr/local/bin

SHELL [ "/bin/bash", "-c" ]

# TOO : Should be replace by generic function 
RUN DOCKER_CLI_VERSION=$(comm -12  \
  <(curl -s https://download.docker.com/linux/static/stable/aarch64/ | \
      sed -n 's/.*docker-\([0-9]*\.[0-9]*\.[0-9]*\).tgz.*/\1/p' | tail -n1) \
  <(curl -s https://download.docker.com/linux/static/stable/x86_64/ | \
      sed -n 's/.*docker-\([0-9]*\.[0-9]*\.[0-9]*\).tgz.*/\1/p' | tail -n1)) && \
# DOCKER_COMPOSE_VERSION=$(comm -12 \
#   <(curl -s https://api.github.com/repos/docker/compose/releases/latest \
#     | grep "browser_download_url.*-linux-x86_64\"$"| cut -d : -f 2,3 \
#     | tr -d '"' | sed "s/.*v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/") \
#   <(curl -s https://api.github.com/repos/docker/compose/releases/latest \
#     | grep "browser_download_url.*-linux-aarch64\"$" \
#     | cut -d : -f 2,3 \
#     | tr -d '"' \
#     | sed "s/.*v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/")) && \
# DOCKER_BUILDX_VERSION=$(comm -12 \
#   <(curl -s https://api.github.com/repos/docker/buildx/releases/latest \
#     | grep "browser_download_url.*.linux-amd64\"$" | cut -d : -f 2,3 \
# | tr -d '"' | sed "s/.*v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/") \
#   <(curl -s https://api.github.com/repos/docker/buildx/releases/latest \
#     | grep "browser_download_url.*.linux-arm64\"$" | cut -d : -f 2,3 \
#     | tr -d '"' | sed "s/.*v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/")) && \
if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
		ARCH_LEG=x86_64; \
		ARCH=amd64; \
	elif [ "$TARGETPLATFORM" = "linux/arm64/v8" ] || [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
		ARCH_LEG=aarch64; \
		ARCH=arm64; \
	else \
		ARCH_LEG=amd64; \
		ARCH=amd64; \
	fi && \
echo -e "\e[93m**** Installs docker client ****\e[38;5;241m"  && \
wget --no-verbose -O - "https://download.docker.com/linux/static/stable/${ARCH_LEG}/docker-${DOCKER_CLI_VERSION}.tgz" | \ 
      tar --directory="${BIN_DIR}" --strip-components=1 -zx docker/docker && \
chmod +x "${BIN_DIR}/docker" && \
# mkdir -p "$DOCKER_CONFIG" && \
# echo -e "\e[93m**** Installs docker compose ****\e[38;5;241m"  && \	  
# wget --no-verbose "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH_LEG}" \
#      -O "$DOCKER_CONFIG/docker-compose" && \ 
# chmod +x "$DOCKER_CONFIG/docker-compose" && \
# echo -e "\e[93m**** Installs docker buildx ****\e[38;5;241m"  && \
# wget --no-verbose "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${ARCH}" \
#      -O "$DOCKER_CONFIG/docker-buildx" && \ 
# chmod +x "$DOCKER_CONFIG/docker-buildx"
echo "done"

FROM builder_docker_${ENV:-default} AS builder_docker

########### MAIN IMAGE ###########
FROM ${LAB_BASE}

ARG ENV

ARG TARGETPLATFORM
ARG BUILDPLATFORM
RUN echo "I am running on $BUILDPLATFORM, building for $TARGETPLATFORM"

# Set defaults directories
ARG WORK_DIR
ARG NOTEBOOKS_DIR
ARG MATERIALS_DIR
ENV WORK_DIR=${WORK_DIR}
ENV NOTEBOOKS_DIR=${NOTEBOOKS_DIR} 
ENV MATERIALS_DIR=${MATERIALS_DIR}
ENV PATH=/opt/bin:$PATH

USER root

# Set dirs and files that exist in $HOME (not persistent)
# create and link them in $HOME/work (persistent) after notebook start
# usefull for config files like .gitconfig, .ssh, ...
ENV NEEDED_WORK_DIRS .ssh .config/code-server .local/share/jupyter
ENV NEEDED_WORK_FILES .gitconfig

RUN ln -s /usr/share/plantuml/plantuml.jar /usr/local/bin/

ENV APT_CACHE_DIR=/var/cache/apt/

ARG PIP_CACHE_DIR
ARG CONDA_PKG_DIR
ENV PIP_CACHE_DIR=${PIP_CACHE_DIR}
ENV CONDA_PKG_DIR=${CONDA_PKG_DIR}

## APT PACKAGES
# We need to remove the default `docker-clean` to avoid cache cleaning
RUN mkdir -p ${PIP_CACHE_DIR} && \
 	rm -f /etc/apt/apt.conf.d/docker-clean && \ 
    #echo "Dir::Cache::pkgcache ${APT_CACHE_DIR};" > /etc/apt/apt.conf.d/00-move-cache && \
    mkdir -p ${CONDA_PKG_DIR} && \
    fix-permissions ${PIP_CACHE_DIR} ${CONDA_PKG_DIR}

# Install needed apt packages
COPY Artefacts/apt_packages* /tmp/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
 	apt-get update && \
  pkgfiles=$(if [ "${ENV}" = "minimal" ]; then echo "/tmp/apt_packages_minimal"; else echo "/tmp/apt_packages*"; fi) && \
	apt-get install -qq --yes --no-install-recommends \
		# $(cat /tmp/apt_packages) && \
    $(cat  $pkgfiles) && \
	rm -rf /var/lib/apt/lists/*

# For window manager remote access via VNC
# Install TurboVNC (https://github.com/TurboVNC/turbovnc)
ARG TURBOVNC_VERSION=3.0.3
RUN if [[ "$ENV" = "" ]] ; then \
      if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
	  	  ARCH_LEG=x86_64; \
	  	  ARCH=amd64; \
	    elif [ "$TARGETPLATFORM" = "linux/arm64/v8" ] || [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
  	  	ARCH_LEG=aarch64; \
	    	ARCH=arm64; \
	    else \
	  	  ARCH_LEG=amd64; \
	  	  ARCH=amd64; \
	    fi && \
      wget --no-verbose \
        "https://sourceforge.net/projects/turbovnc/files/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_${ARCH}.deb/download" \
        -O turbovnc.deb && \
      apt-get install -y -q ./turbovnc.deb && \
      # remove light-locker to prevent screen lock
      apt-get remove -y -q light-locker && \
      rm ./turbovnc.deb && \
      ln -s /opt/TurboVNC/bin/* /usr/local/bin/ ; \
    fi

## ZSH
ADD zsh/p10k.zsh $HOME/.p10k.zsh 
RUN --mount=type=bind,from=builder_zsh,source=/home/jovyan,target=/user \
    cp -a /user/.z* ${HOME} && \
    fix-permissions ${HOME}/.z* ${HOME}/.p10k.zsh

## DOCKER
ARG DOCKER_CONFIG
ENV DOCKER_CONFIG=${DOCKER_CONFIG}
ENV DOCKER_CLI_VERSION=${DOCKER_CLI_VERSION}
ENV DOCKER_COMPOSE_VERSION=${DOCKER_COMPOSE_VERSION}
ENV DOCKER_BUILDX_VERSION=${DOCKER_BUILDX_VERSION}
# Install docker client binaries
COPY --from=builder_Docker /usr/local/bin/docker* /usr/local/bin/
#COPY --from=builder_Docker --chown=jovyan:users ${DOCKER_CONFIG}/* ${DOCKER_CONFIG}/
COPY --from=docker/buildx-bin /buildx /usr/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker/compose-bin /docker-compose /usr/libexec/docker/cli-plugins/docker-compose


## CODE SERVER
ARG CODESERVER_DIR
ARG CODESERVEREXT_DIR
ARG CODE_WORKINGDIR
ARG CODESERVERDATA_DIR
ENV CODESERVER_DIR=${CODESERVER_DIR}
ENV CODESERVEREXT_DIR=${CODESERVEREXT_DIR}
ENV CODE_WORKINGDIR=${CODE_WORKINGDIR}
ENV CODESERVERDATA_DIR=${CODESERVERDATA_DIR}
# Install preconfigured code server
COPY --from=builder_codeserver /opt/ /opt/

## PYTHON_DEPENDENCIES
COPY --from=builder_pythondependencies "${CONDA_DIR}" "${CONDA_DIR}"

# Enable persistant conda env
COPY --chown=$NB_UID:$NB_GID condarc /home/jovyan/.condarc
COPY configs/jupyter_condaenv_config.json /tmp
RUN [[ ! -f /home/jovyan/.jupyter/jupyter_config.json ]] && touch /home/jovyan/.jupyter/jupyter_config.json ; \
	cat /tmp/jupyter_condaenv_config.json >> /home/jovyan/.jupyter/jupyter_config.json && \
  echo "source /opt/conda/bin/activate base" >> ${HOME}/.zshrc && \
  fix-permissions ${HOME}/.jupyter ${HOME}/.zshrc

# Configure nbgrader
COPY nbgrader_config.py /etc/jupyter/nbgrader_config.py

USER $NB_USER

RUN echo -e "\e[93m**** Update Jupyter config ****\e[38;5;241m" && \
        mkdir -p $HOME/jupyter_data && \
        jupyter lab --generate-config && \
        sed -i -e '/c.ServerApp.root_dir =/ s/= .*/= "\/home\/jovyan\/work"/' \
            -e "s/# \(c.ServerApp.root_dir\)/\1/" \ 
            -e '/c.ServerApp.disable_check_xsrf =/ s/= .*/= True/' \
            -e 's/# \(c.ServerApp.disable_check_xsrf\)/\1/' \
            -e '/c.ServerApp.data_dir =/ s/= .*/= "\/home\/jovyan\/jupyter_data"/' \
            -e '/c.ServerApp.db_file =/ s/= .*/= ":memory:"/' \
            -e '/c.JupyterApp.log_level =/ s/= .*/= "DEBUG"/' \
            -e "/c.ServerApp.terminado_settings =/ s/= .*/= { 'shell_command': ['\/bin\/zsh'] }/" \
            -e 's/# \(c.ServerApp.terminado_settings\)/\1/' \ 
        $HOME/.jupyter/jupyter_lab_config.py 

# sets the jupyter proxy for codeserver
COPY code-server/jupyter_codeserver_config.py /tmp/
COPY --chown=$NB_USER:$NB_GRP code-server/icons $HOME/.jupyter/icons
RUN if [[ "$ENV" = "" ]] ; then \
    [[ ! -f /home/jovyan/.jupyter/jupyter_config.py ]] && touch /home/jovyan/.jupyter/jupyter_config.py ; \
	  cat /tmp/jupyter_codeserver_config.py >> /home/jovyan/.jupyter/jupyter_config.py ; \
  fi 

# Copy scripts that should be executed before notebook start
# Files creation/setup in persistant space.
# Git client default initialisation
COPY before-notebook/ /usr/local/bin/before-notebook.d/

COPY conda-activate.sh /home/$NB_USER/

# preinstall gitstatusd
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
		ARCH_LEG=x86_64; \
		ARCH=amd64; \
	elif [ "$TARGETPLATFORM" = "linux/arm64/v8" ] || [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
		ARCH_LEG=aarch64; \
		ARCH=arm64; \
	else \
		ARCH_LEG=amd64; \
		ARCH=amd64; \
	fi && \
    mkdir -p /home/jovyan/.cache/gitstatus && \ 
    curl -sL "https://github.com/romkatv/gitstatus/releases/download/v1.5.4/gitstatusd-linux-${ARCH_LEG}.tar.gz" | \
      tar --directory="/home/jovyan/.cache/gitstatus" -zx

ARG CACHEBUST=4
COPY versions/ /versions/
COPY --chown=$NB_UID:$NB_GID README.md ${HOME}/
RUN touch ${HOME}/README.md && \
    echo "# jupyter-base Software détail" && \
    echo ${CACHEBUST} && \
    for version in $(ls -d /versions/*) ; do \
      echo >> ${HOME}/README.md ; \
      $version 2>/dev/null >> ${HOME}/README.md ; \
    done

COPY --chown=$NB_UID:$NB_GID home/ /home/jovyan/

ENV DOCKER_CONFIG=${DOCKER_CONFIG}

WORKDIR "${HOME}/work"

# Configure container startup adding ssh-agent
CMD ["ssh-agent","start-notebook.sh"]