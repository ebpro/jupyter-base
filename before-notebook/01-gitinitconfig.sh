#!/bin/bash

echo -e "\e[93m**** Default git user setup ****\e[38;5;241m"

git config --global init.defaultBranch master

ssh-keyscan -H github.com >> /home/jovyan/.ssh/known_hosts
