# 302 neuro lab image. Multi-stage, and multi-arch (linux/amd64, linux/arm64).
#
# The multi-stage lesson the AFNI build used to carry is still here, and it is a
# sharper one now: stages 1 and 2 exist because their OUTPUT is architecture-neutral
# data, so they run once on the build host and feed both target architectures.
# Stage 3 exists to throw a C toolchain away.
ARG PYTHON_TAG=3.12-slim-trixie

# --- 1. The SynthStrip payload ----------------------------------------------
# Pinned to amd64 because the official image HAS no arm64 manifest, so without
# this the stage cannot be resolved at all when building on Apple silicon.
#
# It is safe, and it is the whole trick: nothing from this stage is ever
# EXECUTED. We take a Python script and 31 MB of PyTorch tensors -- both are
# just bytes, identical on every CPU -- and we leave /freesurfer/env behind,
# which is the arch-specific part.
#
# BuildKit lints a constant --platform as a likely mistake, which it usually is.
# Carrying it in an ARG says the value was chosen rather than forgotten, and
# lets anyone override it if an arm64 build of that image ever appears.
ARG SYNTHSTRIP_PLATFORM=linux/amd64
FROM --platform=${SYNTHSTRIP_PLATFORM} freesurfer/synthstrip:1.8 AS synthstrip

# --- 2. The dataset ----------------------------------------------------------
# $BUILDPLATFORM is the machine doing the building, so this runs natively for both
# target legs and its result is shared. One 5 MB file, fetched over plain HTTPS.
FROM --platform=$BUILDPLATFORM python:${PYTHON_TAG} AS data
ARG T1W_URL=https://s3.amazonaws.com/openneuro.org/ds000005/sub-01/anat/sub-01_T1w.nii.gz
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data/ds000005/sub-01/anat \
    && curl -fsSL --retry 5 -o /data/ds000005/sub-01/anat/sub-01_T1w.nii.gz "${T1W_URL}"

# --- 3. surfa ----------------------------------------------------------------
# surfa ships source-only on PyPI: two Cython extensions, so it needs a compiler.
# Build the wheel here and leave build-essential behind.
#
# The pins are not arbitrary. They are the combination the official
# freesurfer/synthstrip:1.8 image ships, read out of its own site-packages.
# surfa 0.6.3 is BROKEN against this stack: it trips numpy 2's strictness in
# reorient(), and then hands scipy a boolean mask that find_objects() rejects.
FROM python:${PYTHON_TAG} AS wheels
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
# python:3.12-slim ships no setuptools, and --no-build-isolation needs one. The
# isolation is disabled on purpose, so surfa compiles against the SAME numpy it
# will run against rather than whatever pip would pick for the build.
RUN pip install --no-cache-dir "setuptools" "wheel" "Cython>=3.0" "numpy==1.26.4" \
    && pip wheel --no-cache-dir --wheel-dir /wheels "numpy==1.26.4" \
    && pip wheel --no-cache-dir --no-build-isolation --wheel-dir /wheels "surfa==0.6.1"

# --- 4. The lab image --------------------------------------------------------
FROM python:${PYTHON_TAG}

ARG DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git less \
    && rm -rf /var/lib/apt/lists/*

# CPU-only torch. The default PyPI wheel drags in gigabytes of CUDA that nothing
# here can use; from the CPU index it is 104 MB on aarch64, 184 MB on x86_64.
RUN pip install --no-compile --index-url https://download.pytorch.org/whl/cpu "torch==2.9.1"

# One resolve, so nothing quietly drags numpy forward again. The constraint is
# the point: surfa 0.6.1 is a numpy-1 package, and a later scikit-learn would
# happily upgrade numpy underneath it and break skull-stripping at run time.
RUN --mount=from=wheels,source=/wheels,target=/wheels \
    printf '%s\n' "numpy==1.26.4" "scipy==1.15.3" > /tmp/constraints.txt \
    && pip install --no-compile --find-links=/wheels --constraint /tmp/constraints.txt \
        "surfa==0.6.1" \
        numpy \
        scipy \
        nibabel \
        scikit-learn \
        niimath \
        ipyniivue \
        jupyter \
        notebook \
    && rm /tmp/constraints.txt \
    && python -c "import numpy, surfa, sklearn, scipy; assert numpy.__version__.startswith('1.26'), numpy.__version__"

# SynthStrip: the driver script and the weights, nothing else.
ENV FREESURFER_HOME=/opt/synthstrip
COPY --from=synthstrip /freesurfer/models/        ${FREESURFER_HOME}/models/
COPY --from=synthstrip /freesurfer/mri_synthstrip /usr/local/bin/mri_synthstrip

COPY scripts/simple_strip scripts/tissue_segment scripts/tissue_volumes /usr/local/bin/
RUN chmod +x /usr/local/bin/mri_synthstrip \
             /usr/local/bin/simple_strip \
             /usr/local/bin/tissue_segment \
             /usr/local/bin/tissue_volumes \
    # the niimath wheel ships its binary without the execute bit and its Python
    # wrapper tries to chmod at import, which a non-root user cannot do
    # niimath's console script is a Python shim that chmod()s its own bundled
    # binary at import, which a non-root user cannot do even when the bit is
    # already set. Point the name straight at the binary instead.
    && chmod +x /usr/local/lib/python3.12/site-packages/niimath/bin/niimath \
    && ln -sf /usr/local/lib/python3.12/site-packages/niimath/bin/niimath \
              /usr/local/bin/niimath

# The recipe that built this image, inside the image. Week 1 day 2 asks you to
# split it in two, and the lab repository is private, so this is where you read it.
COPY Dockerfile /opt/302/Dockerfile

RUN useradd -m -s /bin/bash -G users databot
USER databot
ENV HOME=/home/databot
WORKDIR /home/databot
RUN mkdir -p $HOME/outputs $HOME/work $HOME/src

COPY --from=data --chown=databot:databot /data /home/databot/data
COPY --chown=databot:databot brain_mri_pipeline.ipynb /home/databot/src/

WORKDIR /home/databot/work
RUN ln -s ../src/brain_mri_pipeline.ipynb .

EXPOSE 8888

# No ENTRYPOINT on purpose: `docker run IMAGE mri_synthstrip ...` has to work,
# because that is what a Compose "tools" service does.
CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--port=8888", "--no-browser"]
