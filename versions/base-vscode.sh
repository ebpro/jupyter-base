#!/bin/bash


if ! command -v code-server &> /dev/null
then
    echo "code-server could not be found"
    exit
fi

CODESERVERDATA_DIR=/tmp/vscode_datadir

ls -alR /home/jovyan/.config

CODE_WORKINGDIR=/tmp

# To generate empty config
code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version > /dev/null 2>&1

echo "### Visual Studio Code"
echo
echo "$(code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $   --version)"
echo "| Extension | Version |"
echo "|-----------|--------:|"
echo "$(code-server --extensions-dir $CODESERVEREXT_DIR --list-extensions --show-versions|sed -n s/'\([^@]*\)@\([^@]*\)/|\1|\2|/p')"

# to remove the empty config
# rm -rf ~/.config/code-server