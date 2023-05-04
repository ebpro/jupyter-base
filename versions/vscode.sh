#!/bin/bash

# To generate empty config
code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version

echo "## Visual Studio Code"
echo
echo "  * $(code-server --user-data-dir $CODESERVERDATA_DIR --extensions-dir $CODESERVEREXT_DIR --version)"
echo "  * Extensions :"
echo "$(code-server --extensions-dir $CODESERVEREXT_DIR --list-extensions --show-versions|sed s/'\([^@]*\)@\([^@]*\)/    * \1 (\2)/')"

# to remove the empty config
rm -rf ~/.config/code-server