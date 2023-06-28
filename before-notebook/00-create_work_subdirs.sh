#!/bin/bash

echo -e "\e[93m**** Create and link user files and dirs ****\e[38;5;241m"

for subdir in $NEEDED_WORK_DIRS; do
		dir="/home/jovyan/work/$subdir"
		ln -s "$dir" "/home/jovyan/$subdir"
        if [ ! -f "$dir" ]; then
        	echo Creating "$dir for group ${NB_GID}"
        	mkdir -p "$dir"
        fi
		ls -l $dir
		chown -R jovyan:users "$dir"
		ls -l $dir
done

for subfile in $NEEDED_WORK_FILES; do
		file="/home/jovyan/work/$subfile"
		ln -s "$file" "/home/jovyan/$subfile"
        if [ ! -f "$file" ]; then
        	echo Creating "$file for group ${NB_GID}"
        	touch "$file"        
        fi
		chown -R jovyan:users "$file"
done
