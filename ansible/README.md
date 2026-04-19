# Ansible playbook for OLS + Gemma 4 on SNO

Automates GPU detection and manifest application for the
OpenShift Lightspeed + Gemma 4 reference architecture.

**No SSH required. No Python Kubernetes libraries. Just `oc` and
`ansible-core`.**

## What it does

1. **Detects the NVIDIA GPU** on the SNO node via `oc debug node` +
   `lspci` in a privileged debug pod. Fails loudly if no NVIDIA GPU
   is present. Identifies the specific model and warns about known
   consumer-GPU driver issues.
2. Applies the NFD and GPU Operator manifests via `oc apply`, waits
   for the driver daemonset to finish building (5-10 min on first run)
   using `oc wait`.
3. Runs a CUDA vector-add validation pod to prove the GPU is usable
   from a container.
4. Applies the trimmed RHOAI DataScienceCluster.
5. Deploys the Gemma 4 InferenceService and smoke-tests it by
   `oc exec`-ing a curl into the predictor pod.
6. Wires up OpenShift Lightspeed via OLSConfig.
7. Prints a summary with the console URL and next steps.

## Prerequisites

### On the machine running the playbook (your laptop)

```bash
# Just ansible-core. No collections, no Python K8s libraries.
pip install --user ansible-core

# And of course `oc` on your PATH, already logged in:
oc whoami
```

### In the cluster (install from OperatorHub)

- Node Feature Discovery Operator
- NVIDIA GPU Operator
- Red Hat OpenShift AI Operator
- OpenShift Lightspeed Operator

The playbook waits for the _operators_ to already be installed and
creates the CRs that configure them. It does NOT subscribe operators
itself — subscribing operators via automation is brittle and a poor
fit for a demo where you want the user to see the OperatorHub
click-through.

### Environment

- `oc` in PATH
- Already logged in to the target cluster (`oc login ...`)
- Current user has cluster-admin privileges
- The OCI model image already built and pushed to Quay (see
  `../build.sh`)

## Usage

Full run:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml
```

Just detect the GPU (no cluster changes made):

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --tags detect
```

Re-apply just the OLS config (after tweaking `07-olsconfig.yaml`):

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --tags ols
```

Dry run to see what would change:

```bash
ansible-playbook -i inventory/hosts.ini deploy.yml --check --diff
```

Target a different cluster — just log in somewhere else first:

```bash
oc login https://api.customer-cluster.example.com:6443
ansible-playbook -i inventory/hosts.ini deploy.yml
```

## Available tags

| Tag | What it runs |
|---|---|
| `detect` | GPU detection only (oc debug node + lspci) |
| `gpu` | Detection + NFD + GPU Operator + CUDA validation |
| `rhoai` | DataScienceCluster |
| `model` | Namespace + ServingRuntime + InferenceService + smoke test |
| `ols` | OLS secret + OLSConfig |
| `validate` | Summary output with console URL |

## Teardown

```bash
ansible-playbook -i inventory/hosts.ini teardown.yml
```

Removes all CRs deployed by `deploy.yml`. Does NOT uninstall the
operators themselves — remove those via OperatorHub if desired.

## How GPU detection works without SSH

The playbook uses `oc debug node/<n>` — a built-in OCP mechanism that
spawns a privileged debug pod on the target node with the host
filesystem mounted at `/host`. Then it chroots into `/host` and runs
`lspci -nn`, which sees the real PCI devices on the node, including
any NVIDIA GPU.

This is the canonical "run a command on an OCP node" pattern and works
identically on RHCOS, SNO, and any other OCP node type. No SSH keys,
no firewall rules, no user account management.

The cost is ~10 seconds of latency per run while the debug pod spins
up and tears down. For a homelab playbook that's fine; if you were
detecting GPUs across hundreds of nodes it would be worth replacing
with NFD's own labels (which is what you'd use in production anyway,
but which require NFD to already be running — the thing we're
deciding whether to install).

## Re-running

The playbook is idempotent — every `oc apply` naturally is, and all
`oc delete` operations use `--ignore-not-found`. Re-running after a
partial failure picks up where it left off. Re-running after a
successful run is a no-op (modulo the smoke test, which always runs).

`changed_when` checks parse `oc apply` output for "configured/created"
vs "unchanged" so Ansible's summary accurately reflects what actually
changed.

## Troubleshooting

**`oc whoami` fails at preflight.** You're not logged in, or your
token expired. Run `oc login ...` and retry.

**NFD wait times out.** NFD operator pod may not be running. Check
`oc get pods -n openshift-nfd`. The NodeFeatureDiscovery CR requires
the operator to be installed first.

**Driver daemonset wait times out.** On a 3060 Ti (or other consumer
GPU), the NVIDIA driver build can fail. Check pod logs:
`oc -n nvidia-gpu-operator logs -l app=nvidia-driver-daemonset`. If
you see driver version issues, pin `driver.version` in
`02-gpu-clusterpolicy.yaml` to a known-good build (e.g. `550.90.07`)
and re-run with `--tags gpu`.

**KServe wait times out in Phase 2.** The label selector
`control-plane=kserve-controller-manager` may not match what RHOAI
actually uses in your version. Check:

```bash
oc -n redhat-ods-applications get pods --show-labels | grep kserve
```

Update the selector in `deploy.yml` Phase 2 accordingly.

**Smoke test curl fails.** The model name mismatch is the most common
cause. Check what vLLM is actually advertising:

```bash
oc exec -n gemma-serving <predictor-pod> -- curl -s http://localhost:8080/v1/models
```

The `id` field in that response must match `--served-model-name` in
`04-servingruntime.yaml` and `models[].name` in `07-olsconfig.yaml`.
