#!/bin/bash

echo "## Docker Client"
echo
echo "  * $(docker --version)"
docker info --format '{{json .}}'|jq -r '. | .ClientInfo.Plugins[] | "  * \(.Name) \(.Version)"'