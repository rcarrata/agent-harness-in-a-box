# Demo 1: Basic OpenShell on OpenShift

Install OpenShell gateway on OpenShift with no authentication. This is the simplest way to get started and experiment with sandboxed agent runtimes.

## What You Will Learn

- How OpenShell deploys on OpenShift via Helm
- Why sandbox pods need the privileged Security Context Constraint
- How the gateway manages sandbox lifecycle through the Agent Sandbox CRD
- How to create, connect to, and manage sandboxes

## What You'll Build

By the end of this demo you will have an OpenShell gateway running on OpenShift, exposed via an OpenShift Route. You will connect the `openshell` CLI from your workstation and create your first sandboxed runtime. The sandbox enforces network default-deny via a CONNECT proxy, Landlock filesystem isolation, and process isolation - even without installing any AI agent or model.

## Architecture

```
+------------------+       +-----------------------+       +------------------+
|                  |  gRPC |                       |  K8s  |                  |
|  openshell CLI   +------>+  OpenShell Gateway     +------>+  Sandbox Pods    |
|  (workstation)   |       |  (StatefulSet)         |       |  (Agent Sandbox) |
|                  |       |                       |       |                  |
+------------------+       +-----------+-----------+       +------------------+
                                       |
                                  OpenShift
                                  Route (HTTP)
```

The gateway runs as a StatefulSet with a 1Gi PVC for its SQLite database. It creates and manages sandbox pods through the Agent Sandbox CRD. The CLI communicates with the gateway via gRPC, exposed through an OpenShift Route.

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access (tested on 4.20, 4.21)
- `oc` CLI configured and logged in
- Helm 3.x installed
- `openshell` CLI v0.0.85+ installed on your workstation

> **CRD source:** This demo installs the [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/) operator via OLM (channel `preview-0.9`). The upstream [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) CRDs also work if you prefer a manual install.

### Install the openshell CLI

```bash
# macOS
brew install nvidia/openshell/openshell

# Linux
curl -fsSL https://docs.nvidia.com/openshell/latest/install.sh | bash

# Verify
openshell --version
```

## Quick Start (Automated)

```bash
# Default (HTTP, uses port-forward for sandbox operations)
bash install.sh

# With TLS (passthrough route, no port-forward needed)
ENABLE_TLS=true bash install.sh
```

This runs all steps below automatically. Continue reading for the manual walkthrough.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NAMESPACE` | `openshell` | OpenShift namespace for all resources |
| `OPENSHELL_VERSION` | *(latest)* | Pin a specific Helm chart version |
| `ENABLE_TLS` | `false` | Enable passthrough TLS via cert-manager |
| `LITELLM_URL` | `https://maas-rhdp.apps.maas.redhatworkshops.io` | LiteLLM endpoint used in security tests |

### TLS Mode (Optional)

By default the gateway runs without TLS, and sandbox operations (create, exec, connect) go through `oc port-forward` to avoid gRPC trailer issues with OpenShift routes.

Setting `ENABLE_TLS=true` enables passthrough TLS via cert-manager:

- cert-manager creates a CA chain (SelfSigned -> CA Certificate -> CA Issuer -> Server/Client Certs)
- Gateway serves TLS on port 8080
- Route becomes passthrough (preserves gRPC trailers end-to-end)
- Sandbox pods get a client TLS cert for mTLS with the gateway
- CLI connects with `--gateway-insecure` flag (self-signed CA)

**Why:** OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS is the only route type that preserves them. Without TLS, you need port-forward.

Use `ENABLE_TLS=true` for production-like setups. Use the default (no TLS) for quick evaluation where port-forward is acceptable.

**TLS prerequisites:**
- cert-manager on the cluster. The install script auto-installs the [Red Hat cert-manager operator](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-cert-manager-operator) via OLM if CRDs are not already present. To install manually:
  ```bash
  oc apply -k https://github.com/redhat-cop/gitops-catalog/openshift-cert-manager-operator/operator/overlays/stable-v1
  ```

## Step-by-Step Guide

### Step 1: Install the Agent Sandbox Operator

The Red Hat build of Agent Sandbox provides the `Sandbox` custom resource definition that OpenShell uses to manage sandbox pod lifecycle. Install it via OLM:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: agent-sandbox-operator
  namespace: openshift-operators
spec:
  channel: preview-0.9
  installPlanApproval: Automatic
  name: agent-sandbox-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator CSV to succeed:

```bash
CSV=$(oc -n openshift-operators get subscription agent-sandbox-operator \
    -o jsonpath='{.status.installedCSV}')
oc -n openshift-operators wait --for=jsonpath='{.status.phase}'=Succeeded \
    csv/"$CSV" --timeout=300s
```

Verify the CRD exists:

