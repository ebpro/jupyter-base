# Base image arguments
ARG VARIANT="ubuntu-24.04"
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

LABEL org.opencontainers.image.authors="Emmanuel BRUNO <emmanuel.bruno@univ-tln.fr>" \
      org.opencontainers.image.description="A devcontainer image for development" \
    org.opencontainers.image.documentation="https://github.com/ebpro/solen/" \
      org.opencontainers.image.license="MIT" \
    org.opencontainers.image.support="https://github.com/ebpro/solen/issues" \
      org.opencontainers.image.title="Base Devcontainer" \
      org.opencontainers.image.vendor="UTLN"

# User configuration
ARG NB_USER="jovyan"
ARG NB_UID="1001"
ARG NB_GID="1001"

ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Global environment variables
ENV USER=${NB_USER} \
    NB_USER=${NB_USER} \
    HOME=/home/${NB_USER} \
    WORK_DIR=/home/${NB_USER}/work
ENV MATERIALS_DIR=${WORK_DIR}/materials \
    NOTEBOOKS_DIR=${WORK_DIR}/local \
    PATH=${HOME}/bin:/opt/bin:${PATH}

# System dependencies installation with cache mounting
# By default install `apt_packages.base`. To also install extras, pass
# --build-arg INSTALL_EXTRA_PACKAGES=true to the build.
ARG INSTALL_EXTRA_PACKAGES="false"
RUN --mount=type=bind,source=Artefacts/apt_packages/base,target=/tmp/Artefacts/apt_packages_base \
    --mount=type=bind,source=Artefacts/apt_packages/extra,target=/tmp/Artefacts/apt_packages_extra \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    # Read base packages
    BASE_PKGS=$(grep -v -e "^#" -e "^$" /tmp/Artefacts/apt_packages_base | tr '\n' ' ' || true); \
    EXTRA_PKGS=""; \
    if [ "${INSTALL_EXTRA_PACKAGES}" = "true" ] && [ -f /tmp/Artefacts/apt_packages_extra ]; then \
        EXTRA_PKGS=$(grep -v -e "^#" -e "^$" /tmp/Artefacts/apt_packages_extra | tr '\n' ' ' || true); \
    fi; \
    PKGS="${BASE_PKGS} ${EXTRA_PKGS}"; \
    # Normalize whitespace
    PKGS=$(echo "${PKGS}" | xargs || true); \
    if [ -n "${PKGS}" ]; then \
        apt-get update; \
        apt-get install -qq --yes --no-install-recommends ${PKGS}; \
        rm -rf /var/lib/apt/lists/*; \
        # Verify installation and fail early if a package didn't install
        for p in ${PKGS}; do \
            if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "installed"; then \
                echo "FATAL: apt package '$p' failed to install"; \
                exit 1; \
            fi; \
        done; \
    else \
        echo "No apt packages to install"; \
    fi; \
    # Create user and set up sudo
    groupadd -g ${NB_GID} ${NB_USER}; \
    useradd -l -m -s /bin/zsh -N -u ${NB_UID} -g ${NB_GID} ${NB_USER}; \
    echo "${NB_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${NB_USER}; \
    chmod 0440 /etc/sudoers.d/${NB_USER}

# Copy artifact checksums for build-time verification
COPY --chown=root:root Artefacts/checksums.json /tmp/checksums.json

# Install Docker tools with latest versions

# Copy Docker CLI and plugins from official images
COPY --from=docker:27-cli /usr/local/bin/docker* /usr/local/bin/
COPY --from=docker/buildx-bin:latest /buildx /usr/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker/compose-bin:latest /docker-compose /usr/libexec/docker/cli-plugins/docker-compose
COPY --from=docker/scout-cli:latest /docker-scout /usr/libexec/docker/cli-plugins/docker-scout

# Switch to jovyan user for security
USER ${NB_USER}
WORKDIR ${HOME}
SHELL ["/bin/zsh","-l","-c"]

# Create working directories
RUN mkdir -p ${WORK_DIR} ${MATERIALS_DIR} ${NOTEBOOKS_DIR}

# Install Kubernetes tools
ARG KUBECTL_VERSION="1.29.1"
ARG HELM_VERSION="3.14.0"
ARG K9S_VERSION="0.31.6"
ARG KUSTOMIZE_VERSION="5.3.0"
ARG LOCAL_BIN=${HOME}/bin

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json \
    set -ex && \
    mkdir -p ${LOCAL_BIN} && \
    ARCH=$(case "$TARGETPLATFORM" in \
        "linux/amd64") echo "amd64" ;; \
        "linux/arm64") echo "arm64" ;; \
        *) echo "amd64" ;; \
    esac) && \
    # Read pinned tool versions from Artefacts/versions.json
    KUBECTL_VERSION=$(jq -r '.tools.kubectl' /tmp/versions.json) && \
    HELM_VERSION=$(jq -r '.tools.helm' /tmp/versions.json) && \
    K9S_VERSION=$(jq -r '.tools.k9s' /tmp/versions.json) && \
    KUSTOMIZE_VERSION=$(jq -r '.tools.kustomize' /tmp/versions.json) && \
    # Install kubectl
        curl --silent --show-error --location --fail --retry 3 --retry-delay 5  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl && \
        # Verify kubectl checksum when available
        if [ -f /tmp/checksums.json ]; then \
            KUBE_CHKSUM=$(jq -r --arg t "kubectl" --arg ver "${KUBECTL_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${KUBE_CHKSUM}" ]; then echo "${KUBE_CHKSUM}  /tmp/kubectl" > /tmp/kubectl.sha256 && sha256sum -c /tmp/kubectl.sha256; fi; \
        fi && \
        mv /tmp/kubectl ${LOCAL_BIN}/kubectl && chmod +x ${LOCAL_BIN}/kubectl && \
        # Install Helm with retries and verify checksum
        curl --silent --show-error --location --fail --retry 3 --retry-delay 5 "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz || (cat /tmp/helm.tar.gz && false) && \
        if [ -f /tmp/checksums.json ]; then \
            HELM_CHKSUM=$(jq -r --arg t "helm" --arg ver "${HELM_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${HELM_CHKSUM}" ]; then echo "${HELM_CHKSUM}  /tmp/helm.tar.gz" > /tmp/helm.sha256 && sha256sum -c /tmp/helm.sha256; fi; \
        fi && \
        tar xz --strip-components=1 -C ${LOCAL_BIN} -f /tmp/helm.tar.gz linux-${ARCH}/helm && rm /tmp/helm.tar.gz && \
        # Install k9s (download, verify, extract)
        curl --silent --show-error --location --fail --retry 3 --retry-delay 5 "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" -o /tmp/k9s.tar.gz && \
        if [ -f /tmp/checksums.json ]; then \
            K9S_CHKSUM=$(jq -r --arg t "k9s" --arg ver "${K9S_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${K9S_CHKSUM}" ]; then echo "${K9S_CHKSUM}  /tmp/k9s.tar.gz" > /tmp/k9s.sha256 && sha256sum -c /tmp/k9s.sha256; fi; \
        fi && \
        tar xz -C ${LOCAL_BIN} -f /tmp/k9s.tar.gz k9s && rm /tmp/k9s.tar.gz && \
        # Install kustomize (download, verify, extract)
        curl --silent --show-error --location --fail --retry 3 --retry-delay 5  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" -o /tmp/kustomize.tar.gz && \
        if [ -f /tmp/checksums.json ]; then \
            KUSTOMIZE_CHKSUM=$(jq -r --arg t "kustomize" --arg ver "${KUSTOMIZE_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${KUSTOMIZE_CHKSUM}" ]; then echo "${KUSTOMIZE_CHKSUM}  /tmp/kustomize.tar.gz" > /tmp/kustomize.sha256 && sha256sum -c /tmp/kustomize.sha256; fi; \
        fi && \
        tar xz -C ${LOCAL_BIN} -f /tmp/kustomize.tar.gz && rm /tmp/kustomize.tar.gz && \
        # Set permissions
        chmod +x ${LOCAL_BIN}/*

# Install Minikube (use pinned version)
RUN --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json set -ex && \
        ARCH=$(case "$TARGETPLATFORM" in \
                "linux/amd64") echo "amd64" ;; \
                "linux/arm64") echo "arm64" ;; \
                *) echo "amd64" ;; \
        esac) && \
        # Read pinned version and install Minikube
        MINIKUBE_VERSION=$(jq -r '.tools.minikube' /tmp/versions.json) && \
        curl -fsSL "https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VERSION}/minikube-linux-${ARCH}" -o /tmp/minikube && \
        if [ -f /tmp/checksums.json ]; then \
            MINIKUBE_CHKSUM=$(jq -r --arg t "minikube" --arg ver "${MINIKUBE_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${MINIKUBE_CHKSUM}" ]; then echo "${MINIKUBE_CHKSUM}  /tmp/minikube" > /tmp/minikube.sha256 && sha256sum -c /tmp/minikube.sha256; fi; \
        fi && \
        mv /tmp/minikube ${LOCAL_BIN}/minikube && chmod +x ${LOCAL_BIN}/minikube && \
        # Create minikube config directory
        mkdir -p ${HOME}/.minikube

# Add Minikube environment variables
ENV MINIKUBE_HOME=${HOME}/.minikube \
    MINIKUBE_IN_STYLE=true \
    MINIKUBE_WANTUPDATENOTIFICATION=false \
    CHANGE_MINIKUBE_NONE_USER=true


# ZSH Configuration
ARG PREZTO_REPO="https://github.com/sorin-ionescu/prezto.git"

COPY --chown=${NB_UID}:${NB_GID} zsh/p10k.zsh ${HOME}/.p10k.zsh
# COPY --chown=${NB_UID}:${NB_GID} zsh/zpreztorc ${HOME}/.zpreztorc.template

RUN --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json \
    --mount=type=bind,source=zsh/initzsh.sh,target=/tmp/initzsh.sh \
    set -ex && \
    echo "Configuring ZSH environment..." && \
    # Install Prezto
    git clone --depth=1 --recursive "${PREZTO_REPO}" "${HOME}/.zprezto" && \
    # Run initialization script
    zsh -c /tmp/initzsh.sh && \
    # Configure Prezto with Powerlevel10k
    if [[ -f ${HOME}/.zpreztorc.template ]]; then \
        mv ${HOME}/.zpreztorc.template ${HOME}/.zpreztorc; \
    else \
        sed -i -e "s/zstyle ':prezto:module:prompt' theme 'sorin'/zstyle ':prezto:module:prompt' theme 'powerlevel10k'/" ${HOME}/.zpreztorc; \
    fi && \
    # Add Powerlevel10k to ZSH configuration
    echo "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> "$HOME"/.zshrc && \
    # Add Minikube completion to shell
    echo 'source <(minikube completion zsh)' >> ${HOME}/.zshrc

# Install and configure gitstatusd
RUN --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json \
    set -ex && \
    export GITSTATUS_VERSION=$(jq -r '.tools.gitstatus' /tmp/versions.json) && \
    echo "GITSTATUS_VERSION=${GITSTATUS_VERSION}" && \
    echo "Installing gitstatusd..." && \
    # Determine architecture
    ARCH=$(case "$TARGETPLATFORM" in \
        "linux/amd64") echo "x86_64" ;; \
        "linux/arm64/v8" | "linux/arm64") echo "aarch64" ;; \
        *) echo "x86_64" ;; \
    esac) && \
    # Create cache directory
    mkdir -p "${HOME}/.cache/gitstatus" && \
    # Download and extract gitstatusd
        curl -fsSL "https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VERSION}/gitstatusd-linux-${ARCH}.tar.gz" -o /tmp/gitstatusd.tar.gz && \
        if [ -f /tmp/checksums.json ]; then \
            GITSTATUS_CHKSUM=$(jq -r --arg t "gitstatus" --arg ver "${GITSTATUS_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${GITSTATUS_CHKSUM}" ]; then echo "${GITSTATUS_CHKSUM}  /tmp/gitstatusd.tar.gz" > /tmp/gitstatusd.sha256 && sha256sum -c /tmp/gitstatusd.sha256; fi; \
        fi && \
        tar --directory="${HOME}/.cache/gitstatus" -zx -f /tmp/gitstatusd.tar.gz && rm -f /tmp/gitstatusd.tar.gz && \
    # Set permissions
    chown -R "${NB_UID}:${NB_GID}" "${HOME}/.cache/gitstatus" && \
    chmod 755 "${HOME}/.cache/gitstatus"


# Install TeXLive
ENV TEXDIR=${HOME}/.TinyTeX
ENV TINYTEX_INSTALLER="installer-unix"
ENV TINYTEX_VERSION=2025.05
ENV TINYTEX_URL="https://github.com/rstudio/tinytex-releases/releases/download/v$TINYTEX_VERSION/$TINYTEX_INSTALLER-v$TINYTEX_VERSION"
ENV CTAN_REPO="https://distrib-coffee.ipsl.jussieu.fr/pub/mirrors/ctan/systems/texlive/tlnet"
RUN --mount=type=bind,source=Artefacts/TeXLive,target=/tmp/TeXLive \
    curl -fsSL ${TINYTEX_URL}.tar.gz -o ${TINYTEX_INSTALLER}.tar.gz && \
    tar xf ${TINYTEX_INSTALLER}.tar.gz && \
    ./install.sh && \
    mkdir -p "$TEXDIR" && \
    mv texlive/* "$TEXDIR" && \
    rm -r texlive "${TINYTEX_INSTALLER}.tar.gz" install.sh install-tl-unx.tar.gz && \
    export PATH=$(echo ${HOME}/.TinyTeX/bin/*):${PATH} && \
    tlmgr option repository "$CTAN_REPO" && \
    tlmgr paper a4 && \
    tlmgr install --verify-repo=none $(cat /tmp/TeXLive | grep --invert-match "^#")

# Define Conda/Mamba environment variables
ENV CONDA_DIR=${HOME}/miniforge3 \
    MAMBA_ROOT_PREFIX=${HOME}/miniforge3 \
    PATH=${HOME}/miniforge3/bin:$PATH \
    MAMBA_NO_BANNER=1

# Set default environment
ENV CONDA_DEFAULT_ENV=base

# Install Miniforge and configure base environment
RUN --mount=type=bind,source=Artefacts/environment.yml,target=/tmp/environment.yml \
    --mount=type=bind,source=Artefacts/requirements.txt,target=/tmp/requirements.txt \
    curl -sL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" -o miniforge.sh && \
    bash miniforge.sh -b -p ${CONDA_DIR} && \
    rm miniforge.sh && \
    export PATH=${HOME}/miniforge3/bin:$PATH && \
    # Initialize shells
    conda init zsh && \
    conda init bash && \
    # Configure conda/mamba
    conda config --system --set channel_priority strict && \
    # Update base environment with core packages
    mamba env update -n base -f /tmp/environment.yml && \
    # Install additional Python packages
    pip install --no-cache-dir -r /tmp/requirements.txt && \
    # Install Jupyter kernels
    python3 -m zsh_jupyter_kernel.install --sys-prefix && \
    python3 -m bash_kernel.install --sys-prefix && \
    # Clean up
    mamba clean --all --yes --force-pkgs-dirs

# Set dirs and files that have to exist in $HOME (not persistent)
# create and link them in $HOME/work (to become persistent) after notebook start
# useful for config files like .gitconfig, .ssh, ..
ENV NEEDED_WORK_DIRS=.ssh
ENV NEEDED_WORK_FILES=.gitconfig
# Create startup scripts directory with proper permissions
COPY --chown=${NB_USER}:${NB_GID} init-scripts.d/ ${HOME}/startup-scripts.d/
RUN chmod 755 ${HOME}/startup-scripts.d && \
    find ${HOME}/startup-scripts.d/ -type f -name "*.sh" -exec chmod 755 {} \; && \
    # Create directory for storing script execution order
    mkdir -p ${HOME}/.config/startup



# Install GitHub CLI in user space (use pinned version)
RUN --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json mkdir -p ${HOME}/bin && \
        ARCH=$(case "$TARGETPLATFORM" in \
                "linux/amd64") echo "amd64" ;; \
                "linux/arm64") echo "arm64" ;; \
                *) echo "amd64" ;; \
        esac) && \
        GH_VERSION=$(jq -r '.tools.gh' /tmp/versions.json) && \
        curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" -o /tmp/gh.tar.gz && \
        if [ -f /tmp/checksums.json ]; then \
            GH_CHKSUM=$(jq -r --arg t "gh" --arg ver "${GH_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
            if [ -n "${GH_CHKSUM}" ]; then echo "${GH_CHKSUM}  /tmp/gh.tar.gz" > /tmp/gh.sha256 && sha256sum -c /tmp/gh.sha256; fi; \
        fi && \
        tar xz --strip-components=2 -C ${HOME}/bin gh_${GH_VERSION}_linux_${ARCH}/bin/gh -f /tmp/gh.tar.gz && rm -f /tmp/gh.tar.gz && \
        chmod +x ${HOME}/bin/gh && \
        # Add gh completion to zsh
        echo 'eval "$(gh completion -s zsh)"' >> ${HOME}/.zshrc

# Copy version scripts
COPY --chown=${NB_USER}:${NB_GID} versions/ ${HOME}/versions/

# Install Quarto
RUN --mount=type=bind,source=Artefacts/versions.json,target=/tmp/versions.json \
    QUARTO_VERSION=$(jq -r '.tools.quarto' /tmp/versions.json) && \
    set -ex && \
    PLATFORM=$(uname -m) && \
    ARCH=$(case "$PLATFORM" in \
        "X86_64") echo "amd64" ;; \
        "aarch64") echo "arm64" ;; \
        *) echo "amd64" ;; \
    esac) && \
    # Download and install Quarto
    QUARTO_URL="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${ARCH}.tar.gz" && \
    echo "Installing Quarto v${QUARTO_VERSION} for ${ARCH}..." && \
    curl -fsSL ${QUARTO_URL} -o /tmp/quarto.tar.gz && \
    if [ -f /tmp/checksums.json ]; then \
    QUARTO_CHKSUM=$(jq -r --arg t "quarto" --arg ver "${QUARTO_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
      if [ -n "${QUARTO_CHKSUM}" ]; then echo "${QUARTO_CHKSUM}  /tmp/quarto.tar.gz" > /tmp/quarto.sha256 && sha256sum -c /tmp/quarto.sha256; fi; \
    fi && \
    mkdir -p "${HOME}/opt" && \
    tar -C "${HOME}/opt" -xzf /tmp/quarto.tar.gz && rm /tmp/quarto.tar.gz && \
    # Create bin directory and symlink
    mkdir -p "${HOME}/.local/bin" && \
    ln -sf "${HOME}/opt/quarto-${QUARTO_VERSION}/bin/quarto" "${HOME}/.local/bin/quarto" && \
    # Add to PATH
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.zshrc" && \
    # Add Quarto Python environment to zshrc
    echo "QUARTO_PYTHON=$(conda env list|grep "^base"|tr -s ' '|cut -f 3 -d ' ')" >> "${HOME}/.zshrc" && \
    # Install Chromium for HTML rendering
    "${HOME}/.local/bin/quarto" install chromium --no-prompt && \
    # Verify installation
    "${HOME}/.local/bin/quarto" check install && \
    mamba clean --all --yes --force-pkgs-dirs

# Add before CMD
COPY run-startup-scripts.sh /usr/local/bin/run-startup-scripts.sh
COPY entrypoint.sh /usr/local/bin/

# Add startup script execution to zshrc
#RUN [[ -f ${HOME}/.zshrc ]] && \
#    echo "if [[ -f /usr/local/bin/run-startup-scripts.sh ]]; then source /usr/local/bin/run-startup-scripts.sh ; fi" >> ${HOME}/.zshrc && \
#    chmod 600 ${HOME}/.zshrc

COPY bin/* ${HOME}/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command to start a login shell
CMD ["/bin/zsh", "-l"]
