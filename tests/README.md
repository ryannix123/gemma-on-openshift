# OLS Validation Test Suite

Synthetic question bank and Ansible playbook for validating
OpenShift Lightspeed response quality with a self-hosted LLM backend.

## What it tests

20 questions across four categories:

| Category | Count | What it validates |
|---|---|---|
| **Create** | 5 | Can OLS explain how to create common OCP resources? |
| **Troubleshoot** | 5 | Can OLS diagnose common failure modes? |
| **Configure** | 5 | Can OLS guide RBAC, networking, scaling, and SCC configuration? |
| **Explain** | 5 | Can OLS explain architectural concepts (Deployments vs StatefulSets, etc.)? |

Each question is scored on:

- **Keyword hits** — does the response mention the expected technical terms?
- **Response length** — is it substantive (not too short) and focused (not too long)?
- **Anti-keywords** — does it contain terms that indicate hallucination?
- **Error-free** — did OLS return a valid response without HTTP errors?

## Usage

```bash
# From the repo root:
cd ansible
ansible-playbook -i inventory/hosts.ini ../tests/test-ols.yml
```

Or from the tests directory:

```bash
ansible-playbook -i ../ansible/inventory/hosts.ini test-ols.yml
```

## Prerequisites

- `oc` logged in with a user that has OLS access
- OLS is running and healthy (`lightspeed-app-server` 2/2)
- The model predictor is Running in the `llm-serving` namespace

## Output

The playbook prints a per-question pass/fail summary to the console
and writes a detailed JSON report to `/tmp/ols-test-report.json`.

Example console output:

```
✓ [create/easy]        How do I create a PersistentVolumeClaim...  (keywords: 4/3, length: 842 chars)
✓ [troubleshoot/easy]  My pod is stuck in CrashLoopBackOff...     (keywords: 5/3, length: 1203 chars)
✗ [configure/hard]     How do I configure a pod to run with...     (keywords: 1/2, length: 312 chars)

════════════════════════════════════════════════════════════
OLS Validation Report — 17/20 passed (85%)
════════════════════════════════════════════════════════════
Model:    Granite 4.1 3B (self-hosted via vLLM on SNO)

Per-category breakdown:
  Create:        5/5
  Troubleshoot:  4/5
  Configure:     4/5
  Explain:       4/5
════════════════════════════════════════════════════════════
```

## Customizing questions

Edit `test-questions.yml` to add, remove, or modify questions. Each
question entry supports:

```yaml
- question: "Your question here"
  category: create | troubleshoot | configure | explain
  difficulty: easy | medium | hard
  expected_keywords:
    - term1
    - term2
  min_keyword_hits: 2          # at least N keywords must appear
  anti_keywords:               # hallucination indicators
    - wrong_term
  min_response_length: 100     # chars — reject "I don't know" stubs
  max_response_length: 5000    # chars — reject runaway responses
```

## Comparing models

Run the test suite once with each model backend, then compare the
JSON reports:

```bash
# Test with Granite 4.1 3B
ansible-playbook -i inventory/hosts.ini tests/test-ols.yml
cp /tmp/ols-test-report.json /tmp/report-granite-41-3b.json

# Swap model, restart predictor, then re-run
ansible-playbook -i inventory/hosts.ini tests/test-ols.yml
cp /tmp/ols-test-report.json /tmp/report-other-model.json

# Compare scores
python3 -c "
import json
for name in ['granite-41-3b', 'other-model']:
    with open(f'/tmp/report-{name}.json') as f:
        d = json.load(f)
    print(f\"{name}: {d['summary']['passed']}/{d['summary']['total']} ({d['summary']['score_pct']}%)\")
"
```

## Limitations

- **Keyword matching is approximate.** A response can be correct
  without using the exact expected keyword (e.g. "storage class"
  instead of "storageClassName"). Tune `min_keyword_hits` lower if
  you see false negatives.
- **No semantic evaluation.** This tests for keyword presence, not
  correctness of reasoning. A response that mentions all the right
  terms but gives wrong instructions would still pass.
- **OLS adds its own system prompt.** The model sees the OLS system
  prompt (which includes OCP documentation context) before your
  question. Response quality depends on both the model and the OLS
  RAG pipeline.
