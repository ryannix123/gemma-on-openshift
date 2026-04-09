#!/usr/bin/env bash
#
# build.sh - Download Gemma 4 E4B-IT from Hugging Face, build the
# ModelCar OCI image, and push to Quay.
#
# Prerequisites:
#   - podman (or docker)
#   - huggingface-cli: pip install --user huggingface_hub
#   - HF account with the Gemma license accepted at:
#       https://huggingface.co/google/gemma-4-e4b-it
#   - HF token in $HF_TOKEN env var (or run `huggingface-cli login` first)
#   - You're logged into quay.io: `podman login quay.io`
#
# Usage:
#   export HF_TOKEN=hf_xxxxx
#   ./build.sh                    # builds and pushes :v1
#   ./build.sh v2                 # builds and pushes :v2
#
# Compatible with macOS (zsh/bash) and Linux. Uses BSD-friendly flags.

set -euo pipefail

MODEL_ID="google/gemma-4-e4b-it"
IMAGE_REPO="quay.io/ryan_nix/gemma-4-e4b-it"
TAG="${1:-v1}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="${BUILD_DIR}/model"

echo ">>> Build directory: ${BUILD_DIR}"
echo ">>> Image: ${IMAGE_REPO}:${TAG}"

# 1. Download model from Hugging Face if not already present.
if [ ! -f "${MODEL_DIR}/config.json" ]; then
  echo ">>> Downloading ${MODEL_ID} from Hugging Face..."
  mkdir -p "${MODEL_DIR}"
  huggingface-cli download "${MODEL_ID}" \
    --local-dir "${MODEL_DIR}" \
    --local-dir-use-symlinks False \
    --exclude "*.gguf" "*.bin" "original/*"
  echo ">>> Download complete."
else
  echo ">>> Model files already present in ${MODEL_DIR}, skipping download."
fi

# 2. Show what we're about to package (sanity check before building).
echo ">>> Model directory contents:"
ls -lh "${MODEL_DIR}"
echo ">>> Total size:"
du -sh "${MODEL_DIR}"

# 3. Build the image.
echo ">>> Building OCI image..."
podman build \
  --platform linux/amd64 \
  -t "${IMAGE_REPO}:${TAG}" \
  -f "${BUILD_DIR}/Containerfile" \
  "${BUILD_DIR}"

# 4. Push to Quay.
echo ">>> Pushing to ${IMAGE_REPO}:${TAG}..."
podman push "${IMAGE_REPO}:${TAG}"

# 5. Also tag and push :latest for convenience.
podman tag "${IMAGE_REPO}:${TAG}" "${IMAGE_REPO}:latest"
podman push "${IMAGE_REPO}:latest"

echo ""
echo ">>> Done. Update 05-inferenceservice.yaml storageUri to:"
echo ">>>   oci://${IMAGE_REPO}:${TAG}"
echo ""
echo ">>> Then re-apply:"
echo ">>>   oc apply -f 05-inferenceservice.yaml"
