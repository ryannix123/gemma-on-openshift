# Architecture

This document describes the component and namespace architecture of
the OpenShift Lightspeed self-hosted LLM reference design. For setup
instructions, see the [main README](README.md). For the automation
playbook, see [ansible/README.md](ansible/README.md).

## The big picture

Three namespaces, three responsibilities, three teams that often
own them at an enterprise customer:

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  openshift-lightspeed  (OLS product namespace)                   │
│  ─────────────────────                                           │
│                                                                  │
│    ┌──────────────────────┐                                      │
│    │ lightspeed-app-server│  ◄── user asks a question            │
│    │ (FastAPI + Langchain)│      in the OCP web console          │
│    └──────────┬───────────┘                                      │
│               │                                                  │
│               │ POST /v1/chat/completions                        │
│               │ (OpenAI-compatible HTTP)                         │
│               ▼                                                  │
└──────────────────────────────────────────────────────────────────┘
                │
                │  in-cluster Service DNS:
                │  granite-41-3b-predictor.gemma-serving.svc:8080
                │
                ▼
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  gemma-serving  (model workload namespace)                       │
│  ─────────────                                                   │
│                                                                  │
│    ┌─────────────────────────────────────┐                       │
│    │ granite-41-3b-predictor-<hash>      │                       │
│    │                                     │                       │
│    │   Container: vLLM OpenAI server     │                       │
│    │     ├─ loads Granite 4.1 3B weights │                       │
│    │     ├─ serves /v1/chat/completions  │                       │
│    │     └─ requests nvidia.com/gpu: 1   │──┐                    │
│    └─────────────────────────────────────┘  │                    │
│                       ▲                     │                    │
│                       │                     │ uses the GPU       │
│     InferenceService  │                     │ provided by ...    │
│     (managed by       │                     │                    │
│      KServe from      │                     │                    │
│      the platform ns) │                     │                    │
│                                             │                    │
└─────────────────────────────────────────────│────────────────────┘
                       ▲                      │
                       │ reconciled by        │
                       │                      │
┌──────────────────────┴────────────────┐  ┌──┴───────────────────┐
│                                       │  │                      │
│  redhat-ods-applications              │  │  nvidia-gpu-operator │
│  (OpenShift AI platform)              │  │  (GPU driver plane)  │
│  ───────────────────────              │  │  ──────────────────  │
│                                       │  │                      │
│  • kserve-controller-manager          │  │  • nvidia-driver-    │
│  • odh-model-controller               │  │    daemonset         │
│  • rhods-dashboard (optional UI)      │  │  • nvidia-device-    │
│                                       │  │    plugin-daemonset  │
│  Reconciles InferenceService CRs      │  │  • nvidia-dcgm-      │
│  from any project namespace. Does     │  │    exporter          │
│  NOT run model workloads itself.      │  │                      │
│                                       │  │  Makes nvidia.com/   │
│                                       │  │  gpu a schedulable   │
│                                       │  │  resource on the     │
│                                       │  │  node. Does NOT run  │
│                                       │  │  model workloads.    │
└───────────────────────────────────────┘  └──────────────────────┘
```

## What runs where, and why it matters

### `gemma-serving` — the workload

This is the namespace you created. Two things exist here:

- **The `InferenceService` custom resource** — a declarative spec
  that says "I want a vLLM-backed model served from this OCI image
  with this much GPU." It's just a YAML document until the KServe
  controller reconciles it.
- **The predictor pod** — the actual running container, created by
  KServe as a result of reconciling the InferenceService. This is
  where vLLM loads the model weights onto the GPU and serves
  `/v1/chat/completions`. It consumes `nvidia.com/gpu: 1`.

The namespace boundary matters for three reasons:

1. **RBAC and audit.** Whoever has edit access to `gemma-serving`
   can modify the running model — rollback to a previous OCI image
   tag, change vLLM args, scale replicas. In regulated customers,
   that's a narrower trust boundary than "whoever administers the
   RHOAI platform."
2. **Cost attribution.** `oc adm top pod -n gemma-serving` shows
   actual inference cost (GPU memory, CPU, RAM). That's the number
   finance and procurement want, not the RHOAI control plane's
   overhead.
3. **Multi-model scaling.** A second project (e.g. a tuned model
   for a different use case) would live in a second namespace
   alongside this one, reconciled by the same platform in
   `redhat-ods-applications`. One platform, N serving projects.

### `redhat-ods-applications` — the platform

This is where Red Hat OpenShift AI (RHOAI) itself installs. The
control-plane components live here:

- `kserve-controller-manager` — watches `InferenceService` CRs in
  any namespace and creates the Deployments, Services, and (for
  Serverless mode) KnativeServices that actually run the models.
- `odh-model-controller` — RHOAI-specific bits on top of KServe
  for model registry integration, explainability, and similar.
- `rhods-dashboard` — the RHOAI web UI. Optional for OLS but useful
  B-roll for demos. Trimmed deployments can remove it.

**Nothing your model needs to serve traffic lives here.** The
platform is a deployer and manager, not a runtime. If you kill the
`kserve-controller-manager` pod, your predictor keeps answering
requests until someone deletes its underlying Deployment. That
decoupling is intentional and important — platform restarts don't
break inference.

### `nvidia-gpu-operator` — the driver plane

The NVIDIA GPU Operator installs here. Its DaemonSets run on every
GPU-capable node and handle:

- **Driver loading** — compiling and loading the NVIDIA kernel
  module against the RHCOS kernel.
- **Device plugin** — advertising `nvidia.com/gpu` as a schedulable
  resource to kubelet, so pods can request GPUs via resource limits.
- **Container toolkit** — making `/dev/nvidia*` and the CUDA
  libraries available inside containers that request a GPU.
- **DCGM exporter** — Prometheus-format GPU metrics.

Again, **nothing your model runs here**. The GPU Operator just makes
"I need a GPU" a thing the scheduler understands. Your vLLM pod in
`gemma-serving` then requests one and gets scheduled onto the node
with the GPU.

## Data flow for a single query

When a user types a question into the OLS console in the OCP web UI:

1. **Browser → OCP console → OLS API.** The request lands at the
   `lightspeed-app-server` pod in `openshift-lightspeed`.
2. **OLS builds the prompt.** Pulls in OCP documentation context,
   applies any RAG index, assembles the system prompt plus the
   user question.
3. **OLS → predictor.** POST to
   `http://granite-41-3b-predictor.gemma-serving.svc.cluster.local:8080/v1/chat/completions`.
   Uses the `openai` provider type from OLSConfig. No external
   network egress — everything is in-cluster DNS.
