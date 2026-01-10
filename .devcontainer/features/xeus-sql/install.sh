#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "xeus-sql: optional native SQL kernel feature (conda-forge)"

# Prefer conda/mamba install (xeus-sql is provided on conda-forge)
if [ -x "${HOME_DIR}/miniforge3/bin/mamba" ]; then
  "${HOME_DIR}/miniforge3/bin/mamba" install -y -n base -c conda-forge xeus-sql sqlalchemy psycopg2 mysqlclient || true
elif [ -x "${HOME_DIR}/miniforge3/bin/conda" ]; then
  "${HOME_DIR}/miniforge3/bin/conda" install -y -n base -c conda-forge xeus-sql sqlalchemy psycopg2 mysqlclient || true
else
  echo "xeus-sql: conda not found, skipping xeus-sql installation" >&2
fi

echo "xeus-sql: installation step complete (if enabled)"
