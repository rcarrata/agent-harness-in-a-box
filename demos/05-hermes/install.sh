#!/bin/bash
# Demo 5: Hermes Agent on OpenShell
# Deploys OpenShell gateway with no authentication (standalone mode).
# Skip this if Demo 2 infrastructure is already deployed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../common/functions.sh
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-demo-hermes}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 5: Hermes Agent on OpenShell"
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

# Ensure ClusterRoleBinding includes this namespace (Helm chart uses a global
# name so a prior install in another namespace may own the binding).
EXISTING_NS=$(oc get clusterrolebinding openshell-node-reader -o jsonpath='{.subjects[0].namespace}' 2>/dev/null || true)
if [ -n "$EXISTING_NS" ] && [ "$EXISTING_NS" != "$NAMESPACE" ]; then
    info "Patching ClusterRoleBinding to include $NAMESPACE (currently bound to $EXISTING_NS)"
    oc patch clusterrolebinding openshell-node-reader --type='json' -p="[
      {\"op\": \"add\", \"path\": \"/subjects/-\", \"value\": {\"kind\": \"ServiceAccount\", \"name\": \"openshell\", \"namespace\": \"$NAMESPACE\"}}
    ]"
fi

# Step 6: Wait
step "Step 6/7: Wait for gateway rollout"
wait_for_rollout statefulset openshell "$NAMESPACE" 300

# Step 7: Route
step "Step 7/7: Expose gateway via Route"
oc -n "$NAMESPACE" apply -f "$SCRIPT_DIR/manifests/openshell/route.yaml"
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
echo " Gateway deployed!"
echo "============================================"
echo ""
echo " Gateway URL: ${GW_PROTO}://$GW_ROUTE"
echo ""
echo " Next steps:"
echo ""
echo "   1. Register gateway with CLI:"
echo "      openshell gateway add ${GW_PROTO}://$GW_ROUTE $GW_INSECURE_FLAG --local --name openshift"
echo ""
echo "   2. Create Hermes sandbox:"
echo "      bash $SCRIPT_DIR/setup-sandbox.sh"
echo ""