4. **vLLM generates tokens.** The predictor pod uses the GPU
   (provisioned by the driver DaemonSet) to run inference. Streams
   tokens back as Server-Sent Events.
5. **OLS relays tokens to the browser.** User sees the answer appear
   in real time in the console.

No request ever leaves the OCP cluster. That's the entire reason
this architecture exists.

## Why Granite 4.1 and not Gemma 4?

This project originally targeted Google Gemma 4. During development
we discovered fundamental constraints that make Gemma 4 incompatible
with 8 GB consumer GPUs via vLLM:

- **Gemma 4 E4B** ("Effective 4B"): MoE architecture with 128
  experts. Total weight storage ~15 GB even though only a fraction
  fires per token. OOM'd immediately.
- **Gemma 4 E2B** ("Effective 2B"): Same MoE architecture. Total
  weight storage ~9.5 GB. OOM'd in bf16. fp8 quantization failed
  (Ampere GPUs lack native fp8; the Marlin kernel's repack step
  exceeds VRAM). CPU offloading failed (known vLLM bug, PR #18298).
- **RHAIIS preview image** (`registry.redhat.io/rhaii-preview/vllm-cuda-rhel9:gemma4`):
  Red Hat's Gemma 4 tech-preview vLLM build loaded E2B successfully
  with CPU offloading, but hit an assertion error during KV cache
  initialization that hasn't been patched yet.

IBM Granite 4.1 3B is a **dense** transformer — what you see is what
you get. 6.4 GB of weights loads cleanly in bf16 on 8 GB VRAM with
room for KV cache. No quantization hacks, no offloading, no MoE
surprises.

For customers with larger GPUs (16 GB+), Gemma 4 remains a strong
option and the architecture supports it with minimal changes.

## What changes at production scale

The SNO/3060 Ti config is a scaled-down version of the same shape.
When moving to a 3-node compact cluster with an L4 or L40S:

| Layer | SNO homelab | Production pilot |
|---|---|---|
| Model | Granite 4.1 3B, 6.4 GB | Granite 4.1 8B/30B, or model of choice |
| vLLM args | `--enforce-eager`, `max-num-seqs=4` | Full CUDA graphs, `max-num-seqs=16+` |
| Deployment mode | RawDeployment (no Knative) | Serverless (Knative + Istio) for scale-to-zero |
| GPU operator | Consumer driver, may need pinning | Enterprise-certified driver branch |
| Replicas | 1 | 2+ for HA, behind Service |

**The OLSConfig does not change.** That's the point. OLS sees an
OpenAI-compatible endpoint; whether that endpoint is backed by a
3060 Ti in a basement or an L40S in a datacenter rack is invisible
to it.

## What's NOT in this architecture (and why)

- **No external LLM provider.** No OpenAI, no Azure OpenAI, no
  Vertex AI, no Watsonx. The whole point is on-prem inference for
  customers whose legal teams won't allow external LLM calls.
- **No Istio / Service Mesh.** KServe RawDeployment mode avoids
  pulling in OpenShift Serverless and Service Mesh. Lighter on SNO,
  simpler to reason about. Switch back to Serverless for production
  if scale-to-zero matters.
- **No separate model registry.** The OCI image in Quay *is* the
  model registry. Tag `v1`, `v2`, etc. are the versions. For a
  customer with heavier MLOps needs, RHOAI's Model Registry
  component can layer on top — it's disabled in `03-dsc.yaml` by
  default to keep the SNO footprint small.
- **No authentication between OLS and vLLM.** vLLM in this config
  doesn't require a bearer token. The in-cluster Service is not
  exposed externally, and Kubernetes NetworkPolicies can harden this
  further if the customer's security team wants defense-in-depth.
- **No observability stack wired in.** DCGM metrics are exposed by
  the GPU Operator and vLLM exposes standard OpenAI-server metrics,
  but this reference doesn't set up dashboards. OCP's built-in
  monitoring picks up both; a production deployment would add
  Grafana dashboards for GPU utilization and inference latency.

## Related reading

- [Red Hat OpenShift Lightspeed documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/)
- [KServe InferenceService reference](https://kserve.github.io/website/latest/reference/api/)
- [vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html)
- [NVIDIA GPU Operator on OCP](https://docs.nvidia.com/datacenter/cloud-native/openshift/)
- [IBM Granite 4.1 blog post](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)
- [Granite 4.1 on Hugging Face](https://huggingface.co/ibm-granite/granite-4.1-3b)
