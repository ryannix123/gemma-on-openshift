# =============================================================================
# Granite 4.1 3B on OpenShift — UBI 10 Variant
# File: Containerfile
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
#
# Build context: repo root (.)
# Build command: podman build --platform linux/amd64 \
#                  -t quay.io/ryan_nix/granite4-llm:latest .
#
# Packages model weights from the local model/ directory into a minimal
# UBI 10 micro image at /models/. KServe's ModelCar sidecar pattern mounts
# this path into the vLLM serving container via a symlink at runtime.
#
# See hummingbird/Containerfile for the Project Hummingbird distroless variant.
# =============================================================================

FROM registry.access.redhat.com/ubi10/ubi-micro:latest

LABEL name="granite4-llm" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>" \
      summary="Granite 4.1 3B model weights on UBI 10 micro" \
      description="IBM Granite 4.1 3B Instruct, packaged for KServe ModelCar storage" \
      io.k8s.display-name="Granite 4.1 3B (UBI 10)" \
      io.openshift.tags="ai,llm,granite,model" \
      org.opencontainers.image.title="Granite 4.1 3B for OpenShift Lightspeed" \
      org.opencontainers.image.description="IBM Granite 4.1 3B Instruct, packaged for KServe ModelCar storage on UBI 10" \
      org.opencontainers.image.authors="Ryan Nix <ryan.nix@gmail.com>" \
      org.opencontainers.image.source="https://github.com/ryannix123/granite4-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --chown=1001:0 model/ /models/

USER 1001
