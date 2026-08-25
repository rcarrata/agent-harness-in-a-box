#!/bin/bash
# Teardown Demo 6: Remove OpenShell, Keycloak, Gitea MCP server, and optionally Gitea.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/gitea.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
DELETE_CRDS=""
DELETE_GITEA=""

for arg in "$@"; do
    case "$arg" in
        --crd) DELETE_CRDS="true" ;;
        --gitea) DELETE_GITEA="true" ;;
    esac
done

echo "============================================"
echo " Teardown Demo 6: OpenCode/Claude + MCP GW"
echo "============================================"
echo ""

step "Delete sandboxes"
openshell sandbox delete opencode-mcp-demo 2>/dev/null || true
openshell sandbox delete claude-mcp-demo 2>/dev/null || true

step "Delete OpenShell Helm release"
helm uninstall openshell --namespace "$OPENSHELL_NS" 2>/dev/null || warn "Helm release not found"

step "Delete OpenShell Route and secrets"
oc -n "$OPENSHELL_NS" delete route openshell-gw 2>/dev/null || true
oc -n "$OPENSHELL_NS" delete secret openshell-jwt-keys 2>/dev/null || true
oc -n "$OPENSHELL_NS" delete pvc openshell-data-openshell-0 2>/dev/null || true

step "Delete SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$OPENSHELL_NS" 2>/dev/null || true

step "Delete OpenShell namespace"
oc delete ns "$OPENSHELL_NS" 2>/dev/null || true

step "Delete Keycloak namespace"
oc delete ns "$KC_NAMESPACE" 2>/dev/null || true

step "Teardown Gitea MCP Server"
teardown_gitea_mcp_server

if [ "$DELETE_GITEA" = "true" ]; then
    step "Teardown Gitea"
    teardown_gitea
fi

if [ "$DELETE_CRDS" = "true" ]; then
    step "Delete Agent Sandbox operator"
    oc -n openshift-operators delete subscription agent-sandbox-operator 2>/dev/null || true
    csv=$(oc -n openshift-operators get csv -o name 2>/dev/null | grep agent-sandbox || true)
    if [ -n "$csv" ]; then
        oc -n openshift-operators delete "$csv" 2>/dev/null || true
    fi
fi

# Clean up local PATs file
rm -f "$REPO_ROOT/.gitea-pats"

echo ""
info "Teardown complete."
