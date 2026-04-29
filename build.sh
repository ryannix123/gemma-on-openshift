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

MODEL_ID="google/gemma-4-E4B-it"
IMAGE_REPO="quay.io/ryan_nix/gemma-4-e4b-it"
TAG="${1:-v1}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="${BUILD_DIR}/model"

echo ">>> Build directory: ${BUILD_DIR}"
echo ">>> Image: ${IMAGE_REPO}:${TAG}"

# 1. Download model from Hugging Face if not already present.
#
# We invoke the Python API directly rather than the CLI. The `hf` CLI
# (1.x) has broken `--exclude` semantics -- it treats the patterns as
# include filters instead of exclude filters, silently downloading zero
# files. The Python `snapshot_download()` function has a stable
# `ignore_patterns` kwarg that does what we want.
if [ ! -f "${MODEL_DIR}/config.json" ]; then
  echo ">>> Downloading ${MODEL_ID} from Hugging Face..."
  mkdir -p "${MODEL_DIR}"

  # Verify huggingface_hub is installed.
  if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "ERROR: huggingface_hub Python package not found." >&2
    echo "Install with: pip install --user --upgrade huggingface_hub" >&2
    exit 1
  fi

  # Call snapshot_download via inline Python. Ignores quantized GGUF and
  # legacy PyTorch .bin files -- vLLM uses safetensors. Ignores
  # original/* which is the pre-conversion checkpoint.
  python3 - <<PYEOF
from huggingface_hub import snapshot_download
import os

model_id = "${MODEL_ID}"
local_dir = "${MODEL_DIR}"

path = snapshot_download(
    repo_id=model_id,
    local_dir=local_dir,
    ignore_patterns=["*.gguf", "*.bin", "original/*"],
    # Bail instead of resolving to an empty set if patterns filter too aggressively.
    allow_patterns=None,
)
print(f"Downloaded to: {path}")
PYEOF
  echo ">>> Download complete."
else
  echo ">>> Model files already present in ${MODEL_DIR}, skipping download."
fi

# 2. Show what we're about to package (sanity check before building).
echo ">>> Model directory contents:"
ls -lh "${MODEL_DIR}"
echo ">>> Total size:"
du -sh "${MODEL_DIR}"

# Sanity check: Gemma 4 E4B weights should be multiple GB. If the download
# silently failed (wrong repo ID, auth issue, gated model not accepted),
# the directory will be tiny. Bail loudly so we don't waste time building
# and pushing an empty image.
#
# Uses `stat` with two syntaxes to stay portable: BSD stat (-f %z) on
# macOS, GNU stat (--format=%s) on Linux. Sum all regular file sizes
# under MODEL_DIR. No `du -b` because that's GNU-only and silently
# breaks on macOS.
echo ">>> Running sanity check on model size..."
if stat -f %z "${MODEL_DIR}" >/dev/null 2>&1; then
  # macOS / BSD stat
  MODEL_SIZE_BYTES=$(find "${MODEL_DIR}" -type f -exec stat -f %z {} + | awk 'BEGIN{s=0} {s+=$1} END{print s}')
else
  # GNU stat
  MODEL_SIZE_BYTES=$(find "${MODEL_DIR}" -type f -exec stat --format=%s {} + | awk 'BEGIN{s=0} {s+=$1} END{print s}')
fi

MIN_EXPECTED_BYTES=$((3 * 1024 * 1024 * 1024))  # 3 GB floor
if [ "${MODEL_SIZE_BYTES:-0}" -lt "${MIN_EXPECTED_BYTES}" ]; then
  echo "" >&2
  echo "ERROR: Model directory is suspiciously small (< 3 GB)." >&2
  echo "       Actual size: ${MODEL_SIZE_BYTES} bytes" >&2
  echo "" >&2
  echo "       Gemma 4 E4B weights should be 5-16 GB. This usually means:" >&2
  echo "         1. Wrong HF repo ID (case-sensitive: google/gemma-4-E4B-it)" >&2
  echo "         2. Not logged in: run 'hf auth login'" >&2
  echo "         3. Gemma license not accepted at:" >&2
  echo "            https://huggingface.co/${MODEL_ID}" >&2
  echo "" >&2
  echo "       Delete the model/ directory and re-run after fixing the issue." >&2
  exit 1
fi
echo ">>> Sanity check passed: model is ${MODEL_SIZE_BYTES} bytes ($(echo "scale=1; ${MODEL_SIZE_BYTES} / 1073741824" | bc)G)."

# 3. Build the image.
echo ">>> Building OCI image..."
podman build \
  --platform linux/amd64 \
  -t "${IMAGE_REPO}:${TAG}" \
  -f "${BUILD_DIR}/Containerfile" \
  "${BUILD_DIR}"

# 4. Push to Quay using `podman push --retry`.
#
# We previously tried `skopeo copy` with containers-storage:, but on
# macOS skopeo runs on the host and reads from a host-side vfs storage
# while podman runs inside its Linux VM with separate storage -- the
# image lives only in podman's VM and skopeo can't see it.
#
# Podman 5.x supports --retry and --retry-delay natively, which gives
# us the resilience we need without the storage backend mismatch. Same
# behavior conceptually: each blob upload is retried up to N times on
# transient errors, with the connection resuming from where it stalled
# rather than restarting from byte zero.

# Number of retries for each blob upload. 5 is generous enough to survive
# typical ISP flakes without burning excessive time on a real failure.
PUSH_RETRY_TIMES="${PUSH_RETRY_TIMES:-5}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-10s}"

echo ">>> Pushing ${IMAGE_REPO}:${TAG} via podman (retries: ${PUSH_RETRY_TIMES}, delay: ${PUSH_RETRY_DELAY})..."
podman push \
  --retry "${PUSH_RETRY_TIMES}" \
  --retry-delay "${PUSH_RETRY_DELAY}" \
  "${IMAGE_REPO}:${TAG}"

# 5. Also push the :latest tag for convenience.
echo ">>> Tagging and pushing :latest..."
podman tag "${IMAGE_REPO}:${TAG}" "${IMAGE_REPO}:latest"
podman push \
  --retry "${PUSH_RETRY_TIMES}" \
  --retry-delay "${PUSH_RETRY_DELAY}" \
  "${IMAGE_REPO}:latest"

echo ""
echo ">>> Done. Update manifests/05-inferenceservice.yaml storageUri to:"
echo ">>>   oci://${IMAGE_REPO}:${TAG}"
echo ""
echo ">>> Then re-apply:"
echo ">>>   oc apply -f manifests/05-inferenceservice.yaml"