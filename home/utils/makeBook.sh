#!/bin/bash

BUILDERS=("singlehtml" "pdflatex" "dirhtml")
#BUILDERS=("singlehtml")

# If needed sets a default book
[[ -d .book ]] || cp -r ~/.book/ .
[[ -d references.bib ]] || touch references.bib
[[ -f Book.md ]] || echo "# My Book" > Book.md

CURRENT_DIR=$(pwd)

GIT_SUFFIX=$(git config --get remote.origin.url |\
        sed -r -e 's/.*github.com\:?/github/' \
        -e 's/\.git//')
OUTPUT_DIR="/home/jovyan/work/exports/${GIT_SUFFIX:-${PWD##*/}}/book"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

FULLNAME=$(pwd|cut -d '/' -f 6,7,8|tr '/' '-')

echo "Notebooks dir: $CURRENT_DIR"
echo "Output dir: $OUTPUT_DIR"
echo "Fullname: $FULLNAME"

# Cleans up if needed
[[ -d "$OUTPUT_DIR" ]] && jupyter-book clean $OUTPUT_DIR

# Builds all format for every document in notebooks
for builder in ${BUILDERS[@]}; do \
  jupyter-book build \
        --path-output $OUTPUT_DIR \
        --config $CURRENT_DIR/.book/_config.yml \
        --toc $CURRENT_DIR/.book/_toc.yml \
        --builder $builder \
        $CURRENT_DIR ;
done
(cd $OUTPUT_DIR && tar -zcf $FULLNAME.tar.gz \
        --exclude="_build/jupyter_execute" \
        --transform="s/_build/$FULLNAME/g" \
        _build)