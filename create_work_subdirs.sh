#!/bin/bash
for subdir in $NEEDED_WORK_DIRS; do
		dir=/home/jovyan/work/$subdir
		ln -s $dir /home/jovyan/$subdir
        if [ ! -f $dir ]; then
        	echo Creating $dir
        	mkdir -p $dir
        	chmod 700  $dir
        fi
done

for subfile in $NEEDED_WORK_FILES; do
		file=/home/jovyan/work/$subfile
		ln -s $file /home/jovyan/$subfile
        if [ ! -f $file ]; then
        	echo Creating $file
        	touch $file
        	chmod 700  $dir
        fi
done