FROM jupyter/scipy-notebook:584f43f06586

USER root
RUN apt-get update && apt-get install -y \
	bash \
	curl \
	less \
	texlive \
	texlive-lang-french \
	texlive-latex-extra \
	vim \
	unzip \
	zip && \
  apt-get clean && rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/apt && \
  echo en_US.UTF-8 UTF-8 >> /etc/locale.gen && \
  locale-gen

# Sets locale as default
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Sets codeserver directories
ENV CODESERVEREXT_DIR /opt/codeserver/extensions
ENV CODE_WORKINGDIR $HOME/work
ENV CODESERVERDATA_DIR $HOME/work/codeserver/data
ENV PATH=/opt/bin:$PATH

# Add conda env hook
# COPY ./conda-activate.sh /usr/local/bin/before-notebook.d/

# RUN jupyter labextension install @jupyterlab/latex doesn't work with lab 3.0
# SO we test a fork. TODO: Multistage Build

RUN echo -e "\e[93m***** Install Jupyter Lab Extensions ****\e[38;5;241m" && \
        pip install --quiet --no-cache-dir --upgrade \
		jupyter-book==0.10.2 \
		jupyter-server-proxy==3.0.2 \
		nbgitpuller==0.9.0 \
		jupyterlab-git==0.30.1 \
		jupyterlab-system-monitor==0.8.0 && \
        conda install defaults::nb_conda_kernels && \
 	echo -e "\e[93m***** Install Jupyter LaTeX ****\e[38;5;241m" && \
		cd /tmp && \
    		git clone https://github.com/joequant/jupyterlab-latex.git && \
		cd jupyterlab-latex && \
		pip3 install -e . && \
		jlpm install && \
		jlpm run build && \
		jupyter labextension install . && \
		jlpm cache clean && \
		cd && \
		rm -rf /tmp/jupyterlab-latex && \
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
	#        --install-extension GabrielBB.vscode-lombok \
		--install-extension james-yu.latex-workshop \
	        --install-extension jebbs.plantuml && \
        	groupadd codeserver && \
	        chgrp -R codeserver $CODESERVEREXT_DIR &&\
        	chmod 770 -R $CODESERVEREXT_DIR && \
	        adduser "$NB_USER" codeserver && \
	echo -e "\e[93m**** Clean up ****\e[38;5;241m" && \
        	npm cache clean --force && \
	        jupyter lab clean && \
		fix-permissions $CONDA_DIR && \
	    	fix-permissions /home/$NB_USER

COPY code-server/codeserver-jupyter_notebook_config.py /tmp/
COPY code-server/icons $HOME/.jupyter/icons
RUN cat /tmp/codeserver-jupyter_notebook_config.py >> $HOME/.jupyter/jupyter_notebook_config.py

USER $NB_USER
