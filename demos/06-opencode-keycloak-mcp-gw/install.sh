#!/bin/bash
# Demo 6: OpenCode/Claude Code + Keycloak OIDC + MCP Gateway on OpenShift
# Deploys Keycloak, Gitea, Gitea MCP server, registers with MCP Gateway,
# then deploys OpenShell with OIDC authentication.
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

OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 6: OpenCode/Claude Code + MCP Gateway"
echo "============================================"
echo ""
echo " OpenShell namespace: $OPENSHELL_NS"
echo " Keycloak namespace:  $KC_NAMESPACE"
echo " Gitea namespace:     $GITEA_NS"
echo " MCP Gateway NS:      $MCP_GW_NS"
echo " MCP Test NS:         $MCP_TEST_NS"
echo ""

check_prereqs

# -- Phase 1: Keycloak (for OpenShell OIDC) --

step "Phase 1: Deploy Keycloak"

info "Creating Keycloak namespace and resources..."
oc apply -f "$SCRIPT_DIR/manifests/keycloak/namespace.yaml"
oc apply -f "$SCRIPT_DIR/manifests/keycloak/realm-configmap.yaml"
oc apply -f "$SCRIPT_DIR/manifests/keycloak/deployment.yaml"
oc apply -f "$SCRIPT_DIR/manifests/keycloak/service.yaml"
oc apply -f "$SCRIPT_DIR/manifests/keycloak/route.yaml"

wait_for_rollout deployment keycloak "$KC_NAMESPACE" 180

KC_ROUTE=$(oc -n "$KC_NAMESPACE" get route keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
info "Keycloak admin console: https://$KC_ROUTE"

info "Verifying OIDC discovery endpoint..."
sleep 5
if curl -sk --max-time 10 "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration" | grep -q "issuer"; then
    info "OIDC discovery endpoint OK"
else
    warn "OIDC discovery endpoint not yet responding (Keycloak may still be importing realm)"
fi

# -- Phase 2: Gitea --

step "Phase 2: Deploy Gitea"

deploy_gitea
create_gitea_users
create_gitea_pats "$REPO_ROOT/.gitea-pats"
create_demo_repos

GITEA_HOST=$(_gitea_route)
info "Gitea URL: https://$GITEA_HOST"

# -- Phase 3: Gitea MCP Server --

step "Phase 3: Deploy Gitea MCP Server and register with MCP Gateway"

USER1_PAT=$(grep "^user1=" "$REPO_ROOT/.gitea-pats" | cut -d= -f2)
USER2_PAT=$(grep "^user2=" "$REPO_ROOT/.gitea-pats" | cut -d= -f2)

if [ -z "$USER1_PAT" ]; then
    error "user1 PAT not found in .gitea-pats"
    exit 1
fi

deploy_gitea_mcp_server "$GITEA_HOST" "$USER1_PAT"

# -- Phase 4: Update Keycloak MCP realm --

step "Phase 4: Update Keycloak MCP realm with Gitea tool roles"

update_keycloak_gitea_realm "$USER1_PAT" "$USER2_PAT"

# -- Phase 5: OpenShell with OIDC --

step "Phase 5: Deploy OpenShell with Keycloak OIDC"

install_agent_sandbox_operator
create_openshell_namespace "$OPENSHELL_NS"
grant_privileged_scc "$OPENSHELL_NS"

step "Create JWT signing secret"
create_jwt_secret "$OPENSHELL_NS"

adopt_cluster_scoped_resources "$OPENSHELL_NS"
step "Install OpenShell Helm chart with Keycloak OIDC"
# shellcheck disable=SC2086
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace "$OPENSHELL_NS" \
    $VERSION_FLAG \
    -f "$SCRIPT_DIR/manifests/openshell/values-keycloak.yaml"

wait_for_rollout statefulset openshell "$OPENSHELL_NS" 300

step "Expose gateway via Route"
oc -n "$OPENSHELL_NS" apply -f "$SCRIPT_DIR/manifests/openshell/route.yaml"
sleep 2
GW_ROUTE=$(oc -n "$OPENSHELL_NS" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

if [ "${ENABLE_TLS:-false}" = "true" ]; then
    step "Enable passthrough TLS (cert-manager)"
    APPS_DOMAIN=$(detect_apps_domain)
    setup_gateway_tls "$OPENSHELL_NS" "$APPS_DOMAIN"
    GW_ROUTE=$(oc -n "$OPENSHELL_NS" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
    GW_PROTO="https"
    GW_INSECURE_FLAG="--gateway-insecure"
else
    GW_PROTO="http"
    GW_INSECURE_FLAG=""
fi

MCP_GW_ROUTE=$(_mcp_gateway_route)
KC_MCP_ROUTE=$(_keycloak_mcp_route)

# -- Summary --

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Gateway URL:      ${GW_PROTO}://$GW_ROUTE"
echo " Keycloak URL:     https://$KC_ROUTE"
echo " Gitea URL:        https://$GITEA_HOST"
echo " MCP Gateway URL:  https://$MCP_GW_ROUTE"
echo " MCP Keycloak URL: https://$KC_MCP_ROUTE"
echo ""
echo " OpenShell Keycloak (admin / admin):"
echo "   admin@test / admin  (roles: openshell-admin, openshell-user)"
echo "   user@test  / user   (roles: openshell-user)"
echo ""
echo " MCP Gateway users (Keycloak mcp realm):"
echo "   user1 / user1  (full Gitea access)"
echo "   user2 / user2  (read-only Gitea access)"
echo ""
echo " Next steps:"
echo ""
echo "   1. Start Keycloak port-forward (needed for CLI login):"
echo "      oc -n $KC_NAMESPACE port-forward svc/keycloak 9090:80"
echo ""
echo "   2. Register gateway with OIDC:"
echo "      openshell gateway add ${GW_PROTO}://$GW_ROUTE $GW_INSECURE_FLAG \\"
echo "          --name openshift \\"
echo "          --oidc-issuer http://keycloak.$KC_NAMESPACE.svc.cluster.local/realms/openshell \\"
echo "          --oidc-client-id openshell-cli"
echo ""
echo "   3. Setup sandbox with MCP Gateway:"
echo "      bash setup-sandbox.sh --user user1 --agent opencode"
echo "      bash setup-sandbox.sh --user user2 --agent claude"
echo ""
