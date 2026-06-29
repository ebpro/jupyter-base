#!/usr/bin/env bash
# Simple helper to display files in a directory
DIR=${1:-.}
echo "Files in: ${DIR}"
ls -la "${DIR}"
