#!/bin/bash

echo "### Mamba"
echo ""
echo "$(mamba --version|sed s'/\(.*\)/  * \1/')"
echo "  * $(python --version)"
echo ""
echo "| Source  | Package | Version |"
echo "|---------|---------|--------:|"
echo "$(mamba list|grep -v "^#" | tr -s ' '|sed 's/\([^ ]*\) \([^ ]*\) \([^ ]*\) \([^ ]*\)/|\4|\1|\2|/'|sort)"
