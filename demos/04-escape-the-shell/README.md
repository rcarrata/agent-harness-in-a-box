# Demo 4: Escape the Shell - Interactive CTF

An interactive Capture the Flag experience that demonstrates OpenShell's security layers through a browser-based UI. Run commands side-by-side in an unprotected OpenShift pod versus an OpenShell sandbox and see what gets blocked.

## What You Will Learn

- How OpenShell adds security layers on top of what OpenShift already provides
- Network default-deny via the CONNECT proxy
- Binary binding - per-binary network access control
- Landlock LSM kernel-level filesystem restrictions
- L7 HTTP method inspection (read-only API enforcement)
- Live policy hot-reload without restarting sandboxes

## Security Layer Comparison

| Layer | Root User | Network | Filesystem | API Methods | Binary Control |
|-------|-----------|---------|------------|-------------|----------------|
| **Kubernetes** | Yes (default) | Full access | Full access | All | Any binary |
| **OpenShift** | No (SCC) | Full access | Writable overlay | All | Any binary |
| **OpenShell** | No | Default-deny proxy | Landlock kernel LSM | L7 inspection | Per-binary rules |

OpenShift already prevents running as root via Security Context Constraints. This demo shows what OpenShell adds **on top** of that baseline.

## Architecture

```
OpenShift Namespace: openshell-ctf
+-------------------------------------------------------+
|  OpenShell Gateway (StatefulSet, Helm chart)           |
|   - Manages sandbox pod lifecycle                      |
|   - CONNECT proxy enforces network policy              |
+-------------------------------------------------------+
|  CTF UI Pod (Deployment, restricted SCC)               |
|   - FastAPI backend (app.py)                           |
|   - Single-file HTML SPA (index.html)                  |
|   - "Unprotected" = commands run directly on this pod  |
|   - "Protected" = commands via openshell sandbox exec  |
+-------------------------------------------------------+
|  CTF Sandbox (managed by gateway)                      |
|   - Landlock + CONNECT proxy + L7 inspection           |
|   - CTF-specific policy (strict/permissive)            |
+-------------------------------------------------------+
```

## The 5 Challenges

### 1. Data Exfiltration - Network Default-Deny
Try to reach external endpoints. The CONNECT proxy blocks everything not in the policy.

### 2. Tool Smuggling - Binary Binding
The inference endpoint allows python3 but blocks curl. Same endpoint, different binary, different result.

### 3. Filesystem Escape - Landlock LSM
World-writable paths like `/var/tmp` and `/dev/shm` are accessible on a regular OpenShift pod. Landlock blocks them at the kernel level.

### 4. API Abuse - L7 Read-Only
The GitHub API allows GET requests (read) but blocks POST and DELETE (write). HTTP method enforcement at layer 7.

### 5. Live Lockdown - Policy Hot-Reload
Switch between strict and permissive policies in real-time. Watch as httpbin goes from blocked to allowed and back.

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x installed
- `openshell` CLI installed on your workstation
- `envsubst` available (from `gettext`)

## Quick Start

```bash
# Step 1: Deploy everything (gateway + CTF UI)
bash install.sh
# Or with TLS: ENABLE_TLS=true bash install.sh

# Step 2: Create the CTF sandbox
bash setup-sandbox.sh

# Step 3: Open the CTF UI in your browser
CTF_URL=$(oc -n openshell-ctf get route ctf-ui -o jsonpath='{.spec.host}')
echo "https://$CTF_URL"

# Step 4: Capture all 5 flags!
```

## Script Reference

| Script | Purpose |
|--------|---------|
| `install.sh` | Deploy gateway, build CTF UI image, deploy CTF UI pod |
| `setup-sandbox.sh` | Create the CTF sandbox with strict policy |
| `verify.sh` | Check all components are running |
| `test-sandbox-security.sh` | CLI-based validation of all 5 challenge areas |
| `teardown.sh` | Remove everything (add `--crd` to also remove CRDs) |

## File Structure

```
04-escape-the-shell/
  install.sh
  setup-sandbox.sh
  verify.sh
  test-sandbox-security.sh
  teardown.sh
  config/
    policy-ctf-strict.yaml         # CTF strict policy
    policy-ctf-permissive.yaml     # Adds httpbin (for hot-reload demo)
  manifests/
    route.yaml                     # Gateway Route
    ctf-ui-deploy.yaml             # CTF UI: Deployment + Service + Route
  ctf-ui/
    app.py                         # FastAPI backend
    index.html                     # Self-contained SPA (dark CTF theme)
    requirements.txt               # Python dependencies
    Containerfile                   # Container image build
```

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NAMESPACE` | `openshell-ctf` | OpenShift namespace for all resources |
| `OPENSHELL_VERSION` | (latest) | Pin a specific Helm chart version |
| `ENABLE_TLS` | `false` | Enable passthrough TLS via cert-manager (no port-forward needed) |

### TLS Mode (Optional)

By default the gateway runs without TLS. Setting `ENABLE_TLS=true` enables passthrough TLS via cert-manager, which removes the need for port-forward when running sandbox operations.

```bash
ENABLE_TLS=true bash install.sh
```

OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS preserves them end-to-end. When TLS is enabled, cert-manager creates a CA chain and the gateway serves TLS on port 8080 with mTLS for sandbox pods.

**TLS prerequisites:** cert-manager on the cluster. The install script auto-installs the [Red Hat cert-manager operator](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-cert-manager-operator) via OLM if CRDs are not already present. To install manually:
```bash
oc apply -k https://github.com/redhat-cop/gitops-catalog/openshift-cert-manager-operator/operator/overlays/stable-v1
```

## How the UI Works

The CTF UI pod serves a FastAPI backend with a single-page web app. The backend has two execution modes:

- **Unprotected**: Runs commands directly on the pod via `subprocess` (regular OpenShift container, restricted SCC, non-root)
- **Protected**: Runs the same commands inside the OpenShell sandbox via `openshell sandbox exec`

Flags are auto-captured when you demonstrate the security difference. For example, Challenge 1 triggers when any outbound request is blocked in the protected environment but succeeds in the unprotected one.

## CTF Policy Details

The **strict** policy allows:
- Inference endpoint (`*.redhatworkshops.io`) - python3 and node only
- GitHub API (`api.github.com`) - read-only, curl and python3
- Filesystem: `/tmp`, `/sandbox`, `/workspace` writable; `/usr`, `/etc` read-only
- Everything else is denied

The **permissive** policy adds:
- httpbin.org access (curl and python3) - used for the hot-reload demo

## CLI-Based Testing

If you prefer CLI over the web UI, run the security tests directly:

```bash
bash test-sandbox-security.sh
```

This tests all 5 challenge areas and prints a color-coded PASS/FAIL report, including the hot-reload test (switches policies automatically).

## Teardown

```bash
bash teardown.sh
```

To also remove the Agent Sandbox operator:

```bash
bash teardown.sh --crd
```

## Troubleshooting

**CTF UI pod in CrashLoopBackOff:**
Check if the openshell CLI was installed correctly in the image:
```bash
oc -n openshell-ctf logs deployment/ctf-ui
```

**Sandbox commands time out:**
Ensure the gateway is healthy and the sandbox is in Ready state:
```bash
bash verify.sh
openshell sandbox list
```

**Policy switch fails:**
Check that the policies ConfigMap is mounted correctly:
```bash
oc -n openshell-ctf exec deployment/ctf-ui -- ls /policies/
```

**Image build fails:**
Check the BuildConfig logs:
```bash
oc -n openshell-ctf logs -f buildconfig/ctf-ui
```