```bash
oc get crd sandboxes.agents.x-k8s.io
```

### Step 2: Create the namespace

All OpenShell resources (gateway, sandbox pods) will run in this namespace.

```bash
oc create ns openshell
```

### Step 3: Configure Security Context Constraints

Sandbox pods need the `privileged` SCC because the OpenShell supervisor (which runs inside each sandbox pod as PID 1) sets up:

- **Landlock** - Filesystem access control (restricts which paths the agent can read/write)
- **Seccomp** - System call filtering (blocks dangerous syscalls)
- **Network namespacing** - Runs an HTTP CONNECT proxy to enforce network policy

These security mechanisms require elevated privileges at startup, even though the actual agent process runs as the unprivileged `sandbox` user.

```bash
oc adm policy add-scc-to-user privileged \
    -z openshell-sandbox -n openshell
```

The `openshell-sandbox` ServiceAccount is created by the Helm chart and is used by sandbox pods (not the gateway pod itself).

### Step 4: Create JWT signing keys

The OpenShell gateway uses Ed25519 JWT tokens for sandbox-to-gateway authentication. Normally, the Helm chart includes a PKI init Job that generates these keys, but that Job is not compatible with OpenShift's SCC admission controller.

We create the keys manually instead:

```bash
# Generate Ed25519 keypair
openssl genpkey -algorithm Ed25519 -out /tmp/jwt-signing.pem
openssl pkey -in /tmp/jwt-signing.pem -pubout -out /tmp/jwt-public.pem

# Generate a key ID (KID) from the public key fingerprint
KID=$(openssl pkey -in /tmp/jwt-signing.pem -pubout -outform DER \
    | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
echo "$KID" > /tmp/jwt-kid.txt

# Create the Kubernetes secret
oc -n openshell create secret generic openshell-jwt-keys \
    --from-file=signing.pem=/tmp/jwt-signing.pem \
    --from-file=public.pem=/tmp/jwt-public.pem \
    --from-file=kid=/tmp/jwt-kid.txt

# Clean up local key files
rm -f /tmp/jwt-signing.pem /tmp/jwt-public.pem /tmp/jwt-kid.txt
```

### Step 5: Install OpenShell via Helm

Install the OpenShell Helm chart with OpenShift-specific overrides:

```bash
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace openshell \
    --set pkiInitJob.enabled=false \
    --set server.disableTls=true \
    --set server.auth.allowUnauthenticatedUsers=true \
    --set podSecurityContext.fsGroup=null \
    --set securityContext.runAsUser=null
```

**Why each override is needed:**

| Override | Reason |
|----------|--------|
| `pkiInitJob.enabled=false` | We pre-created JWT keys in Step 4 (PKI Job is not SCC-compatible) |
| `server.disableTls=true` | Run gateway in plaintext for evaluation. TLS would require cert-manager. |
| `server.auth.allowUnauthenticatedUsers=true` | No authentication for this basic demo |
| `podSecurityContext.fsGroup=null` | Clear the chart's hardcoded `fsGroup: 1000` so OpenShift SCC can assign |
| `securityContext.runAsUser=null` | Clear the chart's hardcoded `runAsUser: 1000` so OpenShift SCC can assign |

To pin a specific version, add `--version <version>` to the command.

### Step 6: Wait for the gateway

```bash
oc -n openshell rollout status statefulset/openshell --timeout=300s
```

Verify the pod is running:

```bash
oc -n openshell get pods
```

Expected output:
```
NAME          READY   STATUS    RESTARTS   AGE
openshell-0   1/1     Running   0          1m
```

### Step 7: Create the OpenShift Route

Expose the gateway service so the CLI can reach it from your workstation:

```bash
oc -n openshell apply -f manifests/route.yaml
```

Or create it imperatively:

```bash
oc -n openshell expose svc/openshell --port=8080 --name=openshell-gw
```

Get the route URL:

```bash
oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}'
```

### Step 8: Register the gateway

Tell the CLI where the gateway is:

```bash
GW_URL="http://$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}')"
openshell gateway add "$GW_URL" --local --name openshift
```

### Step 9: Verify

```bash
openshell status
```

Expected output shows the gateway connection details and that it is healthy.

You can also run the automated verification:

```bash
bash verify.sh
```

### Monitor Live Events

Use `openshell term` to watch sandbox events in real-time:

```bash
openshell term
```

This streams OCSF-formatted events showing sandbox creation, command execution, network policy enforcement (ALLOWED/DENIED), and more. Leave it running in a second terminal while testing sandbox security.

### Step 10: Create your first sandbox

**Quick test (run a command and exit):**

```bash
openshell sandbox create --name test -- echo 'Hello from OpenShell!'
```

**Interactive session:**

