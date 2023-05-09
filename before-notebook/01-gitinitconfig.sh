#!/bin/bash

echo -e "\e[93m**** Default git user setup ****\e[38;5;241m"

git config --global init.defaultBranch master

git config --global --add safe.directory /home/jovyan/work/notebooks

git config --global pull.rebase false 

git config --global credential.credentialStore gpg

ssh-keyscan -H github.com >> /home/jovyan/.ssh/known_hosts
