#!/bin/bash

echo "## Apt"
echo
echo "$(apt list --installed 2>/dev/null |tr '/' ' '|cut -d ' ' -f 1,3|sed 's/\([^ ]*\) \([^ ]*\)/    * \1 (\2)/')"
