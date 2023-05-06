#!/bin/bash

BUILDERS="${$@:-singlehtml pdflatex pdfhtml dirhtml}"

# If needed sets a default book
[[ -d ~/work/.book ]] || cp -r ~/.book/ ~/work/.book/ 

# Builds all format for every document in notebooks
for builder in $BUILDERS; do \
  jupyter-book build \
        --path-output ~/work/.book/ \
        --config ~/work/.book/_config.yml \
        --toc ~/work/.book/_toc.yml \
        --builder $builder \
        /home/jovyan/work/notebooks;
done