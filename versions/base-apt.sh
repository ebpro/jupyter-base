#!/bin/bash

echo "### Apt packages"
echo
echo "| Package | Version |"
echo "|---------|--------:|"
apt list|cut -d ' ' -f 1,2|sed -n 's/\([^ ]*\) \([^ ]*\)/|\1|\2|/p'
