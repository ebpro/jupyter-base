ARG LAB_BASE=jupyter/minimal-notebook:lab-3.6.3

FROM ${LAB_BASE}

ARG TARGETPLATFORM

ARG DOCKER_CLI_VERSION="23.0.1"
ARG DOCKER_COMPOSE_VERSION="2.17.0"
ARG DOCKER_BUILDX_VERSION="0.10.4"
ARG DOCKER_CONFIG="/usr/local/lib/docker/cli-plugins"

USER root

ARG TARGETPLATFORM
ARG BUILDPLATFORM
RUN echo "I am running on $BUILDPLATFORM, building for $TARGETPLATFORM"

# Sets a cache for pip packages
#ENV PIP_CACHE_DIR=/var/cache/buildkit/pip
ENV PIP_CACHE_DIR=/home/jovyan/work/var/cache/buildkit/pip/
ENV APT_CACHE_DIR=/var/cache/apt/
ENV CONDA_PKG_DIR=/opt/conda/pkgs/

# We need to remove the default `docker-clean` to avoid cache cleaning
RUN mkdir -p ${PIP_CACHE_DIR} && \
 	rm -f /etc/apt/apt.conf.d/docker-clean && \ 
    #echo "Dir::Cache::pkgcache ${APT_CACHE_DIR};" > /etc/apt/apt.conf.d/00-move-cache && \
    mkdir -p ${CONDA_PKG_DIR}

