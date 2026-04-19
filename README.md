# OpenShift Lightspeed + Gemma 4 on Single Node OpenShift

A homelab-scale reference architecture for running Red Hat OpenShift
Lightspeed against a self-hosted Gemma 4 model on Red Hat OpenShift AI,
with no external LLM provider. Built around an SNO cluster with a
consumer NVIDIA GPU (3060 Ti / 8GB VRAM).

**Not officially supported by Red Hat.** This uses the OLS `openai`
provider type pointing at a self-hosted vLLM ServingRuntime. The
pattern works but is outside the supported provider matrix. For
production use with regulated customers, file a support exception
through your account team.

## What this builds

```
OpenShift Lightspeed (openshift-lightspeed ns)
        |
        v  HTTP /v1/chat/completions
        |
KServe InferenceService (gemma-serving ns)
   = vLLM ServingRuntime
   + Gemma 4 E4B-IT (OCI ModelCar image from Quay)
   + nvidia.com/gpu: 1
        |
        v
NVIDIA 3060 Ti (8GB VRAM)
```

## Hardware target

- Single Node OpenShift 4.16+
- 12th Gen Intel i9 (or equivalent), 64GB+ RAM recommended
- NVIDIA RTX 3060 Ti (or any NVIDIA card with 8GB+ VRAM)
- ~50GB free on default storage class for model PVC overhead

For a real customer pilot, the target is a 3-node compact cluster with
an L4 or L40S GPU worker. The YAML in this bundle changes minimally
between the two — see "Scaling up" at the bottom.

## Two paths: manual or automated

You can apply the manifests by hand (`oc apply -f ...`) or run the
included Ansible playbook that handles everything — including GPU
auto-detection, readiness waits, and a CUDA validation step — in one
command.

- **Manual apply:** see "Apply order" below. Best when you're
  recording a video or learning the pattern step by step.
- **Ansible automation:** see [`ansible/README.md`](ansible/README.md).
  Best for repeat deployments, customer pilots, or when you just want
  the thing built without babysitting it.

Both paths apply the same YAML files. The Ansible playbook uses `oc`
under the hood — no extra Python dependencies, no SSH required.

## Prerequisites (do these first, in this order)

1. **Install operators from OperatorHub** (in the web console):
   - Node Feature Discovery Operator
   - NVIDIA GPU Operator
   - Red Hat OpenShift AI
   - OpenShift Lightspeed

   Wait for each to reach Succeeded before installing the next.

2. **Have a Quay account** at `quay.io/ryan_nix` (or update the image
   references in `05-inferenceservice.yaml` and `build.sh` to your own
   namespace).

3. **Accept the Gemma license** on Hugging Face:
   https://huggingface.co/google/gemma-4-e4b-it
   Then `huggingface-cli login` or export `HF_TOKEN`.

4. **Verify vLLM image tag** in `04-servingruntime.yaml` actually
   supports Gemma 4. The tag in the file is a placeholder — check
   vLLM release notes and update before applying. **This is the most
   likely thing to break.**

## Apply order (manual path)

```bash
# Phase 1: GPU plumbing
oc apply -f 01-nfd.yaml
# Wait ~60s for NFD to label the node, then verify:
oc get nodes -o json | jq '.items[].metadata.labels' | grep 10de
# You should see: "feature.node.kubernetes.io/pci-10de.present": "true"

oc apply -f 02-gpu-clusterpolicy.yaml
# This takes 5-10 min on first apply (driver build). Watch:
oc -n nvidia-gpu-operator get pods -w
# Wait until nvidia-driver-daemonset, nvidia-device-plugin-daemonset,
# and nvidia-operator-validator pods are all Running.

# Validate GPU is visible to pods (CRITICAL — do not skip):
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd-test
  namespace: default
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
oc -n default logs cuda-vectoradd-test
# Expected output ends with: "Test PASSED"
oc -n default delete pod cuda-vectoradd-test

# Phase 2: OpenShift AI
oc apply -f 03-dsc.yaml
# Watch the RHOAI pods come up:
oc -n redhat-ods-applications get pods -w
# Wait for kserve-controller-manager and odh-model-controller to be
# Running. Should take 2-3 min.

# Phase 3: Build and push the model image
# (This step happens on your laptop, not in the cluster.)
chmod +x build.sh
./build.sh v1
# This downloads ~10GB from HF, builds the image (~10GB), pushes to
# Quay. Will take a while on first run.

# Phase 4: Deploy the model
oc apply -f 00-namespace.yaml
oc apply -f 04-servingruntime.yaml
oc apply -f 05-inferenceservice.yaml
# Watch the predictor pod come up:
oc -n gemma-serving get pods -w
# First start is slow: KServe pulls the OCI image (~10GB), copies
# model files, vLLM loads the model. Expect 5-10 min.

# SMOKE TEST the model directly before touching OLS:
oc -n gemma-serving port-forward svc/gemma-4-e4b-predictor 8080:80 &
curl -s http://localhost:8080/v1/models | jq
# Should return a model with id "gemma-4-e4b"

curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma-4-e4b",
    "messages": [{"role": "user", "content": "What is a Kubernetes Deployment in one sentence?"}]
  }' | jq
# Should return a coherent answer. If this fails, OLS will too —
# debug here first.

kill %1  # stop port-forward

# Phase 5: Wire OLS
oc apply -f 06-ols-secret.yaml
oc apply -f 07-olsconfig.yaml
oc -n openshift-lightspeed get pods -w
# Wait for lightspeed-app-server to be Running.
```

