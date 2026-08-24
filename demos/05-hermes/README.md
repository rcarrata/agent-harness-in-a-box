# Demo 5: Hermes Agent on OpenShell

Run the upstream [Hermes AI agent](https://github.com/NousResearch/hermes-agent) (NousResearch) inside an OpenShell sandbox on OpenShift, with LiteLLM inference and optional RHOAI MLflow tracing.

## Architecture

```
openshell CLI
    |
    v
OpenShell Gateway (Helm, StatefulSet)
    |
    v
Sandbox Pod
  +---------------------------+
  | Hermes Agent              |
  |   OPENAI_BASE_URL ------->|---> LiteLLM MaaS (inference)
  |   HERMES_HOME             |
  |   /sandbox/.hermes/       |---> RHOAI MLflow (tracing, optional)
  |     config.yaml           |
  |     skills/, memories/    |---> PyPI (skill installs)
  +---------------------------+
```

## Prerequisites

- OpenShift 4.19+ cluster with `oc` CLI logged in
- Helm 3.x
- `openshell` CLI installed
- `.env` file at repo root with LiteLLM credentials (copy from `.env.example`)

## Quick Start

```bash
# 1. Deploy OpenShell gateway (skip if Demo 2 already deployed)
bash install.sh
# Or with TLS: ENABLE_TLS=true bash install.sh

# 2. Register gateway
openshell gateway add http://$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}') --local --name openshift

# 3. Create Hermes sandbox
bash setup-sandbox.sh

# 4. Connect
openshell sandbox connect hermes-demo
# Inside sandbox: hermes
```

### TLS Mode (Optional)

Setting `ENABLE_TLS=true` enables passthrough TLS via cert-manager. This avoids the need for port-forward when creating sandboxes or running commands inside them.

OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS preserves them end-to-end. When TLS is enabled, cert-manager creates a CA chain and the gateway serves TLS on port 8080 with mTLS for sandbox pods. The CLI connects with `--gateway-insecure` flag (self-signed CA).

**TLS prerequisites:** cert-manager on the cluster. The install script auto-installs the [Red Hat cert-manager operator](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-cert-manager-operator) via OLM if CRDs are not already present. To install manually:
```bash
oc apply -k https://github.com/redhat-cop/gitops-catalog/openshift-cert-manager-operator/operator/overlays/stable-v1
```

## Using a Pre-baked Image

Build and push the sandbox image for faster sandbox creation:

```bash
cd sandbox-image
podman build --platform linux/amd64 -t quay.io/<org>/hermes-sandbox:latest -f Containerfile.openshell .
podman push quay.io/<org>/hermes-sandbox:latest

# Use the pre-baked image
SANDBOX_IMAGE=quay.io/<org>/hermes-sandbox:latest bash setup-sandbox.sh
```

## Environment Variables

These are set automatically by `setup-sandbox.sh` inside the sandbox:

| Variable | Purpose |
|----------|---------|
| `OPENAI_API_KEY` | LiteLLM API key (from `.env`) |
| `OPENAI_BASE_URL` | LiteLLM endpoint (from `.env`) |
| `HERMES_HOME` | Hermes config directory (`/sandbox/.hermes`) |
| `MLFLOW_TRACKING_URI` | MLflow server URL (RHOAI external route) |
| `MLFLOW_TRACKING_TOKEN` | OCP Bearer token for RHOAI auth |

## Network Policy

Standard tier - allows:
- LiteLLM MaaS (inference)
- PyPI (Hermes skill/plugin installs)
- GitHub (read-only)
- NousResearch (model catalog, metadata)
- RHOAI MLflow (tracing)

Blocks: direct AI APIs, arbitrary web access, GitHub write operations.

Test with: `bash test-sandbox-security.sh`

## Teardown

```bash
bash teardown.sh         # remove gateway + namespace
bash teardown.sh --crd   # also remove Agent Sandbox operator
```
