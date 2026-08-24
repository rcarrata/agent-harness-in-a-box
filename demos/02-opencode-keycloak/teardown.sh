#!/bin/bash
# Teardown Demo 2: Remove OpenShell, Keycloak, and all associated resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
DELETE_CRDS="${1:-}"

echo "============================================"
echo " Teardown Demo 2: OpenCode + Keycloak"
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

step "Delete Keycloak namespace"
oc delete ns "$KC_NAMESPACE" 2>/dev/null || true

if [ "$DELETE_CRDS" = "--crd" ]; then
    step "Delete Agent Sandbox operator"
    oc -n openshift-operators delete subscription agent-sandbox-operator 2>/dev/null || true
    local csv
    csv=$(oc -n openshift-operators get csv -o name 2>/dev/null | grep agent-sandbox || true)
    if [ -n "$csv" ]; then
        oc -n openshift-operators delete "$csv" 2>/dev/null || true
    fi
fi

echo ""
info "Teardown complete."