```bash
# Create a sandbox
openshell sandbox create --name my-sandbox

# Connect to it (opens a shell inside the sandbox)
openshell sandbox connect my-sandbox

# Inside the sandbox, you are the 'sandbox' user with restricted access.
# Try: whoami, ls /, cat /etc/os-release

# Exit when done
exit

# List sandboxes
openshell sandbox list

# Delete the sandbox
openshell sandbox delete my-sandbox
```

**Autonomous mode (run a task, get results, destroy):**

```bash
openshell sandbox create --name auto-test --no-keep -- bash -c 'echo "Task done" > /sandbox/result.txt && cat /sandbox/result.txt'
```

The `--no-keep` flag automatically deletes the sandbox after the command exits.

## Sandbox Security: Strict Policy

This demo uses a **strict** policy that locks the sandbox to inference-only access. OpenShell enforces four layers of isolation inside every sandbox pod.

### Network: Default-Deny via CONNECT Proxy

Every outbound connection goes through OpenShell's HTTP CONNECT proxy. Only endpoints explicitly listed in the policy are reachable - everything else returns HTTP 403.

```bash
# Apply the strict policy
openshell policy set --global --policy config/policy-strict.yaml --yes

# From inside the sandbox:
curl https://github.com          # -> HTTP 403 (not in policy)
curl https://google.com          # -> HTTP 403 (not in policy)
```

### Network: Binary Binding

The strict policy restricts which executables can reach the inference endpoint. Only `python3` and `node` are allowed - `curl` is blocked even for allowed hosts:

```bash
curl $LITELLM_URL/health                                              # -> HTTP 403 (curl not in binaries)
python3 -c "import urllib.request; print(urllib.request.urlopen(...).status)"  # -> HTTP 200 (python3 IS allowed)
```

### Filesystem: Landlock Enforcement

Landlock (Linux Security Module) restricts filesystem access at the kernel level. Paths must be explicitly declared as read-only or read-write in the policy:

```bash
echo test > /workspace/test.txt    # OK (read-write path)
echo test > /tmp/test.txt          # OK (read-write path)
echo test > /etc/test.txt          # Permission denied (read-only)
echo test > /var/data.txt          # Permission denied (not in policy)
cat /etc/os-release                # OK (read-only allows reads)
```

### Process Isolation

The agent process runs as the unprivileged `sandbox` user, not root:

```bash
whoami   # -> sandbox
id       # -> uid=sandbox gid=sandbox
```

### Run the Full Security Test

```bash
bash setup-sandbox.sh              # create sandbox with strict policy
bash test-sandbox-security.sh      # run all tests, see color-coded report
```

This runs all network, filesystem, and process tests and prints a summary showing what OpenShell blocks at this tier.

## Teardown

Remove everything installed by this demo:

```bash
bash teardown.sh
```

This removes: Helm release, Route, JWT signing secret, PVC (SQLite data), SCC binding, and the namespace.

To also remove the Agent Sandbox operator (only if no other demo is using it):

```bash
bash teardown.sh --crd
```

## Troubleshooting

**Gateway pod stuck in Pending:**
Check if the PVC is bound. The gateway needs a 1Gi PVC for its SQLite database. Also verify a default StorageClass exists.
```bash
oc -n openshell get pvc
oc get storageclass
```

**SCC errors on sandbox pods:**
Verify the SCC binding was applied before Helm install:
```bash
oc adm policy who-can use scc privileged -n openshell
```

**Route not resolving:**
Verify the Route was created and has a host assigned:
```bash
oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}'
```

**`missing grpc-status trailer` or gRPC errors:**
OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Use `ENABLE_TLS=true` for passthrough TLS, or use `oc port-forward` to bypass the route entirely.

**openshell CLI `connection refused` or `Disconnected`:**
Verify the route URL matches what you registered. Check `openshell gateway list` and compare with `oc get route`. For TLS mode, make sure you used `https://` and `--gateway-insecure`.

**Sandbox stuck in `Creating` state:**
Check sandbox pod events for image pull or SCC issues:
```bash
oc -n openshell get pods
oc -n openshell describe pod -l app.kubernetes.io/component=sandbox
```

**`openssl: command not found` or Ed25519 errors (macOS):**
macOS ships LibreSSL which does not support Ed25519. Install OpenSSL 3.x via Homebrew: `brew install openssl@3`. The install script auto-detects Homebrew OpenSSL.

**cert-manager not installing (TLS mode):**
Check the OLM catalog source is available:
```bash
oc get catalogsource -n openshift-marketplace
```

## What's Next

See [Demo 2: OpenCode + Keycloak](../02-opencode-keycloak/) to add:
- Keycloak OIDC authentication with local users
- OpenCode AI coding agent in sandboxes
- Optional MLflow tracing integration
