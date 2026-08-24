#!/bin/bash
# Demo 4: Escape the Shell - Interactive CTF
# Installs OpenShell gateway + CTF web UI on OpenShift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../common/functions.sh
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-ctf}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 4: Escape the Shell - CTF"
echo "============================================"
echo ""
echo " Namespace: $NAMESPACE"
echo ""

check_prereqs

# Step 1: Agent Sandbox operator
install_agent_sandbox_operator

# Step 2: Namespace
create_openshell_namespace "$NAMESPACE"

# Step 3: SCC
grant_privileged_scc "$NAMESPACE"

# Step 4: JWT signing secret
step "Step 4/10: Create JWT signing secret"
create_jwt_secret "$NAMESPACE"

# Step 5: Helm install
adopt_cluster_scoped_resources "$NAMESPACE"
step "Step 5/10: Install OpenShell Helm chart"
# shellcheck disable=SC2086
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace "$NAMESPACE" \
    $VERSION_FLAG \
    --set pkiInitJob.enabled=false \
    --set server.disableTls=true \
    --set server.auth.allowUnauthenticatedUsers=true \
    --set podSecurityContext.fsGroup=null \
    --set securityContext.runAsUser=null

# Step 6: Wait for gateway
step "Step 6/10: Wait for gateway rollout"
wait_for_rollout statefulset openshell "$NAMESPACE" 300

# Step 7: Gateway route
step "Step 7/10: Expose gateway via Route"
oc -n "$NAMESPACE" apply -f "$SCRIPT_DIR/manifests/route.yaml"
sleep 2

# Step 8: Create CTF policy ConfigMap
step "Step 8/10: Create CTF policy ConfigMap"
oc -n "$NAMESPACE" delete configmap ctf-policies 2>/dev/null || true
oc -n "$NAMESPACE" create configmap ctf-policies \
    --from-file="$SCRIPT_DIR/config/policy-ctf-strict.yaml" \
    --from-file="$SCRIPT_DIR/config/policy-ctf-permissive.yaml"

# Step 9: Build CTF UI image on-cluster
step "Step 9/10: Build CTF UI image"
if ! oc -n "$NAMESPACE" get buildconfig ctf-ui &>/dev/null; then
    ln -sf Containerfile "$SCRIPT_DIR/ctf-ui/Dockerfile"
    oc -n "$NAMESPACE" new-build --binary --name=ctf-ui --strategy=docker
fi
oc -n "$NAMESPACE" start-build ctf-ui --from-dir="$SCRIPT_DIR/ctf-ui/" --follow

# Step 10: Deploy CTF UI
step "Step 10/10: Deploy CTF UI"
CTF_UI_IMAGE="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/ctf-ui:latest"
export CTF_UI_IMAGE NAMESPACE
envsubst < "$SCRIPT_DIR/manifests/ctf-ui-deploy.yaml" | oc -n "$NAMESPACE" apply -f -
wait_for_rollout deployment ctf-ui "$NAMESPACE" 120

GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
CTF_ROUTE=$(oc -n "$NAMESPACE" get route ctf-ui -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

if [ "${ENABLE_TLS:-false}" = "true" ]; then
    step "Enable passthrough TLS (cert-manager)"
    APPS_DOMAIN=$(detect_apps_domain)
    setup_gateway_tls "$NAMESPACE" "$APPS_DOMAIN"
    GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
    GW_PROTO="https"
    oc -n "$NAMESPACE" set env deployment/ctf-ui \
        OPENSHELL_GATEWAY_ENDPOINT="https://openshell.${NAMESPACE}.svc.cluster.local:8080" \
        OPENSHELL_GATEWAY_INSECURE=true
    wait_for_rollout deployment ctf-ui "$NAMESPACE" 60
else
    GW_PROTO="http"
fi

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Gateway URL:  ${GW_PROTO}://$GW_ROUTE"
echo " CTF UI URL:   https://$CTF_ROUTE"
echo ""
echo " Next steps:"
echo ""
echo "   1. Create the CTF sandbox:"
echo "      bash $SCRIPT_DIR/setup-sandbox.sh"
echo ""
echo "   2. Open the CTF UI in your browser:"
echo "      https://$CTF_ROUTE"
echo ""
echo "   3. Capture all 5 flags!"
echo ""
