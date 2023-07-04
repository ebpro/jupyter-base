#!/bin/bash

echo "### Docker Client"
echo
if ! command -v docker &> /dev/null
then
    echo "not installed"
    exit
fi
echo "$(docker --version)"
echo
echo "| Plugin  | Version |"
echo "|---------|--------:|"
docker info --format '{{json .}}'|jq -r '. | .ClientInfo.Plugins[] | "|\(.Name)|\(.Version)|"'