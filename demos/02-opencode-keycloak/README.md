# Demo 2: OpenCode + Keycloak OIDC + MLflow

Deploy OpenShell on OpenShift with Keycloak authentication, OpenCode as the AI coding agent, and optional MLflow tracing. This demo builds on Demo 1 by adding OIDC authentication so users must log in before accessing sandboxes.

## What You Will Learn

- How to deploy Keycloak on OpenShift and configure OIDC for OpenShell
- How OIDC tokens flow between the CLI, Keycloak, and the OpenShell gateway
- How to build a custom sandbox image with OpenCode pre-installed
- How to use OpenCode inside a sandboxed environment
- How to add MLflow tracing to track agent activity

## Architecture

```
+--------------+    OIDC     +------------------+
|              +------------>+                  |
| openshell    |    login    |  Keycloak        |
| CLI          +<------------+  (OIDC Provider) |
|              |    JWT      |                  |
+------+-------+             +------------------+
       |
       | gRPC + Bearer token
       v
+------+----------+         +-------------------+
|                  | creates |                   |
| OpenShell        +-------->+ Sandbox Pods      |
| Gateway          |         | (OpenCode agent)  |
| (validates JWT)  |         |                   |
+---------+--------+         +---------+---------+
          |                            |
          |  inference.local           | (optional)
          +----------------------------+-----------> RHOAI MLflow
```

**How OIDC works with OpenShell:**

1. The CLI opens a browser to the Keycloak login page
2. User authenticates with username/password (local Keycloak users)
3. Keycloak issues a signed JWT with `realm_access.roles` containing `openshell-admin` or `openshell-user`
4. The CLI presents the JWT as a Bearer token on every gRPC call
5. The gateway validates the JWT against Keycloak's JWKS endpoint (in-cluster URL)
6. Role-based access: admins can manage providers and policies, users can create sandboxes

**Why Keycloak instead of Dex:**

The original openshell-demo uses Dex as an OIDC bridge for GitHub OAuth. Keycloak is a full OIDC provider that supports local users directly, with no external IdP dependency. OpenShell has native Keycloak support with a pre-built realm configuration.

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x
- `openshell` CLI installed
- `podman` or `docker` for building the sandbox image (optional if using pre-built images)

## Quick Start (Automated)

```bash
# Default (HTTP, uses port-forward for sandbox operations)
bash install.sh
bash verify.sh          # check all components
bash setup-sandbox.sh   # create sandbox with LiteLLM + MLflow

# With TLS (passthrough route, no port-forward needed)
ENABLE_TLS=true bash install.sh
bash verify.sh
bash setup-sandbox.sh
```

This runs all steps below automatically. Continue reading for the manual walkthrough.

### TLS Mode (Optional)

Setting `ENABLE_TLS=true` enables passthrough TLS via cert-manager. This avoids the need for port-forward when creating sandboxes or running commands inside them.

OpenShift HAProxy strips gRPC trailers from H2C, edge, and re-encrypt routes. Passthrough TLS is the only route type that preserves gRPC trailers, so without TLS you need port-forward for sandbox operations.

When TLS is enabled:
- cert-manager creates a CA chain (SelfSigned -> CA Certificate -> CA Issuer -> Server/Client Certs)
- Gateway serves TLS on port 8080 with a passthrough route
- Sandbox pods get a client TLS cert for mTLS with the gateway
- CLI connects with `--gateway-insecure` flag (self-signed CA)

**TLS prerequisites:**
- cert-manager on the cluster. The install script auto-installs the [Red Hat cert-manager operator](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-cert-manager-operator) via OLM if CRDs are not already present. To install manually:
  ```bash
  oc apply -k https://github.com/redhat-cop/gitops-catalog/openshift-cert-manager-operator/operator/overlays/stable-v1
  ```

## Step-by-Step Guide

### Step 1: Prerequisites check

```bash
bash ../../common/prerequisites.sh
```

### Step 2: Deploy Keycloak

Create the namespace and apply all Keycloak manifests:

```bash
oc apply -f manifests/keycloak/namespace.yaml
oc apply -f manifests/keycloak/realm-configmap.yaml
oc apply -f manifests/keycloak/deployment.yaml
oc apply -f manifests/keycloak/service.yaml
```

Wait for Keycloak to be ready (it takes about 30-60 seconds to start and import the realm):

```bash
oc -n openshell-keycloak rollout status deployment/keycloak --timeout=120s
```

**What happens during startup:**

