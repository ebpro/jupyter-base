#!/bin/bash

echo "### Jupyterlab"
echo
echo '```'
echo "$(jupyter labextension list 2>&1)"
echo '```'
