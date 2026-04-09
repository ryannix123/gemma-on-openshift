# Containerfile for the Gemma 4 E4B OCI model image (ModelCar pattern).
#
# KServe's OCI storage initializer expects model files at /models in
# the image. We use ubi9-micro as the base because it's tiny (~25MB)
# and we don't need a shell or package manager -- the image only ever
# acts as a passive file source for KServe.
#
# Build context (./model/) must contain the Gemma 4 E4B-IT model files
# downloaded from Hugging Face. See build.sh for the download step.
#
# Project label set per Ryan's container/project convention.
FROM registry.access.redhat.com/ubi9/ubi-micro:latest

LABEL org.opencontainers.image.title="Gemma 4 E4B-IT for OpenShift Lightspeed" \
      org.opencontainers.image.description="Google Gemma 4 E4B Instruction-Tuned, packaged for KServe ModelCar storage" \
      org.opencontainers.image.authors="Ryan Nix <ryan.nix@gmail.com>" \
      org.opencontainers.image.source="https://github.com/ryannix123/ols-gemma4-sno" \
      org.opencontainers.image.licenses="Apache-2.0"

# Copy model files into /models. KServe's storage initializer copies
# from this path into the predictor container's /mnt/models volume.
COPY --chown=1001:0 model/ /models/

# Run as non-root for restricted-v2 SCC compatibility.
USER 1001
