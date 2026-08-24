#!/bin/bash
# Demo 1: Basic OpenShell on OpenShift
# Installs OpenShell gateway with no authentication - a minimal playground.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../common/functions.sh
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 1: Basic OpenShell on OpenShift"
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
step "Step 4/7: Create JWT signing secret"
create_jwt_secret "$NAMESPACE"

# Step 5: Helm install
adopt_cluster_scoped_resources "$NAMESPACE"
step "Step 5/7: Install OpenShell Helm chart"
# shellcheck disable=SC2086
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace "$NAMESPACE" \
    $VERSION_FLAG \
    --set pkiInitJob.enabled=false \
    --set server.disableTls=true \
    --set server.auth.allowUnauthenticatedUsers=true \
    --set podSecurityContext.fsGroup=null \
    --set securityContext.runAsUser=null

# Step 6: Wait
step "Step 6/7: Wait for gateway rollout"
wait_for_rollout statefulset openshell "$NAMESPACE" 300

# Step 7: Route
step "Step 7/7: Expose gateway via Route"
oc -n "$NAMESPACE" apply -f "$SCRIPT_DIR/manifests/route.yaml"
sleep 2
GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

if [ "${ENABLE_TLS:-false}" = "true" ]; then
    step "Enable passthrough TLS (cert-manager)"
    APPS_DOMAIN=$(detect_apps_domain)
    setup_gateway_tls "$NAMESPACE" "$APPS_DOMAIN"
    GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
    GW_PROTO="https"
    GW_INSECURE_FLAG="--gateway-insecure"
else
    GW_PROTO="http"
    GW_INSECURE_FLAG=""
fi

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Gateway URL: ${GW_PROTO}://$GW_ROUTE"
echo ""
echo " Next steps:"
echo ""
echo "   1. Register gateway with CLI:"
echo "      openshell gateway add ${GW_PROTO}://$GW_ROUTE $GW_INSECURE_FLAG --local --name openshift"
echo ""
echo "   2. Check status:"
echo "      openshell status"
echo ""
echo "   3. Create your first sandbox:"
echo "      openshell sandbox create --name test -- echo 'Hello from OpenShell!'"
echo ""
echo "   4. Connect interactively:"
echo "      openshell sandbox create --name my-sandbox"
echo "      openshell sandbox connect my-sandbox"
echo ""