- Keycloak starts in `start-dev` mode (H2 in-memory database, no persistence needed for demos)
- The `--import-realm` flag imports the realm JSON from the mounted ConfigMap
- `KC_HOSTNAME` is set to `keycloak.openshell-keycloak.svc.cluster.local` so that tokens always carry this in-cluster hostname as the `iss` (issuer) claim, regardless of how they were obtained

**The pre-configured realm includes:**

| Resource | Details |
|----------|---------|
| Realm | `openshell` |
| Roles | `openshell-admin` (full access), `openshell-user` (standard access) |
| Client `openshell-cli` | Public client with PKCE (for interactive CLI login) |
| Client `openshell-ci` | Confidential client (for CI/automation) |
| User `admin@test` | Password: `admin` - has both admin and user roles |
| User `user@test` | Password: `user` - has user role only |

### Step 3: Expose Keycloak

Create a Route for the Keycloak admin console and OIDC endpoints:

```bash
oc apply -f manifests/keycloak/route.yaml
```

Verify the OIDC discovery endpoint responds:

```bash
KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
curl -sk "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration" | python3 -m json.tool | head -10
```

You should see a JSON response with `issuer`, `authorization_endpoint`, `token_endpoint`, etc.

**Access the admin console (optional):**

Open `https://<KC_ROUTE>` in your browser and log in with `admin`/`admin` to explore the realm, users, and clients.

### Step 4: Customize Keycloak users (optional)

To add custom users, either:

**Option A: Via the admin console**
1. Log in at `https://<KC_ROUTE>`
2. Select the `openshell` realm (dropdown in the top-left)
3. Go to Users > Add user
4. Set username and email, then go to Credentials tab to set a password
5. Go to Role Mapping tab and assign `openshell-user` (or `openshell-admin`)

**Option B: Via the realm JSON**
Edit `manifests/keycloak/realm-configmap.yaml` and add entries to the `users` array, then reapply:
```bash
oc apply -f manifests/keycloak/realm-configmap.yaml
oc -n openshell-keycloak rollout restart deployment/keycloak
```

### Step 5: Install the Agent Sandbox Operator

If you already completed Demo 1, skip this step. The install script detects the CRD and skips this automatically.

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

CSV=$(oc -n openshift-operators get subscription agent-sandbox-operator \
    -o jsonpath='{.status.installedCSV}')
oc -n openshift-operators wait --for=jsonpath='{.status.phase}'=Succeeded \
    csv/"$CSV" --timeout=300s
```

### Step 6: Configure OpenShift for OpenShell

Create the namespace, SCC binding, and JWT signing secret:

```bash
# Create namespace
oc create ns openshell --dry-run=client -o yaml | oc apply -f -

# Grant privileged SCC to sandbox service account
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell

