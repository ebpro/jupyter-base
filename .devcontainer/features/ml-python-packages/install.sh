#!/bin/bash
set -e

# Install ML packages via conda
conda install -y -c conda-forge \
    scikit-learn \
    matplotlib \
    seaborn \
    pandas \
    numpy \
    scipy

echo "ML Python packages installed successfully"
