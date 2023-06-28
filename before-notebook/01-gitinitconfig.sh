#!/bin/bash

echo -e "\e[93m**** Default Git user setup ****\e[38;5;241m"

# Adds basic options if not already sets
git config --get init.defaultBranch&>/dev/null || \
    git config --global init.defaultBranch master

git config --get pull.rebase&>/dev/null || \
    git config --global pull.rebase false 

git config --get credential.credentialStore&>/dev/null || \
    git config --global credential.credentialStore gpg

git config --get fetch.prune&>/dev/null || \
    git config --global fetch.prune true

# Adds github sshkey if it does not exists (WARNING DANGEROUS)
( ssh-keygen -F github.com &>/dev/null ) || \
    ( ssh-keyscan github.com >> /home/jovyan/.ssh/known_hosts )