FROM jupyter/scipy-notebook:2021-10-20

USER root

RUN apt-get update --yes && apt-get install --yes --no-install-recommends \
	bash \
	curl \
	less \
	vim \
	zip && \
  apt-get clean && rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/apt

# Sets codeserver directories
ENV CODESERVEREXT_DIR /opt/codeserver/extensions
ENV CODE_WORKINGDIR $HOME/work
ENV CODESERVERDATA_DIR $HOME/work/codeserver/data
ENV PATH=/opt/bin:$PATH

# Enable persistant conda env
COPY condarc /home/jovyan/.condarc

# Instalk JupyterLab
RUN echo -e "\e[93m***** Install Jupyter Lab Extensions ****\e[38;5;241m" && \
        pip install --quiet --no-cache-dir --upgrade \
			jupyter-book \
			jupyter-server-proxy \
			nbgitpuller \
			jupyterlab_latex \
			jupyterlab-git \
			jupyterlab-system-monitor \
			jinja-yaml-magic \
			ipympl && \
	    jupyter labextension install @jupyter-widgets/jupyterlab-manager && \
#	pip install jupyterlab_templates && \
#		jupyter labextension install jupyterlab_templates && \
#		jupyter serverextension enable --py jupyterlab_templates && \
#        conda install defaults::nb_conda_kernels && \
	mamba install --quiet --yes nb_conda_kernels && \
	mamba install --quiet --yes -c conda-forge \
		jupyterlab-drawio \
		jupyterlab_code_formatter \
		tectonic texlab chktex && \
	echo -e "\e[93m**** Installs Code Server Web ****\e[38;5;241m" && \
        	curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/opt --method=standalone && \
	        mkdir -p $CODESERVEREXT_DIR && \
        	PATH=/opt/bin:$PATH code-server \
	        --user-data-dir $CODESERVERDATA_DIR\
        	--extensions-dir $CODESERVEREXT_DIR \
	        --install-extension vscjava.vscode-java-pack \
	        --install-extension redhat.vscode-xml \
	        --install-extension vscode-icons-team.vscode-icons \
	        --install-extension SonarSource.sonarlint-vscode \
	        --install-extension GabrielBB.vscode-lombok \
		    --install-extension james-yu.latex-workshop \
	        --install-extension jebbs.plantuml && \
        	groupadd codeserver && \
	        chgrp -R codeserver $CODESERVEREXT_DIR &&\
        	chmod 770 -R $CODESERVEREXT_DIR && \
	        adduser "$NB_USER" codeserver && \
	echo -e "\e[93m**** Clean up ****\e[38;5;241m" && \
        	npm cache clean --force && \
			mamba clean --all -f -y && \
	        jupyter lab clean && \
			rm -rf "/home/${NB_USER}/.cache/yarn" && \
		fix-permissions "$CONDA_DIR" && \
	    	fix-permissions "/home/$NB_USER"

COPY configs/* /home/jovyan/.jupyter/
COPY code-server/jupyter_codeserver_config.py /tmp/
COPY code-server/icons $HOME/.jupyter/icons
RUN [[ ! -f /home/jovyan/.jupyter/jupyter_config.py ]] && touch /home/jovyan/.jupyter/jupyter_config.py ; \
	cat /tmp/jupyter_codeserver_config.py >> /home/jovyan/.jupyter/jupyter_config.py 

# INSTALL NB GRADER FIXE NEEDED
#COPY nbgrader_config.py /tmp/nbgrader_config.py
#RUN python3 -m pip install git+https://github.com/jupyter/nbgrader.git@5a81fd5 && \
#	jupyter nbextension install --symlink --sys-prefix --py nbgrader && \
#	jupyter nbextension enable --sys-prefix --py nbgrader && \
#	jupyter serverextension enable --sys-prefix --py nbgrader && \
#	python3 -m pip install ngshare_exchange && \
 #       cat  /tmp/nbgrader_config.py >> /etc/jupyter/nbgrader_config.py && \
#	echo -e "\e[93m**** Clean up ****\e[38;5;241m" && \
 #       	npm cache clean --force && \
#			mamba clean --all -f -y && \
#	        jupyter lab clean && \
#			rm -rf "/home/${NB_USER}/.cache/yarn" && \
#		    fix-permissions "$CONDA_DIR" && \
#	    	fix-permissions "/home/$NB_USER"

#Adds git and ssh sub directories in works
COPY create_work_subdirs.sh /usr/local/bin/before-notebook.d/
ENV NEEDED_WORK_DIRS .ssh
ENV NEEDED_WORK_FILES .gitconfig

USER $NB_USER

WORKDIR "${HOME}/work"
