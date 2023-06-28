# THE BASE IMAGE
ARG LAB_BASE=jupyter/base-notebook:lab-4.0.2
# ARG LAB_BASE=jupyter/minimal-notebook:lab-4.0.2
# ARG LAB_BASE=jupyter/minimal-notebook:lab-3.6.3

# minimal, default (empty), full 
ARG ENV

## GENERAL
# Persistent data directory (user working directory)
ARG WORK_DIR=/home/jovyan/work
# directory for given materials (git_provider/account/repo/...).
ARG MATERIALS_DIR=$WORK_DIR/materials
ARG NOTEBOOKS_DIR=$MATERIALS_DIR

# CODE SERVER
ARG CODESERVER_DIR=/opt/codeserver
ARG CODESERVEREXT_DIR=${CODESERVER_DIR}/extensions
ARG CODE_WORKINGDIR=${WORK_DIR}
ARG CODESERVERDATA_DIR=${CODE_WORKINGDIR}/.config/codeserver/data
ARG CODE_SERVER_CONFIG=${CODE_WORKINGDIR}/.config/code-server/config.yaml

#######################
# BASE BUILDER        #
#######################
FROM ubuntu AS builder_base
RUN apt-get update \
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
        echo "PATH=/opt/bin:$HOME/bin:$PATH" >> $HOME/.zshrc
RUN wget --no-verbose --output-document=$HOME/.zprezto/modules/completion/external/src/_docker https://raw.githubusercontent.com/docker/cli/master/contrib/completion/zsh/_docker

############
## DOCKER ##
############

# No docker clients in minimal version
FROM builder_base AS builder_docker_minimal

FROM builder_docker_default AS builder_docker_full

FROM builder_base AS builder_docker_default
# Installs only the docker client and docker compose
# easly used by mounting docker socket 
#    docker run -v /var/run/docker.sock:/var/run/docker.socker
# container must be started as root to change socket ownership before privilege drop
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM}
ENV BUILDPLATFORM=${BUILDPLATFORM}

ARG BIN_DIR
ENV BIN_DIR=/usr/local/bin

SHELL [ "/bin/bash", "-c" ]

# Choose the latest docker version available for x86_64 and aarch64 
RUN DOCKER_CLI_VERSION=$(comm -12  \
  <(curl -s https://download.docker.com/linux/static/stable/aarch64/ | \
      sed -n 's/.*docker-\([0-9]*\.[0-9]*\.[0-9]*\).tgz.*/\1/p' | tail -n1) \
  <(curl -s https://download.docker.com/linux/static/stable/x86_64/ | \
      sed -n 's/.*docker-\([0-9]*\.[0-9]*\.[0-9]*\).tgz.*/\1/p' | tail -n1)) && \
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
wget --no-verbose --output-document=- "https://download.docker.com/linux/static/stable/${ARCH_LEG}/docker-${DOCKER_CLI_VERSION}.tgz" | \ 
      tar --directory="${BIN_DIR}" --strip-components=1 -zx docker/docker && \
chmod +x "${BIN_DIR}/docker" && \
echo "done"

FROM builder_docker_${ENV:-default} AS builder_docker

########### MAIN IMAGE ###########
FROM ${LAB_BASE}

ARG ENV=default

ARG TARGETPLATFORM
ARG BUILDPLATFORM
RUN echo "I am running on $BUILDPLATFORM, building for $TARGETPLATFORM"

# Set defaults directories
# Persistent data directory (user working directory)
ARG WORK_DIR=$HOME/work
# directory for given materials (git_provider/account/repo/...).
ARG MATERIALS_DIR=$WORK_DIR/materials
ARG NOTEBOOKS_DIR=$MATERIALS_DIR

ENV WORK_DIR=${WORK_DIR}
ENV MATERIALS_DIR=${MATERIALS_DIR}
ENV NOTEBOOKS_DIR=${NOTEBOOKS_DIR} 
ENV PATH=${HOME}/bin:/opt/bin:${PATH}

USER root

# Set dirs and files that have to exist in $HOME (not persistent)
# create and link them in $HOME/work (to become persistent) after notebook start
# usefull for config files like .gitconfig, .ssh, ...
ENV NEEDED_WORK_DIRS .ssh
ENV NEEDED_WORK_FILES .gitconfig

ENV PLANTUML=/usr/share/plantuml/plantuml.jar
RUN ln -s /usr/share/plantuml/plantuml.jar /usr/local/bin/

