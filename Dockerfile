ARG LAB_BASE=jupyter/minimal-notebook:lab-3.6.1

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
ENV PIP_CACHE_DIR=/var/cache/buildkit/pip

RUN mkdir -p ${PIP_CACHE_DIR} && \
    mkdir -p /var/cache/apt


COPY Artefacts/apt_packages /tmp/
# We need to remove the default `docker-clean` to avoid cache cleaning
RUN --mount=type=cache,target=/var/cache/apt \
 	rm -f /etc/apt/apt.conf.d/docker-clean && \ 
 	apt-get update && \
	apt-get install -qq --yes --no-install-recommends \
		$(cat /tmp/apt_packages) && \
	rm -rf /var/lib/apt/lists/*

# Installs only the docker client and docker compose
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
ENV CODESERVERDATA_DIR $HOME/work/.codeserver/data

ENV PATH=/opt/bin:$PATH

# Enable persistant conda env
COPY condarc /home/jovyan/.condarc

## ZSH Configuration files
ADD zsh/initzsh.sh /tmp/initzsh.sh
ADD zsh/p10k.zsh $HOME/.p10k.zsh 

# PIP packages (extensions) for JupyterLab
COPY Artefacts/pip_jupyterlab_packages /tmp/

# Codeserver extensions to install
COPY Artefacts/codeserver_extensions /tmp/

RUN --mount=type=cache,target=${PIP_CACHE_DIR}  \
    --mount=type=cache,target=/opt/conda/pkgs  \
        echo -e "\e[93m***** Install Jupyter Lab Extensions ****\e[38;5;241m" && \
        pip install --quiet --upgrade \
			$(cat /tmp/pip_jupyterlab_packages) && \
        mamba install --quiet --yes \
                nb_conda_kernels \
                && \
        echo -e "\e[93m**** Installs Code Server Web ****\e[38;5;241m" && \
                curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/opt --method=standalone && \
                mkdir -p $CODESERVERDATA_DIR &&\
                mkdir -p $CODESERVEREXT_DIR && \
                PATH=/opt/bin:$PATH code-server \
                	--user-data-dir $CODESERVERDATA_DIR\
                	--extensions-dir $CODESERVEREXT_DIR \
                    $(cat /tmp/codeserver-extensions|sed 's/./--install-extension &/') && \
        echo -e "\e[93m**** Install ZSH Kernel for Jupyter ****\e[38;5;241m" && \
            python3 -m pip install zsh_jupyter_kernel && \
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
                rm -rf "/home/${NB_USER}/.cache/yarn" && \
				fix-permissions "$CODESERVERDATA_DIR" && \
				fix-permissions "$CODESERVEREXT_DIR" && \
                fix-permissions "$CONDA_DIR" && \
				fix-permissions /opt/codeserver/extensions && \
                fix-permissions "/home/$NB_USER"

COPY code-server/jupyter_codeserver_config.py /tmp/
COPY code-server/icons $HOME/.jupyter/icons
RUN [[ ! -f /home/jovyan/.jupyter/jupyter_config.py ]] && touch /home/jovyan/.jupyter/jupyter_config.py ; \
	cat /tmp/jupyter_codeserver_config.py >> /home/jovyan/.jupyter/jupyter_config.py 

# Creates dirs and files in $HOME/work (persistent)
# adds links from $HOME (not persistent)
# usefull for config files like .gitconfig, .ssh, ...
COPY create_work_subdirs.sh /usr/local/bin/before-notebook.d/create_work_subdirs.sh
ENV NEEDED_WORK_DIRS .ssh
ENV NEEDED_WORK_FILES .gitconfig

#Git client default initialisation
COPY gitinitconfig.sh /tmp/gitinitconfig.sh

COPY $PWD/initdockerclient.sh /usr/local/bin/before-notebook.d/initdockerclient.sh

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

RUN ln -s /usr/share/plantuml/plantuml.jar /usr/local/bin/

USER $NB_USER

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
    mkdir -p /home/jovyan/.cache/gistatus && \ 
    curl -sL "https://github.com/romkatv/gitstatus/releases/download/v1.5.4/gitstatusd-linux-${ARCH_LEG}.tar.gz" | \
      tar --directory="/home/jovyan/.cache/gitstatus" -zx

WORKDIR "${HOME}/work"
