# Containerfile — OCI ModelCar image for KServe model serving.
#
# Packages model weights from the local model/ directory into a minimal
# UBI9-micro image at /models/. KServe's ModelCar sidecar pattern mounts
# this path into the vLLM serving container via a symlink at runtime.
#
# Build:
#   podman build --platform linux/amd64 -t quay.io/ryan_nix/granite4-llm:v1 .
#
# The model/ directory must be populated before building. Use build.sh
# to download weights from Hugging Face and build+push in one step.

FROM registry.access.redhat.com/ubi9/ubi-micro:latest

LABEL org.opencontainers.image.title="Granite 4.1 3B for OpenShift Lightspeed" \
      org.opencontainers.image.description="IBM Granite 4.1 3B Instruct, packaged for KServe ModelCar storage" \
      org.opencontainers.image.authors="Ryan Nix <ryan.nix@gmail.com>" \
      org.opencontainers.image.source="https://github.com/ryannix123/openshift-ai-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --chown=1001:0 model/ /models/

USER 1001
