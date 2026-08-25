#!/bin/bash
# Teardown Demo 7: Remove OpenShell, Gitea MCP server, and optionally Gitea.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/gitea.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

NAMESPACE="${NAMESPACE:-openshell-demo-hermes-mcp}"
DELETE_CRDS=""
DELETE_GITEA=""

for arg in "$@"; do
    case "$arg" in
        --crd)    DELETE_CRDS=true ;;
        --gitea)  DELETE_GITEA=true ;;
    esac
done

echo "============================================"
echo " Teardown Demo 7: Hermes + MCP Gateway"
echo "============================================"
echo ""

step "Delete OpenShell Helm release"
helm uninstall openshell --namespace "$NAMESPACE" 2>/dev/null || warn "Helm release not found"

step "Delete OpenShell Route and secrets"
oc -n "$NAMESPACE" delete route openshell-gw 2>/dev/null || true
oc -n "$NAMESPACE" delete secret openshell-jwt-keys 2>/dev/null || true
oc -n "$NAMESPACE" delete pvc openshell-data-openshell-0 2>/dev/null || true

step "Delete SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$NAMESPACE" 2>/dev/null || true

step "Delete OpenShell namespace"
oc delete ns "$NAMESPACE" 2>/dev/null || true

step "Remove Gitea MCP Server"
teardown_gitea_mcp_server

if [ "$DELETE_GITEA" = "true" ]; then
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

echo ""
info "Teardown complete."
echo ""
echo " Flags:"
echo "   --crd    also remove Agent Sandbox operator"
echo "   --gitea  also remove Gitea deployment"