# Install needed apt packages
COPY Artefacts/apt_packages* Artefacts/TeXLive /tmp/
RUN apt-get update && \
	  apt-get install -qq --yes --no-install-recommends \
		  $(cat /tmp/apt_packages_minimal|grep --invert-match "^#") $(if [ "${ENV}" != "minimal" ]; then cat /tmp/apt_*|grep --invert-match "^#"; fi) && \
  # Install quarto and LaTeX
  wget --no-verbose --output-document=/tmp/quarto.deb https://github.com/quarto-dev/quarto-cli/releases/download/v1.3.361/quarto-1.3.361-linux-$(echo $TARGETPLATFORM|cut -d '/' -f 2).deb && \
  dpkg -i /tmp/quarto.deb && \
  rm /tmp/quarto.deb && \
  # Tiny TeX installation
  wget -qO- "https://yihui.org/tinytex/install-bin-unix.sh" | sh && \
  PATH=$HOME/bin:$PATH tlmgr install $(cat /tmp/TeXLive|grep --invert-match "^#") && \
  chown -R ${NB_UID}:${NB_GID} ${HOME}/.TinyTeX ${HOME}/bin && \
	rm -rf /var/lib/apt/lists/*

# For window manager remote access via VNC
# Install TurboVNC (https://github.com/TurboVNC/turbovnc)
ARG TURBOVNC_VERSION=3.0.3
RUN if [[ "${ENV}" != "minimal" ]] ; then \
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
      wget --no-verbose --output-document=turbovnc.deb \
        "https://sourceforge.net/projects/turbovnc/files/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_${ARCH}.deb/download" && \
      apt-get install -y -q ./turbovnc.deb && \
      # remove light-locker to prevent screen lock
      apt-get remove -y -q light-locker && \
      rm ./turbovnc.deb && \
      ln -s /opt/TurboVNC/bin/* /usr/local/bin/ ; \
    fi

## ZSH
COPY --chown=$NB_UID:$NB_GID zsh/p10k.zsh $HOME/.p10k.zsh 
RUN --mount=type=bind,from=builder_zsh,source=/home/jovyan,target=/user \
    cp -a /user/.z* ${HOME} && \
    fix-permissions ${HOME}/.z* ${HOME}/.p10k.zsh

## DOCKER
# Install docker client binaries
COPY --from=builder_docker /usr/local/bin/docker* /usr/local/bin/
COPY --from=docker/buildx-bin /buildx /usr/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker/compose-bin /docker-compose /usr/libexec/docker/cli-plugins/docker-compose

## PYTHON_DEPENDENCIES
COPY Artefacts/environment.yml /tmp
COPY Artefacts/requirements.txt /tmp

## CODE SERVER
ARG CODESERVER_DIR
ARG CODESERVEREXT_DIR
ARG CODE_WORKINGDIR
ARG CODESERVERDATA_DIR
ENV CODESERVER_DIR=${CODESERVER_DIR}
ENV CODESERVEREXT_DIR=${CODESERVEREXT_DIR}
ENV CODE_WORKINGDIR=${CODE_WORKINGDIR}
ENV CODESERVERDATA_DIR=${CODESERVERDATA_DIR}
COPY Artefacts/codeserver_extensions /tmp/

# Installs Python packages and codeserver (if needed)
RUN echo -e "\e[93m***** Install Python packages ****\e[38;5;241m" && \
        pip install -r /tmp/requirements.txt && \
        mamba env update -p ${CONDA_DIR} -f /tmp/environment.yml && \
        echo -e "\e[93m**** Install ZSH Kernel for Jupyter ****\e[38;5;241m" && \
            python3 -m zsh_jupyter_kernel.install --sys-prefix
RUN if [[ "${ENV}" != "minimal" ]] ; then \
        echo -e "\e[93m**** Installs Code Server Web ****\e[38;5;241m" && \
                curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/opt --method=standalone && \
                mkdir -p ${CODESERVERDATA_DIR} &&\
                mkdir -p ${CODESERVEREXT_DIR} && \
                PATH=/opt/bin:$PATH code-server \
                	--user-data-dir ${CODESERVERDATA_DIR}\
                	--extensions-dir ${CODESERVEREXT_DIR} \
                    $(cat /tmp/codeserver_extensions|sed 's/./--install-extension &/') ; \
        chown -R ${NB_UID}:${NB_GID} ${CODE_WORKINGDIR}/.config ; \
    fi

# Enable persistant conda env
COPY --chown=$NB_UID:$NB_GID condarc /home/jovyan/.condarc
COPY configs/jupyter_condaenv_config.json /tmp
RUN [[ ! -f /home/jovyan/.jupyter/jupyter_config.json ]] && touch /home/jovyan/.jupyter/jupyter_config.json ; \
	cat /tmp/jupyter_condaenv_config.json >> /home/jovyan/.jupyter/jupyter_config.json && \
  echo "source /opt/conda/bin/activate base" >> ${HOME}/.zshrc && \
  fix-permissions ${HOME}/.jupyter ${HOME}/.zshrc
COPY --chown=$NB_USER:$NB_GID conda-activate.sh /home/$NB_USER/

# Configure nbgrader
COPY nbgrader_config.py /etc/jupyter/nbgrader_config.py

RUN mkdir -p $HOME/.TinyTeX &&\
  chown -R jovyan:users $HOME/.config $HOME/.local $HOME/.cache $HOME/.ipython $HOME/.TinyTeX

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

# Sets the jupyter proxy for codeserver
COPY code-server/jupyter_codeserver_config.py /tmp/
COPY --chown=$NB_USER:$NB_GID code-server/icons $HOME/.jupyter/icons
RUN if [[ "${ENV}" != "minimal" ]] ; then \
    [[ ! -f /home/jovyan/.jupyter/jupyter_config.py ]] && touch /home/jovyan/.jupyter/jupyter_config.py ; \
	  cat /tmp/jupyter_codeserver_config.py >> /home/jovyan/.jupyter/jupyter_config.py ; \
  fi && \
  fix-permissions ${HOME}/.jupyter 

# Copy scripts that should be executed before notebook start
# Files creation/setup in persistant space.
# Git client default initialisation
COPY before-notebook/ /usr/local/bin/before-notebook.d/

# Preinstall gitstatusd
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

# Generate 
ARG CACHEBUST=4
COPY versions/ /versions/
COPY --chown=$NB_UID:$NB_GID README.md ${HOME}/
RUN echo "## Software details" >> ${HOME}/README.md && \
    echo ${CACHEBUST} && \
    for versionscript in $(ls -d /versions/*) ; do \
      echo "Executing ($versionscript)"; \
      echo ""; \
      eval "$versionscript" 2>/dev/null >> ${HOME}/README.md ; \      
      #eval "$versionscript"; \
    done

COPY --chown=$NB_UID:$NB_GID home/ /home/jovyan/

WORKDIR "${WORK_DIR}"

# Configure container startup adding ssh-agent
CMD ["ssh-agent","start-notebook.sh"]
