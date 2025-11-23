ARG VARIANT="ubuntu-24.04"
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

ARG NB_USER="jovyan"
ARG NB_UID="1001"
ARG NB_GID="1001"
ARG QUARTO_VERSION="1.8.24"

ENV HOME=/home/${NB_USER}
ENV PATH=${HOME}/.local/bin:/opt/quarto-${QUARTO_VERSION}/bin:${PATH}

# Install minimal system deps and micromamba
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates tar bzip2 gnupg jq && \
    rm -rf /var/lib/apt/lists/*

# Install micromamba (fast lightweight conda compatible tool)
RUN curl -fsSL https://micromamba.snakepit.net/api/micromamba/linux-$(uname -m)/latest \
    | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    chmod +x /usr/local/bin/micromamba

# Copy environment and metadata for build-time configuration
COPY Artefacts/environment.yml /tmp/environment.yml
COPY Artefacts/versions.json /tmp/versions.json
COPY Artefacts/requirements.txt /tmp/requirements.txt
COPY Artefacts/checksums.json /tmp/checksums.json

# Install Quarto (binary tarball) with optional checksum verification
RUN set -eux; \
    ARCH=$(uname -m); \
    case "${ARCH}" in \
      x86_64|X86_64) arch=amd64 ;; \
      aarch64) arch=arm64 ;; \
      *) arch=amd64 ;; \
    esac; \
    QUARTO_VERSION=$(jq -r '.tools.quarto' /tmp/versions.json) && \
    QUARTO_URL="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${arch}.tar.gz"; \
    echo "Downloading Quarto from ${QUARTO_URL}"; \
    curl -fsSL "${QUARTO_URL}" -o /tmp/quarto.tar.gz; \
    # Verify checksum if provided in /tmp/checksums.json
    if command -v jq >/dev/null 2>&1 && [ -f /tmp/checksums.json ]; then \
      QUARTO_CHECKSUM=$(jq -r --arg ver "${QUARTO_VERSION}" --arg arch "$arch" --arg t "quarto" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json || true); \
      if [ -n "${QUARTO_CHECKSUM}" ] && [ "${QUARTO_CHECKSUM}" != "null" ]; then \
        echo "Verifying Quarto checksum..."; \
        echo "${QUARTO_CHECKSUM}  /tmp/quarto.tar.gz" > /tmp/quarto.sha256; \
        sha256sum -c /tmp/quarto.sha256; \
      else \
        echo "No Quarto checksum provided in /tmp/checksums.json — writing computed checksum to /tmp/quarto.sha256"; \
        sha256sum /tmp/quarto.tar.gz > /tmp/quarto.sha256 || true; \
      fi; \
    else \
      echo "jq not available or /tmp/checksums.json missing — writing computed checksum to /tmp/quarto.sha256"; \
      sha256sum /tmp/quarto.tar.gz > /tmp/quarto.sha256 || true; \
    fi; \
    mkdir -p /opt && tar -C /opt -xzf /tmp/quarto.tar.gz && rm /tmp/quarto.tar.gz; \
    ln -sf /opt/quarto-${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto

# Ensure user exists and set permissions
RUN id -u ${NB_USER} >/dev/null 2>&1 || useradd -m -s /bin/zsh -u ${NB_UID} -U ${NB_USER} || true && \
    mkdir -p ${HOME}/.local/bin && chown -R ${NB_USER}:${NB_USER} ${HOME}

USER ${NB_USER}
WORKDIR ${HOME}
SHELL ["/bin/zsh","-l","-c"]

# Create the micromamba environment from provided environment.yml and install pip requirements
RUN set -eux; \
  mkdir -p ${HOME}/.local/bin ${HOME}/.micromamba; \
  micromamba create -y -p ${HOME}/.micromamba/envs/jupyter-env -f /tmp/environment.yml || true; \
  if [ -f /tmp/requirements.txt ]; then \
    micromamba run -p ${HOME}/.micromamba/envs/jupyter-env python -m pip install --no-cache-dir -r /tmp/requirements.txt || true; \
  fi; \
  # Register IPython kernel for the environment if ipykernel is available
  if micromamba run -p ${HOME}/.micromamba/envs/jupyter-env python -c "import ipykernel" >/dev/null 2>&1; then \
    micromamba run -p ${HOME}/.micromamba/envs/jupyter-env python -m ipykernel install --user --name jupyter-env --display-name "Python (jupyter-env)" || true; \
  fi

CMD ["/bin/zsh","-l"]
ARG VARIANT="ubuntu-24.04"
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

ARG NB_USER="jovyan"
ARG NB_UID="1001"
ARG NB_GID="1001"
ARG QUARTO_VERSION="1.8.24"

ENV HOME=/home/${NB_USER}
ENV PATH=${HOME}/.local/bin:/opt/quarto-${QUARTO_VERSION}/bin:${PATH}

# Install minimal system deps and micromamba
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates tar bzip2 gnupg && \
    rm -rf /var/lib/apt/lists/*

# Install micromamba (fast lightweight conda compatible tool)
RUN curl -fsSL https://micromamba.snakepit.net/api/micromamba/linux-$(uname -m)/latest \
    | tar -xvj -C /usr/local/bin --strip-components=1 bin/micromamba && \
    chmod +x /usr/local/bin/micromamba

# Copy environment and versions metadata (for later use in postCreate)
COPY Artefacts/environment.yml /tmp/environment.yml
COPY Artefacts/versions.json /tmp/versions.json

# Install Quarto (binary tarball)
RUN set -eux; \
    ARCH=$(uname -m); \
    case "${ARCH}" in \n+      x86_64|X86_64) arch=amd64 ;; \n+      aarch64) arch=arm64 ;; \n+      *) arch=amd64 ;; \n+    esac; \
    QUARTO_URL="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL "${QUARTO_URL}" -o /tmp/quarto.tar.gz; \
    mkdir -p /opt && tar -C /opt -xzf /tmp/quarto.tar.gz && rm /tmp/quarto.tar.gz; \
    ln -sf /opt/quarto-${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto

# Ensure user exists and set permissions
RUN id -u ${NB_USER} >/dev/null 2>&1 || useradd -m -s /bin/zsh -u ${NB_UID} -U ${NB_USER} || true && \
    mkdir -p ${HOME}/.local/bin && chown -R ${NB_USER}:${NB_USER} ${HOME}

USER ${NB_USER}
WORKDIR ${HOME}
SHELL ["/bin/zsh","-l","-c"]

CMD ["/bin/zsh","-l"]
