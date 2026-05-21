# Project Hummingbird Variant

This folder contains a distroless Containerfile that packages the
Granite 4.1 3B model weights on a
[Project Hummingbird](https://hummingbird-project.io) base image
instead of UBI.

## Why Hummingbird?

Project Hummingbird provides minimal, hardened container images
targeting near-zero CVE counts. For regulated customers (insurance,
financial services, healthcare) where every container in the cluster
is subject to security review, the difference is significant:

| | UBI 10 micro | Hummingbird |
|---|---|---|
| CVE profile | Typically 4-30+ High | Near-zero / Passed |
| Image overhead | ~24 MB base | ~15 MB base |
| Shell | Yes (minimal) | No (distroless) |
| Package manager | No | No |
| SBOM | Standard | Signed, Konflux-built |
| Support | Red Hat subscription | Red Hat subscription (planned GA) |

The model weights are identical between variants — only the base
layer changes. KServe mounts `/models/` the same way regardless
of which base image the container was built on.

## Build

From the repo root (model weights must be in `model/`):

```bash
podman build --platform linux/amd64 \
  -f hummingbird/Containerfile \
  -t quay.io/ryan_nix/granite4-llm:hummingbird-latest .
```

## CI/CD

The GitHub Actions workflow at `.github/workflows/build-model-image.yml`
builds both the UBI 10 and Hummingbird variants automatically every
Sunday, pushing both to the same Quay repository with distinct tags:

- `:latest` — UBI 10 variant
- `:hummingbird-latest` — Project Hummingbird variant

To deploy the Hummingbird variant, update the `storageUri` in
`manifests/05-inferenceservice.yaml`:

```yaml
storageUri: oci://quay.io/ryan_nix/granite4-llm:hummingbird-latest
```

## More information

- [Project Hummingbird documentation](https://hummingbird-project.io)
- [Red Hat Hardened Images catalog](https://catalog.redhat.com/search?gs&q=hummingbird)
- [Exploring distroless containers with Project Hummingbird](https://developers.redhat.com/articles/2026/04/28/exploring-distroless-containers-project-hummingbird)
