#!/bin/bash
# Demo 2: OpenCode + Keycloak OIDC on OpenShift
# Deploys Keycloak with local users, then OpenShell with OIDC authentication.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../common/functions.sh
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " Demo 2: OpenCode + Keycloak OIDC"
echo "============================================"
echo ""
echo " OpenShell namespace: $NAMESPACE"
echo " Keycloak namespace:  $KC_NAMESPACE"
echo ""

check_prereqs

# -- Phase 1: Keycloak --

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

# -- Phase 2: OpenShell with OIDC --

step "Phase 2: Deploy OpenShell with Keycloak OIDC"

install_agent_sandbox_operator
create_openshell_namespace "$NAMESPACE"
grant_privileged_scc "$NAMESPACE"

step "Create JWT signing secret"
create_jwt_secret "$NAMESPACE"

adopt_cluster_scoped_resources "$NAMESPACE"
step "Install OpenShell Helm chart with Keycloak OIDC"
# shellcheck disable=SC2086
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace "$NAMESPACE" \
    $VERSION_FLAG \
    -f "$SCRIPT_DIR/manifests/openshell/values-keycloak.yaml"

wait_for_rollout statefulset openshell "$NAMESPACE" 300

step "Expose gateway via Route"
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

# -- Summary --

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Gateway URL:   ${GW_PROTO}://$GW_ROUTE"
echo " Keycloak URL:  https://$KC_ROUTE"
echo " Keycloak admin: admin / admin"
echo ""
echo " Pre-configured users:"
echo "   admin@test / admin  (roles: openshell-admin, openshell-user)"
echo "   user@test  / user   (roles: openshell-user)"
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
echo "   3. Login:"
echo "      openshell gateway login openshift"
echo ""
echo "   4. Create a sandbox:"
echo "      openshell sandbox create --name test -- echo 'Hello from OpenShell!'"
echo ""
