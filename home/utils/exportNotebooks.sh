#!/usr/bin/env bash

FORMATS=("html" "pdf" "slides")

CURRENT_DIR=$(pwd)

GIT_SUFFIX=$(git config --get remote.origin.url |\
        sed -r -e 's/.*github.com\:?/github/' \
        -e 's/\.git//')
OUTPUT_DIR="/home/jovyan/work/exports/"${GIT_SUFFIX:-${PWD##*/}}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "Exports in $OUTPUT_DIR"

mkdir -p $OUTPUT_DIR

NOTEBOOKS=$(ls *.ipynb)

if [[ "$NOTEBOOKS" == "" ]]; then 
        echo "No notebooks. Exiting."
        exit 0
fi

# Execute every notebook once
jupyter nbconvert --to notebook --execute --inplace *.ipynb

# Generate export
for format in ${FORMATS[@]}; do
    echo "-->Converting to $format"
    jupyter nbconvert --output-dir $OUTPUT_DIR --embed-images --to $format *.ipynb;
done