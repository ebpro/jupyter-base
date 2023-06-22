#!/bin/bash

# To generate empty config
code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version > /dev/null 2>&1

echo "## Visual Studio Code"
echo
echo "$(code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version)"
echo "| Extension | Version |"
echo "|-----------|--------:|"
echo "$(code-server --extensions-dir $CODESERVEREXT_DIR --list-extensions --show-versions|sed -n s/'\([^@]*\)@\([^@]*\)/|\1|\2|/p')"

# to remove the empty config
rm -rf ~/.config/code-server