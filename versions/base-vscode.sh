#!/bin/bash

echo "### Visual Studio Code"
echo

if ! command -v code-server &> /dev/null
then
    echo "not installed"
    exit
fi

CODESERVERDATA_DIR=/tmp/vscode_datadir

CODE_WORKINGDIR=/tmp

# To generate empty config
code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version > /dev/null 2>&1

echo "$(code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $   --version)"
echo
echo "| Extension | Version |"
echo "|-----------|--------:|"
echo "$(code-server --extensions-dir $CODESERVEREXT_DIR --list-extensions --show-versions|sed -n s/'\([^@]*\)@\([^@]*\)/|\1|\2|/p')"

# to remove the empty config
# rm -rf ~/.config/code-server