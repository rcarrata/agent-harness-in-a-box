#!/bin/bash
# Demo 7: Hermes Agent with MCP Gateway (Gitea tools) on OpenShell
# Deploys Gitea, MCP Gateway integration, and OpenShell gateway (standalone mode).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../common/functions.sh
source "$REPO_ROOT/common/functions.sh"
# shellcheck source=../../common/gitea.sh
source "$REPO_ROOT/common/gitea.sh"
# shellcheck source=../../common/mcp-gateway.sh
source "$REPO_ROOT/common/mcp-gateway.sh"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

NAMESPACE="${NAMESPACE:-openshell-demo-hermes-mcp}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 7: Hermes Agent + MCP Gateway"
echo "============================================"
echo ""
echo " Namespace: $NAMESPACE"
echo ""

check_prereqs

# Step 1: Deploy Gitea
step "Step 1/10: Deploy Gitea"
deploy_gitea

# Step 2: Create Gitea users and PATs
step "Step 2/10: Create Gitea users"
create_gitea_users

PATS_FILE="${REPO_ROOT}/.gitea-pats"
step "Step 3/10: Create Gitea PATs"
create_gitea_pats "$PATS_FILE"

# Step 3: Create demo repos
step "Step 4/10: Create demo repositories"
create_demo_repos

# Step 4: Deploy Gitea MCP Server
step "Step 5/10: Deploy Gitea MCP Server"
GITEA_HOST=$(_gitea_route)
USER1_PAT=$(grep "^user1=" "$PATS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
if [ -n "$USER1_PAT" ]; then
    deploy_gitea_mcp_server "$GITEA_HOST" "$USER1_PAT"
else
    warn "No user1 PAT found - Gitea MCP server may already be deployed"
fi

# Step 5: Update Keycloak realm
step "Step 6/10: Update Keycloak realm"
USER2_PAT=$(grep "^user2=" "$PATS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
update_keycloak_gitea_realm "${USER1_PAT:-}" "${USER2_PAT:-}"

# Step 6: Agent Sandbox operator
install_agent_sandbox_operator

# Step 7: Namespace
create_openshell_namespace "$NAMESPACE"

# Step 8: SCC
grant_privileged_scc "$NAMESPACE"

# Step 9: JWT signing secret
step "Step 7/10: Create JWT signing secret"
create_jwt_secret "$NAMESPACE"

# Step 10: Helm install
adopt_cluster_scoped_resources "$NAMESPACE"
step "Step 8/10: Install OpenShell Helm chart"
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

# Wait
step "Step 9/10: Wait for gateway rollout"
wait_for_rollout statefulset openshell "$NAMESPACE" 300

# Route
step "Step 10/10: Expose gateway via Route"
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
echo " Gateway + MCP Gateway deployed!"
echo "============================================"
echo ""
echo " Gateway URL: ${GW_PROTO}://$GW_ROUTE"
echo " MCP Gateway: $(_mcp_gateway_url)"
echo " Keycloak:    https://$(_keycloak_mcp_route)"
echo " Gitea:       $(_gitea_url)"
echo ""
echo " Next steps:"
echo ""
echo "   1. Register gateway with CLI:"
echo "      openshell gateway add ${GW_PROTO}://$GW_ROUTE $GW_INSECURE_FLAG --local --name openshift"
echo ""
echo "   2. Create Hermes sandbox (read-only user by default):"
echo "      bash $SCRIPT_DIR/setup-sandbox.sh --user user2"
echo ""
echo "   3. Or with full access:"
echo "      bash $SCRIPT_DIR/setup-sandbox.sh --user user1"
echo ""