# Create JWT signing secret (if not already created by Demo 1)
if ! oc -n openshell get secret openshell-jwt-keys &>/dev/null; then
    openssl genpkey -algorithm Ed25519 -out /tmp/jwt-signing.pem
    openssl pkey -in /tmp/jwt-signing.pem -pubout -out /tmp/jwt-public.pem
    KID=$(openssl pkey -in /tmp/jwt-signing.pem -pubout -outform DER \
        | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$KID" > /tmp/jwt-kid.txt
    oc -n openshell create secret generic openshell-jwt-keys \
        --from-file=signing.pem=/tmp/jwt-signing.pem \
        --from-file=public.pem=/tmp/jwt-public.pem \
        --from-file=kid=/tmp/jwt-kid.txt
    rm -f /tmp/jwt-signing.pem /tmp/jwt-public.pem /tmp/jwt-kid.txt
fi
```

### Step 7: Install OpenShell with Keycloak OIDC

Install using the Keycloak values overlay, which includes both OpenShift overrides and OIDC configuration:

```bash
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace openshell \
    -f manifests/openshell/values-keycloak.yaml
```

Wait for the gateway:

```bash
oc -n openshell rollout status statefulset/openshell --timeout=300s
```

**What the OIDC configuration does:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `oidc.issuer` | `http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell` | In-cluster Keycloak URL (tokens carry this as `iss`) |
| `oidc.audience` | `openshell-cli` | Must match the client ID in Keycloak |
| `oidc.rolesClaim` | `realm_access.roles` | Where Keycloak puts roles in the JWT |
| `oidc.adminRole` | `openshell-admin` | Maps to Keycloak realm role |
| `oidc.userRole` | `openshell-user` | Maps to Keycloak realm role |

The gateway fetches Keycloak's JWKS (public keys) from the issuer URL inside the cluster to validate tokens. No external connectivity is needed.

### Step 8: Create the gateway Route and register

```bash
oc -n openshell apply -f manifests/openshell/route.yaml
```

Register the gateway with OIDC:

```bash
GW_URL="http://$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}')"

openshell gateway add "$GW_URL" \
    --name openshift \
    --oidc-issuer "http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell" \
    --oidc-client-id "openshell-cli"
```

**Authenticate with the gateway:**

The CLI needs to reach Keycloak to perform the OIDC login. Since the issuer is an in-cluster URL, set up a port-forward:

```bash
# In a separate terminal
oc -n openshell-keycloak port-forward svc/keycloak 9090:80
```

Then login:

```bash
openshell gateway login openshift
```

This opens your browser to the Keycloak login page. Log in with `admin@test` / `admin` (or `user@test` / `user`).

Verify authentication works:

```bash
openshell status
```

### Step 9: Create an OpenCode sandbox

The recommended approach uses `setup-sandbox.sh`, which creates the sandbox, uploads OpenCode config, and injects LiteLLM + MLflow credentials:

```bash
# Ensure .env exists with your credentials
cp ../../.env.example ../../.env
# Edit .env with your LiteLLM endpoint and API key

bash setup-sandbox.sh
```

To use a pre-baked sandbox image (OpenCode already installed):

```bash
SANDBOX_IMAGE=quay.io/rcarrata/agentic-harness-openshell:opencode-v1 \
    bash setup-sandbox.sh
```

Connect and run OpenCode (credentials are auto-loaded from `.profile`):

```bash
openshell sandbox connect opencode-demo
opencode
```

**Build your own sandbox image (optional):**

```bash
cd sandbox-image
podman build --platform linux/amd64 \
    -t quay.io/<your-org>/opencode-sandbox:latest \
    -f Containerfile.openshell .
podman push quay.io/<your-org>/opencode-sandbox:latest
```

Then use it: `SANDBOX_IMAGE=quay.io/<your-org>/opencode-sandbox:latest bash setup-sandbox.sh`

**Manual sandbox creation (without setup script):**

```bash
openshell sandbox create --name opencode-test \
    --from quay.io/<your-org>/opencode-sandbox:latest
openshell sandbox connect opencode-test

# Inside the sandbox, set credentials manually:
export OPENAI_API_KEY="your-litellm-key"
export OPENAI_BASE_URL="https://your-litellm-endpoint.example.com/v1"
opencode
```

### Step 10: Configure LiteLLM inference

If you used `setup-sandbox.sh`, this is already done. For manual setup:

```bash
openshell provider create openai \
    --name litellm \
    --base-url https://your-litellm-endpoint.example.com/v1 \
    --api-key <your-api-key>

openshell inference set --provider litellm --model gpt-oss-120b --role user
openshell inference set --provider litellm --model llama-scout-17b --role system

openshell policy set --global --policy /tmp/policy-standard-rendered.yaml --yes
```

### Step 10b: Choose an LLM model in OpenCode

The OpenCode config at `config/opencode-config.json` defines all available LiteLLM models. It is uploaded to `/workspace/.opencode/config.json` inside the sandbox by `setup-sandbox.sh`.

**Available models:**

| Model ID | Name | Reasoning | Context |
|----------|------|-----------|---------|
| `gpt-oss-120b` | GPT OSS 120B | Yes | 128K |
| `gemini-2.5-pro` | Gemini 2.5 Pro | Yes | 1M |
| `llama-scout-17b` | Llama Scout 17B | No | 128K |
| `qwen3-235b` | Qwen3 235B | Yes | 128K |
| `minimax-m2` | MiniMax M2 | No | 128K |

**Change the default model before creating the sandbox:**

Edit `config/opencode-config.json` and set `"model"` and `"small_model"`:

```json
{
  "model": "litellm/gemini-2.5-pro",
  "small_model": "litellm/llama-scout-17b"
}
```

**Switch models inside a running OpenCode session:**

Type `/model` in the OpenCode prompt to interactively pick from the configured models.

**Change the default model in an existing sandbox:**

```bash
openshell sandbox exec --name opencode-demo -- \
    sed -i 's|"model": "litellm/.*"|"model": "litellm/qwen3-235b"|' \
    /workspace/.opencode/config.json
```

Then restart OpenCode to pick up the change.

### Step 11: Configure RHOAI MLflow tracing (optional)

`setup-sandbox.sh` configures MLflow automatically when an OCP token is available. For manual setup, see `overlays/mlflow/README.md`.

Access the RHOAI MLflow dashboard at the route exposed by OpenShift AI and navigate to the `openshell` workspace.

## Sandbox Security: Standard Policy

This demo uses a **standard** policy - a balanced tier for coding agents that allows inference, package registries, and read-only GitHub access while blocking direct AI APIs and arbitrary web browsing.

### Network Allowlisting

Unlike the strict policy (Demo 01), the standard tier opens access to package registries and code hosts that coding agents need:

```bash
# From inside the sandbox:
curl https://registry.npmjs.org/express    # -> HTTP 200 (npm allowed)
curl https://pypi.org/simple/requests/     # -> HTTP 200 (PyPI allowed)
curl https://api.anthropic.com             # -> HTTP 403 (direct AI APIs not needed)
curl https://example.com                   # -> HTTP 403 (not in policy)
```

### L7 Inspection: Read-Only Enforcement

GitHub is allowed but restricted to read-only access. The CONNECT proxy terminates TLS and inspects each HTTP request at Layer 7:

```bash
curl https://api.github.com/repos/NVIDIA/OpenShell    # -> HTTP 200 (GET allowed)
curl -X POST https://api.github.com/repos/.../issues  # -> HTTP 403 (POST blocked!)
```

The proxy returns a structured JSON error for blocked methods:

```json
{"error": "policy_denied", "detail": "POST not permitted by read-only policy"}
```

### Filesystem: Landlock Enforcement

Same Landlock rules as the strict tier - filesystem access is identical across all policy levels:

```bash
echo test > /workspace/test.txt    # OK (read-write path)
echo test > /tmp/test.txt          # OK (read-write path)
echo test > /etc/test.txt          # Permission denied (read-only)
echo test > /usr/test.txt          # Permission denied (read-only)
cat /etc/os-release                # OK (read-only allows reads)
```

### Comparing Tiers

Switch to strict to see the contrast (hot-reload, no restart needed):

```bash
openshell policy set --global --policy ../01-basic-openshell/config/policy-strict.yaml --yes
curl https://registry.npmjs.org/express    # -> HTTP 403 (was 200!)
```

### Run the Full Security Test

```bash
bash setup-sandbox.sh              # create sandbox with standard policy
bash test-sandbox-security.sh      # run all tests, see color-coded report
```

This runs network allowlisting, L7 inspection, Landlock, and process isolation tests.

## Teardown

Remove everything:

```bash
bash teardown.sh
```

This removes both the OpenShell and Keycloak namespaces.

## Troubleshooting

**"PermissionDenied" when accessing the gateway:**

The OIDC token does not have the required roles. Check that:
1. The user has `openshell-admin` or `openshell-user` role in Keycloak
2. The `rolesClaim` in Helm values matches Keycloak's token structure (`realm_access.roles`)

Decode your token to inspect it:
```bash
# Get the token (stored locally by openshell CLI)
openshell gateway login openshift 2>&1 | grep -i token
```

**"issuer mismatch" or token validation errors:**

The `iss` claim in the JWT must exactly match the `oidc.issuer` in the Helm values. Both must use the in-cluster Keycloak service hostname:
```
http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell
```

If you see mismatches, check `KC_HOSTNAME` on the Keycloak deployment.

**Self-signed certificate errors:**

If the cluster uses self-signed ingress certificates:

```bash
# Option 1: Use insecure mode
openshell gateway add "$GW_URL" --gateway-insecure ...

# Option 2: Extract and trust the ingress CA
oc -n openshift-ingress get secret router-certs-default \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ingress-ca.pem
export SSL_CERT_FILE=/tmp/ingress-ca.pem
```

**Keycloak pod not starting:**

Check the logs:
```bash
oc -n openshell-keycloak logs deployment/keycloak
```

Common issues:
- Realm JSON syntax error in the ConfigMap
- Resource limits too low (Keycloak needs at least 512Mi)

**Cannot reach Keycloak for CLI login:**

The OIDC issuer URL points to an in-cluster hostname. You need a port-forward for the CLI to reach it:
```bash
oc -n openshell-keycloak port-forward svc/keycloak 9090:80
```

## References

- [OpenShell Access Control](https://docs.nvidia.com/openshell/latest/kubernetes/access-control)
- [OpenShell on OpenShift](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
