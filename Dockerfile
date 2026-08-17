# Ubuntu 22.04 LTS - Jammy
ARG BASE_IMAGE=ubuntu:jammy-20240125


# Utilities for downloading packages
FROM ${BASE_IMAGE} as downloader
# Bump the date to current to refresh curl/certificates/etc
RUN echo "2024.03.18"
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
                    binutils \
                    bzip2 \
                    ca-certificates \
                    curl \
                    unzip && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# AFNI
FROM downloader as afni
# Bump the date to current to update AFNI
RUN echo "2024.03.18"
RUN mkdir -p /opt/afni-latest \
    && curl -fsSL --retry 5 https://afni.nimh.nih.gov/pub/dist/tgz/linux_openmp_64.tgz \
    | tar -xz -C /opt/afni-latest --strip-components 1 \
    --exclude "linux_openmp_64/*.gz" \
    --exclude "linux_openmp_64/funstuff" \
    --exclude "linux_openmp_64/shiny" \
    --exclude "linux_openmp_64/afnipy" \
    --exclude "linux_openmp_64/lib/RetroTS" \
    --exclude "linux_openmp_64/lib_RetroTS" \
    --exclude "linux_openmp_64/meica.libs" \
    # Keep only what we use
    && find /opt/afni-latest -type f -not \( \
            -name "3dAFNItoNIFTI" \
        -or -name "3dAutomask" \
        -or -name "3dcalc" \
        -or -name "3dFWHMx" \
        -or -name "3dinfo" \
        -or -name "3dmaskave" \
        -or -name "3dSeg" \
        -or -name "3dSkullStrip" \
        -or -name "3dTnorm" \
        -or -name "3dToutcount" \
        -or -name "3dTqual" \
        -or -name "3dTshift" \
        -or -name "3dTstat" \
        -or -name "3dUnifize" \
        -or -name "3dvolreg" \
        -or -name "afni" \
       \) -delete

       # Use Ubuntu 20.04 LTS
FROM nipreps/miniconda:py39_2403.0

ARG DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:${CONDA_PATH}/lib"
ENV CONDA_PATH="/opt/conda"

# Configure PPAs for libpng12 and libxp6
RUN GNUPGHOME=/tmp gpg --keyserver hkps://keyserver.ubuntu.com --no-default-keyring --keyring /usr/share/keyrings/linuxuprising.gpg --recv 0xEA8CACC073C3DB2A \
    && GNUPGHOME=/tmp gpg --keyserver hkps://keyserver.ubuntu.com --no-default-keyring --keyring /usr/share/keyrings/zeehio.gpg --recv 0xA1301338A3A48C4A \
    && echo "deb [signed-by=/usr/share/keyrings/linuxuprising.gpg] https://ppa.launchpadcontent.net/linuxuprising/libpng12/ubuntu jammy main" > /etc/apt/sources.list.d/linuxuprising.list \
    && echo "deb [signed-by=/usr/share/keyrings/zeehio.gpg] https://ppa.launchpadcontent.net/zeehio/libxp/ubuntu jammy main" > /etc/apt/sources.list.d/zeehio.list

# Dependencies for AFNI; requires a discontinued multiarch-support package from bionic (18.04)
RUN apt-get update -qq \
    && apt-get install -y -q --no-install-recommends \
           ed \
           gsl-bin \
           libglib2.0-0 \
           libglu1-mesa-dev \
           libglw1-mesa \
           libgomp1 \
           libjpeg62 \
           libpng12-0 \
           libxm4 \
           libxp6 \
           netpbm \
           tcsh \
           xfonts-base \
           xvfb \
    && curl -sSL --retry 5 -o /tmp/multiarch.deb http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/multiarch-support_2.27-3ubuntu1.5_amd64.deb \
    && dpkg -i /tmp/multiarch.deb \
    && rm /tmp/multiarch.deb \
    && apt-get install -f \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && gsl2_path="$(find / -name 'libgsl.so.27' || printf '')" \
    && if [ -n "$gsl2_path" ]; then \
         ln -sfv "$gsl2_path" "$(dirname $gsl2_path)/libgsl.so.0"; \
    fi \
    && ldconfig

# Install AFNI
ENV AFNI_DIR="/opt/afni"
COPY --from=afni /opt/afni-latest ${AFNI_DIR}
ENV PATH="${AFNI_DIR}:$PATH" \
    AFNI_IMSAVE_WARNINGS="NO" \
    AFNI_MODELPATH="${AFNI_DIR}/models" \
    AFNI_TTATLAS_DATASET="${AFNI_DIR}/atlases" \
    AFNI_PLUGINPATH="${AFNI_DIR}/plugins"

# Install AFNI's dependencies
RUN micromamba install -n base -c conda-forge "ants=2.5" \
            && sync \
	    && micromamba clean -afy; sync \
	    && ldconfig

RUN python -m pip install ipyniivue jupyter

# Create a shared $HOME directory
RUN useradd -m -s /bin/bash -G users databot
WORKDIR /home/databot
ENV HOME="/home/databot"

RUN chmod 755 /home/databot

USER databot

# Pacify datalad
RUN git config --global user.name "302 data computation" \
    && git config --global user.email "302@hes-so.ch"

RUN micromamba shell init -s bash
ENV PATH="${CONDA_PATH}/bin:$PATH" \
    CPATH="${CONDA_PATH}/include:$CPATH" \
    LD_LIBRARY_PATH="${CONDA_PATH}/lib:$LD_LIBRARY_PATH"

RUN mkdir $HOME/data $HOME/outputs $HOME/.local \
    && chmod 1777 $HOME/.local \
    && datalad clone https://github.com/OpenNeuroDatasets/ds000005 $HOME/data/ds000005 \
    && datalad get -d $HOME/data/ds000005 $HOME/data/ds000005/sub-01/anat/sub-01_T1w.nii.gz

WORKDIR /home/databot/work

COPY brain_mri_pipeline.ipynb .

EXPOSE 8888

CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--allow-root"]
