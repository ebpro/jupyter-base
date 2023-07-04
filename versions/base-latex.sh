#!/bin/bash

echo "### LaTeX"
echo
echo '```'
echo "$(tlmgr --version)"
echo '```'
echo
echo "| Package  | Description  |"
echo "|---------|----------:|"
echo "$(tlmgr list --only-installed|sed 's/^i \(.*\):\(.*\)/|\1|\2|/')"
