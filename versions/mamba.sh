#!/bin/bash

echo "## Mamba"
echo "$(mamba --version|sed s'/\(.*\)/  * \1/')"
echo "  * $(python --version)"
echo "  * Packages :"
echo "$(mamba list|grep -v "^#" | tr -s ' '|sed 's/\([^ ]*\) \([^ ]*\) \([^ ]*\) \([^ ]*\)/    * \4 \1 \2/'|sort)"