# Install need apt packages
COPY Artefacts/apt_packages /tmp/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
 	apt-get update && \
	apt-get install -qq --yes --no-install-recommends \
		$(cat /tmp/apt_packages) && \
	rm -rf /var/lib/apt/lists/*

# Installs only the docker client and docker compose
# easly used by mounting docker socket 
#    docker run -v /var/run/docker.sock:/var/run/docker.socker
# container must be start as root to change socket owner ship before privilege drop
ENV BIN_DIR=/usr/local/bin
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
   echo -e "\e[93m**** Installs docker client ****\e[38;5;241m"  && \
   curl -sL "https://download.docker.com/linux/static/stable/${ARCH_LEG}/docker-${DOCKER_CLI_VERSION}.tgz" | \ 
      tar --directory="${BIN_DIR}" --strip-components=1 -zx docker/docker && \
      chmod +x "${BIN_DIR}/docker" && \
      mkdir -p "$DOCKER_CONFIG" && \
   echo -e "\e[93m**** Installs docker compose ****\e[38;5;241m"  && \	  
   curl -sL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH_LEG}" \
        -o "$DOCKER_CONFIG/docker-compose" && \ 
      chmod +x "$DOCKER_CONFIG/docker-compose" && \
   echo -e "\e[93m**** Installs docker buildx ****\e[38;5;241m"  && \
   curl -sL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${ARCH}" \
        -o "$DOCKER_CONFIG/docker-buildx" && \ 
      chmod +x "$DOCKER_CONFIG/docker-buildx"

# Sets Defaults directories
ENV WORK_DIR $HOME/work
ENV NOTEBOOKS_DIR $WORK_DIR/notebooks
ENV DATA_DIR  $WORK_DIR/data

# Sets codeserver directories
ENV CODESERVEREXT_DIR /opt/codeserver/extensions
ENV CODE_WORKINGDIR $HOME/work
ENV CODESERVERDATA_DIR $HOME/work/.config/codeserver/data

ENV PATH=/opt/bin:$PATH

# Enable persistant conda env
COPY condarc /home/jovyan/.condarc

## ZSH Configuration files
ADD zsh/initzsh.sh /tmp/initzsh.sh
ADD zsh/p10k.zsh $HOME/.p10k.zsh 

# PIP packages (extensions) for JupyterLab
COPY Artefacts/environment.yml /tmp
COPY Artefacts/requirements.txt /tmp
# Codeserver extensions to install
COPY Artefacts/codeserver_extensions /tmp/

# Installs python packages, jupyter extensions and codeserver
RUN --mount=type=cache,target=${PIP_CACHE_DIR},sharing=locked  \
    --mount=type=cache,target=${CONDA_PKG_DIR},sharing=locked  \
        echo -e "\e[93m***** Install Jupyter Lab Extensions ****\e[38;5;241m" && \
        pip install -r /tmp/requirements.txt && \
        mamba env update -p ${CONDA_DIR} -f /tmp/environment.yml && \
        echo -e "\e[93m**** Installs Code Server Web ****\e[38;5;241m" && \
                curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/opt --method=standalone && \
                mkdir -p $CODESERVERDATA_DIR &&\
                mkdir -p $CODESERVEREXT_DIR && \
                PATH=/opt/bin:$PATH code-server \
                	--user-data-dir $CODESERVERDATA_DIR\
                	--extensions-dir $CODESERVEREXT_DIR \
                    $(cat /tmp/codeserver_extensions|sed 's/./--install-extension &/') && \
        echo -e "\e[93m**** Install ZSH Kernel for Jupyter ****\e[38;5;241m" && \
            python3 -m zsh_jupyter_kernel.install --sys-prefix && \ 
        echo -e "\e[93m**** Configure a nice zsh environment ****\e[38;5;241m" && \
        git clone --recursive https://github.com/sorin-ionescu/prezto.git "$HOME/.zprezto" && \
        zsh -c /tmp/initzsh.sh && \
        sed -i -e "s/zstyle ':prezto:module:prompt' theme 'sorin'/zstyle ':prezto:module:prompt' theme 'powerlevel10k'/" $HOME/.zpreztorc && \
        echo "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> $HOME/.zshrc && \
        echo "PATH=/opt/bin:$PATH" >> $HOME/.zshrc && \
        echo -e "\e[93m**** Clean up ****\e[38;5;241m" && \
#               npm cache clean --force && \
#               mamba clean --all -f -y && \
#               jupyter lab clean && \
#&& mamba clean -afy \
#    && find ${CONDA_DIR} -follow -type f -name '*.a' -delete \
#    && find ${CONDA_DIR} -follow -type f -name '*.pyc' -delete
                rm -rf "/home/${NB_USER}/.cache/yarn" && \
				fix-permissions "$CODESERVERDATA_DIR" && \
				fix-permissions "$CODESERVEREXT_DIR" && \
                fix-permissions "$CONDA_DIR" && \
				fix-permissions /opt/codeserver/extensions && \
                fix-permissions "/home/$NB_USER" && \
                fix-permissions "/home/$NB_USER/.zprezto"

# Set dirs and files that exist in $HOME (not persistent)
# but create and link them in $HOME/work (persistent) after notebook start
# usefull for config files like .gitconfig, .ssh, ...
ENV NEEDED_WORK_DIRS .ssh
ENV NEEDED_WORK_FILES .gitconfig

RUN ln -s /usr/share/plantuml/plantuml.jar /usr/local/bin/

# For window manager remote access via VNC
# Install TurboVNC (https://github.com/TurboVNC/turbovnc)
ARG TURBOVNC_VERSION=3.0.3
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
 wget -q "https://sourceforge.net/projects/turbovnc/files/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_${ARCH}.deb/download" -O turbovnc.deb \
 && apt-get install -y -q ./turbovnc.deb \
 # remove light-locker to prevent screen lock
 && apt-get remove -y -q light-locker \
 && rm ./turbovnc.deb \
 && ln -s /opt/TurboVNC/bin/* /usr/local/bin/

ENV SHELL=/bin/bash


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
            -e "/c.ServerApp.terminado_settings =/ s/= .*/= { 'shell_command': ['\/bin\/zsh'] }/" \
            -e 's/# \(c.ServerApp.terminado_settings\)/\1/' \ 
        $HOME/.jupyter/jupyter_lab_config.py 

# sets the jupyter proxy for codeserver
COPY code-server/jupyter_codeserver_config.py /tmp/
COPY code-server/icons $HOME/.jupyter/icons
RUN [[ ! -f /home/jovyan/.jupyter/jupyter_config.py ]] && touch /home/jovyan/.jupyter/jupyter_config.py ; \
	cat /tmp/jupyter_codeserver_config.py >> /home/jovyan/.jupyter/jupyter_config.py 

# Copy scripts that should be executed before notebook start
# Files creation/setup in persistant space.
# Git client default initialisation
COPY before-notebook/ /usr/local/bin/before-notebook.d/

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

WORKDIR "${HOME}/work"
