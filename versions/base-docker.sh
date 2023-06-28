#!/bin/bash

echo "### Docker Client"
echo
echo "$(docker --version)"
echo "| Plugin  | Version |"
echo "|---------|--------:|"
docker info --format '{{json .}}'|jq -r '. | .ClientInfo.Plugins[] | "|\(.Name)|\(.Version)|"'