## Apply order (Ansible path)

```bash
cd ansible/
pip install --user ansible-core
oc login ...                                    # log in to target cluster
ansible-playbook -i inventory/hosts.ini deploy.yml
```

That's it. The playbook runs every step above — including GPU
detection via `oc debug node`, readiness waits, and the CUDA
validation pod — as a single idempotent run. See
[`ansible/README.md`](ansible/README.md) for tags, troubleshooting,
and teardown instructions.

## Demo: ask OLS a question

1. In the OCP web console, click the Lightspeed sparkle icon
   (top-right corner).
2. Ask: "How do I create a PersistentVolumeClaim with the LVM storage
   class?"
3. In a side terminal: `oc -n gemma-serving logs -f deployment/gemma-4-e4b-predictor`
   You'll see the request hit and tokens stream back. **This is the
   money shot for the video.**

## Verifying GPU offload is actually happening

```bash
# Check that vLLM detected the GPU at startup:
oc -n gemma-serving logs deployment/gemma-4-e4b-predictor | grep -i "cuda\|gpu\|device"
# Look for lines mentioning CUDA device, GPU memory, etc.

# Live GPU utilization from inside the cluster:
oc -n nvidia-gpu-operator exec -it ds/nvidia-driver-daemonset -- nvidia-smi
# You should see the vLLM python process holding ~6-7GB of VRAM and
# GPU-Util spiking when you send queries.
```

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| `nvidia-driver-daemonset` CrashLoop | Driver version doesn't support 3060 Ti | Pin `driver.version` in `02-gpu-clusterpolicy.yaml` to a known-good build (e.g. `550.90.07`) and re-apply |
| `cuda-vectoradd-test` pod fails | GPU Operator not fully ready | Wait longer; check `nvidia-operator-validator` logs |
| Predictor pod stuck `Init` | OCI image pull slow | Normal on first deploy; check `oc describe pod` for image pull progress |
| vLLM container CrashLoop with "unsupported model architecture" | vLLM image too old for Gemma 4 | Update `image:` in `04-servingruntime.yaml` to a newer tag |
| vLLM CrashLoop with CUDA OOM | KV cache too big for 8GB | Lower `--max-model-len` and/or `--gpu-memory-utilization` in `04-servingruntime.yaml` |
| OLS pod CrashLoop with "model not found" | Model name mismatch | `curl /v1/models` against the predictor, copy the exact `id` into `07-olsconfig.yaml` `models[].name` |
| OLS connects but answers are gibberish | Wrong chat template | Add `--chat-template` arg to ServingRuntime pointing at correct Jinja file |
| OLS pod can't reach predictor | Wrong service name/URL | Verify with `oc -n gemma-serving get svc`; the service is `<isvc-name>-predictor` in RawDeployment mode |

## Scaling up: from SNO/3060 Ti to L4/L40S pilot

The beauty of this pattern is that the OLSConfig is identical between
homelab and pilot. Only three things change:

1. **Model size**: Build a new OCI image with `google/gemma-4-26b-a4b-it`
   instead of E4B. Push as `quay.io/ryan_nix/gemma-4-26b-a4b-it:v1`.
   Update `storageUri` in `05-inferenceservice.yaml`.

2. **vLLM args**: Drop `--enforce-eager`, raise `--max-model-len` to
   32768 or higher, raise `--max-num-seqs` to 16-32 for real
   concurrency. Raise memory limit to 64Gi.

3. **DSC**: Switch `kserve.defaultDeploymentMode` from `RawDeployment`
   to `Serverless` if the customer wants scale-to-zero. Costs
   Knative + Istio overhead but is the more "enterprise" pattern.

That's it. The OLSConfig (`07-olsconfig.yaml`) doesn't change at all.

## Repository layout

```
.
├── 00-namespace.yaml ............ gemma-serving namespace
├── 01-nfd.yaml .................. NodeFeatureDiscovery instance
├── 02-gpu-clusterpolicy.yaml .... NVIDIA GPU Operator config
├── 03-dsc.yaml .................. RHOAI DataScienceCluster (trimmed for SNO)
├── 04-servingruntime.yaml ....... Custom vLLM runtime (Gemma 4 compatible)
├── 05-inferenceservice.yaml ..... Gemma 4 E4B InferenceService
├── 06-ols-secret.yaml ........... Placeholder OLS credentials secret
├── 07-olsconfig.yaml ............ OLSConfig pointing at the KServe predictor
├── Containerfile ................ OCI ModelCar image definition
├── build.sh ..................... HF download + image build + Quay push
├── VIDEO_SCRIPT.md .............. Script for the accompanying YouTube video
├── ansible/
│   ├── deploy.yml ............... Full deployment playbook (oc-based)
│   ├── teardown.yml ............. Remove all CRs created by deploy.yml
│   ├── README.md ................ Ansible-specific docs
│   ├── inventory/hosts.ini ...... Localhost-only inventory
│   └── group_vars/all.yml ....... Timeouts, GPU ID table, manifests dir
├── LICENSE ...................... Apache 2.0
├── .gitignore
└── README.md .................... This file
```

## Disclaimer

The projects and opinions in this repository are my own and are
not official Red Hat positions or products.
